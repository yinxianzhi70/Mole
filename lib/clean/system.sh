#!/bin/bash
# System-Level Cleanup Module
# Deep system cleanup (requires sudo) and Time Machine failed backups

set -euo pipefail

# Deep system cleanup (requires sudo)
clean_deep_system() {
    # Clean old system caches
    safe_sudo_find_delete "/Library/Caches" "*.cache" "$MOLE_TEMP_FILE_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/Library/Caches" "*.tmp" "$MOLE_TEMP_FILE_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/Library/Caches" "*.log" "$MOLE_LOG_AGE_DAYS" "f" || true

    # Clean old temp files
    local tmp_cleaned=0
    local tmp_count=$(sudo command find /tmp -type f -mtime +"${MOLE_TEMP_FILE_AGE_DAYS}" 2> /dev/null | wc -l | tr -d ' ')
    if [[ "$tmp_count" -gt 0 ]]; then
        safe_sudo_find_delete "/tmp" "*" "${MOLE_TEMP_FILE_AGE_DAYS}" "f" || true
        tmp_cleaned=1
    fi
    local var_tmp_count=$(sudo command find /var/tmp -type f -mtime +"${MOLE_TEMP_FILE_AGE_DAYS}" 2> /dev/null | wc -l | tr -d ' ')
    if [[ "$var_tmp_count" -gt 0 ]]; then
        safe_sudo_find_delete "/var/tmp" "*" "${MOLE_TEMP_FILE_AGE_DAYS}" "f" || true
        tmp_cleaned=1
    fi
    [[ $tmp_cleaned -eq 1 ]] && log_success "Old system temp files (${MOLE_TEMP_FILE_AGE_DAYS}+ days)"

    # Clean crash reports
    safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*" "$MOLE_CRASH_REPORT_AGE_DAYS" "f" || true
    log_success "Old system crash reports (${MOLE_CRASH_REPORT_AGE_DAYS}+ days)"

    # Clean system logs
    safe_sudo_find_delete "/var/log" "*.log" "$MOLE_LOG_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/var/log" "*.gz" "$MOLE_LOG_AGE_DAYS" "f" || true
    log_success "Old system logs (${MOLE_LOG_AGE_DAYS}+ days)"

    # Clean Library Updates safely - skip if SIP is enabled to avoid error messages
    # SIP-protected files in /Library/Updates cannot be deleted even with sudo
    if [[ -d "/Library/Updates" && ! -L "/Library/Updates" ]]; then
        if is_sip_enabled; then
            # SIP is enabled, skip /Library/Updates entirely to avoid error messages
            # These files are system-protected and cannot be removed
            : # No-op, silently skip
        else
            # SIP is disabled, attempt cleanup with restricted flag check
            local updates_cleaned=0
            while IFS= read -r -d '' item; do
                # Skip system-protected files (restricted flag)
                local item_flags
                item_flags=$(command stat -f%Sf "$item" 2> /dev/null || echo "")
                if [[ "$item_flags" == *"restricted"* ]]; then
                    continue
                fi

                if safe_sudo_remove "$item"; then
                    ((updates_cleaned++))
                fi
            done < <(command find /Library/Updates -mindepth 1 -maxdepth 1 -print0 2> /dev/null)
            [[ $updates_cleaned -gt 0 ]] && log_success "System library updates"
        fi
    fi

    # Clean orphaned cask records (delegated to clean_brew module)
    clean_orphaned_casks
}

