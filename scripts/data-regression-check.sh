#!/usr/bin/env bash
# Refuse a data refresh that makes SCORING worse than the data it replaces.
#
# Josh 2026-08-08: the monthly refresh may bump the version and publish on its
# own, "as long as the data is 100% usable and won't introduce a bug". This is
# what makes that condition true rather than assumed.
#
# v2.11.2 auto-published a real regression: the refreshed curves widened Heroic
# raid role spread from 8.7 to 16.2 against a threshold of 10, and every check
# reported success. tests/run.lua DOES gate on validate.lua - but by COUNT
# (`count <= 2 known`), so a NEW problem hides whenever an old one is fixed.
# That is precisely what happened: the two documented known items were gone, a
# different one took their place, and 1 <= 2 passed.
#
# So this compares BEFORE against AFTER instead of against a threshold. It only
# fails when the refreshed data ADDS a problem the previous data did not have,
# which means it cannot be tripped by pre-existing known issues and stays quiet
# on design questions nobody has settled. A refresh that fixes problems, or
# leaves them exactly as they were, still ships.
#
# Run from the repo root, with the refreshed Data/ present but UNCOMMITTED.
set -uo pipefail

LUA="${LUA:-lua5.4}"
command -v "$LUA" >/dev/null 2>&1 || LUA=lua

problems() { # -> one problem per line, sorted
	"$LUA" tests/validate.lua 2>/dev/null | sed -n 's/^  - //p' | sort
}

if git diff --quiet -- Data/ && git diff --cached --quiet -- Data/; then
	echo "No Data/ changes to check."
	exit 0
fi

after="$(problems)"

# Swap in the previous data. --keep-index is deliberately NOT used: we want the
# committed state, whatever is staged.
if ! git stash push -q -- Data/; then
	echo "Could not stash Data/ to establish a baseline; refusing to guess." >&2
	exit 1
fi
before="$(problems)"
git stash pop -q || {
	echo "FAILED TO RESTORE Data/ - the refreshed data is in the stash." >&2
	exit 1
}

introduced="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
fixed="$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"

[ -n "$fixed" ] && { echo "This refresh FIXES:"; printf '  + %s\n' "$fixed"; }

if [ -n "$introduced" ]; then
	echo ""
	echo "REFUSING THIS DATA REFRESH - it introduces scoring problems:"
	printf '  - %s\n' "$introduced"
	echo ""
	echo "The data is not wrong to crawl, but it must not auto-publish: these"
	echo "are new since the data it replaces. Land it as a PR and look at the"
	echo "curves, or fix the underlying calibration first."
	exit 1
fi

echo "No new scoring problems: this data is safe to publish."
