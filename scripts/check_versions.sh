#!/usr/bin/env bash
# Checks that the four libraries are at one version and that each changelog has
# an "## Unreleased" section for scripts/bump_version.sh to cut, then prints the
# version.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="$(version_of pb)"
if [[ -z "$VERSION" ]]; then
  echo "error: no @version in pb/mix.exs" >&2
  exit 1
fi

status=0
for package in "${PACKAGES[@]}"; do
  if [[ "$(version_of "$package")" != "$VERSION" ]]; then
    echo "error: $package/mix.exs is at version $(version_of "$package"), pb/mix.exs is at $VERSION" >&2
    status=1
  fi
  if ! grep -qx '## Unreleased' "$ROOT/$package/CHANGELOG.md" 2>/dev/null; then
    echo "error: $package/CHANGELOG.md has no \"## Unreleased\" section" >&2
    status=1
  fi
done

if [[ "$status" == 0 ]]; then
  echo "$VERSION"
fi
exit "$status"
