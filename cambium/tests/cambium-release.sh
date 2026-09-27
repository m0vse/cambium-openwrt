#!/bin/sh
# Tests for the release tooling: cambium/scripts/release-branch.sh, which
# ports the Cambium commits onto an OpenWrt stable release and merges later
# point releases, and cambium/scripts/prune-feeds.sh. Scratch git
# repositories stand in for upstream OpenWrt and this fork.
#
# Usage: cambium/tests/cambium-release.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
script=$top/cambium/scripts/release-branch.sh
prune=$top/cambium/scripts/prune-feeds.sh
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0

export HOME=$W/home GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; sed 's/^/    /' "$W/log" 2>/dev/null; }
is() { # is DESCRIPTION GOT WANTED
	if [ "$2" = "$3" ]; then ok; else bad "$1 (got '$2', wanted '$3')"; fi
}
yes_() { # yes_ DESCRIPTION COMMAND...
	local d=$1; shift
	if "$@" >/dev/null 2>&1; then ok; else bad "$d"; fi
}
no_() {
	local d=$1; shift
	if "$@" >/dev/null 2>&1; then bad "$d"; else ok; fi
}

U=$W/upstream O=$W/origin.git F=$W/fork
# commit REPO FILE CONTENT MESSAGE
commit() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "$4"; }
# release TAG FILE CONTENT: an annotated upstream tag on its stable branch.
release() {
	local series=${1#v}
	series=${series%.*}; series=${series%%-*}
	case "$1" in *-rc*) series=${1#v}; series=${series%.*-rc*} ;; esac
	git -C "$U" checkout -q "openwrt-$series" 2>/dev/null || git -C "$U" checkout -q -b "openwrt-$series" "${4:-main}"
	commit "$U" "$2" "$3" "OpenWrt ${1#v}"
	git -C "$U" tag -a -m "${1#v}" "$1"
	git -C "$U" checkout -q main
}
run() { # run [SERIES]: in the fork; sets rc
	: > "$W/kv"
	(cd "$F" && UPSTREAM_URL=$U GITHUB_OUTPUT=$W/kv sh "$script" "$@") > "$W/log" 2>&1
	rc=$?
}
kv() { sed -n "s/^$1=//p" "$W/kv" | tail -n 1; }

# Upstream: main, a 25.12 series with final releases, then main moves on.
git init -q "$U"
commit "$U" base.txt "line 1
line 2" "base"
release v25.12.0 version 25.12.0
release v25.12.1 version 25.12.1
commit "$U" main.txt "main" "main work"
# The fork: upstream main plus two Cambium commits, the second editing an
# upstream file.
git init -q --bare "$O"
git -C "$U" push -q "$O" main
git clone -q "$O" "$F"
commit "$F" cambium.txt "cambium" "cambium: add support"
commit "$F" base.txt "line 1
line 2 cambium" "cambium: change base"
git -C "$F" push -q origin main
# Upstream branches 26.05 (a release candidate), then main moves on after the
# fork was last rebased.
release v26.05.0-rc1 version 26.05.0-rc1
commit "$U" later.txt "later" "main later"

run
is "no final release after 25.12: nothing to build" "$rc" 2
run 25.12
is "the 25.12 series is refused" "$rc" 3
run banana
is "an invalid series is refused" "$rc" 3

# Release candidates never count; a final release does.
run
is "a release candidate alone is not a release" "$rc" 2
release v26.05.0 version 26.05.0
release v27.05.0-rc1 version 27.05.0-rc1
run
is "the first final release is ported" "$rc" 0
is "  action" "$(kv action)" ported
is "  series (a newer candidate is ignored)" "$(kv series)" 26.05
is "  version" "$(kv version)" 26.05.0
is "  branch" "$(kv branch)" cambium-26.05
is "  upstream tag" "$(kv upstream_tag)" v26.05.0
is "  the branch is checked out" "$(git -C "$F" rev-parse --abbrev-ref HEAD)" cambium-26.05
is "  sha is the branch head" "$(kv sha)" "$(git -C "$F" rev-parse HEAD)"
yes_ "  the branch is based on the release tag" git -C "$F" merge-base --is-ancestor refs/upstream-tags/v26.05.0 HEAD
is "  both Cambium commits on top of the release" "$(git -C "$F" rev-list --count refs/upstream-tags/v26.05.0..HEAD)" 2
is "  the Cambium change to an upstream file" "$(sed -n 2p "$F/base.txt")" "line 2 cambium"
yes_ "  the release's own content" test "$(cat "$F/version")" = 26.05.0
no_ "  upstream main after the release is not included" test -e "$F/later.txt"
no_ "  nothing is pushed" git -C "$F" ls-remote --exit-code --heads origin cambium-26.05
git -C "$F" push -q origin cambium-26.05
first=$(git -C "$F" rev-parse HEAD)

run
is "an up-to-date branch is left alone" "$rc" 0
is "  action" "$(kv action)" none
is "  sha" "$(kv sha)" "$first"

release v26.05.1 other.txt "fix"
run
is "a point release is merged" "$rc" 0
is "  action" "$(kv action)" merged
is "  version" "$(kv version)" 26.05.1
yes_ "  no rewrite: the previous head is kept" git -C "$F" merge-base --is-ancestor "$first" HEAD
yes_ "  the point release is in" git -C "$F" merge-base --is-ancestor refs/upstream-tags/v26.05.1 HEAD
is "  the Cambium change survives" "$(sed -n 2p "$F/base.txt")" "line 2 cambium"
git -C "$F" push -q origin cambium-26.05
merged=$(git -C "$F" rev-parse HEAD)

release v26.05.2 base.txt "line 1
line 2 upstream"
run
is "a conflicting point release stops" "$rc" 1
is "  conflicting file" "$(kv conflict_files)" "base.txt "
is "  conflicting release" "$(kv conflict_commit)" v26.05.2
is "  the branch is unchanged" "$(git -C "$F" rev-parse HEAD)" "$merged"
is "  the working tree is clean" "$(git -C "$F" status --porcelain)" ""
is "  no version is reported" "$(kv version)" ""

# A new series whose release conflicts with a Cambium commit.
git -C "$U" checkout -q main
commit "$U" base.txt "line 1
line 2 rework" "main rework"
release v26.11.0 version 26.11.0
run
is "a conflicting port stops" "$rc" 1
is "  conflicting commit" "$(kv conflict_subject)" "cambium: change base"
is "  conflicting file" "$(kv conflict_files)" "base.txt "
no_ "  no branch is left behind" git -C "$F" rev-parse --verify -q refs/heads/cambium-26.11
run 27.05
is "a series with only candidates has nothing to build" "$rc" 2

# Feed pruning.
site=$W/site
feeds() { rm -rf "$site"; mkdir -p "$site"; for d; do mkdir -p "$site/$d/thor"; echo x > "$site/$d/thor/p"; done; }
left() { ls -1 "$site" | tr '\n' ' '; }
feeds 2026.09.25.0 2026.09.26.4 2026.09.27.0 2026.09.27.1 26.05.0-1 26.05.0-2 26.05.1-1 26.11.0-1
touch "$site/index.html"
SITE_BUDGET_KB=100000 sh "$prune" "$site" > "$W/log" 2>&1
is "pruning keeps two snapshots and each series' newest release" "$(left)" \
	"2026.09.27.0 2026.09.27.1 26.05.1-1 26.11.0-1 index.html "
feeds 2026.09.26.4 2026.09.27.0 26.05.0-9 26.05.0-10
SITE_BUDGET_KB=100000 KEEP_FEEDS=1 sh "$prune" "$site" > "$W/log" 2>&1
is "release numbers sort numerically; KEEP_FEEDS" "$(left)" "2026.09.27.0 26.05.0-10 "
feeds 2026.09.26.4 2026.09.27.0 26.05.0-1
dd if=/dev/zero of="$site/2026.09.26.4/thor/big" bs=1024 count=300 2>/dev/null
dd if=/dev/zero of="$site/26.05.0-1/thor/big" bs=1024 count=300 2>/dev/null
SITE_BUDGET_KB=500 sh "$prune" "$site" > "$W/log" 2>&1
is "over budget: the older snapshot goes" "$(left)" "2026.09.27.0 26.05.0-1 "
dd if=/dev/zero of="$site/2026.09.27.0/thor/big" bs=1024 count=300 2>/dev/null
SITE_BUDGET_KB=500 sh "$prune" "$site" > "$W/log" 2>&1; rc=$?
is "the newest snapshot and the release are never pruned" "$rc" 1
is "  both kept" "$(left)" "2026.09.27.0 26.05.0-1 "

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
