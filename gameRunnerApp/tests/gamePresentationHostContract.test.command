#!/bin/zsh
set -euo pipefail
root="${0:A:h:h:h}"
output="${1:-$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/identityv-host-contract.XXXXXX")}"
/bin/mkdir -p "$output"
/usr/bin/clang -x objective-c -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -Wall -Wextra -Werror \
  -framework AppKit "$root/gameRunnerApp/IdentityVLauncher.c" -o "$output/launchIdentityV"
/usr/bin/python3 - "$root" "$output" <<'PY'
from pathlib import Path
import concurrent.futures, hashlib, json, os, plistlib, shutil, subprocess, sys
root, out = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
engine = out/'engine 原核 with spaces'; engine.mkdir(exist_ok=True)
info = dict(CFBundleIdentifier='com.codeweavers.CrossOver.wineloader', CFBundlePackageType='APPL',
            CFBundleExecutable='wine', CFBundleName='CrossOver-Hosted Application', LSUIElement=True,
            NSMicrophoneUsageDescription='vendor microphone purpose', NSCameraUsageDescription='vendor camera purpose',
            LSMinimumSystemVersion='15.0', FixtureMetadataVersion='one')
plist = out/'fixture.plist'; plist.write_bytes(plistlib.dumps(info))
source = out/'Fixture.m'
source.write_text('''#import <Foundation/Foundation.h>
int main(void) { @autoreleasepool {
  NSBundle *bundle = NSBundle.mainBundle;
  NSDictionary *result = @{ @"bundle": bundle.bundleURL.path ?: @"", @"name": bundle.infoDictionary[@"CFBundleName"] ?: @"",
    @"argv": NSProcessInfo.processInfo.arguments, @"loader": NSProcessInfo.processInfo.environment[@"WINELOADER"] ?: @"",
    @"display": NSProcessInfo.processInfo.environment[@"IDENTITYV_GAME_DISPLAY_NAME"] ?: @"",
    @"preloader": NSProcessInfo.processInfo.environment[@"WINEPRELOADERAPPNAME"] ?: @"" };
  NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
  puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); return 0;
} }
''')
loader = engine/'wine'
subprocess.run(['/usr/bin/clang','-arch','arm64','-fobjc-arc','-mmacosx-version-min=14.0','-framework','Foundation',
                '-Wl,-sectcreate,__TEXT,__info_plist,'+str(plist), str(source), '-o',str(loader)],check=True)
subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier',info['CFBundleIdentifier'],str(loader)],check=True)
digest = hashlib.sha256(loader.read_bytes()).hexdigest()
cache = out/'cache 用户 with spaces'
profile = 'codeweavers-wine-release-dxmt'
def prepare(product='mainland', name='第五人格', cache_root=cache):
    return subprocess.run([str(out/'launchIdentityV'),'--prepare-game-host',str(loader),str(cache_root),product,name,profile],
                          text=True,capture_output=True)
