#!/usr/bin/env python3
"""Build/probe the opt-in native-only lease without creating a real window.
Usage: testNativeCameraCompat.py OEM_RUNTIME NEW_OUTPUT [UNKNOWN_WINEMAC]
Never starts Wine, a game, a prefix or input; no live-process attachment.
"""
import ast
import hashlib
import json
import os
import pathlib
import subprocess
import sys

here = pathlib.Path(__file__).resolve().parent
runtime = pathlib.Path(sys.argv[1]).resolve(strict=True)
root = pathlib.Path(sys.argv[2]); root.mkdir(); root = root.resolve()
module = runtime / 'lib/wine/x86_64-unix/winemac.so'
upper = runtime / 'lib/wine/x86_64-unix/win32u.so'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(module) == '365fefb1c0bf4c0e54f4fd3a00dbd44bd9a6febc75209846b6de2c270bdb9c60'
assert sha(upper) == '15c047bb78a84da940eb86eff692e6aa6b74ed69975613c93715b9f3ce0f13f7'
common = ['clang','-arch','x86_64','-O2','-mmacosx-version-min=14.0','-Werror','-Wno-deprecated-declarations','-framework','CoreFoundation']
shim = root / 'native-camera-compat.dylib'
subprocess.run(common+['-dynamiclib','-fvisibility=hidden','-Wl,-install_name,@rpath/native-camera-compat.dylib',str(here/'native_camera_compat.m'),'-lobjc','-o',str(shim)],check=True)
# Reuse the already validated loader/errno probe as source, without executing
# the foreground test script or changing its frozen bytes.
tree = ast.parse((here/'testForegroundWarpCompat.py').read_text())
probe = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='probe' for t in node.targets))
probe = '#include <CoreFoundation/CoreFoundation.h>\nstatic void noop(void *x) {}\n' + probe
probe = probe.replace('int main(int argc,char **argv) {','int main(int argc,char **argv) {\n if(argc>3) setprogname(!strcmp(argv[3],"game")?"dwrg.exe":argv[3]);')
probe = probe.replace(' Class cls=', ' CFRunLoopSourceContext ctx={0};ctx.perform=noop;\n CFRunLoopSourceRef src=CFRunLoopSourceCreate(NULL,0,&ctx);CFRunLoopAddSource(CFRunLoopGetMain(),src,kCFRunLoopDefaultMode);CFRunLoopSourceSignal(src);CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.002,1);CFRunLoopRemoveSource(CFRunLoopGetMain(),src,kCFRunLoopDefaultMode);CFRelease(src);\n Class cls=')
(root/'loader-probe.m').write_text(probe)
loader = root/'loader-probe'
subprocess.run(common+[str(root/'loader-probe.m'),'-lobjc','-Wl,-rpath,'+str(module.parent),'-Wl,-rpath,'+str(runtime/'lib64'),'-o',str(loader)],check=True)
base = os.environ.copy()
for key in ('DYLD_INSERT_LIBRARIES','IDENTITYV_FOREGROUND_WARP_GATE','IDENTITYV_NATIVE_CAMERA_CLIP','IDENTITYV_WARP_GATE_AUDIT','IDENTITYV_CAPTURE_DIAGNOSTICS'):
    base.pop(key,None)
results={}
for mode in ('disabled','other-process','camera','background-only'):
    env=base.copy();env['DYLD_INSERT_LIBRARIES']=str(shim);env['IDENTITYV_WARP_GATE_AUDIT']='1'
    env['IDENTITYV_NATIVE_CAMERA_CLIP']='1' if mode in ('camera','other-process') else '0'
    env['IDENTITYV_FOREGROUND_WARP_GATE']='1' if mode=='background-only' else '0'
    name='webview.exe' if mode=='other-process' else 'game'
    run=subprocess.run([str(loader),str(module),str(shim),name],env=env,check=True,capture_output=True,text=True)
    result=json.loads(run.stdout)
    assert result['installed']==int(mode in ('camera','background-only')),run.stderr
    assert not result['applicationCreated'] and result['failureMessage']
    assert ('IDV_NATIVE_CAMERA installed' in run.stderr)==(mode=='camera'),run.stderr
    results[mode]=result
for field in ('failureErrno','successErrno','signature'):
    assert len({row[field] for row in results.values()})==1,(field,results)
