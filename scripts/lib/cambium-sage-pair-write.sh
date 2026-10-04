#!/bin/sh
# Controller-neutral inactive Sage pair writer. Library, not an installer.
# The caller must authenticate payloads, qualify the exact source/target and
# prepare private recovery before calling. This never arms or confirms a boot.
# No production entrypoint currently loads this library.

csp_fail() { echo "sage inactive pair: $*" >&2; return 1; }
csp_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
csp_hash() { sha256sum < "$1" | awk '{print $1}'; }
csp_read() { cat "${CSP_SYS:-/sys/class/ubi}/$1/$2"; }
csp_magic() {
    if command -v hexdump >/dev/null 2>&1; then
        head -c 4 "$1" | hexdump -v -e '1/1 "%02x"'
    elif command -v od >/dev/null 2>&1; then
        od -An -tx1 -N4 "$1" | tr -d ' \n'
    else
        csp_fail 'no qualified byte reader'
    fi
}

csp_geometry() {
    local node name lebs leb inventory
    inventory=
    for node in "${CSP_SYS:-/sys/class/ubi}/ubi0_"*; do
        [ -r "$node/name" ] || continue
        name=$(cat "$node/name") || return 1
        case "$name" in linux"$CSP_TARGET"|rootfs"$CSP_TARGET"|rootfs_data"$CSP_TARGET") continue ;; esac
        lebs=$(cat "$node/reserved_ebs") || return 1
        leb=$(cat "$node/usable_eb_size") || return 1
        csp_number "$lebs" && [ "$lebs" -gt 0 ] && [ "$leb" = 126976 ] || return 1
        case "$name" in ''|*[!a-zA-Z0-9_]*) return 1 ;; esac
        inventory="$inventory${node##*/} $name $lebs $leb
"
    done
    printf '%s' "$inventory" | LC_ALL=C sort
}