paths = []
for product in ('mainland','global'):
    for name in ('第五人格','Identity V'):
        result = prepare(product,name); assert result.returncode == 0, result.stderr
        executable = Path(result.stdout.strip()); app = executable.parents[2]
        assert app.name == name+'.app' and executable.is_symlink() and executable.resolve() == loader
        metadata = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        assert metadata['CFBundleIdentifier'] == info['CFBundleIdentifier']
        assert metadata['NSMicrophoneUsageDescription'] == info['NSMicrophoneUsageDescription']
        assert metadata['NSCameraUsageDescription'] == info['NSCameraUsageDescription']
        assert metadata['LSSupportsGameMode'] and metadata['NSHighResolutionCapable']
        assert metadata['LSApplicationCategoryType'] == 'public.app-category.games'
        assert metadata['LSUIElement'] and metadata['CFBundleExecutable'] == 'wine'
        before = (app/'Contents/Info.plist').stat().st_mtime_ns
        reused = prepare(product,name)
        assert reused.returncode == 0, reused.stderr
        assert reused.stdout == result.stdout, (result.stdout, reused.stdout)
        assert (app/'Contents/Info.plist').stat().st_mtime_ns == before
        native = json.loads(subprocess.check_output([str(executable)],text=True))
        assert Path(native['bundle']) == app and native['name'] == name, native
        paths.append(str(executable))
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    simultaneous = list(pool.map(lambda _: prepare('global','Identity V',out/'concurrent'), range(12)))
assert all(item.returncode == 0 for item in simultaneous), [item.stderr for item in simultaneous]
assert len({item.stdout for item in simultaneous}) == 1
# Unknown existing objects are never replaced/deleted or followed.
app = Path(paths[0]).parents[2]; owned_plist = app/'Contents/Info.plist'
modified = plistlib.loads(owned_plist.read_bytes()); modified['UserSentinel']='retain me'
owned_plist.write_bytes(plistlib.dumps(modified)); saved = owned_plist.read_bytes()
assert prepare().returncode != 0 and owned_plist.read_bytes() == saved
alias_root = out/'alias-cache'; alias_root.mkdir(exist_ok=True)
foreign = out/'foreign'; foreign.mkdir(exist_ok=True)
(alias_root/'v1').symlink_to(foreign,target_is_directory=True)
assert prepare(cache_root=alias_root).returncode != 0 and not list(foreign.iterdir())
root_alias = out/'root-alias'; root_alias.symlink_to(foreign,target_is_directory=True)
assert prepare(cache_root=root_alias).returncode != 0 and not list(foreign.iterdir())
readonly = out/'readonly'; readonly.mkdir(exist_ok=True); readonly.chmod(0o500)
try: assert prepare(cache_root=readonly).returncode != 0
finally: readonly.chmod(0o700)
assert prepare(name='bad/name').returncode != 0 and prepare(product='unknown').returncode != 0
# Exact source runner fragments: metadata ARM mode precedes injection; final
# exec and WINELOADER stay host scoped, preserving Windows argv and parent.
for runner in ('IdentityV-Mac.app','IdentityV-AGTK.app'):
    text=(root/'gameRunnerApp'/runner/'Contents/MacOS/launchIdentityVRunner').read_text()
    assert text.count('# Final game presentation child:') == 2
    content = out/runner/'Contents'; (content/'MacOS').mkdir(parents=True,exist_ok=True); (content/'Resources').mkdir(exist_ok=True)
    shutil.copy2(out/'launchIdentityV',content/'MacOS/launchIdentityV')
    shutil.copy2(root/'gameRunnerApp/gamePresentationHost.command',content/'Resources/gamePresentationHost.command')
    for product in ('mainland','global'):
        for desktop in (False,True):
            marker = '# Final game presentation child:'
            fragment=text.split(marker)[1 if desktop else 2]
            fragment=fragment[:fragment.index('    ) >>')]
            if not desktop: fragment=fragment[:fragment.index('if (( ${#hud_environment')]+fragment[fragment.index('      # Resolve native language/control'):]
            prelude='typeset -a GAME_LAUNCH_ARGUMENTS\nGAME_LAUNCH_ARGUMENTS=(--one "two words")\n'
            code=prelude+'(\n# '+fragment+'\n)\nprint -r -- "parent=${WINELOADER-unset}"\n'
            env=os.environ.copy()
            for key in ('WINELOADER','DYLD_INSERT_LIBRARIES','IDENTITYV_NATIVE_CAMERA_CLIP','IDENTITYV_FOREGROUND_WARP_GATE'): env.pop(key,None)
            env.update(APP_CONTENTS=str(content),CONFIG_DIR=str(out/'runner-config'),WINE_BIN=str(loader),PRODUCT=product,
                       IDENTITYV_GAME_DISPLAY_NAME='Identity V',LAUNCH_PROFILE=profile,WINDOWS_GAME_ROOT='IdentityVGlobal' if product=='global' else 'IdentityV',
                       IDENTITYV_DESKTOP_NAME='IdentityV',IDENTITYV_DESKTOP_SIZE='1920x1080',wine_inserted_libraries='')
            result=subprocess.run(['/bin/zsh','-c',code],env=env,text=True,capture_output=True)
            assert result.returncode==0,(result.stdout,result.stderr,code)
            lines=result.stdout.splitlines(); sample=json.loads(lines[0]); assert lines[1]=='parent=unset',lines
            assert sample['display']==sample['preloader']=='Identity V'
            assert sample['loader'].endswith('/Identity V.app/Contents/MacOS/wine') and Path(sample['loader']).resolve()==loader,sample
            assert 'C:\\Games\\'+env['WINDOWS_GAME_ROOT']+'\\dwrg.exe' in sample['argv'],sample
            assert sample['argv'][-2:]==['--one','two words'],sample
# Unsupported/read-only/missing-helper paths remain executable and do not
# introduce a host override. These run the same shared library, not a replica.
for failure in ('unsupported','readonly','missing-helper'):
    content=out/'fallback.app/Contents'; (content/'Resources').mkdir(parents=True,exist_ok=True)
    (content/'MacOS').mkdir(exist_ok=True)
    shutil.copy2(root/'gameRunnerApp/gamePresentationHost.command',content/'Resources/gamePresentationHost.command')
    helper_path=content/'MacOS/launchIdentityV'
    if failure!='missing-helper': shutil.copy2(out/'launchIdentityV',helper_path)
    elif helper_path.exists():
        assert helper_path.resolve().is_relative_to(out)
        helper_path.unlink()
    config=out/('fallback-'+failure); config.mkdir(exist_ok=True)
    if failure=='readonly': config.chmod(0o500)
    env=os.environ.copy(); env.pop('WINELOADER',None)
    env.update(APP_CONTENTS=str(content),CONFIG_DIR=str(config),WINE_BIN=str(loader),PRODUCT='mainland',
               IDENTITYV_GAME_DISPLAY_NAME='Identity V',LAUNCH_PROFILE='unsupported' if failure=='unsupported' else profile)
    code='source "$APP_CONTENTS/Resources/gamePresentationHost.command"\nidentityv_prepare_game_presentation\nexec "$game_loader"\n'
    try:
        sample=json.loads(subprocess.check_output(['/bin/zsh','-c',code],env=env,text=True,stderr=subprocess.PIPE))
        assert sample['loader']=='' and sample['display']==sample['preloader']=='Identity V',sample
    finally: config.chmod(0o700)
assert hashlib.sha256(loader.read_bytes()).hexdigest()==digest
subprocess.run(['/usr/bin/codesign','--verify','--strict',str(loader)],check=True)
(out/'host-results.json').write_text(json.dumps(dict(loaderUnchanged=True,paths=paths,contracts='two products/locales, native bundle identity, cache reuse/concurrency, alias/readonly/foreign fallback, exact desktop/direct child scope'),ensure_ascii=False,indent=2)+'\n')
print('Game presentation host contracts passed without Wine, AppKit windows, activation, input or permissions')
PY
