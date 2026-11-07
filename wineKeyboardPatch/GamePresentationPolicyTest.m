/* Synthetic WineWindow objects run the real production policy. They are not
 * NSWindows: this test cannot create/activate visible windows or send input. */
#define IDV_GAME_PRESENTATION_PROBE 1
#include "IdentityVCommandGraveForwarder.m"
#include "IdentityVGameNameBootstrap.h" // Probe-only hypothesis; not in the product.
#include <assert.h>

@interface PresentationView : NSObject
@property NSRect bounds;
@property CGFloat scale;
- (NSRect)convertRectToBacking:(NSRect)rect;
@end
@implementation PresentationView
- (NSRect)convertRectToBacking:(NSRect)rect { return NSMakeRect(rect.origin.x * self.scale, rect.origin.y * self.scale, rect.size.width * self.scale, rect.size.height * self.scale); }
@end
@interface PresentationScreen : NSObject
@property NSRect visibleFrame;
@end
@implementation PresentationScreen
@end
@interface WineWindow : NSObject
@property(nonatomic) NSRect frame;
@property BOOL inLiveResize;
@property NSWindowStyleMask styleMask;
@property NSInteger level;
@property(getter=isVisible) BOOL visible;
@property(getter=isMiniaturized) BOOL miniaturized;
@property(nonatomic, strong) NSWindow *parentWindow;
@property(nonatomic, strong) NSWindow *sheetParent;
@property(nonatomic, strong) PresentationView *contentView;
@property(nonatomic, strong) PresentationScreen *screen;
@property NSUInteger moves;
- (NSRect)contentRectForFrameRect:(NSRect)rect;
- (void)setFrameOrigin:(NSPoint)origin;
@end
@implementation WineWindow
@synthesize frame = _frame;
- (void)setFrame:(NSRect)frame {
    _frame = frame;
    self.contentView.bounds = NSMakeRect(0, 0, frame.size.width, frame.size.height - 28);
}
- (NSRect)contentRectForFrameRect:(NSRect)rect { rect.size.height -= 28; return rect; }
- (void)setFrameOrigin:(NSPoint)origin { NSRect frame = self.frame; frame.origin = origin; self.frame = frame; self.moves++; }
@end