csp_pair_check() {
    local id name actual rootarg slot overlay node matches roots attachments arg
    [ "${CSP_ACTIVE:-}" = 0 ] || [ "${CSP_ACTIVE:-}" = 1 ] || csp_fail 'invalid active bank' || return 1
    CSP_TARGET=$((1 - CSP_ACTIVE))
    [ "$(csp_read ubi0 eraseblock_size)" = 126976 ] || csp_fail 'unqualified LEB size' || return 1
    [ "$(csp_read ubi0 min_io_size)" = 2048 ] || csp_fail 'unqualified minimum I/O' || return 1
    [ "$(csp_read ubi0 mtd_num)" = "${CSP_FS_MTD:-}" ] || csp_fail 'wrong UBI attachment' || return 1
    matches=$(for node in "${CSP_SYS:-/sys/class/ubi}/ubi0_"*/name; do
        [ -r "$node" ] || continue
        cat "$node" || exit 1
        printf '\n'
    done) || return 1
    printf '%s\n' "$matches" | awk 'NF {if (seen[$0]++) bad=1} END {exit bad}' || csp_fail 'duplicate volume names' || return 1
    for node in "${CSP_SYS:-/sys/class/ubi}/ubi"*/mtd_num; do
        [ -r "$node" ] || continue
        [ "$node" = "${CSP_SYS:-/sys/class/ubi}/ubi0/mtd_num" ] && continue
        [ "$(cat "$node")" != "$CSP_FS_MTD" ] || csp_fail 'multiple fs attachments' || return 1
    done
    for id in 0 1 2 3; do
        slot=$((id / 2))
        if [ "$((id % 2))" = 0 ]; then name=linux$slot; else name=rootfs$slot; fi
        [ "$(csp_read ubi0_$id name)" = "$name" ] || csp_fail 'unexpected pair IDs' || return 1
        [ "$(csp_read ubi0_$id usable_eb_size)" = 126976 ] || return 1
        actual=$(csp_read ubi0_$id reserved_ebs) || return 1
        case "$name:$actual" in linux?:34|rootfs?:285|rootfs?:305|rootfs?:372) ;; *) csp_fail 'unreviewed pair capacity'; return 1 ;; esac
    done
    CSP_KERNEL_ID=$((2 * CSP_TARGET))
    CSP_ROOT_ID=$((CSP_KERNEL_ID + 1))
    # Running-slot validation is independent of environment selection.
    rootarg=$(cat "${CSP_CMDLINE:-/proc/cmdline}") || return 1
    roots=0 attachments=0
    for arg in $rootarg; do
        case "$arg" in root=*) roots=$((roots + 1)) ;; ubi.mtd=*) attachments=$((attachments + 1)) ;; esac
    done
    [ "$roots:$attachments" = 1:1 ] || csp_fail 'ambiguous root or attachment command line' || return 1
    case " $rootarg " in
        *" root=ubi0:rootfs$CSP_ACTIVE "*) ;;
        *" root=/dev/ubiblock0_$((2 * CSP_ACTIVE + 1)) "*) ;;
        *) csp_fail 'running root disagrees with active pair'; return 1 ;;
    esac
    case " $rootarg " in *" ubi.mtd=fs "*) ;; *) csp_fail 'fs attachment absent from command line'; return 1 ;; esac
    # Refuse a target mount, including a numeric device or named UBIFS volume.
    for id in "$CSP_KERNEL_ID" "$CSP_ROOT_ID"; do
        if awk -v dev="${CSP_DEV:-/dev}/ubi0_$id" -v block="${CSP_DEV:-/dev}/ubiblock0_$id" \
            -v named="ubi0:$(csp_read ubi0_$id name)" '$1==dev || $1==block || $1==named {found=1} END {exit !found}' \
            "${CSP_MOUNTS:-/proc/mounts}"; then csp_fail 'inactive pair is mounted'; return 1; fi
        [ ! -e "${CSP_DEV:-/dev}/ubiblock0_$id" ] || csp_fail 'inactive block mapping must be safely removed before staging' || return 1
    done
    CSP_OVERLAY_ID= CSP_OVERLAY_LEBS=0
    matches=0
    for node in "${CSP_SYS:-/sys/class/ubi}/ubi0_"*; do
        [ -r "$node/name" ] || continue
        [ "$(cat "$node/name")" = "rootfs_data$CSP_TARGET" ] || continue
        matches=$((matches + 1))
        CSP_OVERLAY_ID=${node##*ubi0_}
        csp_number "$CSP_OVERLAY_ID" && [ "$CSP_OVERLAY_ID" -ge 4 ] || return 1
        CSP_OVERLAY_LEBS=$(cat "$node/reserved_ebs") || return 1
        [ "$CSP_OVERLAY_LEBS" = 67 ] || csp_fail 'unreviewed inactive overlay size' || return 1
        if awk -v dev="${CSP_DEV:-/dev}/ubi0_$CSP_OVERLAY_ID" -v named="ubi0:rootfs_data$CSP_TARGET" \
            '$1==dev || $1==named {found=1} END {exit !found}' "${CSP_MOUNTS:-/proc/mounts}"; then
            csp_fail 'inactive overlay is mounted'; return 1
        fi
    done
    [ "$matches" -le 1 ] || csp_fail 'duplicate inactive overlay' || return 1
}

csp_payload_check() {
    local kernel=$1 root=$2 root_lebs=$3 root_format=$4 magic free current needed file
    case "$root_lebs:$root_format" in 285:squashfs|305:ubifs|372:ubifs) ;; *) csp_fail 'unreviewed target geometry/format'; return 1 ;; esac
    for file in "$kernel" "$root"; do
        [ -f "$file" ] && [ ! -L "$file" ] || csp_fail 'payload must be regular and frozen privately' || return 1
    done
    csp_pair_check || return 1
    [ "$(wc -c < "$kernel")" -gt 0 ] && [ "$(wc -c < "$kernel")" -le 4317184 ] || return 1
    [ "$(wc -c < "$root")" -gt 0 ] && [ "$(wc -c < "$root")" -le "$((root_lebs * 126976))" ] || return 1
    magic=$(csp_magic "$kernel") || return 1
    [ "$magic" = d00dfeed ] || csp_fail 'kernel is not FIT' || return 1
    magic=$(csp_magic "$root") || return 1
    case "$root_format:$magic" in squashfs:68737173|ubifs:31181006) ;; *) csp_fail 'root filesystem magic mismatch'; return 1 ;; esac
    # Format, FIT configuration and UBIFS superblock/max-LEB semantics must
    # additionally have been authenticated/validated by the qualified caller.
    free=$(csp_read ubi0 avail_eraseblocks) || return 1
    current=$(csp_read ubi0_$CSP_ROOT_ID reserved_ebs) || return 1
    csp_number "$free" || return 1
    [ "$free" -le 1024 ] || csp_fail 'invalid free-block count' || return 1
    needed=$root_lebs
    [ "$root_format" != squashfs ] || needed=$((needed + 67))
    [ "$((current + free + CSP_OVERLAY_LEBS))" -ge "$needed" ] || csp_fail 'inactive-only capacity is insufficient' || return 1
    if [ "$root_format" = squashfs ] && [ -z "$CSP_OVERLAY_ID" ]; then
        # Reviewed Sage IDs: 4 is shared nvram, 5/6 are the bank overlays.
        CSP_OVERLAY_ID=$((6 - CSP_TARGET))
        [ ! -e "${CSP_SYS:-/sys/class/ubi}/ubi0_$CSP_OVERLAY_ID" ] || csp_fail 'required overlay ID is already occupied' || return 1
    fi
}

