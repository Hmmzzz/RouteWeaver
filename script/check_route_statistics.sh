#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/routeweaver-statistics-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Local socket pairs exercise the actual production parser. No network,
# route mutation, helper, or installed service is used by these checks.
/usr/bin/clang -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
  -I "$ROOT_DIR/Sources/CRouteStatistics/include" \
  "$ROOT_DIR/Tests/CRouteStatisticsChecks/protocol_checks.c" \
  -o "$CHECK_DIR/protocol-checks"
"$CHECK_DIR/protocol-checks"
