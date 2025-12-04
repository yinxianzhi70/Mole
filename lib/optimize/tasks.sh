#!/bin/bash
# Optimization Tasks

set -euo pipefail

# System maintenance: rebuild databases and flush caches
opt_system_maintenance() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding LaunchServices database..."
    run_with_timeout 10 /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user > /dev/null 2>&1 || true
    echo -e "${GREEN}${ICON_SUCCESS}${NC} LaunchServices database rebuilt"

    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing DNS cache..."
    if sudo dscacheutil -flushcache 2> /dev/null && sudo killall -HUP mDNSResponder 2> /dev/null; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} DNS cache cleared"
    else
        echo -e "${RED}${ICON_ERROR}${NC} Failed to clear DNS cache"
    fi

    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing memory cache..."
    if sudo purge 2> /dev/null; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Memory cache cleared"
    else
        echo -e "${RED}${ICON_ERROR}${NC} Failed to clear memory"
    fi

    # Skip: Font cache rebuild breaks ScreenSaverEngine and other system components
    # echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding font cache..."
    # sudo atsutil databases -remove > /dev/null 2>&1
    # echo -e "${GREEN}${ICON_SUCCESS}${NC} Font cache rebuilt"

    echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding Spotlight index (runs in background)..."
    local md_status
    md_status=$(mdutil -s / 2> /dev/null || echo "")
    if echo "$md_status" | grep -qi "Indexing disabled"; then
        echo -e "${GRAY}-${NC} Spotlight indexing disabled, skipping rebuild"
    else
        # mdutil triggers background indexing - don't wait
        run_with_timeout 10 sudo mdutil -E / > /dev/null 2>&1 || true
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Spotlight rebuild initiated"
    fi

    echo -e "${BLUE}${ICON_ARROW}${NC} Refreshing Bluetooth services..."
    sudo pkill -f blued 2> /dev/null || true
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Bluetooth controller refreshed"

    # Skip: log erase --all --force deletes ALL system logs, making debugging impossible
    # Users should manually manage logs if needed using: sudo log erase --all --force
    # if command -v log > /dev/null 2>&1 && [[ "${MO_ENABLE_LOG_CLEANUP:-0}" == "1" ]]; then
    #     echo -e "${BLUE}${ICON_ARROW}${NC} Compressing system logs..."
    #     if command -v has_sudo_session > /dev/null 2>&1 && ! has_sudo_session; then
    #         echo -e "${YELLOW}!${NC} Skipped log compression ${GRAY}(admin session inactive)${NC}"
    #     elif run_with_timeout 15 sudo -n log erase --all --force > /dev/null 2>&1; then
    #         echo -e "${GREEN}${ICON_SUCCESS}${NC} logarchive trimmed"
    #     else
    #         echo -e "${YELLOW}!${NC} Skipped log compression ${GRAY}(requires Full Disk Access)${NC}"
    #     fi
    # fi
}

# Cache refresh: update Finder/Safari caches
opt_cache_refresh() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Resetting Quick Look cache..."
    qlmanage -r cache > /dev/null 2>&1 || true
    qlmanage -r > /dev/null 2>&1 || true

    local -a cache_targets=(
        "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache|Quick Look thumbnails"
        "$HOME/Library/Caches/com.apple.iconservices.store|Icon Services store"
        "$HOME/Library/Caches/com.apple.iconservices|Icon Services cache"
        "$HOME/Library/Caches/com.apple.Safari/WebKitCache|Safari WebKit cache"
        "$HOME/Library/Caches/com.apple.Safari/Favicon|Safari favicon cache"
    )

    for target in "${cache_targets[@]}"; do
        IFS='|' read -r target_path label <<< "$target"
        cleanup_path "$target_path" "$label"
    done

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Finder and Safari caches updated"
}