if len(sys.argv)>3:
    unknown=pathlib.Path(sys.argv[3]).resolve(strict=True);assert sha(unknown)!=sha(module)
    env=base.copy();env.update(DYLD_INSERT_LIBRARIES=str(shim),IDENTITYV_NATIVE_CAMERA_CLIP='1',IDENTITYV_WARP_GATE_AUDIT='1')
    run=subprocess.run([str(loader),str(unknown),str(shim),'game'],env=env,check=True,capture_output=True,text=True)
    result=json.loads(run.stdout);assert result['installed']==0 and 'reason=baseline-identity' in run.stderr
    results['unknown-hash']=result
# Caller-only rpath regression: the executable and outer image have no deps
# rpath. Original dlopen sees caller.dylib's rpaths; broad interpose loses them.
reg=root/'rpath';reg.mkdir();(reg/'deps').mkdir();(reg/'outer').mkdir()
(reg/'inner.c').write_text('int inner(void){return 42;}\n')
(reg/'outer.c').write_text('extern int inner(void); int outer(void){return inner();}\n')
(reg/'caller.c').write_text('#include <dlfcn.h>\n#include <stdio.h>\nint load_from_caller(const char *path){void *h=dlopen(path,RTLD_NOW|RTLD_LOCAL);if(!h){fprintf(stderr,"LOAD_FAILED: %s\\n",dlerror());return 0;}int(*f)(void)=dlsym(h,"outer");return f?f()==42:2;}\n')
(reg/'main.c').write_text('#include <dlfcn.h>\n#include <stdio.h>\nint main(int c,char**v){void*h=dlopen(v[1],RTLD_NOW|RTLD_LOCAL);if(!h)return 3;int(*f)(const char*)=dlsym(h,"load_from_caller");if(!f)return 4;printf("%d\\n",f(v[2]));return 0;}\n')
subprocess.run(common+['-dynamiclib',str(reg/'inner.c'),'-Wl,-install_name,@rpath/libinner.dylib','-o',str(reg/'deps/libinner.dylib')],check=True)
subprocess.run(common+['-dynamiclib',str(reg/'outer.c'),'-L'+str(reg/'deps'),'-linner','-Wl,-install_name,@rpath/libouter.dylib','-o',str(reg/'outer/libouter.dylib')],check=True)
(reg/'outer/winemac.so').write_bytes((reg/'outer/libouter.dylib').read_bytes())
subprocess.run(common+['-dynamiclib',str(reg/'caller.c'),'-Wl,-rpath,'+str(reg/'deps'),'-Wl,-rpath,'+str(module.parent),'-Wl,-rpath,'+str(runtime/'lib64'),'-o',str(reg/'caller.dylib')],check=True)
subprocess.run(common+[str(reg/'main.c'),'-o',str(reg/'main')],check=True)
regression={}
for mode in ('no-shim','disabled','enabled','old-broken'):
    if mode=='old-broken' and len(sys.argv)<5:continue
    env=base.copy()
    if mode!='no-shim':env['DYLD_INSERT_LIBRARIES']=sys.argv[4] if mode=='old-broken' else str(shim)
    env['IDENTITYV_NATIVE_CAMERA_CLIP']='1' if mode=='enabled' else '0'
    env['IDENTITYV_FOREGROUND_WARP_GATE']='1' if mode=='enabled' else '0'
    rows=[]
    for name in ('libouter.dylib','winemac.so'):
        r=subprocess.run([str(reg/'main'),str(reg/'caller.dylib'),str(reg/'outer'/name)],env=env,capture_output=True,text=True,check=True)
        expected='0' if mode=='old-broken' else '1'
        assert r.stdout.strip()==expected,(mode,name,r.stdout,r.stderr)
        rows.append({'target':name,'loaded':r.stdout.strip()=='1'})
    regression[mode]=rows
# Actual transitive winemetal load through the caller image, with OEM rpaths.
metal=runtime/'lib/dxmt/x86_64-unix/winemetal.so'
assert metal.is_file()
for mode in ('no-shim','disabled','enabled'):
    env=base.copy()
    if mode!='no-shim':env['DYLD_INSERT_LIBRARIES']=str(shim)
    env.update(IDENTITYV_NATIVE_CAMERA_CLIP='1' if mode=='enabled' else '0',IDENTITYV_WARP_GATE_AUDIT='1')
    r=subprocess.run([str(reg/'main'),str(reg/'caller.dylib'),str(metal)],env=env,capture_output=True,text=True,check=True)
    assert r.stdout.strip()=='2',(mode,r.stdout,r.stderr) # load succeeded; no fake outer symbol
    regression['winemetal-'+mode]={'loaded':True}
