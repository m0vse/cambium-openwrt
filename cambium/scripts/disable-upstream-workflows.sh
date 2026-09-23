#!/bin/sh
# Keep upstream OpenWrt's CI workflows from running in this fork; only the
# cambium-* workflows are meant to run here. Requires GH_TOKEN with
# actions:write. Problems are reported as warnings: this housekeeping must
# never stop a snapshot build.
set -u
list=$(gh workflow list --all --json id,path,state \
	--jq '.[] | select(.state == "active") | "\(.id) \(.path)"') || {
	echo "::warning::Could not list workflows"
	exit 0
}
printf '%s\n' "$list" | while read -r id path; do
	case "$path" in
	.github/workflows/cambium-*|'') ;;
	.github/workflows/*)
		if gh workflow disable "$id"; then
			echo "Disabled $path"
		else
			echo "::warning::Could not disable $path"
		fi
		;;
	*) echo "Leaving GitHub-managed workflow $path alone" ;;
	esac
done
exit 0
