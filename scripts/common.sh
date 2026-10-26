# Sourced by the release scripts.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# In dependency order, which is the order they're published in.
PACKAGES=(cel_ex pb pb_cel pb_validate)

version_of() {
  sed -n 's/^  @version "\(.*\)"$/\1/p' "$ROOT/$1/mix.exs"
}