# Run the metadata/bootstrap probe on the actual transitive image too.
env=base.copy();env.update(DYLD_INSERT_LIBRARIES=str(shim),IDENTITYV_NATIVE_CAMERA_CLIP='1',IDENTITYV_WARP_GATE_AUDIT='1')
# The caller function loads the image. Give only caller.dylib's own rpaths to
# its dlopen; the bootstrap/loader probe below also needs no new shim rpath.
transitive=probe.replace('void *module=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);','void *caller=dlopen(argv[4],RTLD_NOW|RTLD_LOCAL);int(*load)(const char*)=caller?dlsym(caller,"load_from_caller"):NULL;\n void *module=(load&&load(argv[1])==2)?caller:NULL;')
(root/'transitive-probe.m').write_text(transitive)
subprocess.run(common+[str(root/'transitive-probe.m'),'-lobjc','-o',str(root/'transitive-probe')],check=True)
r=subprocess.run([str(root/'transitive-probe'),str(metal),str(shim),'game',str(reg/'caller.dylib')],env=env,check=True,capture_output=True,text=True)
assert json.loads(r.stdout)['installed']==1 and 'IDV_NATIVE_CAMERA installed' in r.stderr,r.stderr
regression['transitive-mainloop-install']=json.loads(r.stdout)
if len(sys.argv)>5:
    aux=pathlib.Path(sys.argv[5]);forwarder=aux/'IdentityVCommandGraveForwarder.dylib';dns=aux/'IdentityVLoginDNSCompat.dylib'
    assert forwarder.is_file() and dns.is_file()
    env['DYLD_INSERT_LIBRARIES']=':'.join(map(str,(forwarder,shim,dns)))
    r=subprocess.run([str(root/'transitive-probe'),str(metal),str(shim),'game',str(reg/'caller.dylib')],env=env,check=True,capture_output=True,text=True)
    assert json.loads(r.stdout)['installed']==1 and 'IDV_NATIVE_CAMERA installed' in r.stderr,r.stderr
    regression['full-stack-loading']=json.loads(r.stdout)
# No production loader wrapper or interpose section can remain.
imports=subprocess.check_output(['nm','-u',str(shim)],text=True)
sections=subprocess.check_output(['otool','-l',str(shim)],text=True)
assert not any(line.split()[-1]=='_dlopen' for line in imports.splitlines() if line.split())
assert '__interpose' not in sections

