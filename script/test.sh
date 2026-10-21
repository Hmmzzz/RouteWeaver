#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Keep signed XCTest bundles outside File Provider-managed Documents folders.
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/routeweaver-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$TEST_DIR/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$TEST_DIR/modules"
swift test --disable-sandbox --scratch-path "$TEST_DIR/build" --cache-path "$TEST_DIR/cache"
