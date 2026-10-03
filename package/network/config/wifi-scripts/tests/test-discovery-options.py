#!/usr/bin/env python3
"""Execute real discovery emission with synthetic JSON; no daemon/AP access."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import unittest

ROOT, PARSER = map(Path, sys.argv[1:3])
sys.argv = sys.argv[:1]
PKG = ROOT / 'package/network/config/wifi-scripts'
HOST = (PKG / 'files/lib/netifd/hostapd.sh').read_text()
MAC = (PKG / 'files/lib/netifd/wireless/mac80211.sh').read_text()
OPTIONS = ['fils_discovery_min_interval', 'fils_discovery_max_interval', 'unsol_bcast_probe_resp_interval']
SHELL = shlex.split(os.environ.get('DISCOVERY_TEST_SHELL', '/bin/sh'))
FUNCTION = re.search(r'(?ms)^hostapd_set_6ghz_discovery\(\) \{.*?^\}', HOST).group()
PSC = re.search(r'(?ms)^\tif \[ "\$auto_channel" -gt 0 \] && \[ "\$band" = "6g" \]; then\n\t\tjson_get_vars acs_exclude_6ghz_non_psc.*?^\tfi', MAC).group()
STUBS = '''
N='
'
append() { case "$1" in bss_conf) bss_conf="$bss_conf$3$2";; base_cfg) base_cfg="$base_cfg$3$2";; esac; }
json_get_var() { case "$2" in
fils_discovery_min_interval) value="$TEST_MIN";;
fils_discovery_max_interval) value="$TEST_MAX";;
unsol_bcast_probe_resp_interval) value="$TEST_UNSOL";; esac; }
json_get_vars() { acs_exclude_6ghz_non_psc="$TEST_PSC"; }
band="$TEST_BAND"; auto_channel="$TEST_AUTO"
'''

def run(body, band='6g', minimum='', maximum='', unsol='', psc='', auto='1'):
    env = dict(os.environ, TEST_BAND=band, TEST_MIN=minimum, TEST_MAX=maximum,
               TEST_UNSOL=unsol, TEST_PSC=psc, TEST_AUTO=auto)
    return subprocess.run(SHELL, input=STUBS + body, env=env, text=True,
                          capture_output=True, check=True).stdout.strip().splitlines()

class DiscoveryTests(unittest.TestCase):
    def test_explicit_intervals_and_zero(self):
        for val in ['0', '20']:
            self.assertEqual(run(FUNCTION+'\nhostapd_set_6ghz_discovery\nprintf "%s" "$bss_conf"\n',
                                 minimum=val, maximum=val, unsol=val), [name+'='+val for name in OPTIONS])

    def test_schema_default_max_reaches_hostapd(self):
        self.assertEqual(run(FUNCTION+'\nhostapd_set_6ghz_discovery\nprintf "%s" "$bss_conf"\n',
                             maximum='20'), ['fils_discovery_max_interval=20'])

    def test_absent_options_add_no_defaults(self):
        self.assertEqual(run(FUNCTION+'\nhostapd_set_6ghz_discovery\nprintf "%s" "$bss_conf"\n'), [])

    def test_non_6ghz_bss_unchanged(self):
        for band in ['2g', '5g', 's1g', '60g', '']:
            self.assertEqual(run(FUNCTION+'\nhostapd_set_6ghz_discovery\nprintf "%s" "$bss_conf"\n',
                                 band=band, maximum='20'), [])

    def test_registration_and_actual_bss_call(self):
        decl = re.search(r'(?ms)^hostapd_common_add_bss_config\(\).*?^\}', HOST).group()
        for name in OPTIONS:
            self.assertRegex(decl, r'config_add_int[^\n]*\b'+name+r'\b')
            self.assertIn('os_strcmp(buf, "'+name+'")', PARSER.read_text())
        bss = re.search(r'(?ms)^hostapd_set_bss_options\(\).*?^\}', HOST).group()
        self.assertIn('\thostapd_set_6ghz_discovery\n', bss)

    def test_explicit_psc_only_auto_6ghz(self):
        for psc in ['0', '1']:
            self.assertEqual(run(PSC+'\nprintf "%s" "$base_cfg"\n', psc=psc),
                             ['acs_exclude_6ghz_non_psc='+psc])
        for band, auto in [('5g','1'), ('2g','1'), ('6g','0')]:
            self.assertEqual(run(PSC+'\nprintf "%s" "$base_cfg"\n', band=band, auto=auto, psc='1'), [])
        self.assertEqual(run(PSC+'\nprintf "%s" "$base_cfg"\n'), [])
        self.assertIn('config_add_boolean acs_exclude_6ghz_non_psc', MAC)
        self.assertIn('os_strcmp(buf, "acs_exclude_6ghz_non_psc")', PARSER.read_text())

    def test_shell_syntax_and_package_release(self):
        for path in [PKG/'files/lib/netifd/hostapd.sh', PKG/'files/lib/netifd/wireless/mac80211.sh']:
            subprocess.run(SHELL+['-n',str(path)],check=True)
        self.assertIn('PKG_RELEASE:=4\n', (PKG/'Makefile').read_text())

if __name__ == '__main__':
    unittest.main()
