#!/bin/bash
# Standalone so cleanup can finish after the GUI and this bundle are removed.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

rw_fail() { echo "卸载未完成：$*" >&2; return 1; }
rw_exists() { [[ -e "$1" || -L "$1" ]]; }

rw_check_location() {
    local path="$1" base="$2" owner="$3" parent canonical
    [[ "$path" == "$base/"* && -d "$base" && ! -L "$base" ]] || {
        rw_fail "文件不在已确认的用户目录内：$path"; return 1;
    }
    canonical="$(cd -P "$base" && pwd)" || return 1
    [[ "$canonical" == "$base" ]] || { rw_fail "用户目录路径已变化：$base"; return 1; }
    parent="$(/usr/bin/dirname "$path")"
    while true; do
        if rw_exists "$parent"; then
            [[ -d "$parent" && ! -L "$parent" && "$(/usr/bin/stat -f %u "$parent")" == "$owner" ]] || {
                rw_fail "用户文件父目录不安全：$parent"; return 1;
            }
        fi
        [[ "$parent" != "$base" ]] || break
        parent="$(/usr/bin/dirname "$parent")"
    done
}

rw_check_tree() {
    local path="$1" owner="$2" entry uid
    local -a children
    rw_exists "$path" || return 0
    [[ ! -L "$path" && ( -f "$path" || -d "$path" ) ]] || {
        rw_fail "发现非普通文件或符号链接：$path"; return 1;
    }
    uid=$(/usr/bin/stat -f %u "$path") || return 1
    [[ "$uid" == "$owner" ]] || { rw_fail "文件所有者不匹配：$path"; return 1; }
    if [[ -f "$path" ]]; then
        [[ "$(/usr/bin/stat -f %l "$path")" == 1 ]] || {
            rw_fail "拒绝删除存在硬链接的文件：$path"; return 1;
        }
    else
        [[ -r "$path" && -x "$path" ]] || { rw_fail "无法完整检查目录：$path"; return 1; }
        shopt -s nullglob dotglob
        children=("$path"/*)
        shopt -u nullglob dotglob
        for entry in ${children[@]+"${children[@]}"}; do rw_check_tree "$entry" "$owner" || return 1; done
    fi
}

rw_check_profile() {
    local path="$1" entry
    local -a children
    rw_exists "$path" || return 0
    [[ -d "$path" && ! -L "$path" ]] || { rw_fail "配置目录类型异常：$path"; return 1; }
    [[ -r "$path" && -x "$path" ]] || return 1
    shopt -s nullglob dotglob
    children=("$path"/*)
    shopt -u nullglob dotglob
    for entry in ${children[@]+"${children[@]}"}; do
        case "${entry##*/}" in
            profile.json|cn-ipv4.txt|.DS_Store) [[ -f "$entry" && ! -L "$entry" ]] || return 1 ;;
            .profile.lock)
                [[ -f "$entry" && ! -L "$entry" && "$(/usr/bin/stat -f %Lp "$entry")" == 600 && "$(/usr/bin/stat -f %l "$entry")" == 1 ]] || {
                    rw_fail "配置锁类型或权限异常：$entry"; return 1;
                } ;;
            *) rw_fail "配置目录含未知文件，请先移出后重试：$entry"; return 1 ;;
        esac
    done
}

rw_check_command_output() {
    local path="$1" entry
    local -a children
    rw_exists "$path" || return 0
    [[ -d "$path" && ! -L "$path" ]] || return 1
    [[ "$(/usr/bin/stat -f %Lp "$path")" == 700 ]] || { rw_fail "命令临时目录权限异常：$path"; return 1; }
    shopt -s nullglob dotglob
    children=("$path"/*)
    shopt -u nullglob dotglob
    for entry in ${children[@]+"${children[@]}"}; do
        case "${entry##*/}" in
            stdout|stderr)
                [[ -f "$entry" && ! -L "$entry" && "$(/usr/bin/stat -f %Lp "$entry")" == 600 ]] || {
                    rw_fail "命令输出文件类型或权限异常：$entry"; return 1;
                } ;;
            *) rw_fail "临时目录含未知文件，请先处理后重试：$entry"; return 1 ;;
        esac
    done
}

rw_check_other_instances() {
    local executable="$1" pid command pids result
    pids=$(/usr/bin/pgrep -x RouteWeaver) || { result=$?; [[ "$result" == 1 ]] || { rw_fail "无法检查应用进程。"; return 1; }; }
    for pid in $pids; do
        command=$(/bin/ps -p "$pid" -o comm= 2>/dev/null) || {
            if /bin/kill -0 "$pid" 2>/dev/null; then rw_fail "无法确认应用进程路径。"; return 1; fi
            continue
        }
        [[ -z "$command" || "$command" == "$executable" ]] || {
            rw_fail "另一个位置的 RouteWeaver 正在运行，请先退出：$command"; return 1;
        }
    done
}

