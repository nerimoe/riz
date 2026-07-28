#!/bin/sh
set -eu

cargo_version=${1:?workspace version is required}
latest_version=${2:-0.0.0}
commit=${3:?commit hash is required}
latest_version=${latest_version#v}

is_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

is_version "$cargo_version" || {
  echo "invalid workspace version: $cargo_version" >&2
  exit 1
}
is_version "$latest_version" || {
  echo "invalid latest release version: $latest_version" >&2
  exit 1
}

if awk -v candidate="$cargo_version" -v latest="$latest_version" 'BEGIN {
  split(candidate, c, "."); split(latest, l, ".");
  for (i = 1; i <= 3; i++) {
    if ((c[i] + 0) > (l[i] + 0)) exit 0;
    if ((c[i] + 0) < (l[i] + 0)) exit 1;
  }
  exit 1;
}'; then
  version=$cargo_version
  prerelease=false
else
  short_commit=$(printf '%.8s' "$commit")
  version="$cargo_version-$short_commit"
  prerelease=true
fi

printf 'version=%s\ntag=v%s\nprerelease=%s\n' "$version" "$version" "$prerelease"
