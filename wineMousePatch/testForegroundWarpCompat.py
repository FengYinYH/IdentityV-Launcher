#!/usr/bin/env python3
"""Build/test a known-hash OEM compatibility candidate, without Wine initialization.
Usage: testForegroundWarpCompat.py BASE_RUNTIME NEW_OUTPUT_DIR
Loads the existing OEM module in a fresh x86_64 CLI for class/type/loader checks;
never creates NSApplication, windows, a prefix, or input. Never touches a game.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys

here = pathlib.Path(__file__).resolve().parent
runtime = pathlib.Path(sys.argv[1]).resolve(strict=True)
root = pathlib.Path(sys.argv[2])
module = runtime / 'lib/wine/x86_64-unix/winemac.so'
upper = runtime / 'lib/wine/x86_64-unix/win32u.so'
expected = '365fefb1c0bf4c0e54f4fd3a00dbd44bd9a6febc75209846b6de2c270bdb9c60'
assert hashlib.sha256(module.read_bytes()).hexdigest() == expected
assert hashlib.sha256(upper.read_bytes()).hexdigest() == '15c047bb78a84da940eb86eff692e6aa6b74ed69975613c93715b9f3ce0f13f7'
root.mkdir()
root = root.resolve()
shim = root / 'foreground-warp-compat.dylib'
common = ['clang', '-arch', 'x86_64', '-O2', '-mmacosx-version-min=14.0', '-Werror', '-Wno-deprecated-declarations']
subprocess.run(common + ['-dynamiclib', '-fvisibility=hidden', str(here / 'foreground_warp_compat.m'), '-lobjc', '-o', str(shim)], check=True)
probe = r'''
#include <CoreGraphics/CGGeometry.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv) {
 dlerror();errno=E2BIG;
 void *bad=dlopen("/identityv-compat-nonexistent-library.dylib",RTLD_NOW);
 int failureErrno=errno;const char *error=dlerror();
 int failureMessage=!bad && error && strstr(error,"identityv-compat-nonexistent-library");
 errno=ERANGE;
 void *module=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
 int successErrno=errno;
 if(!module) { fprintf(stderr,"module load failed: %s\n",dlerror());return 2; }
 Class cls=objc_getClass("WineApplicationController");
 Method m=class_getInstanceMethod(cls,sel_registerName("setCursorPosition:"));
 if(!m) return 3;
 IMP implementation=method_getImplementation(m);Dl_info owner;
 if(!dladdr((const void*)implementation,&owner)) return 4;
 char path[4096],shim[4096];
 int installed=realpath(owner.dli_fname,path) && realpath(argv[2],shim) && !strcmp(path,shim);
 id *app=(id*)dlsym(RTLD_DEFAULT,"NSApp");
 if(!app || *app) return 5;
 int denied=installed ? !((BOOL(*)(id,SEL,CGPoint))implementation)(nil,sel_registerName("setCursorPosition:"),(CGPoint){0,0}) : -1;
 printf("{\"installed\":%d,\"applicationCreated\":0,\"deniedWithoutApp\":%d,\"failureErrno\":%d,\"failureMessage\":%d,\"successErrno\":%d,\"signature\":\"%s\"}\n",installed,denied,failureErrno,!!failureMessage,successErrno,method_getTypeEncoding(m));
 return 0;
}
'''
(root / 'loader-probe.m').write_text(probe)
loader = root / 'loader-probe'
subprocess.run(common + [str(root / 'loader-probe.m'), '-lobjc', '-Wl,-rpath,' + str(module.parent), '-Wl,-rpath,' + str(runtime / 'lib64'), '-o', str(loader)], check=True)
base_env = os.environ.copy()
for key in ('DYLD_INSERT_LIBRARIES', 'IDENTITYV_FOREGROUND_WARP_GATE', 'IDENTITYV_WARP_GATE_AUDIT', 'IDENTITYV_CAPTURE_DIAGNOSTICS'):
    base_env.pop(key, None)
results = {}
for mode in ('without-shim', 'disabled', 'enabled'):
    env = base_env.copy()
    if mode != 'without-shim':
        env['DYLD_INSERT_LIBRARIES'] = str(shim)
        env['IDENTITYV_FOREGROUND_WARP_GATE'] = '1' if mode == 'enabled' else '0'
        env['IDENTITYV_WARP_GATE_AUDIT'] = '1'
    run = subprocess.run([str(loader), str(module), str(shim)], env=env, check=True, capture_output=True, text=True)
    info = json.loads(run.stdout)
    assert info['installed'] == int(mode == 'enabled'), (mode, run.stdout, run.stderr)
    assert info['failureMessage'] and not info['applicationCreated']
    if mode == 'enabled':
        assert info['deniedWithoutApp'] == 1
        assert 'IDV_WARP_GATE installed' in run.stderr, run.stderr
    results[mode] = info
for key in ('failureErrno', 'successErrno', 'signature'):
    assert len({value[key] for value in results.values()}) == 1, (key, results)
fixture = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#define IDV_GATE_TEST 1
#include "foreground_warp_compat.m"
@interface FakeWindow : NSObject @end
@implementation FakeWindow @end
@interface FakeApp : NSObject
@property(getter=isActive) BOOL active;
@property(retain) id keyWindow;
@end
@implementation FakeApp @end
@interface Signature : NSObject
- (BOOL)valid:(CGPoint)p;
- (long)badReturn:(CGPoint)p;
- (BOOL)badArgument:(CGRect)p;
@end
@implementation Signature
- (BOOL)valid:(CGPoint)p { return YES; }
- (long)badReturn:(CGPoint)p { return 1; }
- (BOOL)badArgument:(CGRect)p { return YES; }
@end
static unsigned calls;static id expectedSelf;static SEL expectedCommand;static CGPoint expectedPoint;static BOOL result;
static BOOL delegate(id self,SEL command,CGPoint p) {
 assert(self==expectedSelf && command==expectedCommand && p.x==expectedPoint.x && p.y==expectedPoint.y);
 calls++;return result;
}
int main(int argc,char **argv) { @autoreleasepool {
 assert(module_has_known_hash(argv[1]));
 assert(!module_has_known_hash(argv[2]));
 assert(signature_matches(class_getInstanceMethod([Signature class],@selector(valid:))));
 assert(!signature_matches(class_getInstanceMethod([Signature class],@selector(badReturn:))));
 assert(!signature_matches(class_getInstanceMethod([Signature class],@selector(badArgument:))));
 FakeApp *app=[FakeApp new];id appValue=app;application_slot=&appValue;
 wine_window_class=[FakeWindow class];active_selector=@selector(isActive);key_selector=@selector(keyWindow);kind_selector=@selector(isKindOfClass:);
 original_warp=delegate;expectedSelf=[NSObject new];expectedCommand=@selector(valid:);
 unsigned cases=0;
 for(int active=0;active<2;active++)for(int key=0;key<3;key++)for(int returned=0;returned<2;returned++)for(int point=0;point<2;point++) {
 app.active=active;app.keyWindow=key==0?nil:(key==1?[NSObject new]:[FakeWindow new]);
 expectedPoint=point?(CGPoint){-3.5,450.25}:(CGPoint){300.5,-47.25};result=returned;calls=0;
 BOOL actual=eligible_warp(expectedSelf,expectedCommand,expectedPoint);BOOL allowed=active&&key==2;
 assert(calls==(unsigned)allowed && actual==(allowed?returned:NO));cases++;
 }
 printf("PASS: %u eligibility/delegation cases; exact self/SEL/CGPoint/BOOL preserved; hash/type failures reject\n",cases);
 } return 0; }
'''
(root / 'fixture.m').write_text(fixture)
fixture_binary = root / 'fixture'
subprocess.run(common + ['-I', str(here), str(root / 'fixture.m'), '-framework', 'Foundation', '-o', str(fixture_binary)], check=True)
fixture_result = subprocess.run([str(fixture_binary), str(module), str(shim)], env=base_env, capture_output=True, text=True, check=True)
assert hashlib.sha256(module.read_bytes()).hexdigest() == expected
assert hashlib.sha256(upper.read_bytes()).hexdigest() == '15c047bb78a84da940eb86eff692e6aa6b74ed69975613c93715b9f3ce0f13f7'
report = {'baselineWinemacSHA256': expected, 'sourceSHA256': hashlib.sha256((here / 'foreground_warp_compat.m').read_bytes()).hexdigest(), 'compatSHA256': hashlib.sha256(shim.read_bytes()).hexdigest(), 'loaderProbe': results, 'fixture': fixture_result.stdout.strip(), 'startupOnly': True, 'eventDiagnostics': False, 'newInputTap': False, 'deployed': False}
(root / 'compat-audit.json').write_text(json.dumps(report, indent=2)+'\n')
print(fixture_result.stdout.strip())
print(json.dumps(report, indent=2))
