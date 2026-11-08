# Changelogs

One file per family, plus `common.md` for changes that apply to every family
(the installer, the project site, the build and release checks). Newest
first. Each heading is the snapshot a change first shipped in; `Unreleased`
is on `main` and ships in the next snapshot, whose release notes include it.

When a snapshot is published, move the shipped entries from `Unreleased` to
that snapshot's build ID in the next commit that touches the changelog.
Leave later changes under `Unreleased`; if several snapshots have shipped,
use the first published snapshot containing each entry and that family's
release assets, rather than moving everything to the newest snapshot.
A shipped change can still have hardware validation pending: release history
and hardware qualification describe different things.
