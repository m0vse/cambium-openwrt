#!/bin/sh
# Publish one snapshot: a GitHub release with the images and ImageBuilders,
# and the matching apk feeds on the gh-pages branch (served by GitHub Pages).
#
# Usage: cambium/scripts/publish.sh ARTIFACT_DIR
# ARTIFACT_DIR holds cambium-<family>/ directories written by build.sh.
# Environment: GH_TOKEN BUILD_ID SHA UPSTREAM FAMILIES FEED_URL GITHUB_REPOSITORY
#   KEEP_RELEASES (default 14)  KEEP_FEEDS (default 2)

set -eu

in=$(cd "${1:?usage: $0 artifact-dir}" && pwd)
repo=${GITHUB_REPOSITORY:?}

# When republishing an earlier run, recover the snapshot identity from the
# build output itself.
release_value() {
	sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$in"/cambium-*/images/cambium-openwrt-release | sort -u
}
[ -n "${FAMILIES:-}" ] || FAMILIES=$(ls -1 "$in" | sed -n 's/^cambium-//p' | tr '\n' ' ')
[ -n "${BUILD_ID:-}" ] || BUILD_ID=$(cat "$in"/cambium-*/BUILD_ID | sort -u)
[ -n "${SHA:-}" ] || SHA=$(release_value CAMBIUM_SOURCE_COMMIT)
[ -n "${UPSTREAM:-}" ] || UPSTREAM=$(release_value OPENWRT_UPSTREAM_COMMIT)
for value in "$BUILD_ID" "$SHA" "$UPSTREAM"; do
	case "$value" in
	''|*[[:space:]]*) echo "Build output does not identify exactly one snapshot" >&2; exit 1 ;;
	esac
done
FEED_URL=${FEED_URL:?}
tag=snapshot-$BUILD_ID
keep_releases=${KEEP_RELEASES:-14}
keep_feeds=${KEEP_FEEDS:-2}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

built= failed=
for family in $FAMILIES; do
	dir=$in/cambium-$family
	if [ -f "$dir/BUILD_ID" ] && [ "$(cat "$dir/BUILD_ID")" = "$BUILD_ID" ]; then
		built="$built $family"
	else
		failed="$failed $family"
	fi
done
[ -n "$built" ] || { echo "No family built successfully; nothing to publish." >&2; exit 1; }

# Release assets must have unique names across families.
mkdir -p "$stage/assets"
for family in $built; do
	for file in "$in/cambium-$family/images/"*; do
		base=${file##*/}
		case "$base" in
		*cambiumnetworks_*|*imagebuilder*) cp "$file" "$stage/assets/$base" ;;
		SHA256SUMS) ;;
		*) cp "$file" "$stage/assets/$family-$base" ;;
		esac
	done
done
# One release manifest for all families, and the SKU-based configuration
# selector for installs.
python3 - "$stage/assets/cambium-manifest.json" "$BUILD_ID" "$SHA" "$UPSTREAM" \
	"$in"/cambium-*/images/cambium-manifest.json <<'PY'
import json, sys
out, build_id, sha, upstream, *parts = sys.argv[1:]
families = [json.load(open(p)) for p in parts]
json.dump({"schema": 1, "build_id": build_id, "source_commit": sha,
           "upstream_commit": upstream, "families": families},
          open(out, "w"), indent=2)
PY
python3 "$(dirname "$0")/gen-select-config.py" "$(dirname "$0")/../families.json" \
	> "$stage/assets/select-config.sh"
cp "$(dirname "$0")/../site/cambium-report.sh" "$stage/assets/cambium-report.sh"
cp "$(dirname "$0")/../site/cambium-install.sh" "$stage/assets/cambium-install.sh"
cp "$(dirname "$0")/../site/cambium-serve.py" "$stage/assets/cambium-serve.py"
(cd "$stage/assets" && sha256sum -- * > SHA256SUMS)

{
	echo "Automated OpenWrt snapshot for Cambium access points, build \`$BUILD_ID\`."
	echo
	echo "- Source: [\`$(printf %.12s "$SHA")\`](https://github.com/$repo/commit/$SHA)"
	echo "- Upstream OpenWrt: [\`$(printf %.12s "$UPSTREAM")\`](https://github.com/openwrt/openwrt/commit/$UPSTREAM)"
	echo "- Built:$(echo "$built" | sed 's/ /, /g; s/^,//')"
	[ -z "$failed" ] || echo "- **Failed (not included):**$(echo "$failed" | sed 's/ /, /g; s/^,//')"
	echo "- Package feeds: $FEED_URL/$BUILD_ID/"
	echo
	cat "$(dirname "$0")/../release-notes.md"
} > "$stage/notes.md"

echo "Creating $tag at $SHA"
gh api "repos/$repo/git/refs" -f ref="refs/tags/$tag" -f sha="$SHA" >/dev/null
gh release create "$tag" --repo "$repo" --prerelease \
	--title "Cambium OpenWrt snapshot $BUILD_ID" --notes-file "$stage/notes.md" \
	"$stage/assets/"*

echo "Updating package feeds"
site=$stage/site
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
	git clone --quiet --depth 1 --branch gh-pages \
		"https://x-access-token:$GH_TOKEN@github.com/$repo.git" "$site"
	rm -rf "$site/.git"
else
	mkdir -p "$site"
fi
for family in $built; do
	mkdir -p "$site/$BUILD_ID/$family"
	cp -R "$in/cambium-$family/feed/." "$site/$BUILD_ID/$family/"
done
# Feeds only serve the newest snapshots; older images keep working but can
# no longer install extra kernel modules.
ls -1 "$site" | grep -E '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n |
	head -n "-$keep_feeds" | while read -r old; do rm -rf "${site:?}/$old"; done
"$(dirname "$0")/update-site.sh" "$site"
(
	cd "$site"
	git init --quiet --initial-branch gh-pages
	git add -A
	git commit --quiet -m "Site and package feeds for snapshot $BUILD_ID"
	git push --quiet --force "https://x-access-token:$GH_TOKEN@github.com/$repo.git" gh-pages
)

echo "Pruning old snapshot releases"
gh release list --repo "$repo" --limit 200 --json tagName --jq '.[].tagName' |
	grep '^snapshot-' | sort -t. -k1,1 -k2,2n -k3,3n -k4,4n -r |
	tail -n "+$((keep_releases + 1))" |
	while read -r old; do gh release delete "$old" --repo "$repo" --yes --cleanup-tag; done

echo "Published $tag"
