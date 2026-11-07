#!/usr/bin/env python3
"""Exercise actual C loggers without Wine, AppKit, windows or input.
The v3 pair uses fixed 48+16 shares; no cross-module exports are required.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]) / 'dlls/winemac.drv'
def extract(path):
    text = path.read_text()
    return text[text.index('/* IDV_CAPTURE_TRANSPORT_BEGIN'):text.index('/* IDV_CAPTURE_TRANSPORT_END */')]
transport = extract(source / 'macdrv_main.c')
paired = 'capture_diag_records >= 48' in transport
if paired:
    upper = extract(source.parent / 'win32u/input.c')
    upper = upper.replace('macdrv_capture_diag_', 'upper_capture_diag_').replace('static unsigned capture_diag_', 'static unsigned upper_state_')
    upper = upper.replace('capture_diag_mutex', 'upper_state_mutex').replace('capture_diag_records', 'upper_state_records').replace('capture_diag_once_bits', 'upper_state_once_bits')
else:
    upper = ''
includes = '#include "capture_diagnostics.h"\n#include <pthread.h>\n#include <stdarg.h>\n#include <stdlib.h>\n#include <string.h>\n#include <unistd.h>\n#define IDV_DIAG_WIN32U_MODULE (1u << 15)\n'
probe = r'''
int main(void) {
    macdrv_capture_diag_module_start(1);
    macdrv_capture_diag_module_start(1);
    UPPER_START
    for (unsigned i = 0; i < 100; i++) {
        macdrv_capture_diag_log(IDV_DIAG_WARP, "reason=warp-once");
        macdrv_capture_diag_log(IDV_DIAG_HANDLER, "reason=handler-once");
        macdrv_capture_diag_log(0, "reason=snapshot");
        UPPER_LOG
    }
    return 0;
}
'''
probe = probe.replace('UPPER_START', 'upper_capture_diag_module_start(-2);' if paired else '')
probe = probe.replace('UPPER_LOG', 'upper_capture_diag_log(IDV_DIAG_WARP, "reason=upper-once"); upper_capture_diag_log(0, "reason=upper-snapshot");' if paired else '')
with tempfile.TemporaryDirectory(prefix='idv-capture-transport-') as temp:
    root = pathlib.Path(temp)
    (root / 'probe.c').write_text(includes + transport + upper + probe)
    for diagnostic_build in (False, True):
        binary = root / ('diagnostic' if diagnostic_build else 'normal')
        command = ['clang', '-Werror', '-I', str(source), str(root / 'probe.c'), '-o', str(binary)]
        if diagnostic_build:
            command += ['-DIDENTITYV_CAPTURE_DIAGNOSTIC_BUILD=1']
        subprocess.run(command, check=True)
        for value in (None, 'yes', '1'):
            env = os.environ.copy()
            env.pop('IDENTITYV_CAPTURE_DIAGNOSTICS', None)
            if value is not None:
                env['IDENTITYV_CAPTURE_DIAGNOSTICS'] = value
            result = subprocess.run([str(binary)], env=env, capture_output=True, text=True, check=True)
            lines = result.stderr.splitlines()
            presence_count = 2 if paired else 1
            if value != '1':
                assert len(lines) == (presence_count if diagnostic_build else 0), result.stderr
                assert all('reason=module-start enabled=0 diagnosticBuild=1' in line for line in lines)
            else:
                assert len(lines) == 64, result.stderr
                assert sum('reason=module-start' in line for line in lines) == presence_count
                assert sum('reason=warp-once' in line for line in lines) == 1
                assert sum('reason=handler-once' in line for line in lines) == 1
                if paired:
                    for layer, budget in [('macdrv', 48), ('win32u', 16)]:
                        selected = [line for line in lines if f'layer={layer} ' in line]
                        assert len(selected) == budget
                        assert [int(re.search(r' seq=(\d+) ', line)[1]) for line in selected] == list(range(1, budget + 1))
                else:
                    assert [int(re.search(r' seq=(\d+) ', line)[1]) for line in lines] == list(range(1, 65))
            version = '3 ' if paired else '2 '
            assert all(line.startswith('IDV_CAPTURE_DIAG v=' + version) for line in lines)
    print('PASS: ordinary default quiet; isolated per-module presence; exact env gate; once bits; hard process budget 48+16=64' if paired else 'PASS: isolated presence and shared 64-record budget')
