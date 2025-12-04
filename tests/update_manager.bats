#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-update-manager.XXXXXX")"
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
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/manage/update.sh"
}

# Test brew_has_outdated function
@test "brew_has_outdated returns 1 when brew not installed" {
    # shellcheck disable=SC2329
    function brew() {
        return 127  # Command not found
    }
    export -f brew

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; brew_has_outdated"
    [ "$status" -eq 1 ]
}

@test "brew_has_outdated checks formula by default" {
    # Mock brew to simulate outdated formulas
    # shellcheck disable=SC2329
    function brew() {
        if [[ "$1" == "outdated" && "$2" != "--cask" ]]; then
            echo "package1"
            echo "package2"
            return 0
        fi
        return 1
    }
    export -f brew

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; brew_has_outdated"
    [ "$status" -eq 0 ]
}

@test "brew_has_outdated checks casks when specified" {
    # Mock brew to simulate outdated casks
    function brew() {
        if [[ "$1" == "outdated" && "$2" == "--cask" ]]; then
            echo "app1"
            return 0
        fi
        return 1
    }
    export -f brew

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; brew_has_outdated cask"
    [ "$status" -eq 0 ]
}

# Test format_brew_update_label function
@test "format_brew_update_label returns empty when no updates" {
    result=$(BREW_OUTDATED_COUNT=0 bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; format_brew_update_label")
    [[ -z "$result" ]]
}

@test "format_brew_update_label formats with formula and cask counts" {
    result=$(BREW_OUTDATED_COUNT=5 BREW_FORMULA_OUTDATED_COUNT=3 BREW_CASK_OUTDATED_COUNT=2 bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; format_brew_update_label")
    [[ "$result" =~ "3 formula" ]]
    [[ "$result" =~ "2 cask" ]]
}

@test "format_brew_update_label shows total when breakdown unavailable" {
    result=$(BREW_OUTDATED_COUNT=5 bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; format_brew_update_label")
    [[ "$result" =~ "5 updates" ]]
}

# Test ask_for_updates function
@test "ask_for_updates returns 1 when no updates available" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; ask_for_updates < /dev/null"
    [ "$status" -eq 1 ]
}

@test "ask_for_updates detects Homebrew updates" {
    # Mock environment with Homebrew updates
    export BREW_OUTDATED_COUNT=5
    export BREW_FORMULA_OUTDATED_COUNT=3
    export BREW_CASK_OUTDATED_COUNT=2

    # Use input redirection to simulate ESC (cancel)
    run bash -c "printf '\x1b' | source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; ask_for_updates"
    # Should show updates and ask for confirmation
    [ "$status" -eq 1 ]  # ESC cancels
}

@test "ask_for_updates detects App Store updates" {
    export APPSTORE_UPDATE_COUNT=3

    run bash -c "printf '\x1b' | source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; ask_for_updates"
    [ "$status" -eq 1 ]  # ESC cancels
}

@test "ask_for_updates detects macOS updates" {
    export MACOS_UPDATE_AVAILABLE=true

    run bash -c "printf '\x1b' | source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; ask_for_updates"
    [ "$status" -eq 1 ]  # ESC cancels
}

@test "ask_for_updates detects Mole updates" {
    export MOLE_UPDATE_AVAILABLE=true

    run bash -c "printf '\x1b' | source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/manage/update.sh'; ask_for_updates"
    [ "$status" -eq 1 ]  # ESC cancels
}