# Maintenance scripts: run periodic tasks
opt_maintenance_scripts() {
    local success=true
    local periodic_cmd="/usr/sbin/periodic"

    # Show spinner while running all tasks
    if [[ -t 1 ]]; then
        start_inline_spinner ""
    fi

    # Run periodic scripts silently with timeout
    if [[ -x "$periodic_cmd" ]]; then
        if ! run_with_timeout 180 sudo "$periodic_cmd" daily weekly monthly > /dev/null 2>&1; then
            success=false
        fi
    fi

    # Run newsyslog silently with timeout
    if ! run_with_timeout 120 sudo newsyslog > /dev/null 2>&1; then
        success=false
    fi

    # Run repair_packages silently with timeout
    if [[ -x "/usr/libexec/repair_packages" ]]; then
        if ! run_with_timeout 180 sudo /usr/libexec/repair_packages --repair --standard-pkgs --volume / > /dev/null 2>&1; then
            success=false
        fi
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Show final status
    if [[ "$success" == "true" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Complete"
    else
        echo -e "${YELLOW}!${NC} Some tasks timed out or failed"
    fi
}

# Log cleanup: remove diagnostic and crash logs
opt_log_cleanup() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing diagnostic & crash logs..."
    local -a user_logs=(
        "$HOME/Library/Logs/DiagnosticReports"
        "$HOME/Library/Logs/corecaptured"
    )
    for target in "${user_logs[@]}"; do
        cleanup_path "$target" "$(basename "$target")"
    done

    if [[ -d "/Library/Logs/DiagnosticReports" ]]; then
        safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*.crash" 0 "f"
        safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*.panic" 0 "f"
        echo -e "${GREEN}${ICON_SUCCESS}${NC} System diagnostic logs cleared"
    else
        echo -e "${GRAY}-${NC} No system diagnostic logs found"
    fi
}

# Recent items: clear recent file lists
opt_recent_items() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing recent items lists..."
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    if [[ -d "$shared_dir" ]]; then
        safe_find_delete "$shared_dir" "*.sfl2" 0 "f"
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Shared file lists cleared"
    fi

    rm -f "$HOME/Library/Preferences/com.apple.recentitems.plist" 2> /dev/null || true
    defaults delete NSGlobalDomain NSRecentDocumentsLimit 2> /dev/null || true

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Recent items cleared"
}

# Radio refresh: reset Bluetooth and Wi-Fi (safe mode - no pairing/password loss)
opt_radio_refresh() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Refreshing Bluetooth controller..."
    # Only restart Bluetooth service, do NOT delete pairing information
    sudo pkill -HUP bluetoothd 2> /dev/null || true
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Bluetooth controller refreshed"

    echo -e "${BLUE}${ICON_ARROW}${NC} Refreshing Wi-Fi service..."
    # Only restart Wi-Fi service, do NOT delete saved networks
    # Skip: Deleting airport.preferences.plist causes all saved Wi-Fi passwords to be lost
    # sudo rm -f "$sysconfig"/com.apple.airport.preferences.plist

    # Safe alternative: just restart the Wi-Fi interface
    local wifi_interface
    wifi_interface=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}' | head -1)
    if [[ -n "$wifi_interface" ]]; then
        sudo ifconfig "$wifi_interface" down 2> /dev/null || true
        sleep 1
        sudo ifconfig "$wifi_interface" up 2> /dev/null || true
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Wi-Fi interface restarted"
    else
        echo -e "${GRAY}-${NC} Wi-Fi interface not found"
    fi

    # Restart AirDrop interface
    sudo ifconfig awdl0 down 2> /dev/null || true
    sudo ifconfig awdl0 up 2> /dev/null || true
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Wireless services refreshed"
}

