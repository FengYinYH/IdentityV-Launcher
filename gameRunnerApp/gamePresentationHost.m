/* Included by the existing ARM launcher. This early, non-AppKit command only
 * prepares user-owned metadata; callers already verified the selected runtime.
 * Dock names these processes from bundleURL's basename, hence the real localized
 * .app directory. Never copy/sign the vendor loader or register a global app. */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>

static NSError *IDVHostError(NSString *reason) {
    return [NSError errorWithDomain:@"IdentityVGameHost" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}];
}
static BOOL IDVHostRealDirectory(NSURL *url, BOOL create, NSError **error) {
    struct stat state;
    if (lstat(url.fileSystemRepresentation, &state) && create) {
        if (mkdir(url.fileSystemRepresentation, 0700) && errno != EEXIST) {
            if (error) *error = IDVHostError(@"host directory is unavailable"); return NO;
        }
    }
    if (lstat(url.fileSystemRepresentation, &state) || !S_ISDIR(state.st_mode) || state.st_uid != getuid() ||
        !(state.st_mode & S_IWUSR)) {
        if (error) *error = IDVHostError(@"host directory must be a writable, owned real directory"); return NO;
    }
    return YES;
}
static BOOL IDVHostMatches(NSURL *app, NSDictionary *expected, NSURL *loader) {
    if (!IDVHostRealDirectory(app, NO, NULL)) return NO;
    NSURL *contents = [app URLByAppendingPathComponent:@"Contents" isDirectory:YES];
    NSURL *macos = [contents URLByAppendingPathComponent:@"MacOS" isDirectory:YES];
    if (!IDVHostRealDirectory(contents, NO, NULL) || !IDVHostRealDirectory(macos, NO, NULL)) return NO;
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSArray *entry in @[@[app, @[@"Contents"]], @[contents, @[@"Info.plist", @"MacOS"]], @[macos, @[@"wine"]]]) {
        NSArray *names = [files contentsOfDirectoryAtPath:[entry[0] path] error:NULL];
        if (!names || ![[NSSet setWithArray:names] isEqual:[NSSet setWithArray:entry[1]]]) return NO;
    }
    NSURL *plist = [contents URLByAppendingPathComponent:@"Info.plist"];
    NSURL *executable = [macos URLByAppendingPathComponent:@"wine"];
    struct stat state;
    if (lstat(plist.fileSystemRepresentation, &state) || !S_ISREG(state.st_mode) || state.st_uid != getuid()) return NO;
    NSDictionary *actual = [NSDictionary dictionaryWithContentsOfURL:plist];
    if (![actual isEqualToDictionary:expected] || lstat(executable.fileSystemRepresentation, &state) || (!S_ISLNK(state.st_mode) || state.st_uid != getuid())) return NO;
    NSString *destination = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:executable.path error:NULL];
    return [destination isEqualToString:loader.path];
}
static NSString *IDVPrepareGameHost(NSString *loaderPath, NSString *cachePath, NSString *product,
                                   NSString *name, NSString *profile, NSError **error) {
    if (geteuid() == 0 || ![profile isEqualToString:@"codeweavers-wine-release-dxmt"] ||
        (![product isEqualToString:@"mainland"] && ![product isEqualToString:@"global"]) ||
        (![name isEqualToString:@"第五人格"] && ![name isEqualToString:@"Identity V"]) ||
        !loaderPath.isAbsolutePath || !cachePath.isAbsolutePath) {
        if (error) *error = IDVHostError(@"unsupported game host profile or arguments"); return nil;
    }
    NSURL *loader = [NSURL fileURLWithPath:loaderPath].URLByResolvingSymlinksInPath;
    struct stat state;
    if (lstat(loader.fileSystemRepresentation, &state) || !S_ISREG(state.st_mode) || access(loader.fileSystemRepresentation, X_OK)) {
        if (error) *error = IDVHostError(@"verified loader is unavailable"); return nil;
    }
    // Public API explicitly supports unbundled Mach-O's embedded Info section.
    NSDictionary *original = CFBridgingRelease(CFBundleCopyInfoDictionaryForURL((__bridge CFURLRef)loader));
    if (![original[@"CFBundleIdentifier"] isEqual:@"com.codeweavers.CrossOver.wineloader"] ||
        ![original[@"CFBundlePackageType"] isEqual:@"APPL"]) {
        if (error) *error = IDVHostError(@"loader metadata is outside the supported profile"); return nil;
    }
    NSMutableDictionary *info = [original mutableCopy];
    info[@"CFBundleName"] = name; info[@"CFBundleDisplayName"] = name;
    info[@"CFBundleExecutable"] = @"wine";
    info[@"LSUIElement"] = @YES; info[@"LSApplicationCategoryType"] = @"public.app-category.games";
    info[@"LSSupportsGameMode"] = @YES; info[@"NSHighResolutionCapable"] = @YES;
    if (!info[@"LSMinimumSystemVersion"]) info[@"LSMinimumSystemVersion"] = @"15.0";
    if (![info[@"NSMicrophoneUsageDescription"] isKindOfClass:NSString.class] || ![info[@"NSMicrophoneUsageDescription"] length]) info[@"NSMicrophoneUsageDescription"] = [name isEqual:@"Identity V"] ?
        @"Identity V uses the microphone for in-game voice chat." : @"第五人格使用麦克风进行游戏内语音交流。";
    info[@"IdentityVGameHostSchemaVersion"] = @1;
    info[@"IdentityVGameHostLoader"] = loader.path;
    NSData *metadata = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!metadata) return nil;
    // Immutable generations handle metadata/runtime changes without editing an
    // active host or removing user files. The basename itself stays localized.
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(metadata.bytes, (CC_LONG)metadata.length, digest);
    NSMutableString *generation = [NSMutableString string];
    for (int index = 0; index < 16; index++) [generation appendFormat:@"%02x", digest[index]];
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:cachePath isDirectory:YES].URLByStandardizingPath;
    // Cache aliases are not runtime aliases: never follow an existing link
    // into another user's/app's tree. An unavailable/relocated cache simply
    // leaves launch on the original path. Engine aliases were canonicalized
    // separately after the runner's runtime verification.
    for (NSURL *ancestor = root; ![ancestor.path isEqual:@"/"]; ancestor = ancestor.URLByDeletingLastPathComponent) {
        if (!lstat(ancestor.fileSystemRepresentation, &state) && S_ISLNK(state.st_mode)) {
            if (error) *error = IDVHostError(@"host cache contains a symbolic-link ancestor"); return nil;
        }
    }
    if (![files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error] ||
        !IDVHostRealDirectory(root, NO, error)) return nil;
    root = root.URLByResolvingSymlinksInPath;
    for (NSString *component in @[@"v1", product, generation]) {
        root = [root URLByAppendingPathComponent:component isDirectory:YES];
        if (!IDVHostRealDirectory(root, YES, error)) return nil;
    }
    NSURL *app = [root URLByAppendingPathComponent:[name stringByAppendingString:@".app"] isDirectory:YES];
    if (IDVHostMatches(app, info, loader)) return [[app URLByAppendingPathComponent:@"Contents/MacOS/wine"] path];
    if (!lstat(app.fileSystemRepresentation, &state)) {
        if (error) *error = IDVHostError(@"existing host does not match owned metadata; left untouched"); return nil;
    }
    NSURL *stage = [root URLByAppendingPathComponent:[@".identityv-host-stage-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (mkdir(stage.fileSystemRepresentation, 0700)) { if (error) *error = IDVHostError(@"cannot stage game host"); return nil; }
    NSURL *contents = [stage URLByAppendingPathComponent:@"Contents" isDirectory:YES];
    NSURL *macos = [contents URLByAppendingPathComponent:@"MacOS" isDirectory:YES];
    BOOL ready = IDVHostRealDirectory(contents, YES, error) && IDVHostRealDirectory(macos, YES, error) &&
        [metadata writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] options:NSDataWritingAtomic error:error] &&
        [files createSymbolicLinkAtPath:[[macos URLByAppendingPathComponent:@"wine"] path] withDestinationPath:loader.path error:error];
    BOOL moved = ready && [files moveItemAtURL:stage toURL:app error:error];
    BOOL valid = (moved || ready) && IDVHostMatches(app, info, loader); // Concurrent identical winner is valid.
    // Only our exclusive UUID staging directory is eligible for cleanup. Never
    // replace/delete an existing host, foreign object or followed symbolic link.
    if (!moved && [stage.URLByResolvingSymlinksInPath.URLByDeletingLastPathComponent isEqual:root] &&
        [stage.lastPathComponent hasPrefix:@".identityv-host-stage-"]) [files removeItemAtURL:stage error:NULL];
    if (!valid) { if (error && !*error) *error = IDVHostError(@"game host could not be published"); return nil; }
    return [[app URLByAppendingPathComponent:@"Contents/MacOS/wine"] path];
}
static int IDVGameHostCommandMain(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 7) { fprintf(stderr, "IdentityV game host: invalid internal arguments\n"); return 64; }
        NSError *error = nil;
        NSString *result = IDVPrepareGameHost([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]],
            [NSString stringWithUTF8String:argv[4]], [NSString stringWithUTF8String:argv[5]], [NSString stringWithUTF8String:argv[6]], &error);
        if (!result) { fprintf(stderr, "IdentityV game host: %s; using original loader\n", error.localizedDescription.UTF8String); return 1; }
        puts(result.fileSystemRepresentation); return 0;
    }
}
