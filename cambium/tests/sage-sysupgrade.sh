#!/bin/sh
# Tests for the Cambium Sage board table (lib/functions/cambium-sage.sh), which
# the cambium-ab Sage module uses for its models, SKUs, FIT configurations,
# volume sizes, running pair and U-Boot boot commands, and for the Sage
# refusal in the ipq40xx platform.sh. The A/B upgrade itself (writer, guard,
# adoption of the earlier e410_* state) is tested in cambium-ab.sh.
#
# Usage: cambium/tests/sage-sysupgrade.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
base=$top/target/linux/ipq40xx/base-files
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
pass=0 fail=0

export CAMBIUM_SAGE_LIB="$base/lib/functions/cambium-sage.sh"
export CAMBIUM_CMDLINE="$work/cmdline"
export SAGE_DT_SKU="$work/sku"
TEST_BOARD=cambium,e410
board_name() { echo "$TEST_BOARD"; }
set_sku() { printf "$(printf '\\%03o\\%03o\\%03o\\%03o' 0 0 0 "$1")" > "$work/sku"; }
. "$CAMBIUM_SAGE_LIB"

check() { # check DESCRIPTION EXPECTED(0|1) COMMAND...
	local desc="$1" want="$2"; shift 2
	( "$@" ) > "$work/out" 2>&1
	local got=$?
	[ "$got" -ne 0 ] && got=1
	if [ "$got" = "$want" ]; then
		pass=$((pass + 1)); echo "ok   $desc"
	else
		fail=$((fail + 1)); echo "FAIL $desc (expected $want, got $got)"; sed 's/^/     /' "$work/out"
	fi
}
assert() { # assert DESCRIPTION TEST...
	local desc="$1"; shift
	if "$@"; then pass=$((pass + 1)); echo "ok   $desc"
	else fail=$((fail + 1)); echo "FAIL $desc"; fi
}

# --- qualification: only the E410-layout boards write flash --------------------
while read -r board sku qualified; do
	cambium_sage_board "$board"
	assert "$board is SKU $sku, qualified=$qualified" test "$SAGE_SKU:$SAGE_QUALIFIED" = "$sku:$qualified"
done <<EOF
cambium,e410 10 1
cambiumnetworks,e410b 21 1
cambiumnetworks,e510 16 1
cambiumnetworks,e600 11 0
cambiumnetworks,e700 14 0
cambiumnetworks,e430w 13 0
cambiumnetworks,e430h 15 0
EOF
check "an unknown board is not a Sage" 1 cambium_sage_board acme,router

# --- board SKU cross-check ------------------------------------------------------
cambium_sage_board cambium,e410
set_sku 10; check "E410 tree with SKU 10 accepted" 0 cambium_sage_check_sku
set_sku 16; check "E410 tree on a board reporting SKU 16 is refused" 1 cambium_sage_check_sku
rm -f "$work/sku"; check "no board-sku node is accepted" 0 cambium_sage_check_sku

# --- running pair ------------------------------------------------------------------
echo "console=ttyMSM0 root=ubi0:rootfs1 rootfstype=ubifs" > "$work/cmdline"
assert "running pair read from root=ubi0:rootfs1" test "$(cambium_sage_running_slot)" = 1
echo "console=ttyMSM0 root=/dev/mtdblock3" > "$work/cmdline"
assert "no pair on another command line" test -z "$(cambium_sage_running_slot)"

# --- FIT selection and boot commands ------------------------------------------------
validated0='setenv image 0; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs0 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux0 && bootm 0x84000000#config@ap.dk01.1-c2'
validated1='setenv image 1; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs1 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux1 && bootm 0x84000000#config@ap.dk01.1-c2'
cambium_sage_board cambium,e410
assert "E410 slot 0 boot command matches the validated command" test "$(cambium_sage_boot_command 0)" = "$validated0"
assert "E410 slot 1 boot command matches the validated command" test "$(cambium_sage_boot_command 1)" = "$validated1"
while read -r board fit; do
	cambium_sage_board "$board"
	case "$(cambium_sage_boot_command 0)" in
	*"#$fit") r=true ;;
	*) r=false ;;
	esac
	assert "$board boots $fit" $r
done <<EOF
cambiumnetworks,e410b config@17
cambiumnetworks,e510 config@16
EOF

# --- platform.sh: a Sage image without A/B support never writes flash ---------------
eval "$(sed -n '/^platform_check_image() {/,/^}/p; /^platform_do_upgrade() {/,/^}/p' "$base/lib/upgrade/platform.sh")"
nand_do_upgrade() { echo "generic nand_do_upgrade"; }
for board in cambium,e410 cambiumnetworks,e600; do
	TEST_BOARD=$board
	check "$board without cambium-ab: check_image refuses" 1 platform_check_image /dev/null
	check "$board without cambium-ab: do_upgrade refuses" 1 platform_do_upgrade /dev/null
done
assert "no generic write reached" test -z "$(grep -r 'generic nand_do_upgrade' "$work/out")"

# --- board table agrees with families.json and the FIT ------------------------
if python3 - "$top" "$CAMBIUM_SAGE_LIB" <<'PY'
import json, re, sys
top, lib = sys.argv[1:]
text = open(lib).read()
table = {}
for board, body in re.findall(r"^\t(cambium[\w,]+)\)\s*(?:#[^\n]*\n\t*)?(SAGE_[^\n;]+)", text, re.M):
    vals = dict(re.findall(r"(SAGE_\w+)=(\S+)", body))
    table[board] = vals
fams = json.load(open(f"{top}/cambium/families.json"))["families"]
sage = {m["model"]: m for f in fams if f["family"] == "sage" for m in f["models"]}
mk = open(f"{top}/target/linux/ipq40xx/image/generic.mk").read()
dev = mk[mk.index("define Device/cambiumnetworks_sage-persistent"):]
dev = dev[:dev.index("endef")]
fit = set(re.findall(r"(\S+?):\S+?:qcom-ipq4019-sage-\S+-persistent", dev))
errors = []
for board, v in table.items():
    model = v["SAGE_MODEL"]
    if model not in sage:
        errors.append(f"{board}: model {model} missing from families.json")
        continue
    if int(v["SAGE_SKU"]) != sage[model]["sku"]:
        errors.append(f"{board}: SKU {v['SAGE_SKU']} != families.json {sage[model]['sku']}")
    if v["SAGE_FIT"].replace("config@", "") not in fit:
        errors.append(f"{board}: {v['SAGE_FIT']} is not in the Sage persistent FIT")
if len(table) != 7:
    errors.append(f"expected 7 Sage boards in the table, found {len(table)}")
print("\n".join(errors))
sys.exit(1 if errors else 0)
PY
then pass=$((pass + 1)); echo "ok   board table agrees with families.json and the persistent FIT"
else fail=$((fail + 1)); echo "FAIL board table disagrees with families.json or the persistent FIT"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
