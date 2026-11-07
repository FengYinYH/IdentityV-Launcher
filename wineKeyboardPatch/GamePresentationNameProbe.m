/* The real helper, with its constructor disabled. No input/audio installation,
 * activation or visible windows. One hidden window checks actual CG owner data. */
#define IDV_GAME_PRESENTATION_PROBE 1
#include "IdentityVCommandGraveForwarder.m"
#include "GamePresentationLegacyNameAdapter.m"
#include <unistd.h>

static void *missingSymbol(const char *name) { (void)name; return NULL; }

// Exercise the actual AppKit adapter/class check without loading Wine or input.
@interface WineApplication : NSApplication @end
@implementation WineApplication @end

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *desired = [NSString stringWithUTF8String:argv[1]];
        if (![desired isEqualToString:@"第五人格"] && ![desired isEqualToString:@"Identity V"]) return 3;
        IDVInstallGamePresentation(); // Must work before NSApplication exists.
        if (method_getImplementation(class_getInstanceMethod(NSApplication.class, @selector(setApplicationIconImage:))) != (IMP)IDVSetApplicationIcon) return 4;
        NSApplication *app = [WineApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [app finishLaunching];
        NSBitmapImageRep *iconRep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:32 pixelsHigh:32
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bitmapFormat:0 bytesPerRow:128 bitsPerPixel:32];
        for (NSInteger y = 0; y < 32; y++) for (NSInteger x = 0; x < 32; x++) {
            NSUInteger pixel[4] = {60, 80, 100, 255}; [iconRep setPixel:pixel atX:x y:y];
        }
        NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)]; [icon addRepresentation:iconRep];
        // AppKit's getter may render a 2x floating-point/color-managed image.
        // Compare the same native path before/after, not raw device-RGB bytes.
        IDVOriginalSetIcon(app, @selector(setApplicationIconImage:), icon);
        CGImageRef baselineIcon = [app.applicationIconImage CGImageForProposedRect:NULL context:nil hints:nil];
        NSBitmapImageRep *baselineRep = baselineIcon ? [[NSBitmapImageRep alloc] initWithCGImage:baselineIcon] : nil;
        NSColor *baselineCenter = [[baselineRep colorAtX:baselineRep.pixelsWide / 2 y:baselineRep.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        [app setApplicationIconImage:icon];
        CGImageRef nativeIcon = [app.applicationIconImage CGImageForProposedRect:NULL context:nil hints:nil];
        NSBitmapImageRep *nativeRep = nativeIcon ? [[NSBitmapImageRep alloc] initWithCGImage:nativeIcon] : nil;
        NSColor *corner = [[nativeRep colorAtX:0 y:0] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        NSColor *center = [[nativeRep colorAtX:nativeRep.pixelsWide / 2 y:nativeRep.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        BOOL iconVerified = nativeRep && baselineRep && corner.alphaComponent < 0.01 &&
            fabs(center.redComponent - baselineCenter.redComponent) <= 1.5 / 255 &&
            fabs(center.greenComponent - baselineCenter.greenComponent) <= 1.5 / 255 &&
            fabs(center.blueComponent - baselineCenter.blueComponent) <= 1.5 / 255 && center.alphaComponent > 0.99;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(10, 10, 100, 100)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        NSInteger number = window.windowNumber;
        NSString *before = [NSRunningApplication runningApplicationWithProcessIdentifier:getpid()].localizedName ?: @"";
        setenv("IDENTITYV_GAME_DISPLAY_NAME", argv[1], 1);
        configureGameDisplayName();
        BOOL absent = IDVRegisterSystemName(desired, missingSymbol);
        BOOL changed = IDVRegisterSystemName(desired, IDVLookupLSSymbol);
        NSWindow *laterWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(20, 20, 100, 100)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        for (int index = 0; index < 5; index++) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)number));
        NSString *owner = windows.count ? windows[0][(id)kCGWindowOwnerName] : @"";
        NSDictionary *result = @{@"pid": @(getpid()), @"before": before, @"desired": desired,
            @"missingSymbolsNoop": @(!absent), @"statusSucceeded": @(changed), @"nativeIconMaskVerified": @(iconVerified), @"postLaunchPreloaderAbsent": @(getenv("WINEPRELOADERAPPNAME") == NULL), @"owner": owner ?: @"",
            @"nativeIconSize": @[@(nativeRep.pixelsWide), @(nativeRep.pixelsHigh)], @"nativeIconFormat": @(nativeRep.bitmapFormat),
            @"nativeCenter": @[@(center.redComponent), @(center.greenComponent), @(center.blueComponent), @(center.alphaComponent)],
            @"nativeCornerAlpha": @(corner.alphaComponent),
            @"active": @([NSRunningApplication currentApplication].isActive), @"visible": @(window.isVisible || laterWindow.isVisible),
            @"windowNumberBefore": @(number), @"windowNumberAfter": @(laterWindow.windowNumber)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
        for (int index = 0; index < 50; index++) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        return changed && !absent && iconVerified && !window.isVisible && ![NSRunningApplication currentApplication].isActive ? 0 : 1;
    }
}
