#!/bin/sh
# Keep upstream OpenWrt's CI workflows from running in this fork; only the
# cambium-* workflows are meant to run here. Requires GH_TOKEN with
# actions:write.
set -eu
gh workflow list --all --json path,state --jq \
	'.[] | select(.state == "active") | .path' |
while read -r path; do
	case "$path" in
	.github/workflows/cambium-*) ;;
	*) gh workflow disable "${path##*/}" && echo "Disabled $path" ;;
	esac
done
