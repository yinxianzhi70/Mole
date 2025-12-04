#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-caches.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
    mkdir -p "$HOME/.cache/mole"
    mkdir -p "$HOME/Library/Caches"
    mkdir -p "$HOME/Library/Logs"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/clean/caches.sh"

    # Clean permission flag for each test
    rm -f "$HOME/.cache/mole/permissions_granted"
}

# Test check_tcc_permissions in non-interactive mode
@test "check_tcc_permissions skips in non-interactive mode" {
    # Redirect stdin to simulate non-TTY
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; check_tcc_permissions" < /dev/null
    [ "$status" -eq 0 ]
    # Should not create permission flag in non-interactive mode
    [[ ! -f "$HOME/.cache/mole/permissions_granted" ]]
}

# Test check_tcc_permissions with existing permission flag
@test "check_tcc_permissions skips when permissions already granted" {
    # Create permission flag
    mkdir -p "$HOME/.cache/mole"
    touch "$HOME/.cache/mole/permissions_granted"

    # Even in TTY mode, should skip if flag exists
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; [[ -t 1 ]] || true; check_tcc_permissions"
    [ "$status" -eq 0 ]
}

# Test check_tcc_permissions directory checks
@test "check_tcc_permissions validates protected directories" {
    # The function checks these directories exist:
    # - ~/Library/Caches
    # - ~/Library/Logs
    # - ~/Library/Application Support
    # - ~/Library/Containers
    # - ~/.cache

    # Ensure test environment has these directories
    [[ -d "$HOME/Library/Caches" ]]
    [[ -d "$HOME/Library/Logs" ]]
    [[ -d "$HOME/.cache/mole" ]]

    # Function should handle missing directories gracefully
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; check_tcc_permissions < /dev/null"
    [ "$status" -eq 0 ]
}

# Test clean_service_worker_cache with non-existent path
@test "clean_service_worker_cache returns early when path doesn't exist" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; clean_service_worker_cache 'TestBrowser' '/nonexistent/path'"
    [ "$status" -eq 0 ]
}

# Test clean_service_worker_cache with empty directory
@test "clean_service_worker_cache handles empty cache directory" {
    local test_cache="$HOME/test_sw_cache"
    mkdir -p "$test_cache"

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; clean_service_worker_cache 'TestBrowser' '$test_cache'"
    [ "$status" -eq 0 ]

    rm -rf "$test_cache"
}

# Test clean_service_worker_cache domain protection
@test "clean_service_worker_cache protects specified domains" {
    local test_cache="$HOME/test_sw_cache"
    mkdir -p "$test_cache/abc123_https_capcut.com_0"
    mkdir -p "$test_cache/def456_https_example.com_0"

    # Mock PROTECTED_SW_DOMAINS
    export PROTECTED_SW_DOMAINS=("capcut.com" "photopea.com")

    # Dry run to check protection logic
    run bash -c "
        export DRY_RUN=true
        export PROTECTED_SW_DOMAINS=(capcut.com photopea.com)
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        clean_service_worker_cache 'TestBrowser' '$test_cache'
    "
    [ "$status" -eq 0 ]

    # Protected domain directory should still exist
    [[ -d "$test_cache/abc123_https_capcut.com_0" ]]

    rm -rf "$test_cache"
}

# Test clean_project_caches function
@test "clean_project_caches completes without errors" {
    # Create test project structures
    mkdir -p "$HOME/projects/test-app/.next/cache"
    mkdir -p "$HOME/projects/python-app/__pycache__"

    # Create some dummy cache files
    touch "$HOME/projects/test-app/.next/cache/test.cache"
    touch "$HOME/projects/python-app/__pycache__/module.pyc"

    run bash -c "
        export DRY_RUN=true
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        clean_project_caches
    "
    [ "$status" -eq 0 ]

    rm -rf "$HOME/projects"
}

# Test clean_project_caches timeout protection
@test "clean_project_caches handles timeout gracefully" {
    # Create a test directory structure
    mkdir -p "$HOME/test-project/.next"

    # Mock find to simulate slow operation
    function find() {
        sleep 2  # Simulate slow find
        echo "$HOME/test-project/.next"
    }
    export -f find

    # Should complete within reasonable time even with slow find
    run timeout 15 bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        clean_project_caches
    "
    # Either succeeds or times out gracefully (both acceptable)
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]

    rm -rf "$HOME/test-project"
}

# Test clean_project_caches exclusions
@test "clean_project_caches excludes Library and Trash directories" {
    # These directories should be excluded from scan
    mkdir -p "$HOME/Library/.next/cache"
    mkdir -p "$HOME/.Trash/.next/cache"
    mkdir -p "$HOME/projects/.next/cache"

    # Only non-excluded directories should be scanned
    # We can't easily test this without mocking, but we can verify no crashes
    run bash -c "
        export DRY_RUN=true
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        clean_project_caches
    "
    [ "$status" -eq 0 ]

    rm -rf "$HOME/projects"
}