rw_check_gui_stopped() {
    local executable="$1" pid command pids result
    pids=$(/usr/bin/pgrep -x RouteWeaver) || { result=$?; [[ "$result" == 1 ]] || { rw_fail "无法检查应用进程。"; return 1; }; }
    for pid in $pids; do
        command=$(/bin/ps -p "$pid" -o comm= 2>/dev/null) || {
            if /bin/kill -0 "$pid" 2>/dev/null; then rw_fail "无法确认应用进程路径。"; return 1; fi
            continue
        }
        [[ "$command" != "$executable" ]] || {
            rw_fail "App 在卸载期间重新启动，无法确认清理完成。"; return 1;
        }
    done
    rw_check_other_instances "$executable"
}

rw_verify_system_files() {
    /usr/bin/sudo /bin/bash -c '
        for path in "$@"; do
            if [[ -e "$path" || -L "$path" ]]; then
                echo "卸载未完成：系统文件仍存在：$path" >&2; exit 1
            fi
        done
    ' routeweaver-uninstall-check "$@"
}

rw_stop_gui() {
    local executable="$1" pid command remaining attempt pids result
    pids=$(/usr/bin/pgrep -x RouteWeaver) || { result=$?; [[ "$result" == 1 ]] || { rw_fail "无法检查应用进程。"; return 1; }; }
    for pid in $pids; do
        command=$(/bin/ps -p "$pid" -o comm= 2>/dev/null) || {
            if /bin/kill -0 "$pid" 2>/dev/null; then rw_fail "无法确认应用进程路径。"; return 1; fi
            continue
        }
        [[ "$command" == "$executable" ]] || continue
        # The daemon observes owner exit. The caller must subsequently run the
        # standalone privileged cleanup and verify it before removing any data.
        /bin/kill -TERM "$pid" 2>/dev/null || true
    done
    for ((attempt=0; attempt<50; attempt++)); do
        remaining=0
        pids=$(/usr/bin/pgrep -x RouteWeaver) || { result=$?; [[ "$result" == 1 ]] || { rw_fail "无法检查应用进程。"; return 1; }; }
        for pid in $pids; do
            command=$(/bin/ps -p "$pid" -o comm= 2>/dev/null) || {
                if /bin/kill -0 "$pid" 2>/dev/null; then rw_fail "无法确认应用进程路径。"; return 1; fi
                continue
            }
            [[ "$command" != "$executable" ]] || remaining=1
        done
        [[ "$remaining" == 1 ]] || return 0
        /bin/sleep 0.1
    done
    rw_fail "应用进程尚未退出，未删除本机数据或 App。"
}

