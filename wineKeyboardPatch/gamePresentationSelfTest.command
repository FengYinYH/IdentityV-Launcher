#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
(( $# <= 2 )) || { print -u2 -- "用法：${0:t} [独立输出目录 [原签名Wine loader]]"; exit 2; }
output="${1:-$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}identityv-presentation.XXXXXX")}"
/bin/mkdir -p "$output"
output="${output:A}"

# Compile the production policy directly. The probe macro disables only the
# constructor's input/audio installation; it does not replace adapter logic.
typeset -a presentation_clang_flags
presentation_clang_flags=(-arch x86_64 -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0
         -framework AppKit -framework Carbon -framework CoreAudio)
/usr/bin/xcrun clang "${presentation_clang_flags[@]}" "$root/GamePresentationPolicyTest.m" "$root/IdentityVAudioKeyPolicy.c" -o "$output/PolicyTest"
"$output/PolicyTest"
/usr/bin/python3 - "$output/PolicyTest" <<'PY'
import subprocess, sys
cases = [(r'C:\Games\IdentityV\dwrg.exe', 0), (r'C:\Games\IdentityVGlobal\dwrg.exe', 0),
         ('C:/Games/IdentityVGlobal/DWRG.EXE', 0), ('dwrg.exe', 0),
         (r'C:\Games\IdentityV\dwrg.exe.bak', 10), ('--name=dwrg.exe', 10), ('winecfg.exe', 10)]
for argument, expected in cases:
    result = subprocess.run(['/bin/zsh', '-c', 'exec "$1" --scope "$2"', 'scope-test', sys.argv[1], argument])
    assert result.returncode == expected, (argument, result.returncode, expected)
print('Actual zsh argv scope: both products, single Windows separators, slash/case and non-game negatives passed')
PY
/usr/bin/python3 - "$output/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps(dict(CFBundleName='wine', CFBundleDisplayName='wine',
    CFBundleIdentifier='com.fengyin.identityv.presentation-name-probe', CFBundleExecutable='NameProbe',
    CFBundlePackageType='APPL', LSUIElement=True)))
PY
/usr/bin/xcrun clang "${presentation_clang_flags[@]}" -Wl,-sectcreate,__TEXT,__info_plist,"$output/Info.plist" \
  "$root/GamePresentationNameProbe.m" "$root/IdentityVAudioKeyPolicy.c" -o "$output/NameProbe"