# Mail downloads: clear OLD Mail attachment cache (30+ days)
opt_mail_downloads() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing old Mail attachment downloads (30+ days)..."
    local -a mail_dirs=(
        "$HOME/Library/Mail Downloads"
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    )

    local total_kb=0
    for target_path in "${mail_dirs[@]}"; do
        total_kb=$((total_kb + $(get_path_size_kb "$target_path")))
    done

    if [[ $total_kb -lt $MOLE_MAIL_DOWNLOADS_MIN_KB ]]; then
        echo -e "${GRAY}-${NC} Only $(bytes_to_human $((total_kb * 1024))) detected, skipping cleanup"
        return
    fi

    # Only delete old attachments (safety window)
    local deleted=0
    for target_path in "${mail_dirs[@]}"; do
        if [[ -d "$target_path" ]]; then
            # Timeout protection: prevent find from hanging on large mail directories
            local file_count=$(run_with_timeout 15 sh -c "find \"$target_path\" -type f -mtime \"+$MOLE_LOG_AGE_DAYS\" 2> /dev/null | wc -l | tr -d ' '")
            [[ -z "$file_count" || ! "$file_count" =~ ^[0-9]+$ ]] && file_count=0
            if [[ "$file_count" -gt 0 ]]; then
                safe_find_delete "$target_path" "*" "$MOLE_LOG_AGE_DAYS" "f"
                deleted=$((deleted + file_count))
            fi
        fi
    done

    if [[ $deleted -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $deleted old attachment(s)"
    else
        echo -e "${GRAY}-${NC} No old attachments found"
    fi
}

# Saved state: remove OLD app saved states (7+ days)
opt_saved_state_cleanup() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Removing old saved application states (${MOLE_SAVED_STATE_AGE_DAYS}+ days)..."
    local state_dir="$HOME/Library/Saved Application State"

    if [[ ! -d "$state_dir" ]]; then
        echo -e "${GRAY}-${NC} No saved states directory found"
        return
    fi

    # Only delete old saved states (safety window)
    local deleted=0
    while IFS= read -r -d '' state_path; do
        if safe_remove "$state_path" true; then
            ((deleted++))
        fi
    done < <(command find "$state_dir" -type d -name "*.savedState" -mtime "+$MOLE_SAVED_STATE_AGE_DAYS" -print0 2> /dev/null)

    if [[ $deleted -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $deleted old saved state(s)"
    else
        echo -e "${GRAY}-${NC} No old saved states found"
    fi
}

# Finder and Dock: refresh interface caches
# REMOVED: Deleting Finder cache causes user configuration loss
# Including window positions, sidebar settings, view preferences, icon sizes
# Users reported losing Finder settings even with .DS_Store whitelist protection
# Keep this function for reference but do not use in default optimizations
opt_finder_dock_refresh() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Resetting Finder & Dock caches..."
    local -a interface_targets=(
        "$HOME/Library/Caches/com.apple.finder|Finder cache"
        "$HOME/Library/Caches/com.apple.dock.iconcache|Dock icon cache"
    )
    for target in "${interface_targets[@]}"; do
        IFS='|' read -r target_path label <<< "$target"
        cleanup_path "$target_path" "$label"
    done

    # Warn user before restarting Finder (may lose unsaved work)
    echo -e "${YELLOW}${ICON_WARNING}${NC} About to restart Finder & Dock (save any work in Finder windows)"
    sleep 2

    killall Finder > /dev/null 2>&1 || true
    killall Dock > /dev/null 2>&1 || true
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Finder & Dock relaunched"
}

# Swap cleanup: reset swap files
opt_swap_cleanup() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Removing swapfiles and resetting dynamic pager..."
    if sudo launchctl unload /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1; then
        sudo rm -f /private/var/vm/swapfile* > /dev/null 2>&1 || true
        sudo touch /private/var/vm/swapfile0 > /dev/null 2>&1 || true
        sudo chmod 600 /private/var/vm/swapfile0 > /dev/null 2>&1 || true
        sudo launchctl load /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1 || true
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Swap cache rebuilt"
    else
        echo -e "${YELLOW}!${NC} Could not unload dynamic_pager"
    fi
}

# Startup cache: rebuild kernel caches
opt_startup_cache() {
    local macos_version
    macos_version=$(sw_vers -productVersion | cut -d '.' -f 1)
    local success=true

    if [[ -t 1 ]]; then
        start_inline_spinner ""
    fi

    if [[ "$macos_version" -ge 11 ]] || [[ "$(uname -m)" == "arm64" ]]; then
        if ! run_with_timeout 120 sudo kextcache -i / > /dev/null 2>&1; then
            success=false
        fi
    else
        if ! run_with_timeout 180 sudo kextcache -i / > /dev/null 2>&1; then
            success=false
        fi

        # Skip: Deleting PrelinkedKernels breaks ScreenSaverEngine and other system components
        # sudo rm -rf /System/Library/PrelinkedKernels/* > /dev/null 2>&1 || true
        run_with_timeout 120 sudo kextcache -system-prelinked-kernel > /dev/null 2>&1 || true
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ "$success" == "true" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Complete"
    else
        echo -e "${YELLOW}!${NC} Timed out or failed"
    fi
}