# Clean Time Machine failed backups
clean_time_machine_failed_backups() {
    local tm_cleaned=0

    # Check if Time Machine is configured
    if command -v tmutil > /dev/null 2>&1; then
        if tmutil destinationinfo 2>&1 | grep -q "No destinations configured"; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No failed Time Machine backups found"
            return 0
        fi
    fi

    if [[ ! -d "/Volumes" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No failed Time Machine backups found"
        return 0
    fi

    # Skip if backup is running
    if pgrep -x "backupd" > /dev/null 2>&1; then
        echo -e "  ${YELLOW}!${NC} Time Machine backup in progress, skipping cleanup"
        return 0
    fi

    for volume in /Volumes/*; do
        [[ -d "$volume" ]] || continue

        # Skip system and network volumes
        [[ "$volume" == "/Volumes/MacintoshHD" || "$volume" == "/" ]] && continue

        # Skip if volume is a symlink (security check)
        [[ -L "$volume" ]] && continue

        # Check if this is a Time Machine destination
        if command -v tmutil > /dev/null 2>&1; then
            if ! tmutil destinationinfo 2> /dev/null | grep -q "$(basename "$volume")"; then
                continue
            fi
        fi

        local fs_type=$(command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}')
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav) continue ;;
        esac

        # HFS+ style backups (Backups.backupdb)
        local backupdb_dir="$volume/Backups.backupdb"
        if [[ -d "$backupdb_dir" ]]; then
            while IFS= read -r inprogress_file; do
                [[ -d "$inprogress_file" ]] || continue

                # Only delete old failed backups (safety window)
                local file_mtime=$(get_file_mtime "$inprogress_file")
                local current_time=$(date +%s)
                local hours_old=$(((current_time - file_mtime) / 3600))

                if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                    continue
                fi

                local size_kb=$(get_path_size_kb "$inprogress_file")
                if [[ "$size_kb" -gt 0 ]]; then
                    local backup_name=$(basename "$inprogress_file")

                    if [[ "$DRY_RUN" != "true" ]]; then
                        if command -v tmutil > /dev/null 2>&1; then
                            if tmutil delete "$inprogress_file" 2> /dev/null; then
                                local size_human=$(bytes_to_human "$((size_kb * 1024))")
                                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Failed backup: $backup_name ${GREEN}($size_human)${NC}"
                                ((tm_cleaned++))
                                ((files_cleaned++))
                                ((total_size_cleaned += size_kb))
                                ((total_items++))
                                note_activity
                            else
                                echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name (try manually with sudo)"
                            fi
                        else
                            echo -e "  ${YELLOW}!${NC} tmutil not available, skipping: $backup_name"
                        fi
                    else
                        local size_human=$(bytes_to_human "$((size_kb * 1024))")
                        echo -e "  ${YELLOW}→${NC} Failed backup: $backup_name ${YELLOW}($size_human dry)${NC}"
                        ((tm_cleaned++))
                        note_activity
                    fi
                fi
            done < <(command find "$backupdb_dir" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
        fi

        # APFS style backups (.backupbundle or .sparsebundle)
        for bundle in "$volume"/*.backupbundle "$volume"/*.sparsebundle; do
            [[ -e "$bundle" ]] || continue
            [[ -d "$bundle" ]] || continue

            # Check if bundle is mounted
            local bundle_name=$(basename "$bundle")
            local mounted_path=$(hdiutil info 2> /dev/null | grep -A 5 "image-path.*$bundle_name" | grep "/Volumes/" | awk '{print $1}' | head -1 || echo "")

            if [[ -n "$mounted_path" && -d "$mounted_path" ]]; then
                while IFS= read -r inprogress_file; do
                    [[ -d "$inprogress_file" ]] || continue

                    # Only delete old failed backups (safety window)
                    local file_mtime=$(get_file_mtime "$inprogress_file")
                    local current_time=$(date +%s)
                    local hours_old=$(((current_time - file_mtime) / 3600))

                    if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                        continue
                    fi

                    local size_kb=$(get_path_size_kb "$inprogress_file")
                    if [[ "$size_kb" -gt 0 ]]; then
                        local backup_name=$(basename "$inprogress_file")

                        if [[ "$DRY_RUN" != "true" ]]; then
                            if command -v tmutil > /dev/null 2>&1; then
                                if tmutil delete "$inprogress_file" 2> /dev/null; then
                                    local size_human=$(bytes_to_human "$((size_kb * 1024))")
                                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Failed APFS backup in $bundle_name: $backup_name ${GREEN}($size_human)${NC}"
                                    ((tm_cleaned++))
                                    ((files_cleaned++))
                                    ((total_size_cleaned += size_kb))
                                    ((total_items++))
                                    note_activity
                                else
                                    echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                                fi
                            fi
                        else
                            local size_human=$(bytes_to_human "$((size_kb * 1024))")
                            echo -e "  ${YELLOW}→${NC} Failed APFS backup in $bundle_name: $backup_name ${YELLOW}($size_human dry)${NC}"
                            ((tm_cleaned++))
                            note_activity
                        fi
                    fi
                done < <(command find "$mounted_path" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
            fi
        done
    done

    if [[ $tm_cleaned -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No failed Time Machine backups found"
    fi
}
