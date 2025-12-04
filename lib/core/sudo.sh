#!/bin/bash
# Sudo Session Manager
# Unified sudo authentication and keepalive management

set -euo pipefail

# Global state
MOLE_SUDO_KEEPALIVE_PID=""
MOLE_SUDO_ESTABLISHED="false"

# Start sudo keepalive background process
# Returns: PID of keepalive process
_start_sudo_keepalive() {
    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: _start_sudo_keepalive: starting background process..." >&2

    # Start background keepalive process with all outputs redirected
    # This is critical: command substitution waits for all file descriptors to close
    (
        # Initial delay to let sudo cache stabilize after password entry
        # This prevents immediately triggering Touch ID again
        sleep 2

        local retry_count=0
        while true; do
            if ! sudo -n -v 2> /dev/null; then
                ((retry_count++))
                if [[ $retry_count -ge 3 ]]; then
                    exit 1
                fi
                sleep 5
                continue
            fi
            retry_count=0
            sleep 30
            kill -0 "$$" 2> /dev/null || exit
        done
    ) > /dev/null 2>&1 &

    local pid=$!
    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: _start_sudo_keepalive: background PID = $pid" >&2
    echo $pid
}

# Stop sudo keepalive process
# Args: $1 - PID of keepalive process
_stop_sudo_keepalive() {
    local pid="${1:-}"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2> /dev/null || true
        wait "$pid" 2> /dev/null || true
    fi
}

# Check if sudo session is active
has_sudo_session() {
    sudo -n true 2> /dev/null
}

# Request sudo access (wrapper for common.sh function)
# Args: $1 - prompt message
request_sudo() {
    local prompt_msg="${1:-Admin access required}"

    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: request_sudo: checking existing session..."

    if has_sudo_session; then
        [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: request_sudo: session already exists"
        return 0
    fi

    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: request_sudo: calling request_sudo_access from common.sh..."

    # Use the robust implementation from common.sh
    if request_sudo_access "$prompt_msg"; then
        [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: request_sudo: request_sudo_access succeeded"
        return 0
    else
        [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: request_sudo: request_sudo_access failed"
        return 1
    fi
}

# Ensure sudo session is established with keepalive
# Args: $1 - prompt message
ensure_sudo_session() {
    local prompt="${1:-Admin access required}"

    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: ensure_sudo_session called"

    # Check if already established
    if has_sudo_session && [[ "$MOLE_SUDO_ESTABLISHED" == "true" ]]; then
        [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: Sudo session already active"
        return 0
    fi

    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: Checking for old keepalive..."

    # Stop old keepalive if exists
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: Stopping old keepalive PID $MOLE_SUDO_KEEPALIVE_PID"
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi

    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: Calling request_sudo..."

    # Request sudo access
    if ! request_sudo "$prompt"; then
        [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: request_sudo failed"
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: request_sudo succeeded, starting keepalive..."

    # Start keepalive
    MOLE_SUDO_KEEPALIVE_PID=$(_start_sudo_keepalive)

    [[ "${MO_DEBUG:-}" == "1" ]] && echo "DEBUG: Keepalive started with PID $MOLE_SUDO_KEEPALIVE_PID"

    MOLE_SUDO_ESTABLISHED="true"
    return 0
}

# Stop sudo session and cleanup
stop_sudo_session() {
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi
    MOLE_SUDO_ESTABLISHED="false"
}

# Register cleanup on script exit
register_sudo_cleanup() {
    trap stop_sudo_session EXIT INT TERM
}

# Check if sudo is likely needed for given operations
# Args: $@ - list of operations to check
will_need_sudo() {
    local -a operations=("$@")
    for op in "${operations[@]}"; do
        case "$op" in
            system_update | appstore_update | macos_update | firewall | touchid | rosetta | system_fix)
                return 0
                ;;
        esac
    done
    return 1
}
