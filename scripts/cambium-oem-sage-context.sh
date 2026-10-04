#!/bin/sh
# Seven read-only TSV context fields for an authenticated installer source runner.
# Not a production admission check, issuer or writer. No stock library loader.
set -eu
LC_ALL=C
export LC_ALL
fail() { echo "sage OEM context: $*" >&2; exit 1; }
[ "$#" -ge 1 ] || exit 2
mode=$1; shift
root=
case "$mode" in
    check) [ "$#" = 0 ] || exit 2 ;;
    inspect-capture) [ "$#" = 1 ] || exit 2; root=$1 ;;
    *) exit 2 ;;
esac
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -n "$root" ]; then
    evidence=$(sh "$here/cambium-oem-sage-storage-check.sh" inspect-capture "$root") || exit 1
else
    evidence=$(sh "$here/cambium-oem-sage-storage-check.sh" check) || exit 1
fi
field() { printf '%s\n' "$evidence" | awk -F= -v key="$1" '$1==key {v=$2;n++} END {if(n!=1)exit 1;print v}'; }
model=$(field model) && active=$(field running_bank) || exit 1
case "$model:$active" in E410:0|E410:1|E410B:0|E410B:1) ;; *) exit 1 ;; esac
mfg=$(awk '$4=="\"mfginfo\"" {sub(/mtd/,"",$1);sub(/:/,"",$1);v=$1;n++} END {if(n!=1)exit 1;print v}' "$root/proc/mtd") || exit 1
# Reviewed manufacturing format: little-endian CA05 magic, type 1, length 12,
# followed by the canonical ASCII label MAC. Never infer from enclosure or IP.
if command -v hexdump >/dev/null 2>&1; then
    header=$(head -c 6 "$root/dev/mtd${mfg}ro" | hexdump -v -e '1/1 "%02x"')
else
    header=$(od -An -tx1 -N6 "$root/dev/mtd${mfg}ro" | tr -d ' \n')
fi
[ "$header" = 05ca01000c00 ] || fail 'unreviewed manufacturing identity format'
serial=$(dd if="$root/dev/mtd${mfg}ro" bs=1 skip=6 count=12 2>/dev/null | tr 'A-F' 'a-f')
[ "${#serial}" = 12 ] || fail 'short label MAC'
case "$serial" in *[!0-9a-f]*|000000000000|ffffffffffff) fail 'invalid label MAC' ;; esac
first=$(printf '%s' "$serial" | cut -c2)
case "$first" in 1|3|5|7|9|b|d|f) fail 'multicast label MAC' ;; esac
pending() {
    if [ -n "$root" ]; then
        if [ -r "$root/environment/sage_installer_$1" ]; then cat "$root/environment/sage_installer_$1"; fi
    else
        # Storage preflight already validates competing environment configs.
        config=/etc/fw_env.config
        [ -r "$config" ] || config=/tmp/fw_env.config
        fw_printenv -c "$config" -n "sage_installer_$1" 2>/dev/null || :
    fi
}
target=$(pending target) job=$(pending job) image=$(pending image)
if [ -n "$target$job$image" ]; then
    case "$target" in 0|1) ;; *) fail 'invalid pending target' ;; esac
    [ "$target" != "$active" ] || fail 'pending source target is active'
    [ "${#job}" = 32 ] && [ "${#image}" = 64 ] || fail 'incomplete pending identity transaction'
    case "$job$image" in *[!0-9a-f]*) fail 'invalid pending transaction digests' ;; esac
fi
printf '%s\tsage\t%s\t%s\t%s\t%s\t%s\n' "$serial" "$model" "$active" "$target" "$job" "$image"
