#!/bin/sh
# Build, verify and collect one Cambium family snapshot.
#
# Usage: cambium/scripts/build.sh FAMILY [BUILD_ID]
#   FAMILY    sage | thor | cheetah | jaguar
#   BUILD_ID  YYYY.MM.DD.N (default: today's date with N=0)
#
# Environment:
#   JOBS                    parallel make jobs (default: nproc)
#   CAMBIUM_FEED_URL        base URL of the published package feeds; when set,
#                           images get an apk repository for this build
#   CAMBIUM_APK_PRIVATE_KEY PEM EC private key used to sign packages; when
#                           unset the build generates a throwaway key
#   CAMBIUM_OUTPUT          collection directory (default: cambium-output)
#   CAMBIUM_SKIP_FEEDS      set to 1 to reuse already installed feeds

set -eu

family=${1:?usage: $0 sage|thor|cheetah|jaguar [build-id]}
build_id=${2:-$(date -u +%Y.%m.%d).0}
top=$(git rev-parse --show-toplevel)
cd "$top"

case "$family" in
sage)    name=Sage;    target=ipq40xx;    subtarget=generic ;;
thor)    name=Thor;    target=qualcommax; subtarget=ipq807x ;;
cheetah) name=Cheetah; target=qualcommax; subtarget=ipq50xx ;;
jaguar)  name=Jaguar;  target=qualcommax; subtarget=ipq60xx ;;
*) echo "Unknown family: $family" >&2; exit 2 ;;
esac
case "$build_id" in
[0-9][0-9][0-9][0-9].[0-1][0-9].[0-3][0-9].[0-9]*) ;;
*) echo "Invalid build ID: $build_id (expected YYYY.MM.DD.N)" >&2; exit 2 ;;
esac

id_key=$(echo "$name" | tr '[:lower:]' '[:upper:]')_BUILD_ID
jobs=${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}
bin_dir=bin/targets/$target/$subtarget
output=${CAMBIUM_OUTPUT:-$top/cambium-output}/$family
upstream=$(git merge-base HEAD "${CAMBIUM_UPSTREAM_REF:-upstream/main}" 2>/dev/null || echo unknown)

log() { printf '\n==> %s\n' "$*"; }

if [ "${CAMBIUM_SKIP_FEEDS:-0}" != 1 ]; then
	log "Updating feeds"
	./scripts/feeds update -a
	./scripts/feeds install -a
fi

# Building LLVM for eBPF takes hours; use upstream's prebuilt toolchain for
# this target, as the OpenWrt buildbots do.
if [ ! -f llvm-bpf/.llvm-version ]; then
	log "Fetching prebuilt LLVM eBPF toolchain"
	base=https://downloads.openwrt.org/snapshots/targets/$target/$subtarget
	sums=$(wget -qO- "$base/sha256sums")
	file=$(printf '%s\n' "$sums" | sed -n 's/^[0-9a-f]\{64\} \*\{0,1\}\(llvm-bpf-.*\.Linux-x86_64\.tar\.zst\)$/\1/p' | head -n 1)
	if [ -n "$file" ] && wget -q -O "/tmp/$file" "$base/$file" &&
		printf '%s\n' "$sums" | grep " \*\{0,1\}$file\$" | sed 's/ \*/  /' |
			(cd /tmp && sha256sum -c --quiet -); then
		# The archive carries llvm-bpf-<version>/ and an llvm-bpf symlink.
		rm -rf llvm-bpf llvm-bpf-*
		tar -I zstd -xf "/tmp/$file"
		rm -f "/tmp/$file"
		[ -f llvm-bpf/.llvm-version ] || log "Prebuilt LLVM archive has an unexpected layout"
	else
		log "Prebuilt LLVM unavailable; it will be built from source"
	fi
fi

log "Configuring $name ($target/$subtarget), build $build_id"
cat cambium/configs/common.config "cambium/configs/$family.config" > .config

if [ -n "${CAMBIUM_APK_PRIVATE_KEY:-}" ]; then
	umask 077
	printf '%s\n' "$CAMBIUM_APK_PRIVATE_KEY" > private-key.pem
	openssl ec -in private-key.pem -pubout -out public-key.pem 2>/dev/null
	umask 022
fi

# Downstream identity lives beside, not instead of, the upstream OpenWrt
# release identity (see cambium/README.md).
rm -rf files
mkdir -p files/etc
{
	printf "CAMBIUM_FAMILY='%s'\n" "$name"
	printf "%s='%s'\n" "$id_key" "$build_id"
	printf "CAMBIUM_SOURCE_COMMIT='%s'\n" "$(git rev-parse HEAD)"
	printf "OPENWRT_UPSTREAM_COMMIT='%s'\n" "$upstream"
} > files/etc/cambium-openwrt-release

