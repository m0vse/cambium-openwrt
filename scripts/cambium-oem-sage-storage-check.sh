#!/bin/sh
# Read-only OEM source storage check; no converted-stock libraries or ucode.
# Successful storage inspection is NOT production writer admission.
set -eu
LC_ALL=C
export LC_ALL
fail() { echo "sage OEM source storage: $*" >&2; exit 1; }
[ "$#" -ge 1 ] || fail 'usage: check | inspect-capture ROOT'
mode=$1; shift
root=
case "$mode" in
    check) [ "$#" = 0 ] || exit 2; [ "$(id -u)" = 0 ] || fail 'root required' ;;
    inspect-capture) [ "$#" = 1 ] && [ -d "$1" ] || exit 2; root=$1 ;;
    *) exit 2 ;;
esac
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -n "$root" ]; then
    evidence=$(sh "$here/cambium-oem-sage-prepare.sh" inspect-capture "$root") || exit 1
else
    evidence=$(sh "$here/cambium-oem-sage-prepare.sh" check) || exit 1
fi
# Parse declarative evidence; never eval source firmware or a downloaded file.
active=$(printf '%s\n' "$evidence" | awk -F= '$1=="running_bank" {v=$2;n++} END {if(n!=1)exit 1;print v}') || exit 1
case "$active" in 0|1) ;; *) exit 1 ;; esac
[ -r "$root/etc/version" ] || fail 'missing OEM release evidence'
release=$(awk -F= '$1=="VERSION" {v=$2;n++} END {if(n!=1)exit 1;print v}' "$root/etc/version") || fail 'ambiguous OEM release'
product=$(awk -F= '$1=="PRODUCT" {v=$2;n++} END {if(n!=1)exit 1;print v}' "$root/etc/version") || fail 'ambiguous OEM family'
[ "$product:$release" = sage:4.2.3.3-r10 ] || fail 'OEM source release has not been reviewed'
[ -d "$root/root" ] && [ ! -L "$root/root" ] || fail 'source root directory missing or symlinked'
[ -r "$root/proc/mounts" ] || fail 'missing source mount evidence'
# OEM's writable /etc overlay on shared nvram does not make /root durable.
# Require /root itself on the selected writable UBIFS root, with no covering
# child mount. This intentionally rejects an unqualified shared/volatile path.
awk '$2=="/root" || index($2,"/root/")==1 {bad=1} END {exit bad}' "$root/proc/mounts" || fail 'source directory has a covering mount'
volume=ubi0_$((active * 2 + 1))
named=ubi0:rootfs$active
awk -v dev="/dev/$volume" -v named="$named" '
    $2=="/" {roots++; if($3=="ubifs" && ($1==dev || $1==named) && $4 ~ /(^|,)rw(,|$)/)good=1}
    END {exit !(roots==1 && good)}' "$root/proc/mounts" || fail 'root is not the active writable OEM UBIFS volume'
if [ -z "$root" ]; then
    [ "$(readlink -f /root)" = /root ] || fail 'source root resolves elsewhere'
    owner=$(LC_ALL=C ls -ldn /root | awk '{print $1 ":" $3}')
    case "$owner" in drwx------:0|drwxr-x---:0|drwxr-xr-x:0) ;; *) fail 'unsafe source root owner/permissions' ;; esac
fi
printf '%s\n' "$evidence"
printf 'source_release=%s\ndurable_root=%s\nstorage_check=passed\n' "$release" "$named"
printf 'remaining=authenticated exact source runtime, installer adapter, power-loss/recovery qualification\n'
