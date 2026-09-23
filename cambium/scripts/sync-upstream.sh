#!/bin/sh
# Rebase the Cambium commit stack onto the latest upstream OpenWrt branch.
#
# The fork's branch is upstream plus a linear stack of Cambium commits. This
# replays that stack onto the new upstream head. On a conflict the rebase is
# aborted, the branch is left untouched and the conflicting commit is reported.
#
# Usage: cambium/scripts/sync-upstream.sh [UPSTREAM_URL] [UPSTREAM_BRANCH]
# Writes key=value results to $GITHUB_OUTPUT when set.

set -eu

url=${1:-https://github.com/openwrt/openwrt.git}
branch=${2:-main}
out=${GITHUB_OUTPUT:-/dev/null}

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$url"
git fetch --no-tags upstream "$branch"

old_head=$(git rev-parse HEAD)
new_base=$(git rev-parse "upstream/$branch")
old_base=$(git merge-base HEAD "upstream/$branch")
stack=$(git rev-list --count "$old_base..HEAD")

echo "old_head=$old_head" >> "$out"
echo "upstream=$new_base" >> "$out"
echo "Cambium stack: $stack commits on $(git log -1 --format='%h %s' "$old_base")"

if [ "$old_base" = "$new_base" ]; then
	echo "Already based on upstream $branch $(git log -1 --format=%h "$new_base")"
	echo "rebased=false" >> "$out"
	exit 0
fi

echo "Upstream advanced by $(git rev-list --count "$old_base..$new_base") commits"
if ! git rebase --onto "$new_base" "$old_base" 2>&1; then
	failed=$(git rev-parse --short REBASE_HEAD 2>/dev/null || echo unknown)
	subject=$(git log -1 --format=%s REBASE_HEAD 2>/dev/null || echo unknown)
	files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
	git rebase --abort
	echo "conflict_commit=$failed" >> "$out"
	echo "conflict_subject=$subject" >> "$out"
	echo "conflict_files=$files" >> "$out"
	echo "Rebase conflict in $failed ($subject): $files" >&2
	exit 1
fi

remaining=$(git rev-list --count "$new_base..HEAD")
if [ "$remaining" -ne "$stack" ]; then
	# Expected when upstream has merged one of the Cambium patches.
	echo "Cambium stack changed from $stack to $remaining commits; now already upstream:"
	git log --oneline --cherry-pick --right-only "HEAD...$old_head" || true
fi
echo "stack=$remaining" >> "$out"
echo "rebased=true" >> "$out"
echo "Rebased onto $(git log -1 --format='%h %s' "$new_base")"