fixture = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#define IDV_CAMERA_TEST 1
#include "native_camera_compat.m"
static unsigned writes,warps,unhides,captures,frameReads,nativeReads,flipQueries,captureQueries,clipQueries,dragQueries;static BOOL warpOK=YES,rejectRect=NO;
@interface FSet:NSObject
@property(retain) NSMutableSet *data;
- (NSUInteger)count; - (void)addObject:(id)o; - (void)removeObject:(id)o;
@end
@implementation FSet
- (id)init { self=[super init];_data=[NSMutableSet new];return self; }
- (NSUInteger)count { dragQueries++;return [_data count]; }
- (void)addObject:(id)o { [_data addObject:o]; }
- (void)removeObject:(id)o { [_data removeObject:o]; }
@end
@interface FClip:NSObject @property BOOL clippingCursor; @end
@implementation FClip @end
@interface FWindow:NSObject
@property(nonatomic) CGRect frame;
@property CGRect native;
@property(retain) FWindow *parentWindow;
- (CGRect)mouseConfinementRect;
- (void)setMouseConfinementRect:(CGRect)r;
- (CGRect)contentRectForFrameRect:(CGRect)r;
- (CGRect)convertRectFromScreen:(CGRect)r;
@end
@implementation FWindow
@synthesize frame=_frame;
- (CGRect)frame { frameReads++;return _frame; }
- (CGRect)mouseConfinementRect { nativeReads++;return _native; }
- (void)setMouseConfinementRect:(CGRect)r { writes++;_native=rejectRect?(CGRect){{0,0},{0,0}}:r; }
- (CGRect)contentRectForFrameRect:(CGRect)r { r.origin.y+=10;r.size.height-=30;return r; }
- (CGRect)convertRectFromScreen:(CGRect)r { r.origin.x-=_frame.origin.x;r.origin.y-=_frame.origin.y;return r; }
@end
@interface FApp:NSObject
@property(getter=isActive) BOOL active;
@property(retain) id keyWindow;
@end
@implementation FApp @end
@interface FController:NSObject {
@public BOOL clientWantsCursorHidden;id windowsBeingDragged;id clipCursorHandler;
}
@property(nonatomic,retain) id mouseCaptureWindow;
@property BOOL clippingCursor;
- (CGPoint)flippedMouseLocation:(CGPoint)p;
@end
@implementation FController
@synthesize mouseCaptureWindow=_mouseCaptureWindow;
- (id)mouseCaptureWindow { captureQueries++;return _mouseCaptureWindow; }
- (BOOL)clippingCursor { clipQueries++;return [clipCursorHandler clippingCursor]; }
- (void)setClippingCursor:(BOOL)value { if(!clipCursorHandler&&value)clipCursorHandler=[FClip new];[clipCursorHandler setClippingCursor:value]; }
- (CGPoint)flippedMouseLocation:(CGPoint)p { flipQueries++;p.y=1000-p.y;return p; }
@end
static FApp *app;static FWindow *window;static FController *controller;static id appObject;
static BOOL delegateWarp(id self,SEL cmd,CGPoint p) { assert(self==controller);warps++;return warpOK; }
static void delegateUnhide(id self,SEL cmd) { unhides++;((FController*)self)->clientWantsCursorHidden=NO; }
static void delegateCapture(id self,SEL cmd,id c) { captures++;((FController*)self).mouseCaptureWindow=c; }
static void delegateDrag(id self,SEL cmd,id w,BOOL drag) { FController*c=self;if(drag)[c->windowsBeingDragged addObject:w];else[c->windowsBeingDragged removeObject:w]; }
static BOOL delegateStart(id self,SEL cmd,CGRect r) { ((FController*)self).clippingCursor=YES;[window setMouseConfinementRect:r];return YES; }
static BOOL delegateStop(id self,SEL cmd) { ((FController*)self).clippingCursor=NO;[window setMouseConfinementRect:(CGRect){{0,0},{0,0}}];return NO; }
static CGPoint target(void) { CGRect r=[window contentRectForFrameRect:window.frame];return (CGPoint){r.origin.x+r.size.width/2,1000-r.origin.y-r.size.height/2}; }
static void scene(void) {
 release_lease("test-reset");invalidate_geometry();entry_blocked=0;dragging_cached=NO;rejectRect=NO;warpOK=YES;
 app.active=YES;window=[FWindow new];window.frame=(CGRect){{100,100},{800,600}};app.keyWindow=window;
 controller=[FController new];controller->clientWantsCursorHidden=YES;controller->windowsBeingDragged=[FSet new];controller.mouseCaptureWindow=window;
 writes=warps=unhides=captures=0;
}
static void arm(void) { assert(camera_warp(controller,@selector(setCursorPosition:),target()));assert(lease.active); }
static void notify(id object) { camera_notification(nil,NULL,[NSNotification notificationWithName:@"fixture" object:object]); }
int main(void) { @autoreleasepool {
 app=[FApp new];appObject=app;application_slot=&appObject;
 assert(startup_slot_is_safe(&appObject));app.keyWindow=[NSObject new];assert(!startup_slot_is_safe(&appObject));app.keyWindow=nil;assert(!startup_slot_is_safe(NULL));
 wine_window_class=[FWindow class];active_selector=@selector(isActive);key_selector=@selector(keyWindow);kind_selector=@selector(isKindOfClass:);
 capture_selector=@selector(mouseCaptureWindow);clipping_selector=@selector(clippingCursor);parent_selector=@selector(parentWindow);
 native_get=@selector(mouseConfinementRect);native_set=@selector(setMouseConfinementRect:);frame_selector=@selector(frame);
 client_selector=@selector(contentRectForFrameRect:);convert_selector=@selector(convertRectFromScreen:);flip_selector=@selector(flippedMouseLocation:);
 hidden_ivar=class_getInstanceVariable([FController class],"clientWantsCursorHidden");dragging_ivar=class_getInstanceVariable([FController class],"windowsBeingDragged");
 capture_ivar=class_getInstanceVariable([FController class],"_mouseCaptureWindow");handler_ivar=class_getInstanceVariable([FController class],"clipCursorHandler");
 hidden_offset=ivar_getOffset(hidden_ivar);capture_offset=ivar_getOffset(capture_ivar);handler_offset=ivar_getOffset(handler_ivar);original_drag=(IMP)delegateDrag;
 original_warp=delegateWarp;original_unhide=(IMP)delegateUnhide;original_capture=(IMP)delegateCapture;original_start_clip=(IMP)delegateStart;original_stop_clip=(IMP)delegateStop;
 unsigned cases=0;
 for(int active=0;active<2;active++)for(int key=0;key<3;key++)for(int hidden=0;hidden<2;hidden++)for(int cap=0;cap<5;cap++)
 for(int center=0;center<2;center++)for(int drag=0;drag<2;drag++)for(int explicit=0;explicit<2;explicit++)for(int success=0;success<2;success++) {
  scene();app.active=active;app.keyWindow=key==0?nil:(key==1?[NSObject new]:window);controller->clientWantsCursorHidden=hidden;
  FWindow *child=[FWindow new];child.parentWindow=window;
  controller.mouseCaptureWindow=cap==0?nil:(cap==1?[NSObject new]:(cap==2?window:(cap==3?child:[FWindow new])));
  camera_drag(controller,@selector(window:isBeingDragged:),window,drag);controller.clippingCursor=explicit;warpOK=success;
  BOOL result=camera_warp(controller,@selector(setCursorPosition:),center?target():(CGPoint){0,0});
  BOOL eligible=active&&key==2;BOOL qualified=eligible&&hidden&&(cap==0||cap==2||cap==3)&&center&&!drag&&!explicit&&success;
  assert(warps==(unsigned)eligible && result==(eligible?success:NO));assert(lease.active==qualified);
  assert(writes==(unsigned)qualified);cases++;
 }
 scene();arm();unsigned before=writes;assert(camera_warp(controller,@selector(setCursorPosition:),target()));assert(writes==before);
 camera_unhide(controller,@selector(unhideCursor));assert(!lease.active&&rect_empty(window.native)&&unhides==1&&!controller->clientWantsCursorHidden);
 scene();arm();camera_capture(controller,@selector(setMouseCaptureWindow:),nil);assert(lease.active&&!rect_empty(window.native)&&captures==1&&!controller.mouseCaptureWindow);
 before=writes;assert(camera_warp(controller,@selector(setCursorPosition:),target())&&lease.active&&writes==before);
 FWindow*ownedChild=[FWindow new];ownedChild.parentWindow=window;camera_capture(controller,@selector(setMouseCaptureWindow:),ownedChild);assert(lease.active&&writes==before);
 camera_capture(controller,@selector(setMouseCaptureWindow:),nil);assert(lease.active&&writes==before);
 camera_unhide(controller,@selector(unhideCursor));assert(!lease.active&&rect_empty(window.native));
 scene();controller.mouseCaptureWindow=nil;arm();CGPoint steady=target();frameReads=nativeReads=flipQueries=captureQueries=clipQueries=dragQueries=0;before=writes;
 for(unsigned i=0;i<10000;i++)assert(camera_warp(controller,@selector(setCursorPosition:),steady));
 assert(lease.active&&writes==before&&!frameReads&&!nativeReads&&!flipQueries&&!captureQueries&&!clipQueries&&!dragQueries);
 camera_drag(controller,@selector(window:isBeingDragged:),window,YES);assert(!lease.active&&rect_empty(window.native));
 camera_drag(controller,@selector(window:isBeingDragged:),window,NO);arm();camera_unhide(controller,@selector(unhideCursor));assert(!lease.active);
 scene();controller.mouseCaptureWindow=nil;arm();FWindow*second=[FWindow new];
 camera_drag(controller,@selector(window:isBeingDragged:),window,YES);camera_drag(controller,@selector(window:isBeingDragged:),second,YES);assert(dragging_cached&&!lease.active);
 camera_drag(controller,@selector(window:isBeingDragged:),window,NO);assert(dragging_cached);assert(camera_warp(controller,@selector(setCursorPosition:),target())&&!lease.active);
 camera_drag(controller,@selector(window:isBeingDragged:),second,NO);assert(!dragging_cached);arm();
 scene();arm();camera_capture(controller,@selector(setMouseCaptureWindow:),[FWindow new]);assert(!lease.active&&rect_empty(window.native));
 scene();arm();assert(camera_warp(controller,@selector(setCursorPosition:),(CGPoint){0,0}));assert(!lease.active&&rect_empty(window.native));
 scene();arm();app.active=NO;notify(app);assert(!lease.active&&rect_empty(window.native));before=warps;assert(!camera_warp(controller,@selector(setCursorPosition:),target())&&warps==before);
 scene();arm();notify(window);assert(!lease.active&&rect_empty(window.native)&&!geometry.owner);
 scene();arm();window.frame=(CGRect){{-1000,200},{900,700}};notify(window);arm();assert(rect_equal(window.native,geometry.local));
 scene();arm();CGRect ours=lease.native_rect;assert(camera_start_clip(controller,@selector(startClippingCursor:),ours));assert(!lease.active&&rect_equal(window.native,ours));
 assert(camera_warp(controller,@selector(setCursorPosition:),target()));assert(!lease.active&&rect_equal(window.native,ours));
 scene();arm();assert(!camera_stop_clip(controller,@selector(stopClippingCursor)));assert(!lease.active&&rect_empty(window.native));
 assert(camera_warp(controller,@selector(setCursorPosition:),target())&&!lease.active);camera_unhide(controller,@selector(unhideCursor));controller->clientWantsCursorHidden=YES;arm();
 scene();CGRect foreign={{3,4},{100,80}};window.native=foreign;assert(camera_warp(controller,@selector(setCursorPosition:),target()));assert(!lease.active&&rect_equal(window.native,foreign));camera_unhide(controller,@selector(unhideCursor));assert(rect_equal(window.native,foreign));
 scene();arm();window.native=foreign;camera_unhide(controller,@selector(unhideCursor));assert(!lease.active&&rect_equal(window.native,foreign));
 scene();rejectRect=YES;assert(camera_warp(controller,@selector(setCursorPosition:),target()));assert(!lease.active&&rect_empty(window.native));before=writes;assert(camera_warp(controller,@selector(setCursorPosition:),target()));assert(writes==before);
 scene();arm();warpOK=NO;assert(!camera_warp(controller,@selector(setCursorPosition:),target()));assert(!lease.active&&rect_empty(window.native));
 scene();CGPoint p=target();p.x+=1;assert(camera_warp(controller,@selector(setCursorPosition:),p)&&lease.active);p.x+=0.01;assert(camera_warp(controller,@selector(setCursorPosition:),p)&&!lease.active);
 release_lease("test-end");invalidate_geometry();
 printf("PASS: %u predicate/delegation cases plus nullable capture continuity, 10000 steady calls without redundant getter/native queries, reversible lease, geometry, explicit-clip priority, foreign ownership and failure fences\n",cases);
 } return 0; }
'''
(root/'fixture.m').write_text(fixture)
subprocess.run(common+['-I',str(here),str(root/'fixture.m'),'-framework','Foundation','-o',str(root/'fixture')],check=True)
run=subprocess.run([str(root/'fixture')],env=base,check=True,capture_output=True,text=True)
assert sha(module)=='365fefb1c0bf4c0e54f4fd3a00dbd44bd9a6febc75209846b6de2c270bdb9c60'
assert sha(upper)=='15c047bb78a84da940eb86eff692e6aa6b74ed69975613c93715b9f3ce0f13f7'
report={'sourceSHA256':sha(here/'native_camera_compat.m'),'sharedFrozenSourceSHA256':sha(here/'foreground_warp_compat.m'),'testSHA256':sha(pathlib.Path(__file__)),'binarySHA256':sha(shim),'loaderProbe':results,'loaderRegression':regression,'loaderInterpose':False,'mainRunloopInstall':True,'fixture':run.stdout.strip(),'nativeOnly':True,'fullClientRect':True,'oemWarpDelegated':True,'highHzOptimization':False,'deployed':False}
(root/'native-camera-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print(run.stdout.strip());print(json.dumps(report,indent=2))
