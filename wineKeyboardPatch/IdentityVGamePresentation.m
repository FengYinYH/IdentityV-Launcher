/* Included in the existing AppKit-linked final-Wine helper, not a new DSO.
 * Keep presentation separate from keyboard/input policy. See gamePresentation.md
 * for the exact CW26.1 lifecycle and the self-process LaunchServices boundary. */
#import <objc/runtime.h>
#include <dlfcn.h>
#include <float.h>

static BOOL IDVHasGameArgument(NSArray<NSString *> *arguments)
{
    for (NSString *argument in arguments) {
        NSString *path = [argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if ([path.lastPathComponent caseInsensitiveCompare:@"dwrg.exe"] == NSOrderedSame) return YES;
    }
    return NO;
}

/* Audit is opt-in, bounded and contains geometry/state only: never titles,
 * window text, input events or screen/image contents. Four rows are reserved
 * for terminal reasons so noisy initialization cannot hide cancellation. */
static BOOL IDVPresentationAuditEnabled(void)
{
    const char *value = getenv("IDENTITYV_PRESENTATION_AUDIT");
    return value && !strcmp(value, "1");
}
static void IDVPresentationAudit(NSString *reason, NSWindow *window, NSDictionary *extra)
{
    static NSUInteger rows, nextWindow;
    static NSMapTable *identifiers;
    static NSMutableSet *seen;
    if (!IDVPresentationAuditEnabled() || rows >= 32 ||
        (rows >= 28 && ![reason hasPrefix:@"finish"])) return;
    if (!identifiers) { identifiers = [NSMapTable weakToStrongObjectsMapTable]; seen = [NSMutableSet set]; }
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
    entry[@"reason"] = reason;
    if (window) {
        NSNumber *identifier = [identifiers objectForKey:window];
        if (!identifier) { identifier = @(++nextWindow); [identifiers setObject:identifier forKey:window]; }
        entry[@"window"] = identifier;
        entry[@"class"] = NSStringFromClass(window.class);
        if ([window isKindOfClass:NSWindow.class]) {
            entry[@"frame"] = NSStringFromRect(window.frame);
            entry[@"content"] = NSStringFromRect([window contentRectForFrameRect:window.frame]);
            entry[@"viewFrame"] = NSStringFromRect(window.contentView.frame);
            entry[@"viewBounds"] = NSStringFromRect(window.contentView.bounds);
            entry[@"backing"] = NSStringFromRect([window.contentView convertRectToBacking:window.contentView.bounds]);
            entry[@"scale"] = @(window.backingScaleFactor);
            entry[@"visible"] = @(window.isVisible); entry[@"minimized"] = @(window.isMiniaturized);
            entry[@"style"] = @(window.styleMask); entry[@"level"] = @(window.level);
            entry[@"parent"] = @(window.parentWindow != nil); entry[@"sheet"] = @(window.sheetParent != nil);
            entry[@"liveResize"] = @(window.inLiveResize);
            entry[@"visibleFrame"] = NSStringFromRect(window.screen.visibleFrame);
        }
    }
    NSString *fingerprint = entry.description;
    if ([seen containsObject:fingerprint]) return;
    [seen addObject:fingerprint];
    entry[@"row"] = @(++rows); entry[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime);
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:NULL];
    if (data) fprintf(stderr, "IdentityV presentation audit: %s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

/* Draw at each original representation's pixel dimensions. No content crop,
 * new artwork, border, shadow, inset or enlargement: only alpha at the rounded
 * rectangle boundary changes. Already-masked objects are not masked twice. */
static char IDVRoundedIconKey;
static NSImage *IDVRoundedGameIcon(NSImage *source)
{
    if (!source || objc_getAssociatedObject(source, &IDVRoundedIconKey)) return source;
    NSImage *result = [[NSImage alloc] initWithSize:source.size];
    NSArray<NSImageRep *> *representations = source.representations;
    for (NSImageRep *representation in representations) {
        if (![representation isKindOfClass:[NSBitmapImageRep class]]) continue;
        CGImageRef original = [(NSBitmapImageRep *)representation CGImage];
        size_t width = CGImageGetWidth(original), height = CGImageGetHeight(original);
        if (!width || !height || width > 4096 || height > 4096) continue;
        CGColorSpaceRef space = CGImageGetColorSpace(original);
        CGColorSpaceRef fallback = NULL;
        if (!space || CGColorSpaceGetModel(space) != kCGColorSpaceModelRGB) space = fallback = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (fallback) CGColorSpaceRelease(fallback);
        if (!context) continue;
        CGRect rect = CGRectMake(0, 0, width, height);
        CGFloat radius = MIN(width, height) * 0.20;
        CGPathRef mask = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
        CGContextAddPath(context, mask);
        CGContextClip(context);
        CGContextSetInterpolationQuality(context, kCGInterpolationNone);
        CGContextDrawImage(context, rect, original);
        CGImageRef masked = CGBitmapContextCreateImage(context);
        if (masked) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:masked];
            rep.size = representation.size;
            [result addRepresentation:rep];
            CGImageRelease(masked);
        }
        CGPathRelease(mask);
        CGContextRelease(context);
    }
    if (!result.representations.count) return source;
    objc_setAssociatedObject(result, &IDVRoundedIconKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

/* AppKit coordinates are logical, bottom-up points. Never resize the content
 * or turn 1920x1080 backing pixels into 1920x1080 logical points. Oversized
 * windows align their title/traffic lights with visibleFrame's top-left. */
static NSPoint IDVCenteredGameOrigin(NSRect frame, NSRect visible)
{
    CGFloat x = NSMidX(visible) - frame.size.width / 2;
    CGFloat y = NSMidY(visible) - frame.size.height / 2;
    if (frame.size.width > visible.size.width) x = NSMinX(visible);
    else x = MAX(NSMinX(visible), MIN(x, NSMaxX(visible) - frame.size.width));
    if (frame.size.height > visible.size.height) y = NSMaxY(visible) - frame.size.height;
    else y = MAX(NSMinY(visible), MIN(y, NSMaxY(visible) - frame.size.height));
    return NSMakePoint(round(x), round(y));
}

@interface IDVGamePresentationController : NSObject
@property(nonatomic, weak) NSWindow *candidate;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) NSTimeInterval totalDeadline;
@property(nonatomic) NSRect settlingFrame;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) BOOL finished;
@property(nonatomic, strong) NSMutableArray *startupObservers;
- (BOOL)isGameWindow:(NSWindow *)window;
- (void)observeWindow:(NSWindow *)window now:(NSTimeInterval)now;
- (void)settleWindow:(NSWindow *)window revision:(NSUInteger)revision now:(NSTimeInterval)now;
- (void)finishStartup;
- (void)finishStartupForReason:(NSString *)reason;
- (void)install;
@end

