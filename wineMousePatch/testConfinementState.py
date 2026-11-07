#!/usr/bin/env python3
"""Compile the patched handler with in-memory windows; no NSApplication/input.
Pass the patched Wine source root. This tests state transitions, not macOS's
WindowServer enforcement or high-speed physical input.
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]) / 'dlls/winemac.drv/cocoa_cursorclipping.m'
text = source.read_text()
helpers = text[text.index('static void clip_cursor_location'):text.index('@implementation WineEventTapClipCursorHandler')]
handler = text[text.index('@implementation WineConfinementClipCursorHandler'):]
harness = r'''
#import <Cocoa/Cocoa.h>
#include <unistd.h>
static NSPoint diagnosticPointer;
static double diagnosticClock = 100;
static unsigned diagnosticPointerReads;
@interface ProbeClock : NSObject
+ (id)processInfo;
- (double)systemUptime;
- (BOOL)isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)v;
@end
@implementation ProbeClock
+ (id)processInfo { static id clock; if (!clock) clock = [self new]; return clock; }
- (double)systemUptime { return diagnosticClock; }
- (BOOL)isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)v { return YES; }
@end
@interface ProbeEvent : NSObject
+ (NSPoint)mouseLocation;
@end
@implementation ProbeEvent
+ (NSPoint)mouseLocation { diagnosticPointerReads++; return diagnosticPointer; }
@end
@interface ProbeWorkspace : NSObject
+ (id)sharedWorkspace;
- (id)frontmostApplication;
- (pid_t)processIdentifier;
@end
@implementation ProbeWorkspace
+ (id)sharedWorkspace { static id workspace; if (!workspace) workspace = [self new]; return workspace; }
- (id)frontmostApplication { return self; }
- (pid_t)processIdentifier { return 123; }
@end
#define NSEvent ProbeEvent
#define NSWorkspace ProbeWorkspace
#define NSProcessInfo ProbeClock
@interface ProbeWindow : NSObject
@property NSRect frame;
@property NSInteger windowNumber;
@property NSRect mouseConfinementRect;
@property(retain) ProbeWindow *parentWindow;
- (NSRect)convertRectFromScreen:(NSRect)r;
@end
@implementation ProbeWindow
- (NSRect)convertRectFromScreen:(NSRect)r { r.origin.x -= self.frame.origin.x; r.origin.y -= self.frame.origin.y; return r; }
@end
@interface WineApplicationController : NSObject
@property(retain) ProbeWindow *frontWineWindow;
@property(retain) NSArray *windows;
@property(retain) ProbeWindow *keyWindow;
@property(getter=isActive) BOOL active;
- (NSPoint)flippedMouseLocation:(NSPoint)p;
+ (id)sharedController;
- (void)flipRect:(NSRect*)r;
- (id)windowWithWindowNumber:(NSInteger)n;
@end
static WineApplicationController *controller;
@implementation WineApplicationController
+ (id)sharedController { return controller; }
- (NSPoint)flippedMouseLocation:(NSPoint)p { return p; }
- (void)flipRect:(NSRect*)r { /* Identity projection in this state-only harness. */ }
- (id)windowWithWindowNumber:(NSInteger)n { for (ProbeWindow *w in self.windows) if (w.windowNumber == n) return w; return nil; }
@end
#define WineWindow ProbeWindow
#define NSWindow ProbeWindow
#define NSApp controller
@interface WineConfinementClipCursorHandler : NSObject {
 BOOL clippingCursor; CGRect cursorClipRect; NSInteger clippingWindowNumber;
 BOOL diagnosticEnabled;
 unsigned diagnosticRecords, diagnosticEpoch, diagnosticAnomalyKinds;
 NSTimeInterval diagnosticLastCheck;
}
@property(readonly) BOOL clippingCursor;
@property(readonly) CGRect cursorClipRect;
+ (NSRect)rectForScreenRect:(CGRect)r inWindow:(ProbeWindow*)w;
- (BOOL)startClippingCursor:(CGRect)r;
- (BOOL)stopClippingCursor;
- (BOOL)isClippingCursorToRect:(CGRect)r;
- (void)diagnoseCursorEventAt:(CGPoint)p;
- (void)diagnoseCursorState:(const char*)reason eventPoint:(CGPoint)p hasEvent:(BOOL)hasEvent;
@end
'''
checks = r'''
static int count;
static void check(BOOL ok, const char *name) { if (!ok) { fprintf(stderr,"FAIL: %s\n",name); exit(1); } count++; }
int main(void) { @autoreleasepool {
 unsetenv("IDENTITYV_CAPTURE_DIAGNOSTICS");
 controller = [WineApplicationController new];
 ProbeWindow *a = [ProbeWindow new], *b = [ProbeWindow new];
 a.windowNumber = 1; b.windowNumber = 2;
 a.frame = b.frame = NSMakeRect(100,100,800,600);
 controller.windows = @[a,b]; controller.frontWineWindow = a;
 WineConfinementClipCursorHandler *h = [WineConfinementClipCursorHandler new];
 CGRect r = CGRectMake(120,120,200,200);
 check(![h isClippingCursorToRect:r], "free mode is not captured");
 check([h startClippingCursor:r], "start");
 check([h isClippingCursorToRect:r], "matching native constraint");
 a.mouseConfinementRect = NSZeroRect;
 check(![h isClippingCursorToRect:r], "native reset invalidates cache");
 check([h startClippingCursor:r] && [h isClippingCursorToRect:r], "same rect repairs reset");
 a.frame = NSMakeRect(110,110,800,600);
 check(![h isClippingCursorToRect:r], "geometry invalidates projection");
 check([h startClippingCursor:r] && [h isClippingCursorToRect:r], "geometry repair");
 controller.frontWineWindow = b;
 check(![h isClippingCursorToRect:r], "new owner invalidates cache");
 check([h startClippingCursor:r] && [h isClippingCursorToRect:r] && NSIsEmptyRect(a.mouseConfinementRect), "transfer clears old owner");
 controller.frontWineWindow = nil;
 check(![h startClippingCursor:r] && h.clippingCursor && !NSIsEmptyRect(b.mouseConfinementRect), "missing owner failure retains old capture");
 controller.frontWineWindow = b;
 check(![h startClippingCursor:CGRectMake(5000,5000,10,10)] && [h isClippingCursorToRect:r], "outside-window failure retains old capture");
 check(![h isClippingCursorToRect:CGRectMake(121,120,200,200)], "new rect rejected by cache");
 check([h stopClippingCursor] && !h.clippingCursor && NSIsEmptyRect(b.mouseConfinementRect), "free mode clears native constraint");
 check([h stopClippingCursor] && ![h isClippingCursorToRect:r], "repeated release remains free");
 printf("PASS: %d confinement state checks; no windows, Wine or input created\n", count);
 } return 0; }
'''
diagnostic_checks = r'''
 check(diagnosticPointerReads == 0, "disabled diagnostics never sample pointer");
 setenv("IDENTITYV_CAPTURE_DIAGNOSTICS", "yes", 1);
 WineConfinementClipCursorHandler *off = [WineConfinementClipCursorHandler new];
 [off startClippingCursor:r];
 for (unsigned i=0; i<10000; i++) [off diagnoseCursorEventAt:CGPointMake(500,500)];
 check(diagnosticPointerReads == 0, "only exact env value 1 enables diagnostics");
 [off stopClippingCursor];
 setenv("IDENTITYV_CAPTURE_DIAGNOSTICS", "1", 1);
 WineConfinementClipCursorHandler *d = [WineConfinementClipCursorHandler new];
 controller.keyWindow = b; controller.active = YES;
 [d startClippingCursor:r];
 diagnosticPointer = NSMakePoint(500,500);
 for (unsigned i=0; i<10000; i++) [d diagnoseCursorEventAt:CGPointMake(150,150)];
 check(diagnosticPointerReads == 0, "in-bounds events do not query native pointer");
 [d diagnoseCursorEventAt:CGPointMake(500,500)];
 check(diagnosticPointerReads == 1 && [d isClippingCursorToRect:r], "native-present escape classified without repairing");
 b.mouseConfinementRect = NSZeroRect;
 for (unsigned i=0; i<10000; i++) [d diagnoseCursorEventAt:CGPointMake(500,500)];
 check(diagnosticPointerReads == 1, "outside-event snapshots rate limited");
 diagnosticClock += 1.1;
 [d diagnoseCursorEventAt:CGPointMake(500,500)];
 check(NSIsEmptyRect(b.mouseConfinementRect), "diagnosis does not restore lost native state");
 b.mouseConfinementRect = [WineConfinementClipCursorHandler rectForScreenRect:r inWindow:b];
 controller.active = NO; diagnosticClock += 1.1;
 [d diagnoseCursorEventAt:CGPointMake(500,500)];
 controller.active = YES; diagnosticPointer = NSMakePoint(150,150); diagnosticClock += 1.1;
 [d diagnoseCursorEventAt:CGPointMake(500,500)];
 unsigned reads = diagnosticPointerReads;
 diagnosticClock += 1.1;
 for (unsigned i=0; i<10000; i++) [d diagnoseCursorEventAt:CGPointMake(500,500)];
 check(diagnosticPointerReads == reads, "all anomaly classes stop further snapshot reads");
 [d stopClippingCursor];
 [d startClippingCursor:r];
 diagnosticPointer = NSMakePoint(500,500);
 [d diagnoseCursorEventAt:CGPointMake(500,500)];
 for (unsigned i=0; i<100; i++) { [d stopClippingCursor]; [d startClippingCursor:r]; }
 reads = diagnosticPointerReads;
 diagnosticClock += 1.1;
 [d diagnoseCursorEventAt:CGPointMake(500,500)];
 check(diagnosticPointerReads == reads, "record budget stops snapshot reads");
'''
if '- (void) diagnoseCursorEventAt:' in text:
    checks = checks.replace(' } return 0; }', diagnostic_checks + '\n } return 0; }')
with tempfile.TemporaryDirectory(prefix='idv-confinement-state-') as temp:
    root = pathlib.Path(temp)
    (root / 'probe.m').write_text(harness + helpers + handler + checks)
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations', '-framework', 'Cocoa', str(root / 'probe.m'), '-o', str(root / 'probe')], check=True)
    result = subprocess.run([str(root / 'probe')], check=True, capture_output=True, text=True)
    print(result.stdout, end='')
    if '- (void) diagnoseCursorEventAt:' in text:
        lines = result.stderr.splitlines()
        assert len(lines) == 64, (len(lines), result.stderr)
        assert all(line.startswith('IDV_CAPTURE_DIAG v=1 ') for line in lines)
        for kind in ('native-constraint-mismatch', 'inactive-or-nonkey', 'native-present-pointer-outside', 'event-outside-pointer-inside'):
            assert any(f'kind={kind} ' in line for line in lines), kind
        assert sum('kind=native-present-pointer-outside ' in line for line in lines) == 2
        assert all(' event=' not in line for line in lines if 'kind=transition ' in line)
        assert all(' event=' in line for line in lines if 'kind=transition ' not in line)
        print('PASS: diagnostic classification, opt-in, rate limits, epoch deduplication and 64-line budget')
    else:
        assert not result.stderr, result.stderr
