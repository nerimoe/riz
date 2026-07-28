#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PLAN="$ROOT/scripts/release-plan.sh"

assert_plan() {
  cargo_version=$1
  latest_version=$2
  commit=$3
  expected=$4
  actual=$($PLAN "$cargo_version" "$latest_version" "$commit")
  [ "$actual" = "$expected" ] || {
    echo "unexpected release plan for $cargo_version after $latest_version" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_plan 0.1.0 0.0.0 abcdef123456 'version=0.1.0
tag=v0.1.0
prerelease=false'
assert_plan 0.1.0 v0.1.0 abcdef123456 'version=0.1.0-abcdef12
tag=v0.1.0-abcdef12
prerelease=true'
assert_plan 0.1.0 v0.2.0 123456789abc 'version=0.1.0-12345678
tag=v0.1.0-12345678
prerelease=true'
assert_plan 1.0.0 v0.99.99 deadbeefcafe 'version=1.0.0
tag=v1.0.0
prerelease=false'

if "$PLAN" invalid 0.1.0 abcdef12 >/dev/null 2>&1; then
  echo "invalid versions must fail" >&2
  exit 1
fi

echo "release plan tests passed"