rw_main() {
    local dry_run=0 app="" script_dir canonical uid username user_home library helper answer path temporary
    local -a user_paths system_paths byhost command_outputs
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|--dry-run) dry_run=1; shift ;;
            --app) [[ $# -ge 2 ]] || { rw_fail "--app 缺少路径"; return 1; }; app="$2"; shift 2 ;;
            *) rw_fail "用法：uninstall.sh [--app /完整路径/RouteWeaver.app] [--check]"; return 1 ;;
        esac
    done
    uid=$(/usr/bin/id -u)
    [[ "$uid" -ge 500 ]] || { rw_fail "请以登录用户运行本工具，不要对整个脚本使用 sudo。"; return 1; }
    username=$(/usr/bin/id -un)
    user_home=$(/usr/bin/dscl /Search -read "/Users/$username" NFSHomeDirectory | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')
    [[ "$user_home" == /* && "$user_home" != / && -d "$user_home" && ! -L "$user_home" ]] || {
        rw_fail "无法安全确认当前用户主目录。"; return 1;
    }
    if [[ -z "$app" ]]; then
        [[ ! -L "${BASH_SOURCE[0]}" ]] || { rw_fail "卸载脚本不能是符号链接。"; return 1; }
        script_dir="$(cd -P "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
        [[ "$script_dir" == *.app/Contents/Resources ]] || {
            rw_fail "源码目录运行时请通过 --app 指定要卸载的 App。"; return 1;
        }
        app="${script_dir%/Contents/Resources}"
    fi
    [[ "$app" == /*.app && -d "$app" && ! -L "$app" ]] || { rw_fail "App 路径无效。"; return 1; }
    canonical="$(cd -P "$app" && pwd)"
    [[ "$app" == "$canonical" ]] || { rw_fail "App 路径包含符号链接或未规范化的路径。"; return 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.routeweaver.app ]] || {
        rw_fail "目标不是 RouteWeaver。"; return 1;
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == RouteWeaver ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$app" || { rw_fail "App 签名校验失败。"; return 1; }
    helper="$app/Contents/Helpers/RouteWeaverHelper"
    [[ -x "$helper" && ! -L "$helper" ]] || { rw_fail "缺少应用内卸载帮助程序。"; return 1; }
    rw_check_tree "$app" "$uid" || return 1
    [[ -w "$(/usr/bin/dirname "$app")" ]] || { rw_fail "当前用户无权移除该 App。"; return 1; }

    library="$user_home/Library"
    [[ -d "$library" && ! -L "$library" ]] || { rw_fail "用户 Library 目录不安全。"; return 1; }
    user_paths=(
        "$library/Application Support/RouteWeaver"
        "$library/Caches/com.routeweaver.app"
        "$library/Preferences/com.routeweaver.app.plist"
        "$library/Saved Application State/com.routeweaver.app.savedState"
        "$library/HTTPStorages/com.routeweaver.app"
        "$library/HTTPStorages/com.routeweaver.app.binarycookies"
        "$library/WebKit/com.routeweaver.app"
    )
    shopt -s nullglob
    byhost=("$library/Preferences/ByHost/com.routeweaver.app."*.plist)
    shopt -u nullglob
    user_paths+=(${byhost[@]+"${byhost[@]}"})
    for path in "${user_paths[@]}"; do
        rw_check_location "$path" "$user_home" "$uid" || return 1
        rw_check_tree "$path" "$uid" || return 1
    done
    rw_check_profile "${user_paths[0]}" || return 1
    temporary=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
    [[ "$temporary" == /* && -d "$temporary" ]] || { rw_fail "无法确认用户临时目录。"; return 1; }
    temporary="$(cd -P "$temporary" && pwd)"
    [[ "$(/usr/bin/stat -f %u "$temporary")" == "$uid" ]] || { rw_fail "临时目录所有者异常。"; return 1; }
    shopt -s nullglob
    command_outputs=("$temporary/routeweaver-"*)
    shopt -u nullglob
    for path in ${command_outputs[@]+"${command_outputs[@]}"}; do
        [[ "${path##*/}" =~ ^routeweaver-[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || continue
        rw_check_location "$path" "$temporary" "$uid" || return 1
        rw_check_tree "$path" "$uid" || return 1
        rw_check_command_output "$path" || return 1
    done
    system_paths=(
        /Library/LaunchDaemons/com.routeweaver.helper.plist
        /Library/PrivilegedHelperTools/com.routeweaver.helper
        /Library/PrivilegedHelperTools/com.routeweaver.control.sock
        /private/var/db/com.routeweaver.service
        /private/var/db/com.routeweaver.routes
    )
    echo "将恢复网络并移除 RouteWeaver 后台服务、规则与活动记录、缓存和以下 App："
    echo "  $app"
    echo "Tailscale 配置、导出的文件、源码和独立诊断归档不在删除范围内。"
    if [[ "$dry_run" == 1 ]]; then
        echo "已发现的用户文件："
        for path in "${user_paths[@]}"; do if rw_exists "$path"; then echo "  $path"; fi; done
        for path in ${command_outputs[@]+"${command_outputs[@]}"}; do
            [[ "${path##*/}" =~ ^routeweaver-[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || continue
            echo "  $path"
        done
        echo "系统文件由管理员帮助程序在实际卸载时核验。"
        echo "只读检查通过。未请求管理员权限，未停止进程或修改文件。"
        return 0
    fi
    [[ -t 0 ]] || { rw_fail "请在终端交互运行，确认后才能卸载。"; return 1; }
    read -r -p "永久删除上述应用数据并卸载？请输入 UNINSTALL：" answer
    [[ "$answer" == UNINSTALL ]] || { echo "已取消。"; return 0; }
    rw_check_other_instances "$app/Contents/MacOS/RouteWeaver" || return 1

    echo "正在请求管理员授权…"
    /usr/bin/sudo -v || { rw_fail "管理员授权未完成，尚未停止应用或修改文件。"; return 1; }
    rw_check_other_instances "$app/Contents/MacOS/RouteWeaver" || return 1
    # Stop the GUI only after authorization succeeds. This prevents downloads,
    # repairs and preference writes racing the cleanup. The installed daemon
    # observes owner exit and the standalone helper then verifies its recovery.
    rw_stop_gui "$app/Contents/MacOS/RouteWeaver" || return 1
    echo "正在恢复网络并移除后台服务…"
    [[ "$(cd -P "$app" && pwd)" == "$app" ]] || { rw_fail "App 路径已变化。"; return 1; }
    /usr/bin/codesign --verify --deep --strict "$app" || return 1
    rw_check_tree "$app" "$uid" || return 1
    /usr/bin/sudo -- "$helper" uninstall-service || {
        rw_fail "后台服务或网络未完全清理；本机数据和 App 已保留，便于恢复。"; return 1;
    }
    rw_check_gui_stopped "$app/Contents/MacOS/RouteWeaver" || return 1
    # Commands may have created another private output directory since the
    # preflight. Rescan after the GUI is gone, using its exact UUID naming rule.
    shopt -s nullglob
    command_outputs=("$temporary/routeweaver-"*)
    shopt -u nullglob
    for path in ${command_outputs[@]+"${command_outputs[@]}"}; do
        [[ "${path##*/}" =~ ^routeweaver-[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || continue
        rw_check_location "$path" "$temporary" "$uid" || return 1
        rw_check_tree "$path" "$uid" || return 1
        rw_check_command_output "$path" || return 1
        user_paths+=("$path")
    done

    # Update cfprefsd through its API after the GUI stops, then verify its file.
    rw_check_location "$library/Preferences/com.routeweaver.app.plist" "$user_home" "$uid" || return 1
    rw_check_tree "$library/Preferences/com.routeweaver.app.plist" "$uid" || return 1
    if /usr/bin/defaults read com.routeweaver.app >/dev/null 2>&1; then
        /usr/bin/defaults delete com.routeweaver.app || return 1
    fi
    rw_check_location "$library/Preferences/ByHost/com.routeweaver.app.plist" "$user_home" "$uid" || return 1
    if /usr/bin/defaults -currentHost read com.routeweaver.app >/dev/null 2>&1; then
        /usr/bin/defaults -currentHost delete com.routeweaver.app || return 1
    fi
    shopt -s nullglob
    byhost=("$library/Preferences/ByHost/com.routeweaver.app."*.plist)
    shopt -u nullglob
    user_paths+=(${byhost[@]+"${byhost[@]}"})
    for path in "${user_paths[@]}"; do
        if [[ "$path" == "$temporary/"* ]]; then
            rw_check_location "$path" "$temporary" "$uid" || return 1
            rw_check_command_output "$path" || return 1
        else
            rw_check_location "$path" "$user_home" "$uid" || return 1
        fi
        rw_check_tree "$path" "$uid" || return 1
        if [[ "$path" == "${user_paths[0]}" ]]; then rw_check_profile "$path" || return 1; fi
        if rw_exists "$path"; then /bin/rm -rf -- "$path" || return 1; fi
    done
    /bin/sleep 1
    for path in "${user_paths[@]}"; do
        if rw_exists "$path"; then rw_fail "仍有用户文件残留：$path"; return 1; fi
    done
    rw_verify_system_files "${system_paths[@]}" || return 1
    rw_check_gui_stopped "$app/Contents/MacOS/RouteWeaver" || return 1
    # The complete function has already been parsed. Removing this bundle also
    # removes the script, without leaving an external cleanup worker behind.
    [[ -d "$app" && ! -L "$app" && "$(cd -P "$app" && pwd)" == "$app" ]] || {
        rw_fail "App 路径已变化，未删除。"; return 1;
    }
    /usr/bin/codesign --verify --deep --strict "$app" || return 1
    rw_check_tree "$app" "$uid" || return 1
    /bin/rm -rf -- "$app" || return 1
    if rw_exists "$app"; then rw_fail "App 未能移除：$app"; return 1; fi
    rw_check_gui_stopped "$app/Contents/MacOS/RouteWeaver" || return 1
    for path in "${user_paths[@]}"; do
        if [[ "$path" == "$temporary/"* ]]; then
            rw_check_location "$path" "$temporary" "$uid" || return 1
        else
            rw_check_location "$path" "$user_home" "$uid" || return 1
        fi
        if rw_exists "$path"; then rw_fail "用户文件重新出现：$path"; return 1; fi
    done
    rw_verify_system_files "${system_paths[@]}" || return 1
    echo "卸载完成：网络已恢复，后台服务、恢复日志、本机数据和该 App 均已移除并核验。"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rw_main "$@"
fi
