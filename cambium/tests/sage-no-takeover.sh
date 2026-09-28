#!/bin/sh
# All deployed Sage units are already in shared A/B mode.
set -eu

top=$(cd "$(dirname "$0")/../.." && pwd)
module=$top/package/cambium/cambium-sage-support/files/cambium-ab-sage.sh
sim=$top/cambium/tests/cambium-ab.sh
site=$top/cambium/site/index.html

if grep -Eq 'ab_sage_(takeover|adopt)|e410_upgrade_(state|target|fallback)|owrt_boot[01]' "$module"; then
	echo 'FAIL: Sage takeover code remains' >&2
	exit 1
fi
if grep -Eq 'takeover of an earlier Sage|unhealthy takeover|committed takeover|new_sage_ap .* (trial|upgraded)' "$sim"; then
	echo 'FAIL: Sage takeover fixtures remain' >&2
	exit 1
fi
if grep -q 'adopts the earlier' "$site"; then
	echo 'FAIL: obsolete site takeover note remains' >&2
	exit 1
fi
echo 'ok: retired Sage takeover removed'
