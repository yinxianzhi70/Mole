# Contributing to Mole

## Setup

```bash
# Install development tools
brew install shfmt shellcheck bats-core
```

## Development

Run all quality checks before committing:

```bash
./scripts/check.sh
```

This command runs:

- Code formatting check
- ShellCheck linting
- Unit tests

Individual commands:

```bash
# Format code
./scripts/format.sh

# Run tests only
./tests/run.sh
```

## Code Style

- Bash 3.2+ compatible
- 4 spaces indent
- Use `set -euo pipefail`
- Quote all variables
- BSD commands not GNU

Config: `.editorconfig` and `.shellcheckrc`

## Requirements

- macOS 10.14 or newer, works on Intel and Apple Silicon
- Default macOS Bash 3.2+ plus administrator privileges for cleanup tasks
- Install Command Line Tools with `xcode-select --install` for curl, tar, and related utilities
- Go 1.24+ required when building the `mo status` or `mo analyze` TUI binaries locally

## Go Components

`mo status` and `mo analyze` use Go with Bubble Tea for interactive dashboards.

**Code organization:**

- Each module split into focused files by responsibility
- `cmd/analyze/` - Disk analyzer with 7 files under 500 lines each
- `cmd/status/` - System monitor with metrics split into 11 domain files

**Development workflow:**

- Format code with `gofmt -w ./cmd/...`
- Run `go vet ./cmd/...` to check for issues
- Build with `go build ./...` to verify all packages compile
- Build universal binaries via `./scripts/build-status.sh` and `./scripts/build-analyze.sh`

**Guidelines:**

- Keep files focused on single responsibility
- Extract constants instead of magic numbers
- Use context for timeout control on external commands
- Add comments explaining why, not what

## Pull Requests

1. Fork and create branch
2. Make changes
3. Run checks: `./scripts/check.sh`
4. Commit and push
5. Open PR

CI will verify formatting, linting, and tests.
