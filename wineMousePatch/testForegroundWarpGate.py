#!/usr/bin/env python3
"""Compile the actual gated Cocoa method with in-memory app/queue/warp substitutes.
No NSApplication, window, CGWarp, Wine, or input is created.
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('    - (BOOL) setCursorPosition:(CGPoint)pos')
end = source.index('    - (void) updateWindowsForCursorClipping', start)
method = source[start:end]
harness = r'''
#import <Cocoa/Cocoa.h>
#include <stdint.h>
static unsigned warpCalls, tapCalls, clipCalls, resetCalls, discardCalls;
static BOOL operationSuccess = YES;
static CGError probeWarp(CGPoint p) { warpCalls++; return operationSuccess ? kCGErrorSuccess : kCGErrorFailure; }
static void probeSuppression(double t) {}
static void probeAssociate(boolean_t b) {}
#define CGWarpMouseCursorPosition probeWarp
#define CGSetLocalEventsSuppressionInterval probeSuppression
#define CGAssociateMouseAndMouseCursorPosition probeAssociate
static int macdrv_capture_diag_enabled(void) { return 0; }
static void macdrv_capture_diag_log(unsigned bit, const char *format, ...) {}
#define event_mask_for_type(x) (1u << (x))
enum { MOUSE_MOVED_RELATIVE, MOUSE_MOVED_ABSOLUTE };
@interface ProbeWindow : NSObject @end
@implementation ProbeWindow @end
#define WineWindow ProbeWindow
@interface ProbeApp : NSObject
@property(getter=isActive) BOOL active;
@property(retain) id keyWindow;
@end
@implementation ProbeApp @end
static ProbeApp *app;
#define NSApp app
@interface ProbeClip : NSObject
- (void)clipCursorLocation:(CGPoint*)p;
@end
@implementation ProbeClip
- (void)clipCursorLocation:(CGPoint*)p { clipCalls++; }
@end
@interface ProbeTap : ProbeClip
- (BOOL)setCursorPosition:(CGPoint)p;
@end
@implementation ProbeTap
- (BOOL)setCursorPosition:(CGPoint)p { tapCalls++; return operationSuccess; }
@end
@interface WineEventQueue : NSObject
- (void)discardEventsMatchingMask:(unsigned)mask forWindow:(id)window;
- (void)resetMouseEventPositions:(CGPoint)p;
@end
@implementation WineEventQueue
- (void)discardEventsMatchingMask:(unsigned)mask forWindow:(id)window { discardCalls++; }
- (void)resetMouseEventPositions:(CGPoint)p { resetCalls++; }
@end
@interface ProbeController : NSObject {
@public
 NSSet *windowsBeingDragged;
 id clipCursorHandler;
 id mouseCaptureWindow;
 BOOL cursorHidden, clientWantsCursorHidden;
 NSTimeInterval lastSetCursorPositionTime;
 NSLock *eventQueuesLock;
 NSArray *eventQueues;
}
@property BOOL clippingCursor;
- (BOOL)setCursorPosition:(CGPoint)p;
@end
@implementation ProbeController
'''
checks = r'''
@end
static void check(BOOL valid, const char *name) { if (!valid) { fprintf(stderr,"FAIL: %s\n",name); exit(1); } }
int main(void) { @autoreleasepool {
 app = [ProbeApp new];
 unsigned cases = 0;
 for (int active=0; active<2; active++) for (int key=0; key<3; key++)
 for (int drag=0; drag<2; drag++) for (int captured=0; captured<2; captured++)
 for (int tap=0; tap<2; tap++) {
  ProbeController *c = [ProbeController new];
  app.active = active; app.keyWindow = key == 0 ? nil : (key == 1 ? [NSObject new] : [ProbeWindow new]);
  c->windowsBeingDragged = drag ? [NSSet setWithObject:@"drag"] : [NSSet set];
  c->clipCursorHandler = tap ? [ProbeTap new] : [ProbeClip new];
  c->eventQueuesLock = [NSLock new]; c->eventQueues = @[[WineEventQueue new]];
  c.clippingCursor = captured;
  warpCalls = tapCalls = clipCalls = resetCalls = discardCalls = 0;
  BOOL result = [c setCursorPosition:CGPointMake(400,300)];
  BOOL eligible = active && key == 2 && !drag;
  check(result == eligible, "return reflects eligibility");
  check(warpCalls + tapCalls == (unsigned)eligible, "only eligible foreground operation reaches native warp");
  check(warpCalls == (unsigned)(eligible && !(captured && tap)), "free and native-clip paths preserved");
  check(tapCalls == (unsigned)(eligible && captured && tap), "eventtap delegation preserved");
  check(clipCalls == (unsigned)(eligible && captured && !tap), "no clip inference or inactive clip mutation");
  check(resetCalls == (unsigned)eligible && discardCalls == (unsigned)eligible, "denied operation never resets queues");
  cases++;
 }
 ProbeController *c = [ProbeController new];
 app.active = YES; app.keyWindow = [ProbeWindow new];
 c->windowsBeingDragged = [NSSet set]; c->clipCursorHandler = [ProbeClip new];
 c->eventQueuesLock = [NSLock new]; c->eventQueues = @[[WineEventQueue new]];
 operationSuccess = NO; resetCalls = discardCalls = 0;
 check(![c setCursorPosition:CGPointZero] && !resetCalls && !discardCalls, "real warp failure is not reported as success");
 printf("PASS: %u active/key/drag/captured/handler matrix cases plus native failure; no real input\n",cases);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='idv-warp-gate-') as temp:
    root = pathlib.Path(temp)
    (root / 'probe.m').write_text(harness + method + checks)
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations', '-framework', 'Cocoa', str(root / 'probe.m'), '-o', str(root / 'probe')], check=True)
    subprocess.run([str(root / 'probe')], check=True)