@implementation IDVGamePresentationController
- (BOOL)isGameWindow:(NSWindow *)window
{
    Class wine = NSClassFromString(@"WineWindow");
    if (!wine || ![window isKindOfClass:wine] || !window.isVisible || window.isMiniaturized ||
        window.parentWindow || window.sheetParent || window.level != NSNormalWindowLevel ||
        !(window.styleMask & NSWindowStyleMaskTitled) || (window.styleMask & NSWindowStyleMaskUtilityWindow)) return NO;
    NSRect content = [window contentRectForFrameRect:window.frame];
    return content.size.width >= 600 && content.size.height >= 300;
}
- (void)finishStartup { [self finishStartupForReason:@"explicit"]; }
- (void)finishStartupForReason:(NSString *)reason
{
    if (self.finished) return;
    IDVPresentationAudit([@"finish-" stringByAppendingString:reason], self.candidate,
        @{@"candidateDeadline": @(self.deadline), @"totalDeadline": @(self.totalDeadline)});
    self.finished = YES;
    self.revision++;
    for (id token in self.startupObservers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [self.startupObservers removeAllObjects];
    self.candidate = nil;
}
- (void)observeWindow:(NSWindow *)window now:(NSTimeInterval)now
{
    if (self.finished) return;
    if (![self isGameWindow:window]) { IDVPresentationAudit(@"ineligible", window, nil); return; }
    IDVPresentationAudit(@"observe", window, nil);
    if (!self.candidate) {
        if (self.totalDeadline && now >= self.totalDeadline) { [self finishStartupForReason:@"total-timeout"]; return; }
        self.candidate = window;
        IDVPresentationAudit(@"candidate-bound", window, nil);
        if (!self.deadline) self.deadline = self.totalDeadline ? MIN(now + 30, self.totalDeadline) : now + 30;
        __weak IDVGamePresentationController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, self.deadline - now) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf finishStartupForReason:@"candidate-timeout"];
        });
    }
    if (window != self.candidate) return;
    if (now >= self.deadline || window.inLiveResize || (window.styleMask & NSWindowStyleMaskFullScreen)) {
        [self finishStartupForReason:@"candidate-state"]; return;
    }
    NSRect backing = [window.contentView convertRectToBacking:window.contentView.bounds];
    self.revision++;
    if (fabs(backing.size.width - 1920) > 4 || fabs(backing.size.height - 1080) > 4) {
        IDVPresentationAudit(@"backing-not-final", window, nil); return;
    }
    IDVPresentationAudit(@"settle-scheduled", window, nil);
    self.settlingFrame = window.frame;
    NSUInteger revision = self.revision;
    __weak IDVGamePresentationController *weakSelf = self;
    __weak NSWindow *weakWindow = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf settleWindow:weakWindow revision:revision now:NSProcessInfo.processInfo.systemUptime];
    });
}
- (void)settleWindow:(NSWindow *)window revision:(NSUInteger)revision now:(NSTimeInterval)now
{
    if (self.finished || window != self.candidate || revision != self.revision) return;
    if (now >= self.deadline || ![self isGameWindow:window] || window.inLiveResize ||
        (window.styleMask & NSWindowStyleMaskFullScreen) || !NSEqualRects(window.frame, self.settlingFrame)) {
        [self finishStartupForReason:@"settle-invalid"]; return;
    }
    NSScreen *screen = window.screen;
    if (!screen || NSIsEmptyRect(screen.visibleFrame)) { [self finishStartupForReason:@"no-screen"]; return; }
    NSPoint origin = IDVCenteredGameOrigin(window.frame, screen.visibleFrame);
    [self finishStartupForReason:@"centered"]; // Remove move observers before our one public move.
    [window setFrameOrigin:origin];
    fprintf(stderr, "IdentityV final window centered: %.0f,%.0f size=%.0fx%.0f points\n",
        origin.x, origin.y, window.frame.size.width, window.frame.size.height);
}
- (void)install
{
    self.startupObservers = [NSMutableArray array];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak IDVGamePresentationController *weakSelf = self;
    self.totalDeadline = NSProcessInfo.processInfo.systemUptime + 90;
    IDVPresentationAudit(@"installed", nil, @{@"totalDeadline": @(self.totalDeadline)});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf finishStartupForReason:@"total-timeout"];
    });
    for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidMoveNotification,
                                      NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification]) {
        id token = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [weakSelf observeWindow:note.object now:NSProcessInfo.processInfo.systemUptime];
        }];
        [self.startupObservers addObject:token];
    }
    for (NSNotificationName name in @[NSWindowWillMoveNotification, NSWindowWillStartLiveResizeNotification,
                                      NSWindowWillEnterFullScreenNotification, NSWindowWillMiniaturizeNotification,
                                      NSWindowWillCloseNotification]) {
        id token = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (note.object == weakSelf.candidate) [weakSelf finishStartupForReason:note.name];
        }];
        [self.startupObservers addObject:token];
    }
    id screens = [center addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            // First foreground/menu registration can emit this without a user
            // display change. Invalidate settling and use the window's current
            // screen; keep both original deadlines and user/fullscreen cancels.
            IDVPresentationAudit(@"screen-parameters-reobserve", weakSelf.candidate, nil);
            weakSelf.revision++;
            if (weakSelf.candidate) [weakSelf observeWindow:weakSelf.candidate now:NSProcessInfo.processInfo.systemUptime];
        }];
    [self.startupObservers addObject:screens];
    for (NSWindow *window in NSApp.windows) [self observeWindow:window now:NSProcessInfo.processInfo.systemUptime];
}
@end

