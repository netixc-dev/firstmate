#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.iqYkjk/owner-dep.sh
. "/Users/control/.treehouse/firstmate-706da9/5/firstmate/.fm-lint-parity.iqYkjk/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
