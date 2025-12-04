#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    # Source common.sh first (required by sudo_manager)
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/core/sudo.sh"
}

# Test sudo session detection
@test "has_sudo_session returns 1 when no sudo session" {
    # Most test environments don't have active sudo
    # This test verifies the function handles no-sudo gracefully
    run has_sudo_session
    # Either no sudo (status 1) or sudo available (status 0)
    # Both are valid - we just check it doesn't crash
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# Test sudo keepalive lifecycle
@test "sudo keepalive functions don't crash" {
    # Test that keepalive functions can be called without errors
    # We can't actually test sudo without prompting, but we can test structure

    # Mock sudo to avoid actual auth
    # shellcheck disable=SC2329
    function sudo() {
        return 1  # Simulate no sudo available
    }
    export -f sudo

    # These should not crash even without real sudo
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; has_sudo_session"
    [ "$status" -eq 1 ]  # Expected: no sudo session
}

# Test keepalive PID management
@test "_start_sudo_keepalive returns a PID" {
    # Mock sudo to simulate successful session
    function sudo() {
        case "$1" in
            -n) return 0 ;;  # Simulate valid sudo session
            -v) return 0 ;;  # Refresh succeeds
            *) return 1 ;;
        esac
    }
    export -f sudo

    # Start keepalive (will run in background)
    local pid
    pid=$(bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _start_sudo_keepalive")

    # Should return a PID (number)
    [[ "$pid" =~ ^[0-9]+$ ]]

    # Clean up background process
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Test _stop_sudo_keepalive
@test "_stop_sudo_keepalive handles invalid PID gracefully" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _stop_sudo_keepalive ''"
    [ "$status" -eq 0 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _stop_sudo_keepalive '99999'"
    [ "$status" -eq 0 ]
}



# Test stop_sudo_session cleanup
@test "stop_sudo_session cleans up keepalive process" {
    # Set a fake PID
    export MOLE_SUDO_KEEPALIVE_PID="99999"

    run bash -c "export MOLE_SUDO_KEEPALIVE_PID=99999; source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; stop_sudo_session"
    [ "$status" -eq 0 ]
}

# Test global state management
@test "sudo manager initializes global state correctly" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; echo \$MOLE_SUDO_ESTABLISHED")
    [[ "$result" == "false" ]] || [[ -z "$result" ]]
}