# Local snapshots: thin Time Machine snapshots
opt_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        echo -e "${YELLOW}!${NC} tmutil not available on this system"
        return
    fi

    local before after
    before=$(count_local_snapshots)
    if [[ "$before" -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No local snapshots to thin"
        return
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner ""
    fi

    local success=false
    if run_with_timeout 180 sudo tmutil thinlocalsnapshots / 9999999999 4 > /dev/null 2>&1; then
        success=true
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ "$success" == "true" ]]; then
        after=$(count_local_snapshots)
        local removed=$((before - after))
        [[ "$removed" -lt 0 ]] && removed=0
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $removed snapshots (remaining: $after)"
    else
        echo -e "${YELLOW}!${NC} Timed out or failed"
    fi
}

# Developer cleanup: remove Xcode/simulator cruft
opt_developer_cleanup() {
    local -a dev_targets=(
        "$HOME/Library/Developer/Xcode/DerivedData|Xcode DerivedData"
        "$HOME/Library/Developer/Xcode/iOS DeviceSupport|iOS Device support files"
        "$HOME/Library/Developer/CoreSimulator/Caches|CoreSimulator caches"
    )

    for target in "${dev_targets[@]}"; do
        IFS='|' read -r target_path label <<< "$target"
        cleanup_path "$target_path" "$label"
    done

    if command -v xcrun > /dev/null 2>&1; then
        echo -e "${BLUE}${ICON_ARROW}${NC} Removing unavailable simulator runtimes..."
        if xcrun simctl delete unavailable > /dev/null 2>&1; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Unavailable simulators removed"
        else
            echo -e "${YELLOW}!${NC} Could not prune simulator runtimes"
        fi
    fi

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Developer caches cleaned"
}

# Execute optimization by action name
execute_optimization() {
    local action="$1"
    local path="${2:-}"

    case "$action" in
        system_maintenance) opt_system_maintenance ;;
        cache_refresh) opt_cache_refresh ;;
        maintenance_scripts) opt_maintenance_scripts ;;
        log_cleanup) opt_log_cleanup ;;
        recent_items) opt_recent_items ;;
        radio_refresh) opt_radio_refresh ;;
        mail_downloads) opt_mail_downloads ;;
        saved_state_cleanup) opt_saved_state_cleanup ;;
        finder_dock_refresh) opt_finder_dock_refresh ;;
        swap_cleanup) opt_swap_cleanup ;;
        startup_cache) opt_startup_cache ;;
        local_snapshots) opt_local_snapshots ;;
        developer_cleanup) opt_developer_cleanup ;;
        *)
            echo -e "${RED}${ICON_ERROR}${NC} Unknown action: $action"
            return 1
            ;;
    esac
}
#!/bin/bash
# System Health Check - Pure Bash Implementation
# Replaces optimize-go

set -euo pipefail

# Get memory info in GB
get_memory_info() {
    local total_bytes used_gb total_gb

    # Total memory
    total_bytes=$(sysctl -n hw.memsize 2> /dev/null || echo "0")
    total_gb=$(awk "BEGIN {printf \"%.2f\", $total_bytes / (1024*1024*1024)}" 2> /dev/null || echo "0")
    [[ -z "$total_gb" || "$total_gb" == "" ]] && total_gb="0"

    # Used memory from vm_stat
    local vm_output active wired compressed page_size
    vm_output=$(vm_stat 2> /dev/null || echo "")
    page_size=4096

    active=$(echo "$vm_output" | awk '/Pages active:/ {print $NF}' | tr -d '.' 2> /dev/null || echo "0")
    wired=$(echo "$vm_output" | awk '/Pages wired down:/ {print $NF}' | tr -d '.' 2> /dev/null || echo "0")
    compressed=$(echo "$vm_output" | awk '/Pages occupied by compressor:/ {print $NF}' | tr -d '.' 2> /dev/null || echo "0")

    active=${active:-0}
    wired=${wired:-0}
    compressed=${compressed:-0}

    local used_bytes=$(((active + wired + compressed) * page_size))
    used_gb=$(awk "BEGIN {printf \"%.2f\", $used_bytes / (1024*1024*1024)}" 2> /dev/null || echo "0")
    [[ -z "$used_gb" || "$used_gb" == "" ]] && used_gb="0"

    echo "$used_gb $total_gb"
}

