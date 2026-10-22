#!/bin/bash
# Filesystem-only tests. Never invokes rw_main, sudo, the helper, or GUI/network operations.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/uninstall.sh"

fixture="$(/usr/bin/mktemp -d /private/tmp/routeweaver-uninstall-tests.XXXXXX)"
trap '/bin/rm -rf -- "$fixture"' EXIT
owner="$(/usr/bin/id -u)"
wrong_owner="$((owner + 1))"
passed=0
failed=0

expect_success() {
    local label="$1"
    shift
    if "$@" >"$fixture/assertion.log" 2>&1; then
        passed=$((passed + 1))
    else
        echo "FAIL: $label (expected success)" >&2
        /bin/cat "$fixture/assertion.log" >&2
        failed=$((failed + 1))
    fi
}

expect_failure() {
    local label="$1"
    shift
    if "$@" >"$fixture/assertion.log" 2>&1; then
        echo "FAIL: $label (expected refusal)" >&2
        failed=$((failed + 1))
    else
        passed=$((passed + 1))
    fi
}

/bin/mkdir "$fixture/profile" "$fixture/tree with spaces" "$fixture/command" "$fixture/other"
printf '{}' > "$fixture/profile/profile.json"
printf '# fixture' > "$fixture/profile/cn-ipv4.txt"
/usr/bin/touch "$fixture/profile/.DS_Store"
printf 'preserve' > "$fixture/other/preserved.txt"

expect_success 'ordinary profile tree' rw_check_tree "$fixture/profile" "$owner"
expect_success 'known profile files and Finder metadata' rw_check_profile "$fixture/profile"
expect_success 'empty directory with spaces' rw_check_tree "$fixture/tree with spaces" "$owner"
expect_success 'missing tree is already clean' rw_check_tree "$fixture/missing" "$owner"
expect_success 'missing profile is already clean' rw_check_profile "$fixture/missing"
expect_success 'valid path ancestors' rw_check_location "$fixture/profile/profile.json" "$fixture" "$owner"
expect_success 'missing descendant under safe base' rw_check_location "$fixture/missing/file" "$fixture" "$owner"
expect_failure 'empty path' rw_check_location '' "$fixture" "$owner"
expect_failure 'empty base' rw_check_location "$fixture/profile/profile.json" '' "$owner"
expect_failure 'path outside permitted base' rw_check_location "$fixture/other/preserved.txt" "$fixture/profile" "$owner"
expect_failure 'wrong ancestor owner' rw_check_location "$fixture/profile/profile.json" "$fixture" "$wrong_owner"
expect_failure 'wrong tree owner' rw_check_tree "$fixture/profile" "$wrong_owner"

printf 'preserve unknown' > "$fixture/profile/user-notes.txt"
expect_failure 'unknown profile file' rw_check_profile "$fixture/profile"
expect_success 'unknown file remains untouched' test -f "$fixture/profile/user-notes.txt"
/bin/rm "$fixture/profile/user-notes.txt"
/bin/mkdir "$fixture/profile/unexpected-directory"
expect_failure 'unknown profile directory' rw_check_profile "$fixture/profile"
/bin/rmdir "$fixture/profile/unexpected-directory"

/bin/ln -s "$fixture/other/preserved.txt" "$fixture/tree with spaces/link"
expect_failure 'nested symlink' rw_check_tree "$fixture/tree with spaces" "$owner"
expect_failure 'root symlink' rw_check_tree "$fixture/tree with spaces/link" "$owner"
/bin/rm "$fixture/tree with spaces/link"
/bin/ln -s "$fixture/does-not-exist" "$fixture/tree with spaces/dangling"
expect_failure 'dangling symlink still counts as existing' rw_check_tree "$fixture/tree with spaces" "$owner"
/bin/rm "$fixture/tree with spaces/dangling"
/bin/ln "$fixture/other/preserved.txt" "$fixture/tree with spaces/hardlink"
expect_failure 'hardlinked file' rw_check_tree "$fixture/tree with spaces" "$owner"
/bin/rm "$fixture/tree with spaces/hardlink"
/usr/bin/mkfifo "$fixture/tree with spaces/fifo"
expect_failure 'FIFO is not ordinary data' rw_check_tree "$fixture/tree with spaces" "$owner"
/bin/rm "$fixture/tree with spaces/fifo"

# Model an ancestor changed after the initial preflight. Only fixture paths are used.
/bin/mkdir "$fixture/parent"
expect_success 'ancestor before replacement' rw_check_location "$fixture/parent/file" "$fixture" "$owner"
/bin/rmdir "$fixture/parent"
/bin/ln -s "$fixture/other" "$fixture/parent"
expect_failure 'ancestor redirected after preflight' rw_check_location "$fixture/parent/preserved.txt" "$fixture" "$owner"
expect_failure 'symlink base' rw_check_location "$fixture/parent/preserved.txt" "$fixture/parent" "$owner"
/bin/rm "$fixture/parent"
expect_success 'outside fixture data survives all checks' test "$(/bin/cat "$fixture/other/preserved.txt")" = preserve

/bin/chmod 700 "$fixture/command"
/usr/bin/touch "$fixture/command/stdout" "$fixture/command/stderr"
/bin/chmod 600 "$fixture/command/stdout" "$fixture/command/stderr"
expect_success 'private command output directory' rw_check_command_output "$fixture/command"
/usr/bin/touch "$fixture/command/unexpected"
expect_failure 'unknown command output' rw_check_command_output "$fixture/command"
/bin/rm "$fixture/command/unexpected"
/bin/chmod 644 "$fixture/command/stdout"
expect_failure 'public command output permissions' rw_check_command_output "$fixture/command"
/bin/chmod 600 "$fixture/command/stdout"
/bin/chmod 755 "$fixture/command"
expect_failure 'public command directory permissions' rw_check_command_output "$fixture/command"
/bin/chmod 700 "$fixture/command"
/bin/rm "$fixture/command/stdout"
/bin/ln -s "$fixture/other/preserved.txt" "$fixture/command/stdout"
expect_failure 'command output symlink' rw_check_command_output "$fixture/command"
/bin/rm "$fixture/command/stdout" "$fixture/command/stderr"
expect_success 'empty private command directory' rw_check_command_output "$fixture/command"
/bin/rmdir "$fixture/command"
expect_success 'command directory removed by completed command is already clean' rw_check_command_output "$fixture/command"
expect_success 'duplicate absent command path is idempotent' rw_check_command_output "$fixture/command"
/bin/ln -s "$fixture/does-not-exist" "$fixture/command"
expect_failure 'absent command target behind dangling symlink is unsafe' rw_check_command_output "$fixture/command"
/bin/rm "$fixture/command"

echo "Uninstaller filesystem checks: $passed passed, $failed failed."
[[ "$failed" == 0 ]]
