#!/bin/sh
# Table-driven tests for the Cambium Sage A/B sysupgrade code in
# target/linux/ipq40xx/base-files/lib/upgrade/platform.sh and the board table
# in lib/functions/cambium-sage.sh. The real functions run against a simulated
# UBI layout, device nodes and U-Boot environment; nothing touches the host.
#
# Usage: cambium/tests/sage-sysupgrade.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
base=$top/target/linux/ipq40xx/base-files
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
pass=0 fail=0

command -v sha256sum >/dev/null 2>&1 || sha256sum() { shasum -a 256 "$@"; }

# --- simulated system --------------------------------------------------------
reset_system() {
	rm -rf "$work/sys" "$work/dev" "$work/env" "$work/log"
	mkdir -p "$work/sys" "$work/dev"
	: > "$work/env"
	: > "$work/log"
	i=0
	for name in linux0 rootfs0 linux1 rootfs1 nvram; do
		mkdir -p "$work/sys/ubi0_$i"
		echo "$name" > "$work/sys/ubi0_$i/name"
		case "$name" in
		linux*) echo 4317184 > "$work/sys/ubi0_$i/data_bytes" ;;
		*) echo 47235072 > "$work/sys/ubi0_$i/data_bytes" ;;
		esac
		printf 'old-%s' "$name" > "$work/dev/ubi0_$i"
		i=$((i + 1))
	done
	echo "console=ttyMSM0 root=ubi0:rootfs${1:-0} rootfstype=ubifs" > "$work/cmdline"
	TEST_BOARD=cambium,e410
	FAIL_SETENV_AT=0
	CORRUPT_WRITE=0
	setenv_calls=0
	rm -f "$work/sku"
}

set_sku() { printf "$(printf '\\%03o\\%03o\\%03o\\%03o' 0 0 0 "$1")" > "$work/sku"; }

board_name() { echo "$TEST_BOARD"; }
nand_do_platform_check() { return 0; }
sync() { :; }
nand_find_volume() {
	local v
	for v in "$work"/sys/"$1"_*; do
		[ "$(cat "$v/name")" = "$2" ] && { basename "$v"; return 0; }
	done
	return 1
}
fw_setenv() {
	setenv_calls=$((setenv_calls + 1))
	[ "$FAIL_SETENV_AT" -ne 0 ] && [ "$setenv_calls" -ge "$FAIL_SETENV_AT" ] && return 1
	grep -v "^$1=" "$work/env" > "$work/env.new"
	[ $# -ge 2 ] && printf '%s=%s\n' "$1" "$2" >> "$work/env.new"
	mv "$work/env.new" "$work/env"
}
env() { sed -n "s/^$1=//p" "$work/env"; }
ubiupdatevol() {
	cp "$2" "$1"
	# Corrupt a byte inside the written data, as a failing flash write would.
	[ "$CORRUPT_WRITE" = 1 ] && printf 'X' | dd of="$1" bs=1 count=1 conv=notrunc 2>/dev/null
	echo "wrote $(basename "$1")" >> "$work/log"
}

export CAMBIUM_SAGE_LIB="$base/lib/functions/cambium-sage.sh"
export CAMBIUM_CMDLINE="$work/cmdline"
export SAGE_UBI_SYSFS="$work/sys"
export SAGE_DEV="$work/dev"
export SAGE_DT_SKU="$work/sku"
UPGRADE_BACKUP=

. "$base/lib/upgrade/platform.sh"

# --- images ------------------------------------------------------------------
# make_image NAME [kernel-magic] [root-magic] [kernel-bytes] [board-dir]
make_image() {
	local d="$work/img-$1"
	rm -rf "$d"; mkdir -p "$d/${5:-sysupgrade-cambium_e410}"
	{ printf "$2"; head -c "${4:-1000}" /dev/zero; } > "$d/${5:-sysupgrade-cambium_e410}/kernel"
	{ printf "$3"; head -c 5000 /dev/zero; } > "$d/${5:-sysupgrade-cambium_e410}/root"
	(cd "$d" && tar cf "$work/$1.tar" "${5:-sysupgrade-cambium_e410}")
	echo "$work/$1.tar"
}
FIT='\320\015\376\355'
UBIFS='\061\030\020\006'
good=$(make_image good "$FIT" "$UBIFS")
bad_kernel=$(make_image badkernel 'XXXX' "$UBIFS")
bad_root=$(make_image badroot "$FIT" 'XXXX')
huge=$(make_image huge "$FIT" "$UBIFS" 4400000)
wrong_dir=$(make_image wrongdir "$FIT" "$UBIFS" 1000 sysupgrade-other)

# --- helpers -----------------------------------------------------------------
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

# --- dispatch and qualification --------------------------------------------
while read -r board sku want; do
	reset_system 0; TEST_BOARD=$board; set_sku "$sku"
	check "check_image $board (SKU $sku)" "$want" platform_check_image "$good"
done <<EOF
cambium,e410 10 0
cambiumnetworks,e410b 21 0
cambiumnetworks,e510 16 0
cambiumnetworks,e600 11 1
cambiumnetworks,e700 14 1
cambiumnetworks,e430w 13 1
cambiumnetworks,e430h 15 1
EOF

for board in cambiumnetworks,e600 cambiumnetworks,e430h; do
	reset_system 0; TEST_BOARD=$board
	check "do_upgrade refuses $board" 1 cambium_sage_do_upgrade "$good"
	assert "$board: environment untouched" test ! -s "$work/env"
	assert "$board: no volume written" test ! -s "$work/log"
done

# --- board SKU cross-check ------------------------------------------------------
reset_system 0; set_sku 16
check "E410 tree on a board reporting SKU 16 is refused" 1 platform_check_image "$good"
reset_system 0
check "no board-sku node is accepted" 0 platform_check_image "$good"

# --- image mismatches -----------------------------------------------------------
while IFS='|' read -r desc image; do
	reset_system 0
	check "$desc is refused" 1 platform_check_image "$image"
done <<EOF
kernel without FIT magic|$bad_kernel
root without UBIFS magic|$bad_root
kernel above the 4317184-byte volume limit|$huge
image without sysupgrade-cambium_e410|$wrong_dir
EOF

# --- slots and capacity -------------------------------------------------------
reset_system 0
check "running slot 0 selects slot 1" 0 cambium_sage_board
cambium_sage_board; cambium_sage_select_slots > /dev/null
assert "slot 0 -> target 1 (linux1/rootfs1)" test "$SAGE_TARGET:$SAGE_KERNEL_UBI:$SAGE_ROOTFS_UBI" = "1:ubi0_2:ubi0_3"
reset_system 1
cambium_sage_board; cambium_sage_select_slots > /dev/null
assert "slot 1 -> target 0 (linux0/rootfs0)" test "$SAGE_TARGET:$SAGE_KERNEL_UBI:$SAGE_ROOTFS_UBI" = "0:ubi0_0:ubi0_1"
reset_system 0; echo "console=ttyMSM0" > "$work/cmdline"
check "unknown running slot is refused" 1 platform_check_image "$good"
reset_system 0; echo 500 > "$work/sys/ubi0_2/data_bytes"
check "kernel larger than the inactive volume is refused" 1 platform_check_image "$good"
reset_system 0; rm -rf "$work/sys/ubi0_3"
check "missing inactive rootfs volume is refused" 1 platform_check_image "$good"

# --- FIT selection and boot commands -------------------------------------------
validated0='setenv image 0; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs0 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux0 && bootm 0x84000000#config@ap.dk01.1-c2'
validated1='setenv image 1; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs1 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux1 && bootm 0x84000000#config@ap.dk01.1-c2'
cambium_sage_board cambium,e410
assert "E410 slot 0 boot command matches the validated command" test "$(cambium_sage_boot_command 0)" = "$validated0"
assert "E410 slot 1 boot command matches the validated command" test "$(cambium_sage_boot_command 1)" = "$validated1"
while read -r board config; do
	cambium_sage_board "$board"
	case "$(cambium_sage_boot_command 0)" in
	*"#$config") assert "$board boots $config" true ;;
	*) assert "$board boots $config" false ;;
	esac
