#!/bin/bash
# Maintenance Cleanup Module
# Broken preferences and broken login items cleanup

set -euo pipefail

# ============================================================================
# Broken Preferences Detection and Cleanup
# Find and remove corrupted .plist files
# ============================================================================

# Clean broken preference files
# Uses plutil -lint to validate plist files
# Env: DRY_RUN
# Globals: files_cleaned, total_size_cleaned, total_items (modified)
clean_broken_preferences() {
    local prefs_dir="$HOME/Library/Preferences"
    [[ -d "$prefs_dir" ]] || return 0

    local broken_count=0
    local total_size_kb=0

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking preference files..."
    fi

    # Check main preferences directory
    while IFS= read -r plist_file; do
        [[ -f "$plist_file" ]] || continue

        # Skip system preferences
        local filename
        filename=$(basename "$plist_file")
        case "$filename" in
            com.apple.* | .GlobalPreferences* | loginwindow.plist)
                continue
                ;;
        esac

        # Validate plist using plutil
        if ! plutil -lint "$plist_file" > /dev/null 2>&1; then
            local size_kb
            size_kb=$(get_path_size_kb "$plist_file")

            if [[ "$DRY_RUN" != "true" ]]; then
                rm -f "$plist_file" 2> /dev/null || true
            fi

            ((broken_count++))
            ((total_size_kb += size_kb))
        fi
    done < <(command find "$prefs_dir" -maxdepth 1 -name "*.plist" -type f 2> /dev/null || true)

    # Check ByHost preferences
    local byhost_dir="$prefs_dir/ByHost"
    if [[ -d "$byhost_dir" ]]; then
        while IFS= read -r plist_file; do
            [[ -f "$plist_file" ]] || continue

            local filename
            filename=$(basename "$plist_file")
            case "$filename" in
                com.apple.* | .GlobalPreferences*)
                    continue
                    ;;
            esac

            if ! plutil -lint "$plist_file" > /dev/null 2>&1; then
                local size_kb
                size_kb=$(get_path_size_kb "$plist_file")

                if [[ "$DRY_RUN" != "true" ]]; then
                    rm -f "$plist_file" 2> /dev/null || true
                fi

                ((broken_count++))
                ((total_size_kb += size_kb))
            fi
        done < <(command find "$byhost_dir" -name "*.plist" -type f 2> /dev/null || true)
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ $broken_count -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}→${NC} Broken preferences: $broken_count files ${YELLOW}(dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Removed $broken_count broken preference files"
        fi
        # Update global statistics
        ((files_cleaned += broken_count))
        ((total_size_cleaned += total_size_kb))
        ((total_items++))
        note_activity
    fi
}

# ============================================================================
# Broken Login Items Cleanup
# Find and remove login items pointing to non-existent files
# ============================================================================

# Clean broken login items (LaunchAgents pointing to missing executables)
# Env: DRY_RUN
# Globals: files_cleaned, total_items (modified)
clean_broken_login_items() {
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    [[ -d "$launch_agents_dir" ]] || return 0

    local broken_count=0
    local total_size_kb=0

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking login items..."
    fi

    while IFS= read -r plist_file; do
        [[ -f "$plist_file" ]] || continue

        # Skip system items
        local filename
        filename=$(basename "$plist_file")
        case "$filename" in
            com.apple.*)
                continue
                ;;
        esac

        # Extract Program or ProgramArguments[0] from plist using plutil
        local program=""
        program=$(plutil -extract Program raw "$plist_file" 2> /dev/null || echo "")

        if [[ -z "$program" ]]; then
            # Try ProgramArguments array (first element)
            program=$(plutil -extract ProgramArguments.0 raw "$plist_file" 2> /dev/null || echo "")
        fi

        # Skip if no program found or program exists
        [[ -z "$program" ]] && continue
        [[ -e "$program" ]] && continue

        # Program doesn't exist - this is a broken login item
        local size_kb
        size_kb=$(get_path_size_kb "$plist_file")

        if [[ "$DRY_RUN" != "true" ]]; then
            # Unload first if loaded
            launchctl unload "$plist_file" 2> /dev/null || true
            rm -f "$plist_file" 2> /dev/null || true
        fi

        ((broken_count++))
        ((total_size_kb += size_kb))
    done < <(command find "$launch_agents_dir" -name "*.plist" -type f 2> /dev/null || true)

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ $broken_count -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}→${NC} Broken login items: $broken_count ${YELLOW}(dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Removed $broken_count broken login items"
        fi
        # Update global statistics
        ((files_cleaned += broken_count))
        ((total_size_cleaned += total_size_kb))
        ((total_items++))
        note_activity
    fi
}

# ============================================================================
# Main maintenance cleanup function
# ============================================================================

clean_maintenance() {
    clean_broken_preferences
    clean_broken_login_items
}
