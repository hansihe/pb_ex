#!/usr/bin/env bash
# Publishes cel_ex, pb, pb_cel and pb_validate to Hex, in dependency order.
#
#   scripts/publish.sh          build each package without publishing
#   scripts/publish.sh --yes    publish, without prompting
#
# The four libraries share one version. Packages already on Hex at that version
# are skipped, so a run that failed partway can be retried. Set RELEASE_TAG
# (CI passes the pushed tag) to check that it matches the version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES=(cel_ex pb pb_cel pb_validate)

PUBLISH=0
case "${1:-}" in
  "") ;;
  --yes) PUBLISH=1 ;;
  *) echo "usage: $0 [--yes]" >&2; exit 2 ;;
esac

# Resolve siblings from Hex (see `sibling/1` in pb_cel/mix.exs), and keep the
# Hex-resolved deps and builds out of the local checkouts' deps/ and _build/.
export PB_EX_LOCAL=0
WORK_DIR="$ROOT/tmp/publish"

version_of() {
  sed -n 's/^  @version "\(.*\)"$/\1/p' "$ROOT/$1/mix.exs"
}

VERSION="$(version_of pb)"
for package in "${PACKAGES[@]}"; do
  if [[ "$(version_of "$package")" != "$VERSION" ]]; then
    echo "error: $package is at version $(version_of "$package"), pb is at $VERSION" >&2
    exit 1
  fi
done
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$VERSION" ]]; then
  echo "error: tag $RELEASE_TAG does not match version $VERSION" >&2
  exit 1
fi

published() {
  local status
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "https://hex.pm/api/packages/$1/releases/$VERSION")"
  [[ "$status" == 200 ]]
}

# Resolving from Hex rewrites mix.lock; put the local one back afterwards.
restore_locks() {
  for package in "${PACKAGES[@]}"; do
    if [[ -f "$WORK_DIR/$package/mix.lock" ]]; then
      cp "$WORK_DIR/$package/mix.lock" "$ROOT/$package/mix.lock"
    fi
  done
}
trap restore_locks EXIT

for package in "${PACKAGES[@]}"; do
  if published "$package"; then
    echo "==> $package $VERSION is already on Hex, skipping"
    continue
  fi

  echo "==> $package $VERSION"
  mkdir -p "$WORK_DIR/$package"
  cp "$ROOT/$package/mix.lock" "$WORK_DIR/$package/mix.lock"
  export MIX_DEPS_PATH="$WORK_DIR/$package/deps"
  export MIX_BUILD_ROOT="$WORK_DIR/$package/_build"

  if [[ "$PUBLISH" == 0 ]]; then
    # Packages after the first depend on releases that don't exist yet, so a
    # dry run can only build the tarball, not fetch deps or build docs.
    (cd "$ROOT/$package" && mix hex.build --output "$WORK_DIR/$package.tar")
    continue
  fi

  # A sibling published a moment ago can take a little while to show up in the
  # registry.
  for attempt in 1 2 3 4 5 6; do
    if (cd "$ROOT/$package" && mix deps.get); then
      break
    elif [[ "$attempt" == 6 ]]; then
      exit 1
    fi
    sleep 20
  done

  (cd "$ROOT/$package" && mix hex.publish --yes)
done