make defconfig >/dev/null
arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' .config)
for device in $(sed -n 's/^CONFIG_TARGET_DEVICE_.*_DEVICE_\([^=]*\)=y$/\1/p' "cambium/configs/$family.config"); do
	grep -q "^CONFIG_TARGET_DEVICE_${target}_${subtarget}_DEVICE_$device=y$" .config || {
		echo "defconfig dropped device $device" >&2
		exit 1
	}
done

if [ -n "${CAMBIUM_FEED_URL:-}" ]; then
	mkdir -p files/etc/apk/repositories.d
	{
		echo "# Cambium $name snapshot $build_id: kernel modules and Cambium packages"
		echo "$CAMBIUM_FEED_URL/$build_id/$family/targets/$target/$subtarget/packages/packages.adb"
		echo "$CAMBIUM_FEED_URL/$build_id/$family/packages/$arch/base/packages.adb"
	} > files/etc/apk/repositories.d/cambium.list
fi

log "Downloading sources"
make download -j8 || make download -j1 V=s

log "Building"
# base-files caches release strings; always regenerate them.
make package/base-files/clean >/dev/null
# As on the OpenWrt buildbots, packages built only for the feed (=m, e.g. the
# kernel modules of every feed pulled in by ALL_KMODS) may fail without
# stopping the snapshot. Anything an image needs still fails image assembly.
build_log=$top/logs/cambium-build.log
mkdir -p "$top/logs"
# Run make with its output teed to a log while keeping make's exit status.
logged_make() {
	status_file=$(mktemp)
	{ make "$@"; echo $? > "$status_file"; } 2>&1 | tee -a "$build_log"
	status=$(cat "$status_file")
	rm -f "$status_file"
	return "$status"
}
: > "$build_log"
if ! logged_make -j"$jobs" IGNORE_ERRORS=m BUILD_LOG=1; then
	log "Parallel build failed; retrying serially for a readable log"
	logged_make -j1 V=s IGNORE_ERRORS=m BUILD_LOG=1
fi
skipped=$(sed -n 's/^ *ERROR: \(package\/[^ ]*\) failed to build.*/\1/p' "$build_log" | sort -u)
if [ -n "$skipped" ]; then
	log "Feed-only packages that failed to build (not in any image):"
	printf '  %s\n' $skipped
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "### $name: feed-only packages that failed to build"
			printf -- '- `%s`\n' $skipped
		} >> "$GITHUB_STEP_SUMMARY"
	fi
fi

log "Verifying"
fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }
image() {
	found=$(find "$bin_dir" -maxdepth 1 -type f -name "$1" | head -n 1)
	[ -s "$found" ] || fail "missing image $1"
	echo "$found"
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
verify=cambium/verify/$family/verify-family-fit.sh

case "$family" in
sage)
	fits="recovery=$(image '*cambiumnetworks_sage-recovery-initramfs-zImage.itb')
persistent=$(image '*cambiumnetworks_sage-persistent-squashfs-kernel.itb')"
	SAGE_FLAVOR=recovery sh "$verify" "$(image '*cambiumnetworks_sage-recovery-initramfs-zImage.itb')"
	SAGE_FLAVOR=persistent sh "$verify" "$(image '*cambiumnetworks_sage-persistent-squashfs-kernel.itb')"
	image '*cambiumnetworks_sage-persistent-squashfs-sysupgrade.bin' >/dev/null
	;;
thor)
	THOR_FLAVOR=recovery sh "$verify" "$(image '*cambiumnetworks_thor-recovery-initramfs-uImage.itb')"
	THOR_FLAVOR=persistent sh "$verify" "$(image '*cambiumnetworks_thor-installer-initramfs-uImage.itb')"
	sysupgrade=$(image '*cambiumnetworks_thor-persistent-squashfs-sysupgrade.bin')
	tar -xOf "$sysupgrade" sysupgrade-cambiumnetworks_xv3-8/kernel > "$work/kernel.itb"
	THOR_FLAVOR=ab sh "$verify" "$work/kernel.itb"
	fits="recovery=$(image '*cambiumnetworks_thor-recovery-initramfs-uImage.itb')
installer=$(image '*cambiumnetworks_thor-installer-initramfs-uImage.itb')
persistent=$work/kernel.itb"
	factory=$(image '*cambiumnetworks_thor-persistent-squashfs-factory.ubi')
	[ "$(wc -c < "$factory")" -lt 100663296 ] ||
		fail "XV3-8 factory image exceeds the 96 MiB bank"
	grep -aq cambium_device_data "$factory" ||
		fail "Thor factory image lacks the device-data vault volume"
	;;
