#!/bin/sh
# Real files, tar, hashes and crypto; mounts/UBI identity are isolated stubs.
# This does not prove kernel UBIFS allocation or a physical RAM pivot.
set -eu
top=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d /tmp/cambium-ab-certificates-test.XXXXXX)
umask 077
mkdir -p "$fixture/active" "$fixture/target" "$fixture/runtime" "$fixture/sys/ubi0" "$fixture/sys/ubi1" "$fixture/dev"
printf '\061\030\020\006' > "$fixture/dev/ubi0_4"
AB_DEV=$fixture/dev
printf '0\n' > "$fixture/sys/ubi0/mtd_num"
printf '1\n' > "$fixture/sys/ubi1/mtd_num"
printf 'test-boot\n' > "$fixture/boot"
: > "$fixture/mounts"
AB_CERTIFICATE_ARCHIVE=$fixture/archive
AB_CERTIFICATE_DESCRIPTOR=$fixture/descriptor
AB_CERTIFICATE_OWNER=$(id -u)
AB_CERTIFICATE_RUNTIME=$fixture/runtime
AB_CERTIFICATE_STORE=$fixture/active
AB_BOOT_ID=$fixture/boot
AB_PROC_MOUNTS=$fixture/mounts
AB_UBI_SYS=$fixture/sys
AB_LAYOUT=banks AB_FAMILY=jaguar AB_MODEL=XV2-2T1 AB_SKU=0000001f
AB_ACTIVE=0 AB_TARGET=1 AB_ACTIVE_MTD=0 AB_TARGET_MTD=1
AB_ACTIVE_UBI=ubi0 AB_TARGET_UBI=ubi1 AB_LEB=126976
ab_identity() { return 0; }
ab_certificate_lebs() { echo 20; }
ab_fail() { printf '%s\n' "$*" >&2; return 1; }
ab_ubi_volume() { printf '%s_4\n' "$1"; }
mount() {
	for value in "$@"; do destination=$value; done
	case "$*" in
	*ubi0_4*) cp -a "$fixture/active/." "$destination/"; mount_kind=active ;;
	*ubi1_4*) cp -a "$fixture/target/." "$destination/"; mount_kind=target ;;
	*) return 1 ;;
	esac
}
umount() {
	if [ "${mount_kind:-}" = target ]; then
		cp -a "$1/." "$fixture/target/"
		# Emulate an unmounted filesystem so the mountpoint can be removed.
		find "$1" -mindepth 1 -delete
	fi
	mount_kind=
}
. "$top/package/cambium/cambium-ab/files/cambium-ab-certificates.sh"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test-ap \
	-keyout "$fixture/active/key.pem" -out "$fixture/active/cert.pem" >/dev/null 2>&1
printf 'old\n' > "$fixture/active/gateway.json"
printf 'current\n' > "$fixture/runtime/gateway.json"
printf '{"default":"approved"}\n' > "$fixture/runtime/discovery-policy.json"
before=$(sha256sum "$fixture/active/key.pem")
ab_certificate_export
ab_certificate_restore
# Use the actual base-files copy function, not a hand-written cp model.
. "$top/package/base-files/files/lib/upgrade/common.sh"
RAM_ROOT=$fixture/ram
install_file "$AB_CERTIFICATE_ARCHIVE" "$AB_CERTIFICATE_DESCRIPTOR"
saved_archive=$AB_CERTIFICATE_ARCHIVE saved_descriptor=$AB_CERTIFICATE_DESCRIPTOR
AB_CERTIFICATE_ARCHIVE=$RAM_ROOT/$saved_archive
AB_CERTIFICATE_DESCRIPTOR=$RAM_ROOT/$saved_descriptor
ab_certificate_restore
AB_CERTIFICATE_ARCHIVE=$saved_archive AB_CERTIFICATE_DESCRIPTOR=$saved_descriptor
case " $RAMFS_COPY_DATA " in *" $AB_CERTIFICATE_ARCHIVE "*) ;; *) exit 1 ;; esac
case " $RAMFS_COPY_DATA " in *" $AB_CERTIFICATE_DESCRIPTOR "*) ;; *) exit 1 ;; esac
cmp "$fixture/active/key.pem" "$fixture/target/key.pem"
cmp "$fixture/runtime/gateway.json" "$fixture/target/gateway.json"
cmp "$fixture/runtime/discovery-policy.json" "$fixture/target/discovery-policy.json"
test "$(stat -c '%a' "$fixture/target/key.pem")" = 600
test "$(sha256sum "$fixture/active/key.pem")" = "$before"
printf '1:2\n' > "$fixture/descriptor"
if ab_certificate_restore > "$fixture/error" 2>&1; then exit 1; fi
ab_certificate_export
printf 'tamper' >> "$fixture/archive"
if ab_certificate_restore > "$fixture/error" 2>&1; then exit 1; fi
ab_certificate_export
chmod 0644 "$fixture/archive"
if ab_certificate_restore > "$fixture/error" 2>&1; then exit 1; fi
ab_certificate_export
printf 'next-boot\n' > "$fixture/boot"
if ab_certificate_restore > "$fixture/error" 2>&1; then exit 1; fi
printf 'test-boot\n' > "$fixture/boot"
printf '0\n' > "$fixture/sys/ubi1/mtd_num"
if ab_certificate_restore > "$fixture/error" 2>&1; then exit 1; fi
printf '1\n' > "$fixture/sys/ubi1/mtd_num"
printf 'ubi1:certificates %s ubifs rw 0 0\n' "$fixture/active" > "$fixture/mounts"
if ab_certificate_export > "$fixture/error" 2>&1; then exit 1; fi
: > "$fixture/mounts"
ln -s /etc/passwd "$fixture/active/unsafe.pem"
if ab_certificate_export > "$fixture/error" 2>&1; then exit 1; fi
rm "$fixture/active/unsafe.pem"
AB_LAYOUT=pair
ab_certificate_export
ab_certificate_restore
printf '%s\n' "Certificate file-level retention, policy precedence, privacy, source protection and failure cases passed; fixtures: $fixture"
