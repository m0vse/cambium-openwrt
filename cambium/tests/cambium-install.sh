#!/bin/sh
# Simulation tests for cambium/site/cambium-install.sh: every family's RAM
# boot and install run against a simulated stock firmware (MTD/UBI, U-Boot
# environment, TFTP and web servers) and must produce the site's validated
# U-Boot commands, write only the intended slot, and stop with a precise
# reason on every refusal. Nothing touches the host.
#
# Usage: cambium/tests/cambium-install.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
installer=$top/cambium/site/cambium-install.sh
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0
LEB=126976

mkdir -p "$W/bin" "$W/rel" "$W/http" "$W/tftpd"
tool() { cat > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
cat > "$W/bin/_sim" <<'EOF'
W=${SIM:?}; RT=$W/root
log() { echo "$*" >> "$W/calls"; }
mtd_of() { cat "$RT/sys/class/ubi/$1/mtd_num"; }
refresh() { # UBI MTD
	rm -rf "$RT/sys/class/ubi/$1"_*; rm -f "$RT/dev/$1"_*
	used=0
	for f in "$W/flash/mtd$2"/*.size; do [ -f "$f" ] && used=$((used + ($(cat "$f") + 126975) / 126976)); done
	echo 126976 > "$RT/sys/class/ubi/$1/eraseblock_size"
	echo $(( $(cat "$W/flash/mtd$2.lebs" 2>/dev/null || echo 700) - used )) > "$RT/sys/class/ubi/$1/avail_eraseblocks"
	for n in "$W/flash/mtd$2"/*.name; do
		[ -f "$n" ] || continue
		v=$(basename "$n" .name)
		mkdir -p "$RT/sys/class/ubi/$1_$v"
		cp "$n" "$RT/sys/class/ubi/$1_$v/name"
		cp "$W/flash/mtd$2/$v.size" "$RT/sys/class/ubi/$1_$v/data_bytes"
		ln -sf "$W/flash/mtd$2/$v.data" "$RT/dev/$1_$v"
	done
}
EOF
tool ubiattach <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ "$1" = /dev/ubi_ctrl ] && { form=ctrl; shift; } || form=plain
[ "$1" = -m ] || exit 2
k=0; while [ -d "$RT/sys/class/ubi/ubi$k" ]; do k=$((k + 1)); done
mkdir -p "$RT/sys/class/ubi/ubi$k" "$W/flash/mtd$2"; echo "$2" > "$RT/sys/class/ubi/ubi$k/mtd_num"
refresh "ubi$k" "$2"; log "attach($form) mtd$2"
EOF
tool ubidetach <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
for d in "$RT"/sys/class/ubi/ubi[0-9]*; do
	case "${d##*/}" in *_*) continue ;; esac
	[ "$(cat "$d/mtd_num")" = "$2" ] || continue
	rm -rf "$d" "${d}"_*; log "detach mtd$2"; exit 0
done
exit 1
EOF
tool ubiformat <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
m=${1##*/mtd}; img=${4:-}
for d in "$RT"/sys/class/ubi/ubi[0-9]*; do
	case "${d##*/}" in *_*) continue ;; esac
	[ -f "$d/mtd_num" ] && [ "$(cat "$d/mtd_num")" = "$m" ] && { echo "ubiformat: error!: please, first detach mtd$m" >&2; exit 1; }
done
rm -rf "$W/flash/mtd$m"; mkdir -p "$W/flash/mtd$m"; i=0
if [ -n "$img" ]; then
	for v in $(sed -n 's/^UBI-FACTORY //p' "$img"); do
		echo "$v" > "$W/flash/mtd$m/$i.name"; echo $((10 * 126976)) > "$W/flash/mtd$m/$i.size"
		printf '%s-content' "$v" > "$W/flash/mtd$m/$i.data"
		[ -f "$W/bad_format" ] && [ "$v" = kernel ] && printf 'kernel-contenX' > "$W/flash/mtd$m/$i.data"
		i=$((i + 1))
	done
fi
log "format mtd$m ${img##*/}"
EOF
tool ubimkvol <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
k=${1##*/}; shift; m=$(mtd_of "$k"); name= size=
while [ $# -gt 0 ]; do case "$1" in -N) name=$2; shift ;; -s) size=$2; shift ;; -m) size=max ;; esac; shift; done
[ -f "$W/fail_mkvol" ] && { echo 'ubimkvol: error!: cannot UBI create volume' >&2; exit 255; }
id=0; while [ -f "$W/flash/mtd$m/$id.name" ]; do id=$((id + 1)); done
echo "$name" > "$W/flash/mtd$m/$id.name"; [ "$size" = max ] && size=$((50 * 126976))
echo "$size" > "$W/flash/mtd$m/$id.size"; : > "$W/flash/mtd$m/$id.data"
refresh "$k" "$m"; log "mkvol mtd$m $name"
EOF
tool ubirmvol <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
k=${1##*/}; m=$(mtd_of "$k")
case "$2" in
-n) rm -f "$W/flash/mtd$m/$3".* ;;
-N) for n in "$W/flash/mtd$m"/*.name; do [ "$(cat "$n")" = "$3" ] && rm -f "${n%.name}".*; done ;;
esac
refresh "$k" "$m"; log "rmvol mtd$m $3"
EOF
tool ubiupdatevol <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
vol=${1##*/}; k=${vol%_*}; v=${vol##*_}; m=$(mtd_of "$k")
cp "$2" "$W/flash/mtd$m/$v.data"
[ "$(cat "$W/corrupt" 2>/dev/null)" = "$vol" ] && printf X | dd of="$W/flash/mtd$m/$v.data" bs=1 count=1 conv=notrunc 2>/dev/null
log "update mtd$m $(cat "$W/flash/mtd$m/$v.name")"
EOF
tool fw_printenv <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ "$1" = -n ] && shift
grep -q "^$1=" "$W/env" || exit 1
sed -n "s/^$1=//p" "$W/env"
EOF
tool fw_setenv <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
n=$1; shift
grep -v "^$n=" "$W/env" > "$W/env.new"; [ $# -gt 0 ] && printf '%s=%s\n' "$n" "$*" >> "$W/env.new"
mv "$W/env.new" "$W/env"; log "setenv $n"
EOF
tool tftp <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
op= l= r=
while [ $# -gt 1 ]; do case "$1" in -g|-p) op=$1 ;; -l) l=$2; shift ;; -r) r=$2; shift ;; -b) shift ;; esac; shift; done
case "$op" in
-g) [ -f "$W/tftpd/$r" ] || { echo "tftp: server error: (1) File not found" >&2; exit 1; }; cp "$W/tftpd/$r" "$l" ;;
-p) [ -f "$W/tftp_readonly" ] && { echo "tftp: server error: (2) Access violation" >&2; exit 1; }; cp "$l" "$W/tftpd/$r"; log "upload $r" ;;
esac
EOF
tool wget <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
out=$3 url=$4
case "$url" in https://*) echo "wget: not an http or ftp url: $url" >&2; exit 1 ;; esac
f=$W/http/${url##*/}
[ -f "$f" ] || { echo "wget: server returned error: HTTP/1.0 404 File not found" >&2; exit 1; }
cp "$f" "$out"
EOF
tool reboot <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"; log reboot
EOF
printf '#!/bin/sh\nexit 0\n' | tool sync
tool ip <<'EOF'
#!/bin/sh
echo "$3 via 192.0.2.1 dev br0 src 192.0.2.20"
EOF
command -v sha256sum >/dev/null 2>&1 || tool sha256sum <<'EOF'
#!/bin/sh
exec shasum -a 256 "$@"
EOF
export PATH="$W/bin:$PATH" SIM=$W CAMBIUM_ROOT=$W/root CAMBIUM_SKU_NODE=$W/root/sku

# --- the release -----------------------------------------------------------------
python3 "$top/cambium/scripts/gen-select-config.py" "$top/cambium/families.json" > "$W/rel/select-config.sh"
p=openwrt
for f in \
	ipq40xx-generic-cambiumnetworks_sage-recovery-initramfs-zImage.itb \
	ipq40xx-generic-cambiumnetworks_sage-persistent-squashfs-kernel.itb \
	ipq40xx-generic-cambiumnetworks_sage-persistent-squashfs-rootfs.ubifs \
	qualcommax-ipq807x-cambiumnetworks_thor-recovery-initramfs-uImage.itb \
	qualcommax-ipq807x-cambiumnetworks_thor-installer-initramfs-uImage.itb \
	qualcommax-ipq50xx-cambiumnetworks_cheetah-recovery-initramfs-uImage.itb \
	qualcommax-ipq50xx-cambiumnetworks_cheetah-persistent-squashfs-kernel.itb \
	qualcommax-ipq50xx-cambiumnetworks_cheetah-persistent-squashfs-rootfs.squashfs \
	qualcommax-ipq60xx-cambiumnetworks_jaguar-recovery-initramfs-uImage.itb; do
	echo "image $f" > "$W/rel/$p-$f"
done
echo "UBI-FACTORY kernel rootfs rootfs_data cambium_device_data" > "$W/rel/$p-qualcommax-ipq60xx-cambiumnetworks_jaguar-persistent-squashfs-factory.ubi"
echo "UBI-FACTORY kernel rootfs rootfs_data" > "$W/rel/$p-qualcommax-ipq807x-cambiumnetworks_thor-persistent-squashfs-factory.ubi"
for f in "$W/rel/$p-qualcommax-ipq60xx-cambiumnetworks_jaguar-persistent-squashfs-factory.ubi" \
	"$W/rel/$p-qualcommax-ipq807x-cambiumnetworks_thor-persistent-squashfs-factory.ubi"; do
	for v in kernel rootfs; do
		printf '%s %s %s\n' "$v" "$(printf '%s-content' "$v" | wc -c | tr -d ' ')" "$(printf '%s-content' "$v" | sha256sum | cut -d' ' -f1)"
	done > "$f.contents"
done
cp "$top/target/linux/qualcommax/ipq60xx/base-files/lib/functions/cambium-jaguar.sh" "$W/rel/jaguar-cambium-jaguar-functions.sh"
cp "$top/target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/cambium-jaguar.sh" "$W/rel/jaguar-cambium-jaguar-upgrade.sh"
(cd "$W/rel" && sha256sum -- openwrt-* jaguar-* > SHA256SUMS)
mkdir -p "$W/rel-test"
echo "image jaguar persistent ram" > "$W/rel-test/$p-qualcommax-ipq60xx-cambiumnetworks_jaguar-persistent-initramfs-uImage.itb"
(cd "$W/rel-test" && sha256sum -- openwrt-* > test-only-SHA256SUMS)
cp "$W"/rel-test/* "$W/rel/"
cp "$W"/rel/* "$W/http/"
cp "$W"/rel/* "$W/tftpd/"
cp "$W/rel/$p-ipq40xx-generic-cambiumnetworks_sage-recovery-initramfs-zImage.itb" "$W/tftpd/sage-recovery.itb"

# --- simulated access points ---------------------------------------------------------
RT=$W/root
# ap FAMILY MODEL SKU RUNNING-SLOT(0|1) [bank-hex]
ap() {
	local fam=$1 sku=$3 run=$4 bank=${5:-06000000} i
	rm -rf "$RT" "$W/flash" "$W/calls" "$W/env" "$W/corrupt" "$W/fail_mkvol" "$W/tftp_readonly" "$W/bad_format"
	mkdir -p "$RT/proc" "$RT/sys/class/ubi" "$RT/sys/class/mtd" "$RT/dev" "$RT/tmp" "$W/flash"
	touch "$W/calls"
	printf "\\000\\000\\000\\$(printf '%03o' "$sku")" > "$RT/sku"
	case "$fam" in
	sage)
		printf '%s\n' 'dev:    size   erasesize  name' 'mtd0: 08000000 00020000 "fs"' \
			'mtd5: 00010000 00010000 "0:APPSBLENV"' 'mtd7: 00010000 00010000 "0:ART"' > "$RT/proc/mtd"
		echo "console=ttyMSM0 root=ubi0:rootfs$run rootfstype=ubifs" > "$RT/proc/cmdline"
		mkdir -p "$W/flash/mtd0"; i=0
		for v in linux0 rootfs0 linux1 rootfs1 nvram; do
			echo "$v" > "$W/flash/mtd0/$i.name"; echo 4317184 > "$W/flash/mtd0/$i.size"
			case "$v" in rootfs*) echo 47235072 > "$W/flash/mtd0/$i.size" ;; esac
			echo "oem-$v" > "$W/flash/mtd0/$i.data"; i=$((i + 1))
		done
		mkdir -p "$RT/sys/class/ubi/ubi0"; echo 0 > "$RT/sys/class/ubi/ubi0/mtd_num"
		(. "$W/bin/_sim"; refresh ubi0 0)
		printf '%s\n' 'bootcmd=bootipq' "image=$run" 'bootcount=0' > "$W/env"
		for i in 5 7; do echo "nor$i" > "$RT/dev/mtd${i}ro"; done
		return ;;
	cheetah) off=1 ;;
	*) off=0 ;;
	esac
	# rootfs = mtd(1+off), rootfs_1 = mtd(2+off)
	r0=$((1 + off)); r1=$((2 + off))
	printf '%s\n' 'dev:    size   erasesize  name' \
		"mtd$r0: $bank 00020000 \"rootfs\"" "mtd$r1: $bank 00020000 \"rootfs_1\"" \
		'mtd20: 00010000 00010000 "0:APPSBLENV"' 'mtd21: 00080000 00010000 "0:ART"' > "$RT/proc/mtd"
	[ "$fam" = cheetah ] && { mkdir -p "$RT/sys/class/mtd/mtd$r0"; echo 524288 > "$RT/sys/class/mtd/mtd$r0/offset"; }
	for i in $r0 $r1; do
		mkdir -p "$W/flash/mtd$i"; echo ubi_rootfs > "$W/flash/mtd$i/0.name"
		echo $((100 * LEB)) > "$W/flash/mtd$i/0.size"; echo "oem-slot-mtd$i" > "$W/flash/mtd$i/0.data"
		echo "raw-mtd$i" > "$RT/dev/mtd${i}ro"
	done
	for i in 20 21; do echo "nor$i" > "$RT/dev/mtd${i}ro"; done
	running=$([ "$run" = 0 ] && echo $r0 || echo $r1)
	mkdir -p "$RT/sys/class/ubi/ubi0"; echo "$running" > "$RT/sys/class/ubi/ubi0/mtd_num"
	(. "$W/bin/_sim"; refresh ubi0 "$running")
	case "$fam" in
	thor) printf '%s\n' 'bootcmd=aq_load_fw&&bootipq' 'image=1' > "$W/env" ;;
	*) printf '%s\n' 'bootcmd=bootipq' "image=$run" > "$W/env" ;;
	esac
}
inst() { sh "$installer" "$@"; }
env_get() { sed -n "s/^$1=//p" "$W/env"; }
writes() { grep -E '^(attach|detach|format|mkvol|rmvol|update|setenv|upload|reboot)' "$W/calls" | tr '\n' ';'; }

check() { # check DESCRIPTION EXPECTED(0|1) COMMAND...
	local desc=$1 want=$2 got
	shift 2
	( "$@" ) > "$W/out" 2>&1; got=$?
	[ "$got" -ne 0 ] && got=1
	if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); echo "FAIL: $desc (exit $got, wanted $want)"; sed 's/^/    /' "$W/out"
	fi
}
assert() {
	local desc=$1
	shift
	if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $desc"; fi
}
said() { grep -q -- "$1" "$W/out"; }
nothing_written() { [ -z "$(writes)" ]; }

# Validated one-shots (as on the site), with CONFIG filled in.
jaguar_ram() { echo "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$1@$2($3)\" && ubi part $3 && ubi read 0x60000000 openwrt && bootm 0x60000000#$4; reset"; }
thor_one() { echo "setenv changing_bootcmd; setenv bootcmd \"aq_load_fw&&bootipq\"; saveenv; aq_load_fw; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts \"mtdparts=nand0:0x6000000@0x0(rootfs)\"; ubi part rootfs; ubi read 0x60000000 $1; bootm 0x60000000#config@hk02; bootipq"; }

# --- Jaguar ----------------------------------------------------------------------------
ap jaguar XV2-2T1 31 1
check "Jaguar dry run passes its checks" 0 inst --from "$W/rel" ram
assert "dry run writes nothing" nothing_written
assert "dry run backs up the inactive slot, APPSBLENV and ART" \
	[ -f "$RT/tmp/cambium-install/backup/mtd1ro.bin" -a -f "$RT/tmp/cambium-install/backup/APPSBLENV.bin" -a -f "$RT/tmp/cambium-install/backup/ART.bin" ]
check "--yes without --backed-up stops after the backups" 1 inst --from "$W/rel" --yes ram
assert "the stop says to copy the backups" said 'copy the backups off the access point first'
assert "still nothing written" nothing_written
check "Jaguar XV2-2T1 RAM boot" 0 inst --from "$W/rel" --yes --backed-up ram
assert "XV2-2T1 one-shot is the validated command" [ "$(env_get bootcmd)" = "$(jaguar_ram 0x6000000 0x0 rootfs config@cp01-c1-2)" ]
assert "staged only in rootfs, then armed and rebooted" [ "$(writes)" = 'attach(plain) mtd1;mkvol mtd1 openwrt;update mtd1 openwrt;setenv changing_bootcmd;setenv bootcmd;reboot;' ]
assert "stock bank untouched" [ "$(cat "$W/flash/mtd2/0.data")" = oem-slot-mtd2 ]

ap jaguar XV2-2 20 0 03400000
check "Jaguar XV2-2 RAM boot (stock on slot 0)" 0 inst --from "$W/rel" --yes --backed-up ram
assert "XV2-2 slot 1 uses the (fs) command that booted it" [ "$(env_get bootcmd)" = "$(jaguar_ram 0x3400000 0x3400000 fs config@cp01-c1)" ]
assert "XV2-2 wrote only mtd2" [ "$(writes)" = 'attach(plain) mtd2;mkvol mtd2 openwrt;update mtd2 openwrt;setenv changing_bootcmd;setenv bootcmd;reboot;' ]

ap jaguar XV2-2 20 0 03400000; echo 100 > "$W/flash/mtd2.lebs"; (. "$W/bin/_sim"; refresh ubi0 1)
check "XV2-2 with a full inactive bank refused" 1 inst --from "$W/rel" --yes --backed-up ram
assert "the refusal gives the free and needed eraseblocks" said 'has 0 free UBI eraseblocks but the RAM image needs 1'
assert "full bank: only attach was done" [ "$(writes)" = 'attach(plain) mtd2;' ]
ap jaguar XV2-2 20 0 03400000; echo 100 > "$W/flash/mtd2.lebs"
check "XV2-2 --format-inactive" 0 inst --from "$W/rel" --yes --backed-up --format-inactive ram
assert "--format-inactive erases the inactive slot, then stages" [ "$(writes)" = 'attach(plain) mtd2;detach mtd2;format mtd2 ;attach(plain) mtd2;mkvol mtd2 openwrt;update mtd2 openwrt;setenv changing_bootcmd;setenv bootcmd;reboot;' ]
assert "--format-inactive leaves the running slot" [ "$(cat "$W/flash/mtd1/0.data")" = oem-slot-mtd1 ]

ap jaguar XV2-2 20 1 06000000
check "XV2-2 with 96 MiB slots refused" 1 inst --from "$W/rel" --yes --backed-up ram
assert "layout refusal names the sizes" said 'not a known Jaguar layout'
assert "layout refusal wrote nothing" nothing_written

ap jaguar XV2-2T1 31 1
check "persistent RAM test" 0 inst --from "$W/rel" --yes --backed-up --persistent-test --trial ram
assert "persistent RAM test attaches no bank (own bootargs)" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x6000000@0x0(rootfs)" && ubi part rootfs && ubi read 0x60000000 openwrt && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab swiotlb=1" && bootm 0x60000000#config@cp01-c1-2; reset' ]

ap jaguar XV2-2T1 31 1
check "untested persistent install refused without --trial" 1 inst --from "$W/rel" --yes --backed-up install
assert "refusal says RAM boot only" said 'Only the recovery (RAM) image may be used'
assert "refused install wrote nothing" nothing_written
check "Jaguar persistent install (--trial)" 0 inst --from "$W/rel" --yes --backed-up --trial install
assert "Jaguar first boot is the validated guarded command" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x6000000@0x0(rootfs)" && ubi part rootfs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#config@cp01-c1-2; reset' ]
assert "Jaguar install formatted only rootfs" [ "$(writes)" = "format mtd1 $p-qualcommax-ipq60xx-cambiumnetworks_jaguar-persistent-squashfs-factory.ubi;attach(plain) mtd1;setenv changing_bootcmd;setenv bootcmd;reboot;" ]
assert "Jaguar install hashed the kernel and rootfs back" said 'kernel volume reads back as built'
ap jaguar XV2-2 20 0 03400000
check "XV2-2 install into slot 1 (stock on slot 0)" 0 inst --from "$W/rel" --yes --backed-up --trial install
assert "slot-1 guarded first boot" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x3400000@0x3400000(fs)" && ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#config@cp01-c1; reset' ]
assert "slot-1 install wrote only mtd2" [ -z "$(grep -E '(format|mkvol|update) mtd1' "$W/calls")" ]
ap jaguar XV2-2T1 31 1; touch "$W/bad_format"
check "a factory write that reads back wrong stops" 1 inst --from "$W/rel" --yes --backed-up --trial install
assert "the read-back failure is named" said 'the kernel volume does not read back as built'
assert "bad read-back: nothing armed" [ "$(env_get bootcmd)" = bootipq ]

ap jaguar XV2-2T1 31 1; printf '%s\n' 'bootcmd=run jaguar_stable0' 'image=1' > "$W/env"
check "armed bootcmd refused" 1 inst --from "$W/rel" --yes --backed-up ram
assert "refusal shows the current bootcmd" said "bootcmd is 'run jaguar_stable0'"

# --- Thor --------------------------------------------------------------------------------
ap thor XV3-8 19 1
check "Thor RAM boot" 0 inst --from "$W/rel" --yes --backed-up ram
assert "Thor one-shot is the validated command" [ "$(env_get bootcmd)" = "$(thor_one openwrt)" ]
assert "Thor attaches with /dev/ubi_ctrl" grep -q 'attach(ctrl) mtd1' "$W/calls"
ap thor XV3-8 19 1
check "Thor install stage 1 (installer)" 0 inst --from "$W/rel" --yes --backed-up install
assert "installer staged in rootfs" [ "$(cat "$W/flash/mtd1/1.data")" = "image qualcommax-ipq807x-cambiumnetworks_thor-installer-initramfs-uImage.itb" ]
# Stage 2: the installer in RAM (OpenWrt; rootfs is mtd0 and writable).
rm -rf "$RT/sys/class/ubi"; mkdir -p "$RT/sys/class/ubi" "$RT/etc" "$RT/sys/class/mtd/mtd0"; : > "$RT/etc/openwrt_release"
printf '%s\n' 'dev:    size   erasesize  name' 'mtd0: 06000000 00020000 "rootfs"' 'mtd1: 06000000 00020000 "rootfs_1"' > "$RT/proc/mtd"
echo 'console=ttyMSM0' > "$RT/proc/cmdline"; echo 0x400 > "$RT/sys/class/mtd/mtd0/flags"; : > "$W/calls"
check "Thor install stage 2 (in the installer)" 0 inst --from "http://192.0.2.5:8000" --yes install
assert "stage 2 formats rootfs with the factory image" grep -q "^format mtd0 $p-qualcommax-ipq807x-cambiumnetworks_thor-persistent-squashfs-factory.ubi" "$W/calls"
# Stage 3: back on the stock firmware, trial boot the installed image.
ap thor XV3-8 19 1; rm -rf "$W/flash/mtd1"; mkdir -p "$W/flash/mtd1"
for v in 0:kernel 1:rootfs 2:rootfs_data; do echo "${v#*:}" > "$W/flash/mtd1/${v%%:*}.name"; echo $LEB > "$W/flash/mtd1/${v%%:*}.size"; : > "$W/flash/mtd1/${v%%:*}.data"; done
check "Thor boot (stage 3)" 0 inst --from "$W/rel" --yes boot
assert "Thor trial reads the installed kernel" [ "$(env_get bootcmd)" = "$(thor_one kernel)" ]
# Stage 4: the installed OpenWrt.
mkdir -p "$RT/etc"; : > "$RT/etc/openwrt_release"; echo 'console=ttyMSM0 ubi.mtd=rootfs root=/dev/ubiblock0_1' > "$RT/proc/cmdline"
check "Thor commit (stage 4)" 0 inst --from "$W/rel" --yes commit
assert "Thor permanent command" [ "$(env_get bootcmd)" = 'aq_load_fw; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:0x6000000@0x0(rootfs)"; ubi part rootfs; ubi read 0x60000000 kernel; bootm 0x60000000#config@hk02' ]
ap thor XV3-8 19 0
check "Thor refuses stock on rootfs" 1 inst --from "$W/rel" --yes --backed-up ram
ap thor XE5-8 30 1
check "XE5-8 install refused (not built)" 1 inst --from "$W/rel" --yes --backed-up install
assert "XE5-8 refusal gives the reason" said 'flash layout not yet captured'

# --- Cheetah -------------------------------------------------------------------------------
ap cheetah XV2-21X 35 1
check "Cheetah RAM boot" 0 inst --from "$W/rel" --yes --backed-up ram
assert "Cheetah one-shot is the validated command" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:0x6000000@0x80000(fs)"; ubi part fs && ubi read 0x60000000 openwrt && bootm 0x60000000#config@mp03.3-ocelot; reset' ]
ap cheetah XV2-21X 35 1
check "Cheetah install" 0 inst --from "$W/rel" --yes --backed-up install
assert "Cheetah first boot is the validated command" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:0x6000000@0x80000(fs)"; ubi part fs && ubi read 0x60000000 kernel && bootm 0x60000000#config@mp03.3-ocelot; bootipq' ]
assert "Cheetah replaced only rootfs volumes" [ -z "$(grep -E '(format|mkvol|rmvol|update) mtd3' "$W/calls")" ]
ap cheetah XV2-21X 35 1; touch "$W/fail_mkvol"
check "Cheetah install with a failing ubimkvol stops" 1 inst --from "$W/rel" --yes --backed-up install
assert "the failure names the step, status and error" said 'FAILED: ubimkvol kernel (exit 255: ubimkvol: error!: cannot UBI create volume)'
assert "nothing armed after the failure" [ "$(env_get bootcmd)" = bootipq ]
ap cheetah XV2-21X 35 1; echo ubi1_0 > "$W/corrupt"
check "Cheetah readback mismatch stops" 1 inst --from "$W/rel" --yes --backed-up install
assert "mismatch reported" said 'kernel volume does not read back correctly'
assert "mismatch: not armed" [ "$(env_get bootcmd)" = bootipq ]

# --- Sage -----------------------------------------------------------------------------------
ap sage E410 10 0
check "Sage RAM boot needs a TFTP server" 1 inst --from "$W/rel" --yes --backed-up ram
assert "Sage TFTP reason" said 'Sage U-Boot loads the RAM image over TFTP'
ap sage E410 10 0
check "Sage RAM boot" 0 inst --tftp 192.0.2.5 --yes ram
assert "Sage one-shot is the validated command" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; saveenv; tftpboot 0x84000000 sage-recovery.itb && bootm 0x84000000#config@5; bootipq' ]
assert "Sage addresses set" [ "$(env_get ipaddr):$(env_get serverip)" = 192.0.2.20:192.0.2.5 ]
assert "Sage backups uploaded over TFTP" [ -f "$W/tftpd/cambium-backup-sku10-SHA256SUMS" ]
assert "Sage RAM boot sets no changing_bootcmd" [ -z "$(env_get changing_bootcmd)" ]
ap sage E410 10 0
check "Sage install (stock on pair 0)" 0 inst --from "$W/rel" --yes --backed-up install
assert "Sage trial is the validated command" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; setenv image 0; setenv bootcount 0; saveenv; setenv image 1; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs${image} rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux${image} && bootm 0x84000000#config@ap.dk01.1-c2; setenv image 0; bootipq' ]
assert "Sage trial metadata" [ "$(env_get owrt_trial_slot):$(env_get owrt_fallback_slot):$(env_get image)" = 1:0:0 ]
assert "Sage wrote only linux1/rootfs1" [ "$(grep '^update' "$W/calls" | tr '\n' ';')" = 'update mtd0 linux1;update mtd0 rootfs1;' ]
ap sage E510 16 0
check "Sage E510 install refused (untested)" 1 inst --from "$W/rel" --yes --backed-up install

# --- sources and hashes ----------------------------------------------------------------------
ap jaguar XV2-2T1 31 1
check "https without TLS explains the http fallback" 1 inst --release snapshot-2026.09.24.2 ram
assert "the fallback is suggested" said 'python3 -m http.server'
ap jaguar XV2-2T1 31 1
check "http source" 0 inst --from http://192.0.2.5:8000 --yes --backed-up ram
cp -R "$W/rel" "$W/rel-bad"; echo tampered >> "$W/rel-bad/$p-qualcommax-ipq60xx-cambiumnetworks_jaguar-recovery-initramfs-uImage.itb"
ap jaguar XV2-2T1 31 1
check "a tampered image is refused" 1 inst --from "$W/rel-bad" --yes --backed-up ram
assert "the hash mismatch is named" said 'has SHA-256 .* but the release lists'
assert "tampered image: nothing written" nothing_written
ap jaguar XV2-2T1 31 1; touch "$W/tftp_readonly"
check "backup upload refused by the server stops" 1 inst --from "$W/rel" --tftp 192.0.2.5 --yes ram
assert "upload failure is named" said 'upload .* (exit 1: tftp: server error: (2) Access violation)'
assert "upload failure: nothing written to flash" [ -z "$(grep -E '^(attach|mkvol|update|setenv)' "$W/calls")" ]

# --- update-upgrader (converted Jaguar OpenWrt) -------------------------------------------------
ap jaguar XV2-2 20 1 03400000
mkdir -p "$RT/etc" "$RT/lib/functions" "$RT/lib/upgrade" "$RT/tmp/sysinfo"; : > "$RT/etc/openwrt_release"
echo cambiumnetworks,xv2-2 > "$RT/tmp/sysinfo/board_name"
echo 'console=ttyMSM0 ubi.mtd=rootfs_1 root=/dev/ubiblock0_1' > "$RT/proc/cmdline"
echo '# old functions' > "$RT/lib/functions/cambium-jaguar.sh"; echo '# old upgrade' > "$RT/lib/upgrade/cambium-jaguar.sh"
check "update-upgrader check run" 0 inst --from "$W/rel" update-upgrader
assert "check run leaves the old scripts" [ "$(cat "$RT/lib/upgrade/cambium-jaguar.sh")" = '# old upgrade' ]
check "update-upgrader" 0 inst --from "$W/rel" --yes update-upgrader
assert "the release's upgrade scripts are installed" cmp -s "$RT/lib/upgrade/cambium-jaguar.sh" "$W/rel/jaguar-cambium-jaguar-upgrade.sh"
assert "the release's functions are installed" cmp -s "$RT/lib/functions/cambium-jaguar.sh" "$W/rel/jaguar-cambium-jaguar-functions.sh"
assert "the old copies are kept apart" [ "$(cat "$RT/tmp/cambium-install/upgrader-before/upgrade-cambium-jaguar.sh")" = '# old upgrade' ]
assert "the installed upgrader creates UBI nodes" grep -q jaguar_ubi_node "$RT/lib/functions/cambium-jaguar.sh"
check "update-upgrader again: already current" 0 inst --from "$W/rel" --yes update-upgrader
assert "already current is reported" said 'already the release'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
