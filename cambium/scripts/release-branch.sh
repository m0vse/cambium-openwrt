#!/bin/sh
# Keep the Cambium release branch of an OpenWrt stable series up to date.
#
# Release builds are based on upstream's final stable releases (vX.Y.Z tags,
# never release candidates) of the series after 25.12. For series X.Y the
# branch cambium-X.Y is:
#   - created the first time by replaying the Cambium commits of main onto
#     the series' newest release (the port);
#   - afterwards moved forward by merging each newer vX.Y.Z. It is never
#     rebased or force-pushed, so every release tag stays in its history.
# Cambium fixes reach it by cherry-picking from main (see cambium/README.md).
#
# Usage: cambium/scripts/release-branch.sh [SERIES]
#   SERIES  X.Y (default: the newest series with a final release)
# Environment:
#   CAMBIUM_MAIN          the Cambium branch to port from (default origin/main)
#   CAMBIUM_AFTER_SERIES  releases start after this series (default 25.12)
#   UPSTREAM_URL          upstream OpenWrt (default GitHub)
#
# Leaves the branch checked out and does not push. Writes key=value results
# to $GITHUB_OUTPUT when set: series, branch, upstream_tag, version, sha and
# action (ported, merged or none); on a conflict conflict_commit,
# conflict_subject and conflict_files instead.
# Exit status: 0 done, 1 conflict (the branch is unchanged), 2 no release yet,
# 3 usage error.

set -eu

url=${UPSTREAM_URL:-https://github.com/openwrt/openwrt.git}
main=${CAMBIUM_MAIN:-origin/main}
after=${CAMBIUM_AFTER_SERIES:-25.12}
out=${GITHUB_OUTPUT:-/dev/null}

say() { echo "release-branch: $*"; }
# newer A B: A is a later version than B.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }

series=${1:-}
case "$series" in
''|[0-9]*.[0-9]*) ;;
*) echo "Invalid series: $series (expected X.Y)" >&2; exit 3 ;;
esac

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$url"
# Upstream's tags go under their own namespace, apart from this fork's.
git fetch --quiet --no-tags upstream main '+refs/tags/v*:refs/upstream-tags/v*'

finals=$(git for-each-ref --format='%(refname:lstrip=2)' refs/upstream-tags |
	sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | sort -V)
if [ -z "$series" ]; then
	for v in $finals; do
		newer "${v%.*}" "$after" && series=${v%.*}
	done
	if [ -z "$series" ]; then
		say "no final OpenWrt release newer than the $after series yet"
		exit 2
	fi
elif ! newer "$series" "$after"; then
	echo "Series $series is not after $after: no release builds for it" >&2
	exit 3
fi
version=$(printf '%s\n' $finals | grep -F "$series." | grep -x "$(echo "$series" | sed 's/\./\\./g')\.[0-9]*" | tail -n 1)
if [ -z "$version" ]; then
	say "OpenWrt $series has no final release yet"
	exit 2
fi
branch=cambium-$series
tag=v$version
ref=refs/upstream-tags/$tag

conflict() { # conflict COMMIT SUBJECT
	files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
	{
		echo "conflict_commit=$1"
		echo "conflict_subject=$2"
		echo "conflict_files=$files"
	} >> "$out"
	echo "Conflict in $1 ($2): $files" >&2
}

if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
	git fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch"
	git checkout --quiet -B "$branch" "origin/$branch"
	if git merge-base --is-ancestor "$ref" HEAD; then
		action=none
		say "$branch already contains OpenWrt $tag"
	else
		say "merging OpenWrt $tag into $branch"
		if ! git merge --quiet --no-ff --no-edit -m "Merge OpenWrt $tag into $branch" "$ref"; then
			conflict "$tag" "merge of OpenWrt $tag into $branch"
			git merge --abort
			exit 1
		fi
		action=merged
	fi
else
	base=$(git merge-base "$main" upstream/main)
	stack=$(git rev-list --count "$base..$main")
	say "porting $stack Cambium commits from $main onto OpenWrt $tag as $branch"
	git checkout --quiet -B "$branch" "$main"
	if ! git rebase --quiet --onto "$ref" "$base" >/dev/null 2>&1; then
		conflict "$(git rev-parse --short REBASE_HEAD 2>/dev/null || echo unknown)" \
			"$(git log -1 --format=%s REBASE_HEAD 2>/dev/null || echo unknown)"
		git rebase --abort
		git checkout --quiet --detach "$main"
		git branch -D "$branch" >/dev/null
		exit 1
	fi
	ported=$(git rev-list --count "$ref..HEAD")
	[ "$ported" -eq "$stack" ] ||
		say "$((stack - ported)) of the Cambium commits are already in OpenWrt $tag"
	action=ported
fi

{
	echo "series=$series"
	echo "branch=$branch"
	echo "upstream_tag=$tag"
	echo "version=$version"
	echo "action=$action"
	echo "sha=$(git rev-parse HEAD)"
} >> "$out"
say "$branch at $(git log -1 --format='%h %s') ($action)"
