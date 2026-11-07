#!/usr/bin/env python3
"""Compile the unchanged Wine movement classifier fragment with fake objects.
Usage: testPinnedBoundary.py matching-cocoa_app.m NEW_OUTPUT
No Wine initialization, NSApplication, windows, devices or input.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('if (forceNextMouseMoveAbsolute || targetWindow != lastTargetWindow)')
end = source.index('\n            if (absolute)', start)
fragment = source[start:end]
root = pathlib.Path(sys.argv[2]); root.mkdir()
program = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CGGeometry.h>
#include <assert.h>
@interface Delta:NSObject @property CGFloat deltaX; @property CGFloat deltaY; @end
@implementation Delta @end
@interface Clip:NSObject @property CGRect cursorClipRect; @end
@implementation Clip @end
@interface Classifier:NSObject {
 BOOL forceNextMouseMoveAbsolute; id lastTargetWindow; NSData *screenFrameCGRects; Clip *clipCursorHandler;
}
@property BOOL clippingCursor;
- (CGFloat)primaryScreenHeight;
- (BOOL)run:(CGPoint)point delta:(Delta*)anEvent clip:(CGRect)clip aware:(BOOL)aware force:(BOOL)force changed:(BOOL)changed;
@end
@implementation Classifier
- (CGFloat)primaryScreenHeight {return 1000;}
- (BOOL)run:(CGPoint)point delta:(Delta*)anEvent clip:(CGRect)clip aware:(BOOL)aware force:(BOOL)force changed:(BOOL)changed {
 self.clippingCursor=aware;forceNextMouseMoveAbsolute=force;id targetWindow=@1;lastTargetWindow=changed?@2:targetWindow;
 CGRect desktop={{-1000,0},{2400,1000}};screenFrameCGRects=[NSData dataWithBytes:&desktop length:sizeof(desktop)];
 clipCursorHandler=[Clip new];clipCursorHandler.cursorClipRect=clip;BOOL absolute;
/* ORIGINAL_CLASSIFIER */
 return absolute;
}
@end
int main(void){@autoreleasepool{
 Classifier*c=[Classifier new];Delta*d=[Delta new];CGRect client={{-500,200},{800,600}},desktop={{-1000,0},{2400,1000}};
 struct Case {CGPoint point;CGFloat dx,dy;BOOL edge;BOOL tiny;BOOL desktop;} cases[]={
 {{0,500},2,3,NO,NO,NO},{{299.75,500},2,0,YES,NO,NO},{{-499.75,500},-2,0,YES,NO,NO},
 {{0,200.25},0,-2,YES,NO,NO},{{0,799.75},0,2,YES,NO,NO},{{299.75,799.75},2,2,YES,NO,NO},
 {{299.75,500},0.0001,0,NO,YES,NO},{{1399.75,500},2,0,YES,NO,YES}};
 unsigned tested=0,differences=0;
 for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++)for(int force=0;force<2;force++)for(int changed=0;changed<2;changed++){
 d.deltaX=cases[i].dx;d.deltaY=cases[i].dy;CGRect rect=cases[i].desktop?desktop:client;
 BOOL direct=[c run:cases[i].point delta:d clip:rect aware:NO force:force changed:changed];
 BOOL handler=[c run:cases[i].point delta:d clip:rect aware:YES force:force changed:changed];
 BOOL reset=force||changed;
 assert(direct==(reset||!cases[i].desktop));
 assert(handler==(reset||!cases[i].edge));
 if(direct!=handler){assert(!reset&&cases[i].edge&&!cases[i].desktop);differences++;}
 tested+=2;
 }
 assert(differences==5);printf("PASS: %u classifier cases, 5 pinned client-boundary differences; interior and forced first ABS unchanged\n",tested);
}return 0;}
'''
program = program.replace('/* ORIGINAL_CLASSIFIER */', fragment)
(root/'classifier.m').write_text(program)
subprocess.run(['clang','-arch','x86_64','-O2','-mmacosx-version-min=14.0','-Werror',str(root/'classifier.m'),'-framework','Foundation','-framework','CoreGraphics','-o',str(root/'classifier')],check=True)
result=subprocess.run([str(root/'classifier')],check=True,capture_output=True,text=True)
report={'fragmentSHA256':hashlib.sha256(fragment.encode()).hexdigest(),'result':result.stdout.strip(),'syntheticClassifierOnly':True,'liveInputQualityVerified':False}
(root/'classifier-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