done <<EOF
cambiumnetworks,e410b config@17
cambiumnetworks,e510 config@16
EOF

# --- a complete upgrade ---------------------------------------------------------
reset_system 0
check "do_upgrade on the E410 from slot 0" 0 cambium_sage_do_upgrade "$good"
assert "owrt_boot0 is the validated slot-0 command" test "$(env owrt_boot0)" = "$validated0"
assert "owrt_boot1 is the validated slot-1 command" test "$(env owrt_boot1)" = "$validated1"
assert "image stays on the running slot 0" test "$(env image)" = 0
assert "target 1 and fallback 0 recorded" test "$(env e410_upgrade_target):$(env e410_upgrade_fallback)" = "1:0"
assert "state is trial-armed" test "$(env e410_upgrade_state)" = trial-armed
assert "trial boot restores slot 0 as the default first" test "$(env bootcmd)" = \
	"setenv bootcmd 'run owrt_boot0; run owrt_boot1'; setenv image 0; setenv e410_upgrade_state fallback-restored; saveenv; run owrt_boot1; run owrt_boot0"
assert "inactive kernel written" cmp -s "$work/dev/ubi0_2" "$work/img-good/sysupgrade-cambium_e410/kernel"
assert "inactive rootfs written" cmp -s "$work/dev/ubi0_3" "$work/img-good/sysupgrade-cambium_e410/root"
assert "running slot 0 untouched" test "$(cat "$work/dev/ubi0_0"):$(cat "$work/dev/ubi0_1")" = "old-linux0:old-rootfs0"

reset_system 1; TEST_BOARD=cambiumnetworks,e510; set_sku 16
check "do_upgrade on the E510 from slot 1" 0 cambium_sage_do_upgrade "$good"
assert "E510 writes slot 0 and keeps slot 1 as fallback" test \
	"$(env e410_upgrade_target):$(env e410_upgrade_fallback):$(env image)" = "0:1:1"
case "$(env owrt_boot0)" in *"#config@16") r=true ;; *) r=false ;; esac
assert "E510 boot commands select config@16" $r
assert "E510 running slot 1 untouched" test "$(cat "$work/dev/ubi0_2"):$(cat "$work/dev/ubi0_3")" = "old-linux1:old-rootfs1"

# --- failures never arm the trial ----------------------------------------------
reset_system 0; CORRUPT_WRITE=1
check "readback hash mismatch fails" 1 cambium_sage_do_upgrade "$good"
assert "hash failure: bootcmd stays on the running slot" test "$(env bootcmd)" = "run owrt_boot0; run owrt_boot1"
assert "hash failure: state stays writing" test "$(env e410_upgrade_state)" = writing

for n in 1 3 7 8 9; do
	reset_system 0; FAIL_SETENV_AT=$n
	check "fw_setenv failure at call $n fails" 1 cambium_sage_do_upgrade "$good"
	case "$(env bootcmd)" in
	*fallback-restored*) assert "setenv failure $n: trial not armed" false ;;
	*) assert "setenv failure $n: trial not armed" true ;;
	esac
done
reset_system 0; FAIL_SETENV_AT=2
cambium_sage_do_upgrade "$good" > /dev/null 2>&1
assert "setenv failure before bootcmd: no volume written" test ! -s "$work/log"

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