static IDVGamePresentationController *IDVPresentationController;
static void (*IDVOriginalSetIcon)(id, SEL, NSImage *);

static BOOL IDVIsWineApplication(id application)
{
    Class wine = NSClassFromString(@"WineApplication");
    return wine && [application isKindOfClass:wine] && application == NSApp;
}
static void IDVAuditIcon(NSImage *source, NSImage *result)
{
    if (!IDVPresentationAuditEnabled()) return;
    NSMutableArray *representations = [NSMutableArray array];
    for (NSUInteger index = 0; index < source.representations.count; index++) {
        NSImageRep *original = source.representations[index];
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{
            @"type": NSStringFromClass(original.class), @"width": @(original.pixelsWide), @"height": @(original.pixelsHigh)}];
        if ([original isKindOfClass:NSBitmapImageRep.class] && index < result.representations.count &&
            [result.representations[index] isKindOfClass:NSBitmapImageRep.class]) {
            NSBitmapImageRep *before = (id)original, *after = (id)result.representations[index];
            if (before.pixelsWide > 0 && before.pixelsHigh > 0 && before.samplesPerPixel <= 8 && after.samplesPerPixel <= 8) {
                NSColor *a = [[before colorAtX:0 y:0] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                NSColor *b = [[after colorAtX:0 y:0] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                NSColor *ac = [[before colorAtX:before.pixelsWide / 2 y:before.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                NSColor *bc = [[after colorAtX:after.pixelsWide / 2 y:after.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                BOOL unchanged = ac && bc && fabs(ac.redComponent - bc.redComponent) <= 1.5 / 255 &&
                    fabs(ac.greenComponent - bc.greenComponent) <= 1.5 / 255 && fabs(ac.blueComponent - bc.blueComponent) <= 1.5 / 255;
                row[@"cornerAlphaBefore"] = @(lround(a.alphaComponent * 255));
                row[@"cornerAlphaAfter"] = @(lround(b.alphaComponent * 255));
                row[@"centerRGBPreserved"] = @(unchanged);
                row[@"centerAlphaBefore"] = @(lround(ac.alphaComponent * 255));
                row[@"centerAlphaAfter"] = @(lround(bc.alphaComponent * 255));
            }
        }
        [representations addObject:row];
    }
    IDVPresentationAudit(@"icon", nil, @{@"masked": @(source != result), @"representations": representations});
}
static void IDVSetApplicationIcon(id application, SEL selector, NSImage *image)
{
    NSImage *result = IDVIsWineApplication(application) ? IDVRoundedGameIcon(image) : image;
    if (IDVIsWineApplication(application)) IDVAuditIcon(image, result);
    IDVOriginalSetIcon(application, selector, result);
}
static void IDVInstallGamePresentation(void)
{
    if (!IDVHasGameArgument(NSProcessInfo.processInfo.arguments)) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method icon = class_getInstanceMethod(NSApplication.class, @selector(setApplicationIconImage:));
        if (!icon || method_getNumberOfArguments(icon) != 3) return;
        NSMethodSignature *iconType = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(icon)];
        if (strcmp(iconType.methodReturnType, @encode(void)) || [iconType getArgumentTypeAtIndex:2][0] != '@') return;
        IDVOriginalSetIcon = (void (*)(id, SEL, NSImage *))method_setImplementation(icon, (IMP)IDVSetApplicationIcon);
        IDVPresentationController = [IDVGamePresentationController new];
        [IDVPresentationController install];
        if (NSApp) {
            NSImage *image = NSApp.applicationIconImage;
            if (image && IDVIsWineApplication(NSApp)) [NSApp setApplicationIconImage:image];
        }
    });
}
