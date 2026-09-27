#!/bin/sh
# Prune the package feeds in a gh-pages working tree before it is published.
#
# Feeds are YYYY.MM.DD.N/ (snapshots) and X.Y.Z-N/ (releases). Kept: the
# newest KEEP_FEEDS snapshot feeds and the newest KEEP_RELEASE_FEEDS release
# feeds of each series. GitHub Pages serves at most 1 GB, so while the site
# is larger than SITE_BUDGET_KB, the oldest remaining snapshot feed goes too,
# never the newest snapshot or any kept release. Images whose feed has gone
# keep working but can no longer install extra kernel modules.
#
# Usage: cambium/scripts/prune-feeds.sh SITE_DIR
# Environment: KEEP_FEEDS (2), KEEP_RELEASE_FEEDS (1), SITE_BUDGET_KB (900 MiB)

set -eu

site=$(cd "${1:?usage: $0 site-dir}" && pwd)
keep_feeds=${KEEP_FEEDS:-2}
keep_release=${KEEP_RELEASE_FEEDS:-1}
budget=${SITE_BUDGET_KB:-921600}

# All but the last N lines (BSD head has no negative counts).
all_but_last() { awk -v n="$1" '{ l[NR] = $0 } END { for (i = 1; i <= NR - n; i++) print l[i] }'; }
remove() {
	echo "prune-feeds: removing the $1 feed"
	rm -rf "${site:?}/$1"
}
snapshots() { # oldest first
	ls -1 "$site" | grep -E '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$' |
		sort -t. -k1,1n -k2,2n -k3,3n -k4,4n || true
}
releases() { # oldest first
	ls -1 "$site" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' | sort -V || true
}

snapshots | all_but_last "$keep_feeds" | while read -r old; do remove "$old"; done
for series in $(releases | sed 's/\.[0-9]*-[0-9]*$//' | sort -u); do
	releases | grep -F "$series." | grep -E "^$(echo "$series" | sed 's/\./\\./g')\.[0-9]+-[0-9]+$" |
		all_but_last "$keep_release" | while read -r old; do remove "$old"; done
done
while [ "$(du -sk "$site" | cut -f1)" -gt "$budget" ]; do
	old=$(snapshots | all_but_last 1 | head -n 1)
	if [ -z "$old" ]; then
		echo "prune-feeds: the site is $(du -sk "$site" | cut -f1) KiB, over the $budget KiB budget, with nothing left to prune" >&2
		exit 1
	fi
	remove "$old"
done
