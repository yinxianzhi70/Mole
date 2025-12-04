#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-opt-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    export TERM="dumb"
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/Library/Application Support/com.apple.sharedfilelist"
    mkdir -p "$HOME/Library/Caches"
    mkdir -p "$HOME/Library/Saved Application State"
}

@test "run_with_timeout succeeds without GNU timeout" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 0.1
    '
    [ "$status" -eq 0 ]
}

@test "run_with_timeout enforces timeout and returns 124" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 5
    '
    [ "$status" -eq 124 ]
}

@test "opt_recent_items removes shared file lists" {
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    mkdir -p "$shared_dir"
    touch "$shared_dir/test.sfl2"
    touch "$shared_dir/recent.sfl2"

    run env HOME="$HOME" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Mock sudo and defaults to avoid system changes
sudo() { return 0; }
defaults() { return 0; }
export -f sudo defaults
opt_recent_items
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Recent items cleared"* ]]
}

@test "opt_recent_items handles missing shared directory" {
    rm -rf "$HOME/Library/Application Support/com.apple.sharedfilelist"

    run env HOME="$HOME" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
sudo() { return 0; }
defaults() { return 0; }
export -f sudo defaults
opt_recent_items
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Recent items cleared"* ]]
}

@test "opt_saved_state_cleanup removes old saved states" {
    local state_dir="$HOME/Library/Saved Application State"
    mkdir -p "$state_dir/com.example.app.savedState"
    touch "$state_dir/com.example.app.savedState/data.plist"

    # Make the file old (8+ days) - MOLE_SAVED_STATE_AGE_DAYS defaults to 7
    touch -t 202301010000 "$state_dir/com.example.app.savedState/data.plist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
}

@test "opt_saved_state_cleanup handles missing state directory" {
    rm -rf "$HOME/Library/Saved Application State"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No saved states directory"* ]]
}

@test "opt_cache_refresh cleans Quick Look cache" {
    mkdir -p "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
    touch "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache/test.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Mock qlmanage and cleanup_path to avoid system calls
qlmanage() { return 0; }
cleanup_path() {
    local path="$1"
    local label="${2:-}"
    [[ -e "$path" ]] && rm -rf "$path" 2>/dev/null || true
}
export -f qlmanage cleanup_path
opt_cache_refresh
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Finder and Safari caches updated"* ]]
}

@test "opt_mail_downloads skips cleanup when size below threshold" {
    mkdir -p "$HOME/Library/Mail Downloads"
    # Create small file (below threshold of 5MB)
    echo "test" > "$HOME/Library/Mail Downloads/small.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# MOLE_MAIL_DOWNLOADS_MIN_KB is readonly, defaults to 5120 KB (~5MB)
opt_mail_downloads
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping cleanup"* ]]
    [ -f "$HOME/Library/Mail Downloads/small.txt" ]
}

@test "opt_mail_downloads removes old attachments" {
    mkdir -p "$HOME/Library/Mail Downloads"
    touch "$HOME/Library/Mail Downloads/old.pdf"
    # Make file old (31+ days) - MOLE_LOG_AGE_DAYS defaults to 30
    touch -t 202301010000 "$HOME/Library/Mail Downloads/old.pdf"

    # Create large enough size to trigger cleanup (>5MB threshold)
    dd if=/dev/zero of="$HOME/Library/Mail Downloads/dummy.dat" bs=1024 count=6000 2>/dev/null

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# MOLE_MAIL_DOWNLOADS_MIN_KB and MOLE_LOG_AGE_DAYS are readonly constants
opt_mail_downloads
EOF

    [ "$status" -eq 0 ]
}

@test "get_path_size_kb returns zero for missing directory" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "/nonexistent/path")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_path_size_kb calculates directory size" {
    mkdir -p "$HOME/test_size"
    dd if=/dev/zero of="$HOME/test_size/file.dat" bs=1024 count=10 2>/dev/null

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "$HOME/test_size")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    # Should be >= 10 KB
    [ "$output" -ge 10 ]
}