/usr/bin/codesign --force --sign - "$output/NameProbe" >/dev/null
/usr/bin/xcrun swiftc "$root/GamePresentationNameReadback.swift" -o "$output/Readback"
/usr/bin/python3 - "$output" <<'PY'
from pathlib import Path
import json, os, subprocess, sys
output = Path(sys.argv[1])
results = []
for name in ('第五人格', 'Identity V'):
    environment = os.environ.copy()
    environment.pop('IDENTITYV_GAME_DISPLAY_NAME', None)
    environment.pop('WINEPRELOADERAPPNAME', None)
    environment['IDENTITYV_PRESENTATION_AUDIT'] = '1'
    child = subprocess.Popen([str(output/'NameProbe'), name, r'C:\Games\IdentityV\dwrg.exe'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        sample = json.loads(child.stdout.readline())
        query = subprocess.run([str(output/'Readback'), str(child.pid), name], text=True, capture_output=True)
        remaining, diagnostic = child.communicate(timeout=15)
        result = dict(sample=sample, external=json.loads(query.stdout), diagnostic=diagnostic,
                      probeExit=child.returncode, readbackExit=query.returncode)
        results.append(result)
        assert sample['before'] == 'wine' and sample['statusSucceeded'] and sample['missingSymbolsNoop'], result
        assert not sample['active'] and not sample['visible'] and sample['nativeIconMaskVerified'] and sample['postLaunchPreloaderAbsent'], result
        audits = [json.loads(line.split('audit: ', 1)[1]) for line in diagnostic.splitlines() if line.startswith('IdentityV presentation audit: ')]
        assert len(audits) <= 32 and any(item['reason'] == 'icon' for item in audits), result
        assert child.returncode == query.returncode == 0, result
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
(output/'name-results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
print('Historical LS getter contrast passed (not Dock acceptance); native icon bridge remains inactive/hidden and absent-symbol safe.')
PY
/usr/bin/xcrun clang -arch x86_64 -dynamiclib -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -framework CoreFoundation "$root/GameNameLoaderProbe.c" -o "$output/GameNameLoaderProbe.dylib"
/usr/bin/codesign --force --sign - "$output/GameNameLoaderProbe.dylib" >/dev/null
if (( $# == 2 )); then
  /usr/bin/python3 - "$output" "$2" <<'PY'
from pathlib import Path
import json, os, subprocess, sys
output, loader = Path(sys.argv[1]), Path(sys.argv[2])
import hashlib
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(loader)], check=True)
original_digest = hashlib.sha256(loader.read_bytes()).hexdigest()
results = []
for name in ('第五人格', 'Identity V'):
  for inherited, rearm in ((True, False), (False, True), (True, True)):
    environment = os.environ.copy()
    environment.pop('WINEPRELOADERAPPNAME', None)
    if inherited: environment['WINEPRELOADERAPPNAME'] = name
    environment['IDENTITYV_LOADER_PROBE_REARM'] = '1' if rearm else '0'
    environment['IDENTITYV_GAME_DISPLAY_NAME'] = name
    environment['DYLD_INSERT_LIBRARIES'] = str(output/'GameNameLoaderProbe.dylib')
    environment['WINEPREFIX'] = str(output/'unused-version-prefix')
    result = subprocess.run([str(loader), '--version'], env=environment, text=True, capture_output=True, timeout=15)
    rows = [json.loads(line.split('probe: ', 1)[1]) for line in result.stderr.splitlines() if line.startswith('IdentityV loader bootstrap probe: ')]
    assert result.returncode == 0 and rows, (result.returncode, result.stderr)
    for item in rows:
        assert item['presentBefore'] == inherited and item['restored'] == rearm and item['consumedByMain'], item
        if not rearm:
            assert item['rawNameMatches'] and item['vmWriteSeen'] and item['vmWriteStatus'] == 0 and item['vmRestoreStatus'] == 0, item
        elif item['afterUnsetLength'] == 0:
            assert not item['rawNameMatches'] and not item['vmWriteSeen'], item
        # Record future allocator behavior rather than requiring a dangling
        # pointer bug to persist. Neither rearm nor this observer is production.
    assert not (output/'unused-version-prefix').exists(), 'version probe unexpectedly created a prefix'
    results.append(dict(selected=name, inherited=inherited, rearm=rearm, rows=rows, loaderExit=result.returncode, version=result.stdout.strip()))
assert hashlib.sha256(loader.read_bytes()).hexdigest() == original_digest, 'loader file changed'
(output/'loader-results.json').write_text(json.dumps(dict(loaderSHA256=original_digest, cases=results), ensure_ascii=False, indent=2)+'\n')
print('Original signed Wine contrast: inherited input rewrites raw Info; setenv/unsetenv ownership and exact VM results recorded separately, no production rearm or prefix writes')
PY
fi
# An isolated candidate, never copied into templates, a runtime or /Applications.
/usr/bin/xcrun clang "${presentation_clang_flags[@]}" -dynamiclib -Wl,-install_name,@rpath/IdentityVCommandGraveForwarder.dylib \
  "$root/IdentityVCommandGraveForwarder.m" "$root/IdentityVAudioKeyPolicy.c" -o "$output/IdentityVCommandGraveForwarder.dylib"
/usr/bin/codesign --force --sign - --identifier com.fengyin.identityv.runner.command-grave-forwarder \
  "$output/IdentityVCommandGraveForwarder.dylib" >/dev/null
/usr/bin/codesign --verify --strict "$output/IdentityVCommandGraveForwarder.dylib"
print -r -- "Presentation self-test passed; isolated artifacts: $output"
