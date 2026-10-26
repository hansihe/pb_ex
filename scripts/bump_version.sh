#!/usr/bin/env bash
# Sets the version of all four libraries and cuts a release section in each
# changelog: what's under "## Unreleased" moves under "## vX.Y.Z (date)".
#
#   scripts/bump_version.sh 0.3.0
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NEW="${1:-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 2
fi

"$ROOT/scripts/check_versions.sh" >/dev/null

for package in "${PACKAGES[@]}"; do
  if grep -qF "## v$NEW (" "$ROOT/$package/CHANGELOG.md"; then
    echo "error: $package/CHANGELOG.md already has a section for v$NEW" >&2
    exit 1
  fi
done

HEADING="## v$NEW ($(date -u +%Y-%m-%d))"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Writes through cat so the files keep their permissions.
for package in "${PACKAGES[@]}"; do
  sed "s/^  @version \".*\"$/  @version \"$NEW\"/" "$ROOT/$package/mix.exs" >"$TMP"
  cat "$TMP" >"$ROOT/$package/mix.exs"

  awk -v heading="$HEADING" '{ print } $0 == "## Unreleased" { print ""; print heading }' \
    "$ROOT/$package/CHANGELOG.md" >"$TMP"
  cat "$TMP" >"$ROOT/$package/CHANGELOG.md"
done

cat <<NEXT
Set all four libraries to $NEW and added "$HEADING" to each changelog.
Next: review the changelogs, run scripts/publish.sh, then commit and push the
tag v$NEW.
NEXT