cheetah)
	CHEETAH_FLAVOR=recovery sh "$verify" "$(image '*cambiumnetworks_cheetah-recovery-initramfs-uImage.itb')"
	sysupgrade=$(image '*cambiumnetworks_cheetah-persistent-squashfs-sysupgrade.bin')
	tar -xOf "$sysupgrade" sysupgrade-cambiumnetworks_cheetah/kernel > "$work/cheetah-kernel.itb" ||
		fail "Cheetah sysupgrade lacks the family kernel"
	CHEETAH_FLAVOR=persistent sh "$verify" "$work/cheetah-kernel.itb"
	fits="recovery=$(image '*cambiumnetworks_cheetah-recovery-initramfs-uImage.itb')
persistent=$work/cheetah-kernel.itb"
	factory=$(image '*cambiumnetworks_cheetah-persistent-squashfs-factory.ubi')
	[ "$(wc -c < "$factory")" -lt 100663296 ] ||
		fail "Cheetah factory image exceeds the 96 MiB bank"
	grep -aq cambium_device_data "$factory" ||
		fail "Cheetah factory image lacks the device-data vault volume"
	;;
jaguar)
	JAGUAR_FLAVOR=recovery sh "$verify" "$(image '*cambiumnetworks_jaguar-recovery-initramfs-uImage.itb')"
	kernel=$(find build_dir -type f -name 'cambiumnetworks_jaguar-persistent-uImage.itb' | head -n 1)
	[ -s "$kernel" ] || fail "missing Jaguar persistent kernel FIT"
	JAGUAR_FLAVOR=persistent sh "$verify" "$kernel"
	fits="recovery=$(image '*cambiumnetworks_jaguar-recovery-initramfs-uImage.itb')
persistent=$kernel"
	factory=$(image '*cambiumnetworks_jaguar-persistent-squashfs-factory.ubi')
	grep -aq cambium_device_data "$factory" ||
		fail "Jaguar factory image lacks the device-data vault volume"
	sysupgrade=$(image '*cambiumnetworks_jaguar-persistent-squashfs-sysupgrade.bin')
	tar -tf "$sysupgrade" | grep -qx 'sysupgrade-cambiumnetworks_jaguar/kernel' ||
		fail "Jaguar sysupgrade lacks the family kernel"
	tar -xOf "$sysupgrade" sysupgrade-cambiumnetworks_jaguar/kernel > "$work/jaguar-kernel.itb"
	cmp -s "$work/jaguar-kernel.itb" "$kernel" ||
		fail "Jaguar sysupgrade kernel differs from the verified persistent FIT"
	# One family image serves both bank sizes, so it must fit the XV2-2's
	# 52 MiB bank (392 usable LEBs) with the vault (8) and an 8 MiB overlay (67).
	root_bytes=$(tar -xOf "$sysupgrade" sysupgrade-cambiumnetworks_jaguar/root | wc -c)
	lebs=$(( ($(wc -c < "$kernel") + 126975) / 126976 + (root_bytes + 126975) / 126976 + 8 + 67 ))
	[ "$lebs" -le 392 ] ||
		fail "Jaguar image needs $lebs LEBs; the XV2-2's 52 MiB bank has 392"
	echo "Jaguar image uses $lebs of 392 LEBs in an XV2-2 bank"
	;;
esac

# Per-device root filesystems are staged as $(KDIR)/target-dir-* copies.
roots=$(find build_dir -mindepth 3 -maxdepth 3 -type d -name 'target-dir-*' \
	-path "*/linux-${target}_$subtarget/*")
[ -n "$roots" ] || roots=$(find build_dir -mindepth 2 -maxdepth 2 -type d -name "root-$target*")
[ -n "$roots" ] || fail "no generated root filesystems found"
for root in $roots; do
	grep -qx "$id_key='$build_id'" "$root/etc/cambium-openwrt-release" ||
		fail "$root lacks the $name build ID"
	grep -q "^DISTRIB_RELEASE='[^']\{1,\}'$" "$root/etc/openwrt_release" ||
		fail "$root lacks the upstream OpenWrt release"
	[ ! -s "$root/etc/dropbear/authorized_keys" ] ||
		fail "$root contains SSH authorized keys"
	leaked=$(find "$root/lib/firmware" \( -name 'bdwlan*' -o -path '*/ath11k/*/board.bin' \) 2>/dev/null)
	[ -z "$leaked" ] || fail "$root contains OEM board data: $leaked"
done