static WineWindow *game(NSRect frame, CGFloat scale, NSRect visible)
{
    WineWindow *window = [WineWindow new];
    window.contentView = [PresentationView new]; window.contentView.scale = scale;
    window.screen = [PresentationScreen new]; window.screen.visibleFrame = visible;
    window.styleMask = NSWindowStyleMaskTitled; window.visible = YES; window.frame = frame;
    return window;
}
static NSWindow *native(WineWindow *window) { return (NSWindow *)(id)window; }
static void settle(IDVGamePresentationController *policy, WineWindow *window, double now)
{
    [policy observeWindow:native(window) now:now];
    [policy settleWindow:native(window) revision:policy.revision now:now + 0.6];
}
static void checkWindowPolicy(void)
{
    NSRect visible = NSMakeRect(0, 0, 1920, 1050);
    WineWindow *window = game(NSMakeRect(342, 453, 667, 403), 2, visible);
    IDVGamePresentationController *policy = [IDVGamePresentationController new];
    [policy observeWindow:native(window) now:1];
    assert(window.moves == 0 && policy.candidate == native(window));
    window.frame = NSMakeRect(342, 288, 960, 568);
    settle(policy, window, 4);
    assert(window.moves == 1 && policy.finished);
    assert(NSEqualPoints(window.frame.origin, NSMakePoint(480, 241)));
    assert(NSEqualSizes(window.frame.size, NSMakeSize(960, 568)));
    window.frame = NSMakeRect(77, 88, 960, 568);
    settle(policy, window, 6);
    assert(window.moves == 1 && NSEqualPoints(window.frame.origin, NSMakePoint(77, 88)));

    WineWindow *tool = game(NSMakeRect(0, 0, 500, 500), 2, visible);
    policy = [IDVGamePresentationController new];
    settle(policy, tool, 1);
    assert(!policy.candidate && tool.moves == 0);
    tool.frame = NSMakeRect(0, 0, 1920, 30);
    settle(policy, tool, 2);
    assert(!policy.candidate && tool.moves == 0);
    assert(![policy isGameWindow:(NSWindow *)(id)[NSObject new]]);

    for (NSNotificationName name in @[NSWindowWillMoveNotification, NSWindowWillStartLiveResizeNotification,
                                      NSWindowWillEnterFullScreenNotification, NSWindowWillCloseNotification]) {
        policy = [IDVGamePresentationController new];
        [policy install];
        window = game(NSMakeRect(342, 453, 667, 403), 2, visible);
        double now = NSProcessInfo.processInfo.systemUptime;
        [policy observeWindow:native(window) now:now];
        [NSNotificationCenter.defaultCenter postNotificationName:name object:window];
        window.frame = NSMakeRect(342, 288, 960, 568);
        settle(policy, window, now + 1);
        assert(policy.finished && window.moves == 0 && policy.startupObservers.count == 0);
    }
    policy = [IDVGamePresentationController new]; [policy install];
    double boot = NSProcessInfo.processInfo.systemUptime;
    window = game(NSMakeRect(342, 453, 667, 403), 2, visible);
    [policy observeWindow:native(window) now:boot + 40];
    assert(policy.candidate == native(window) && policy.deadline > boot + 60);
    window.frame = NSMakeRect(342, 288, 960, 568);
    settle(policy, window, boot + 44);
    assert(window.moves == 1 && policy.finished);
    policy = [IDVGamePresentationController new]; [policy install];
    window = game(NSMakeRect(0, 0, 960, 568), 2, visible);
    settle(policy, window, policy.totalDeadline + 1);
    assert(window.moves == 0 && policy.finished);
    policy = [IDVGamePresentationController new]; [policy install];
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification object:nil];
    assert(!policy.finished); // Initial menu registration is not a user cancel.
    window = game(NSMakeRect(342, 453, 667, 403), 2, visible);
    double observed = NSProcessInfo.processInfo.systemUptime;
    [policy observeWindow:native(window) now:observed];
    double originalDeadline = policy.deadline;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification object:nil];
    assert(!policy.finished && policy.deadline == originalDeadline && policy.candidate == native(window));
    window.frame = NSMakeRect(342, 288, 960, 568);
    settle(policy, window, observed + 4);
    assert(window.moves == 1 && NSEqualPoints(window.frame.origin, NSMakePoint(480, 241)));
    policy = [IDVGamePresentationController new]; [policy install];
    window = game(NSMakeRect(342, 288, 960, 568), 2, visible);
    [policy observeWindow:native(window) now:observed];
    window.screen.visibleFrame = NSMakeRect(-1297, 0, 1297, 849.5);
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification object:nil];
    [policy settleWindow:native(window) revision:policy.revision now:observed + 0.6];
    assert(window.moves == 1 && NSEqualPoints(window.frame.origin, NSMakePoint(-1129, 141)));

    window = game(NSMakeRect(-1200, 0, 960, 568), 2, NSMakeRect(-1297, 0, 1297, 849.5));
    policy = [IDVGamePresentationController new]; settle(policy, window, 1);
    assert(NSEqualPoints(window.frame.origin, NSMakePoint(-1129, 141)) && window.moves == 1);
    window = game(NSMakeRect(10, 10, 1920, 1108), 1, visible);
    policy = [IDVGamePresentationController new]; settle(policy, window, 1);
    assert(NSEqualPoints(window.frame.origin, NSMakePoint(0, -58)));
    assert(NSEqualSizes(window.frame.size, NSMakeSize(1920, 1108)));
    assert(NSEqualPoints(IDVCenteredGameOrigin(NSMakeRect(0, 0, 2200, 1300), visible), NSMakePoint(0, -250)));

    window = game(NSMakeRect(0, 0, 960, 568), 2, visible);
    window.styleMask |= NSWindowStyleMaskFullScreen;
    policy = [IDVGamePresentationController new]; settle(policy, window, 1);
    assert(window.moves == 0 && policy.finished);
    window.styleMask &= ~NSWindowStyleMaskFullScreen;
    policy = [IDVGamePresentationController new]; policy.deadline = 10;
    settle(policy, window, 11);
    assert(window.moves == 0 && policy.finished);
    policy = [IDVGamePresentationController new];
    [policy observeWindow:native(window) now:1];
    NSUInteger oldRevision = policy.revision;
    window.frame = NSMakeRect(11, 22, 960, 568);
    [policy observeWindow:native(window) now:1.2];
    [policy settleWindow:native(window) revision:oldRevision now:1.6];
    assert(window.moves == 0 && !policy.finished);
    [policy settleWindow:native(window) revision:policy.revision now:1.8];
    assert(window.moves == 1 && policy.finished);
}

