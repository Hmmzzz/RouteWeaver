#!/usr/bin/env bash
# Read-only Darwin routing-socket decoder check. Never opens a write socket.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/routeweaver-check.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT
cat > "$SCRATCH_DIR/check.c" <<'SOURCE'
#include "CRouteSocket.h"
#include <stdio.h>
int main(void) {
    RWRoute *routes = NULL; size_t count = 0;
    int result = rw_snapshot(&routes, &count);
    if (result) { fprintf(stderr, "snapshot failed: errno=%d\n", result); return 1; }
    size_t defaults = 0, halves = 0;
    for (size_t i = 0; i < count; i++) {
        if (routes[i].mask == 0) defaults++;
        if (routes[i].mask == 0x80000000) halves++;
    }
    printf("Read-only IPv4 snapshot: %zu entries, %zu default routes, %zu /1 routes\n", count, defaults, halves);
    rw_free_routes(routes);
    return 0;
}
SOURCE
/usr/bin/cc -Wall -Wextra -Wpedantic -I "$ROOT_DIR/Sources/CRouteSocket/include" \
    "$SCRATCH_DIR/check.c" "$ROOT_DIR/Sources/CRouteSocket/RouteSocket.c" -o "$SCRATCH_DIR/check"
"$SCRATCH_DIR/check"
