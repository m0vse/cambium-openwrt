#!/bin/sh
# Keep upstream OpenWrt's CI workflows from running in this fork; only the
# cambium-* workflows are meant to run here. Requires GH_TOKEN with
# actions:write. Problems are reported as warnings: this housekeeping must
# never stop a snapshot build.
set -u
: "${GH_REPO:?GH_REPO must name this fork; never act on upstream}"
case "$GH_REPO" in openwrt/*) echo "Refusing to act on $GH_REPO" >&2; exit 1 ;; esac
list=$(gh workflow list --repo "$GH_REPO" --all --json id,path,state \
	--jq '.[] | select(.state == "active") | "\(.id) \(.path)"') || {
	echo "::warning::Could not list workflows"
	exit 0
}
printf '%s\n' "$list" | while read -r id path; do
	case "$path" in
	.github/workflows/cambium-*|'') ;;
	.github/workflows/*)
		if gh workflow disable --repo "$GH_REPO" "$id"; then
			echo "Disabled $path"
		else
			echo "::warning::Could not disable $path"
		fi
		;;
	*) echo "Leaving GitHub-managed workflow $path alone" ;;
	esac
done
exit 0