static NSBitmapImageRep *representation(NSInteger side)
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bitmapFormat:0 bytesPerRow:side * 4 bitsPerPixel:32];
    for (NSInteger y = 0; y < side; y++) for (NSInteger x = 0; x < side; x++) {
        NSUInteger pixel[4] = {(NSUInteger)(x % 90), (NSUInteger)(y % 90), 100, 180};
        [rep setPixel:pixel atX:x y:y];
    }
    rep.size = NSMakeSize(32, 32);
    return rep;
}
static void checkIconMask(void)
{
    NSImage *source = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
    for (NSNumber *side in @[@32, @64, @128]) [source addRepresentation:representation(side.integerValue)];
    NSData *before = source.TIFFRepresentation;
    NSImage *result = IDVRoundedGameIcon(source);
    assert(result != source && result.representations.count == source.representations.count && NSEqualSizes(result.size, source.size));
    for (NSUInteger index = 0; index < result.representations.count; index++) {
        NSBitmapImageRep *old = (id)source.representations[index], *rep = (id)result.representations[index];
        assert(old.pixelsWide == rep.pixelsWide && old.pixelsHigh == rep.pixelsHigh && NSEqualSizes(old.size, rep.size));
        NSInteger side = rep.pixelsWide;
        NSUInteger corner[4] = {0}; [rep getPixel:corner atX:0 y:0]; assert(corner[3] == 0);
        for (NSInteger y = side / 4; y < side * 3 / 4; y++) for (NSInteger x = side / 4; x < side * 3 / 4; x++) {
            NSUInteger expected[4] = {0}, actual[4] = {0};
            [old getPixel:expected atX:x y:y]; [rep getPixel:actual atX:x y:y];
            for (int component = 0; component < 4; component++) assert(labs((long)actual[component] - (long)expected[component]) <= 1);
        }
    }
    assert([before isEqualToData:source.TIFFRepresentation]);
    assert(IDVRoundedGameIcon(result) == result && IDVRoundedGameIcon(nil) == nil);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--scope")) return IDVHasGameArgument(NSProcessInfo.processInfo.arguments) ? 0 : 10;
        assert(IDVHasGameArgument(@[@"wine", @"C:\\Games\\IdentityV\\dwrg.exe"]));
        assert(IDVHasGameArgument(@[@"wine", @"c:/Games/IdentityVGlobal/DWRG.EXE"]));
        assert(!IDVHasGameArgument(@[@"winecfg", @"--name=dwrg.exe"]));
        assert(!IDVHasGameArgument(@[@"wine", @"C:\\Games\\dwrg.exe.backup"]));
        const char *originalName = getenv("WINEPRELOADERAPPNAME");
        char *savedName = originalName ? strdup(originalName) : NULL;
        unsetenv("WINEPRELOADERAPPNAME");
        assert(!idv_restore_preloader_app_name(NULL) && !getenv("WINEPRELOADERAPPNAME"));
        assert(!idv_restore_preloader_app_name("invalid") && !getenv("WINEPRELOADERAPPNAME"));
        assert(idv_restore_preloader_app_name("第五人格") && !strcmp(getenv("WINEPRELOADERAPPNAME"), "第五人格"));
        unsetenv("WINEPRELOADERAPPNAME"); // The parent loader consumes this input.
        assert(idv_restore_preloader_app_name("Identity V") && !strcmp(getenv("WINEPRELOADERAPPNAME"), "Identity V"));
        if (savedName) { setenv("WINEPRELOADERAPPNAME", savedName, 1); free(savedName); }
        else unsetenv("WINEPRELOADERAPPNAME");
        checkWindowPolicy();
        checkIconMask();
        puts("Production presentation policy: final-size/stability, single move, user/fullscreen stop, screen re-observation without extending deadlines, 1x/2x/multi-screen, title accessibility and icon pixel/alpha preservation passed; no native windows or input.");
    }
    return 0;
}
