#!/usr/bin/env python3
"""Run the complete BSS generator with native append, never a radio/daemon."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
sys.argv = sys.argv[:1]
HOST = (ROOT/'package/network/config/wifi-scripts/files/lib/netifd/hostapd.sh').read_text()
LIB = (ROOT/'package/base-files/files/lib/functions.sh').read_text()
def function(name, source):
    return re.search(r'(?ms)^'+name+r'\(\) \{.*?^\}', source).group()
APPEND = function('append', LIB)
BSS = function('hostapd_set_bss_options', HOST)
DISCOVERY = function('hostapd_set_6ghz_discovery', HOST)
SHELL = shlex.split(os.environ.get('DISCOVERY_TEST_SHELL', '/bin/sh'))
STUBS = '''
N='
'
json_get_var() {
    case "$2" in
    fils_discovery_min_interval) eval "$1=\\\"$TEST_MIN\\\"";;
    fils_discovery_max_interval) eval "$1=\\\"$TEST_MAX\\\"";;
    unsol_bcast_probe_resp_interval) eval "$1=\\\"$TEST_UNSOL\\\"";;
    *) eval "$1=''";; esac
}
json_get_vars() { local arg; for arg in "$@"; do json_get_var "${arg%%:*}" "${arg%%:*}"; done; ssid=fixture; }
json_get_values() { eval "$1=''"; }
json_for_each_item() { :; }
json_select() { return 1; }
set_default() { eval "[ -n \\"\\${$1}\\" ] || $1=\\\"$2\\\""; }
wireless_vif_parse_encryption() { wpa=0; auth_type=fixture; auth_mode_open=1; auth_mode_shared=0; }
hostapd_feature_probe() { return 1; }
wireless_setup_vif_failed() { echo "unexpected setup failure" >&2; exit 98; }
touch() { echo "unexpected write" >&2; exit 99; }
rm() { echo "unexpected removal" >&2; exit 99; }
band="$TEST_BAND"
'''

def generate(band='6g', minimum='', maximum='20', unsol='', broken=False):
    # Only replace the executable feature query. All append calls and the
    # entire real caller/control-flow are retained, unlike the old helper test.
    bss = BSS.replace('/usr/sbin/hostapd -vfils', 'hostapd_feature_probe -vfils')
    if broken:
        bss = bss.replace('\n\thostapd_set_6ghz_discovery', '')
        bss = bss.replace('\tlocal bss_conf bss_md5sum ft_key rxkhs',
                          '\tlocal bss_conf bss_md5sum ft_key rxkhs\n\thostapd_set_6ghz_discovery')
    env = dict(os.environ, TEST_BAND=band, TEST_MIN=minimum,
               TEST_MAX=maximum, TEST_UNSOL=unsol)
    result = subprocess.run(SHELL, input=APPEND+'\n'+STUBS+'\n'+DISCOVERY+'\n'+bss+
                            '\nhostapd_set_bss_options result fixture fixture\nprintf "%s\\n" "$result"\n',
                            text=True, capture_output=True, env=env)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip().splitlines()

class Integration(unittest.TestCase):
    def test_actual_parser_complete_output_and_power_enums(self):
        target = os.environ.get('DISCOVERY_TARGET_ROOT')
        if not target:
            self.skipTest('set DISCOVERY_TARGET_ROOT for actual target parser')
        target = Path(target)
        emulator = os.environ.get('DISCOVERY_TARGET_EMULATOR', 'qemu-aarch64')
        power_block = re.search(r'(?ms)^\t\[ "\$band" = "6g" \] && \{\n\t\tset_default reg_power_type 0\n\t\tappend base_cfg "he_6ghz_reg_pwr_type=\$reg_power_type" "\$N"\n\t\}', HOST).group()
        self.assertIn('config_add_int reg_power_type', HOST)
        with tempfile.TemporaryDirectory(prefix='bss-parser.') as tmp:
            config = Path(tmp)/'hostapd.conf'
            for power in ['', '0', '1', '2', '99']:
                env = dict(os.environ, TEST_BAND='6g')
                script = APPEND+'\n'+STUBS+'\nreg_power_type='+power+'\n'+power_block+'\nprintf "%s" "$base_cfg"\n'
                emitted = subprocess.run(SHELL, input=script, env=env, text=True, capture_output=True, check=True).stdout
                self.assertEqual(emitted.strip(), 'he_6ghz_reg_pwr_type='+ (power or '0'))
                config.write_text('driver=deliberately_invalid_no_radio\n'+emitted+'\n'+'\n'.join(generate())+'\n')
                result = subprocess.run([emulator,'-L',str(target),str(target/'usr/sbin/wpad'),'hostapd',str(config)], text=True, capture_output=True, timeout=5)
                output = result.stdout+result.stderr
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('invalid/unknown driver', output)
                self.assertNotIn('unknown configuration item', output)
                self.assertEqual('invalid he_6ghz_reg_pwr_type' in output, power == '99')

    def test_full_caller_separate_lines(self):
        for val in ['0', '20']:
            lines = generate(minimum=val, maximum=val, unsol=val)
            self.assertEqual(lines[0], 'ctrl_interface=/var/run/hostapd')
            for key in ['fils_discovery_min_interval', 'fils_discovery_max_interval', 'unsol_bcast_probe_resp_interval']:
                self.assertEqual(lines.count(key+'='+val), 1)
            self.assertFalse(any(' ctrl_interface=' in line for line in lines))

    def test_original_bug_is_detected(self):
        self.assertIn('fils_discovery_max_interval=20 ctrl_interface=/var/run/hostapd', generate(broken=True))

    def test_other_bands_and_no_defaults(self):
        for band in ['2g', '5g', '']:
            lines = generate(band=band)
            self.assertEqual(lines[0], 'ctrl_interface=/var/run/hostapd')
            self.assertFalse(any('discovery_' in line for line in lines))
        self.assertFalse(any('discovery_' in line for line in generate(maximum='')))

if __name__ == '__main__':
    unittest.main()