# Release gate: unpack each persistent image's actual root filesystem, write
# its installed-package manifest and fail unless the managed-AP packages and
# services are present. A Sage UBIFS root was once made from the shared base
# root filesystem instead of the device's own and shipped without LuCI,
# OpenWISP, WireGuard or its support package.
gate() { # gate ROOT IMAGE_NAME LABEL
	UNSQUASHFS=staging_dir/host/bin/unsquashfs4 UBIREADER_EXTRACT=${UBIREADER_EXTRACT:-ubireader_extract_files} \
		sh cambium/scripts/rootfs-gate.sh "$1" "$work/manifests/$2.manifest" "$3" \
		cambium-$family-support cambium-ab cambium-rrm-agent $gate_extra ||
		fail "the $3 root filesystem failed the package gate"
}
# Thor's persistent image also carries the scanning radio's driver.
gate_extra=
[ "$family" = thor ] && gate_extra="kmod-ath10k-ct ath10k-firmware-qca9887-ct"
mkdir -p "$work/manifests"
sysupgrade=$(image "*cambiumnetworks_$family-persistent-squashfs-sysupgrade.bin")
tar -xOf "$sysupgrade" "$(tar -tf "$sysupgrade" | grep '/root$' | head -n 1)" > "$work/persistent-root" ||
	fail "cannot read the root filesystem of ${sysupgrade##*/}"
gate "$work/persistent-root" "${sysupgrade##*/}" "$name persistent sysupgrade.bin"
if [ "$family" = sage ]; then
	rootfs=$(image '*cambiumnetworks_sage-persistent-squashfs-rootfs.ubifs')
	gate "$rootfs" "${rootfs##*/}" "Sage persistent rootfs.ubifs"
fi

log "Collecting to $output"
rm -rf "$output"
mkdir -p "$output/images" "$output/feed/targets/$target/$subtarget" "$output/feed/packages/$arch"
# Only recovery and installer devices publish RAM (initramfs) images; the
# initramfs builds of persistent devices are a side effect of building both
# kinds together.
find "$bin_dir" -maxdepth 1 -type f \( -name '*cambiumnetworks_*' -o -name 'profiles.json' \
	-o -name '*.buildinfo' -o -name 'sha256sums' -o -name '*imagebuilder*' \) \
	! \( -name '*-initramfs-*' ! -name '*-recovery-initramfs-*' ! -name '*-installer-initramfs-*' \) \
	! -name '*cambiumnetworks_thor-*-test-*' \
	-exec cp {} "$output/images/" \;
cp -R "$bin_dir/packages" "$output/feed/targets/$target/$subtarget/"
# The installed-package manifests the release gate wrote (test images'
# manifests go with the test images).
for m in "$work/manifests/"*.manifest; do
	case "$m" in
	*cambiumnetworks_thor-*-test-*) ;;
	*) cp "$m" "$output/images/" ;;
	esac
done
cp -R "bin/packages/$arch/base" "$output/feed/packages/$arch/"
cp files/etc/cambium-openwrt-release "$output/images/cambium-openwrt-release"
# The kernel and rootfs content of each factory image the installer writes
# with ubiformat, so it can hash them back after writing.
for f in "$output/images/"*cambiumnetworks_thor-persistent-squashfs-factory.ubi \
	"$output/images/"*cambiumnetworks_jaguar-persistent-squashfs-factory.ubi \
	"$output/images/"*cambiumnetworks_cheetah-persistent-squashfs-factory.ubi; do
	[ -f "$f" ] || continue
	python3 cambium/scripts/ubi-contents.py "$f" > "$f.contents" ||
		fail "cannot read the kernel and rootfs content of ${f##*/}"
done
# A running A/B system upgrades with its own scripts; publish the current
# ones so cambium-install.sh update-upgrader can install them first.
module=package/cambium/cambium-$family-support/files/cambium-ab-$family.sh
if [ -f "$module" ]; then
	cp package/cambium/cambium-ab/files/cambium-ab.sh "$output/images/cambium-ab.sh"
	cp package/cambium/cambium-ab/files/cambium-ab-upgrade.sh "$output/images/cambium-ab-upgrade.sh"
	cp "$module" "$output/images/cambium-ab-$family.sh"
fi
# Test images go only to the CI artifact (test-only/), never to a release:
# a RAM build of the Jaguar persistent trees.
if [ "$family" = jaguar ]; then
	mkdir -p "$output/test-only"
	cp "$bin_dir/"*cambiumnetworks_jaguar-persistent-initramfs-uImage.itb "$output/test-only/"
	(cd "$output/test-only" && sha256sum -- * > test-only-SHA256SUMS)
fi
# Machine-readable model/SKU/configuration/image manifest; also fails if
# cambium/families.json names a configuration the built FITs lack.
old_ifs=$IFS; IFS='
'
python3 cambium/scripts/manifest.py cambium/families.json "$family" "$output/images" \
	files/etc/cambium-openwrt-release $fits
IFS=$old_ifs
(cd "$output/images" && sha256sum -- * > SHA256SUMS)
printf '%s\n' "$build_id" > "$output/BUILD_ID"
log "Done: $name $build_id"
