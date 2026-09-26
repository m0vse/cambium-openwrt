#!/bin/sh
# Refresh the project site in a gh-pages working tree: copy the static pages
# from cambium/site/ and describe the snapshot feeds present in builds.json.
#
# Usage: cambium/scripts/update-site.sh SITE_DIR
# SITE_DIR holds the gh-pages content, including one YYYY.MM.DD.N/<family>/
# feed directory per published snapshot.

set -eu

site=$(cd "${1:?usage: $0 site-dir}" && pwd)
src=$(cd "$(dirname "$0")/../site" && pwd)

cp -R "$src/." "$site/"
touch "$site/.nojekyll"
python3 "$(dirname "$0")/gen-select-config.py" "$src/../families.json" > "$site/select-config.sh"
cp "$src/../families.json" "$site/families.json"
python3 "$(dirname "$0")/changelog.py" html "$src/../changelog" "$src/index.html" > "$site/changelog.html"

# Newest snapshot first.
builds=$(ls -1 "$site" | grep -E '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$' |
	sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr || true)
{
	printf '{\n  "updated": "%s",\n  "builds": [' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	sep=
	for build in $builds; do
		families=$(ls -1 "$site/$build" | awk '{printf "%s\"%s\"", (NR>1?", ":""), $0}')
		printf '%s\n    {"build_id": "%s", "families": [%s]}' "$sep" "$build" "$families"
		sep=,
	done
	printf '\n  ]\n}\n'
} > "$site/builds.json"