# Get disk info
get_disk_info() {
    local home="${HOME:-/}"
    local df_output total_gb used_gb used_percent

    df_output=$(command df -k "$home" 2> /dev/null | tail -1)

    local total_kb used_kb
    total_kb=$(echo "$df_output" | awk '{print $2}' 2> /dev/null || echo "0")
    used_kb=$(echo "$df_output" | awk '{print $3}' 2> /dev/null || echo "0")

    total_kb=${total_kb:-0}
    used_kb=${used_kb:-0}
    [[ "$total_kb" == "0" ]] && total_kb=1 # Avoid division by zero

    total_gb=$(awk "BEGIN {printf \"%.2f\", $total_kb / (1024*1024)}" 2> /dev/null || echo "0")
    used_gb=$(awk "BEGIN {printf \"%.2f\", $used_kb / (1024*1024)}" 2> /dev/null || echo "0")
    used_percent=$(awk "BEGIN {printf \"%.1f\", ($used_kb / $total_kb) * 100}" 2> /dev/null || echo "0")

    [[ -z "$total_gb" || "$total_gb" == "" ]] && total_gb="0"
    [[ -z "$used_gb" || "$used_gb" == "" ]] && used_gb="0"
    [[ -z "$used_percent" || "$used_percent" == "" ]] && used_percent="0"

    echo "$used_gb $total_gb $used_percent"
}

# Get uptime in days
get_uptime_days() {
    local boot_output boot_time uptime_days

    boot_output=$(sysctl -n kern.boottime 2> /dev/null || echo "")
    boot_time=$(echo "$boot_output" | sed -n 's/.*sec = \([0-9]*\).*/\1/p' 2> /dev/null || echo "")

    if [[ -n "$boot_time" && "$boot_time" =~ ^[0-9]+$ ]]; then
        local now=$(date +%s 2> /dev/null || echo "0")
        local uptime_sec=$((now - boot_time))
        uptime_days=$(awk "BEGIN {printf \"%.1f\", $uptime_sec / 86400}" 2> /dev/null || echo "0")
    else
        uptime_days="0"
    fi

    [[ -z "$uptime_days" || "$uptime_days" == "" ]] && uptime_days="0"
    echo "$uptime_days"
}

# Get directory size in KB
# Format size from KB
format_size_kb() {
    local kb="$1"
    [[ "$kb" -le 0 ]] && echo "0B" && return

    local mb gb
    mb=$(awk "BEGIN {printf \"%.1f\", $kb / 1024}")
    gb=$(awk "BEGIN {printf \"%.2f\", $mb / 1024}")

    if awk "BEGIN {exit !($gb >= 1)}"; then
        echo "${gb}GB"
    elif awk "BEGIN {exit !($mb >= 1)}"; then
        printf "%.0fMB\n" "$mb"
    else
        echo "${kb}KB"
    fi
}

# Check cache size
check_cache_refresh() {
    local cache_dir="$HOME/Library/Caches"
    local size_kb=$(get_path_size_kb "$cache_dir")
    local desc="Refresh Finder previews, Quick Look, and Safari caches"

    if [[ $size_kb -gt 0 ]]; then
        local size_str=$(format_size_kb "$size_kb")
        desc="Refresh ${size_str} of Finder/Safari caches"
    fi

    echo "cache_refresh|User Cache Refresh|${desc}|true"
}

# Check Mail downloads
check_mail_downloads() {
    local dirs=(
        "$HOME/Library/Mail Downloads"
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    )

    local total_kb=0
    for dir in "${dirs[@]}"; do
        total_kb=$((total_kb + $(get_path_size_kb "$dir")))
    done

    if [[ $total_kb -gt 0 ]]; then
        local size_str=$(format_size_kb "$total_kb")
        echo "mail_downloads|Mail Downloads|Recover ${size_str} of Mail attachments|true"
    fi
}

# Check saved state
check_saved_state() {
    local state_dir="$HOME/Library/Saved Application State"
    local size_kb=$(get_path_size_kb "$state_dir")

    if [[ $size_kb -gt 0 ]]; then
        local size_str=$(format_size_kb "$size_kb")
        echo "saved_state_cleanup|Saved State|Clear ${size_str} of stale saved states|true"
    fi
}