csp_readback() {
    local file=$1 device=$2 bytes expected actual
    bytes=$(wc -c < "$file") || return 1
    expected=$(csp_hash "$file") || return 1
    actual=$(head -c "$bytes" "$device" | sha256sum | awk '{print $1}') || return 1
    [ "$actual" = "$expected" ] || csp_fail 'payload readback differs' || return 1
}

csp_stage_pair() (
    # Subshell prevents state leakage into another transaction.
    local kernel=$1 root=$2 root_lebs=$3 root_format=$4 before after current kh rh overlay_id overlay_lebs
    [ "${CSP_WRITE_ADMISSION:-}" = qualified ] || csp_fail 'caller has not admitted this exact production transaction' || exit 1
    # Test-only filesystem roots never authorize live writes. Tests replace all
    # destructive commands, while an installer must use fixed real roots.
    csp_payload_check "$kernel" "$root" "$root_lebs" "$root_format" || exit 1
    overlay_id=$CSP_OVERLAY_ID overlay_lebs=$CSP_OVERLAY_LEBS
    before=$(csp_geometry) || exit 1
    kh=$(csp_hash "$kernel") && rh=$(csp_hash "$root") || exit 1
    csp_pair_check || exit 1
    current=$(csp_read ubi0_$CSP_ROOT_ID reserved_ebs) || exit 1
    # Inactive-only reclamation. Never touch active overlay or shared volumes.
    if [ "$overlay_lebs" -gt 0 ]; then
        ubirmvol "${CSP_DEV:-/dev}/ubi0" -n "$CSP_OVERLAY_ID" || exit 1
    fi
    if [ "$current" != "$root_lebs" ]; then
        ubiupdatevol -t "${CSP_DEV:-/dev}/ubi0_$CSP_ROOT_ID" || exit 1
        ubirsvol "${CSP_DEV:-/dev}/ubi0" -n "$CSP_ROOT_ID" -s "$((root_lebs * 126976))" || exit 1
    fi
    [ "$(csp_read ubi0_$CSP_ROOT_ID reserved_ebs)" = "$root_lebs" ] || exit 1
    [ "$(csp_hash "$kernel")" = "$kh" ] && [ "$(csp_hash "$root")" = "$rh" ] || exit 1
    ubiupdatevol "${CSP_DEV:-/dev}/ubi0_$CSP_ROOT_ID" "$root" || exit 1
    csp_readback "$root" "${CSP_DEV:-/dev}/ubi0_$CSP_ROOT_ID" || exit 1
    [ "$(csp_hash "$root")" = "$rh" ] && [ "$(csp_hash "$kernel")" = "$kh" ] || exit 1
    ubiupdatevol "${CSP_DEV:-/dev}/ubi0_$CSP_KERNEL_ID" "$kernel" || exit 1
    csp_readback "$kernel" "${CSP_DEV:-/dev}/ubi0_$CSP_KERNEL_ID" || exit 1
    if [ "$root_format" = squashfs ]; then
        ubimkvol "${CSP_DEV:-/dev}/ubi0" -n "$overlay_id" -N "rootfs_data$CSP_TARGET" -s 8507392 || exit 1
    fi
    sync || exit 1
    after=$(csp_geometry) || exit 1
    [ "$before" = "$after" ] || csp_fail 'protected volume geometry changed' || exit 1
    [ "$(csp_hash "$root")" = "$rh" ] && [ "$(csp_hash "$kernel")" = "$kh" ] || exit 1
    printf 'inactive_pair_staged=%s\nboot_state_changed=no\n' "$CSP_TARGET"
)