# Check swap files
check_swap_cleanup() {
    local total_kb=0
    local file

    for file in /private/var/vm/swapfile*; do
        [[ -f "$file" ]] && total_kb=$((total_kb + $(get_file_size "$file") / 1024))
    done

    if [[ $total_kb -gt 0 ]]; then
        local size_str=$(format_size_kb "$total_kb")
        echo "swap_cleanup|Memory & Swap|Purge swap (${size_str}) & inactive memory|false"
    fi
}

# Check local snapshots
check_local_snapshots() {
    command -v tmutil > /dev/null 2>&1 || return

    local snapshots
    snapshots=$(tmutil listlocalsnapshots / 2> /dev/null || echo "")

    local count
    count=$(echo "$snapshots" | grep -c "com.apple.TimeMachine" 2> /dev/null)
    count=$(echo "$count" | tr -d ' \n')
    count=${count:-0}
    [[ "$count" =~ ^[0-9]+$ ]] && [[ $count -gt 0 ]] && echo "local_snapshots|Local Snapshots|${count} APFS local snapshots detected|true"
}

# Check developer cleanup
check_developer_cleanup() {
    local dirs=(
        "$HOME/Library/Developer/Xcode/DerivedData"
        "$HOME/Library/Developer/Xcode/Archives"
        "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
        "$HOME/Library/Developer/CoreSimulator/Caches"
    )

    local total_kb=0
    for dir in "${dirs[@]}"; do
        total_kb=$((total_kb + $(get_path_size_kb "$dir")))
    done

    if [[ $total_kb -gt 0 ]]; then
        local size_str=$(format_size_kb "$total_kb")
        echo "developer_cleanup|Developer Cleanup|Recover ${size_str} of Xcode/simulator data|false"
    fi
}

# Generate JSON output
generate_health_json() {
    # System info
    read -r mem_used mem_total <<< "$(get_memory_info)"
    read -r disk_used disk_total disk_percent <<< "$(get_disk_info)"
    local uptime=$(get_uptime_days)

    # Ensure all values are valid numbers (fallback to 0)
    mem_used=${mem_used:-0}
    mem_total=${mem_total:-0}
    disk_used=${disk_used:-0}
    disk_total=${disk_total:-0}
    disk_percent=${disk_percent:-0}
    uptime=${uptime:-0}

    # Start JSON
    cat << EOF
{
  "memory_used_gb": $mem_used,
  "memory_total_gb": $mem_total,
  "disk_used_gb": $disk_used,
  "disk_total_gb": $disk_total,
  "disk_used_percent": $disk_percent,
  "uptime_days": $uptime,
  "optimizations": [
EOF

    # Collect all optimization items
    local -a items=()

    # Always-on items
    items+=('system_maintenance|System Maintenance|Rebuild system databases & flush caches|true')
    items+=('maintenance_scripts|Maintenance Scripts|Run daily/weekly/monthly scripts & rotate logs|true')
    items+=('radio_refresh|Bluetooth & Wi-Fi Refresh|Reset wireless preference caches|true')
    items+=('recent_items|Recent Items|Clear recent apps/documents/servers lists|true')
    items+=('log_cleanup|Diagnostics Cleanup|Purge old diagnostic & crash logs|true')
    items+=('startup_cache|Startup Cache Rebuild|Rebuild kext caches & prelinked kernel|true')

    # Conditional items
    local item
    item=$(check_cache_refresh || true)
    [[ -n "$item" ]] && items+=("$item")
    item=$(check_mail_downloads || true)
    [[ -n "$item" ]] && items+=("$item")
    item=$(check_saved_state || true)
    [[ -n "$item" ]] && items+=("$item")
    item=$(check_swap_cleanup || true)
    [[ -n "$item" ]] && items+=("$item")
    item=$(check_local_snapshots || true)
    [[ -n "$item" ]] && items+=("$item")
    item=$(check_developer_cleanup || true)
    [[ -n "$item" ]] && items+=("$item")

    # Output items as JSON
    local first=true
    for item in "${items[@]}"; do
        IFS='|' read -r action name desc safe <<< "$item"

        [[ "$first" == "true" ]] && first=false || echo ","

        cat << EOF
    {
      "category": "system",
      "name": "$name",
      "description": "$desc",
      "action": "$action",
      "safe": $safe
    }
EOF
    done

    # Close JSON
    cat << 'EOF'
  ]
}
EOF
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_health_json
fi
