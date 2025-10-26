#!/bin/sh
# Den Shell Wrapper Script
# For use in non-login shell contexts (e.g., scripts, automation, IDEs)
#
# This wrapper ensures Den Shell runs with a minimal environment suitable
# for non-interactive use while maintaining compatibility with login shells.

# Determine the actual den binary location
DEN_BIN="${DEN_BIN:-den}"

# Check if den is in PATH or use absolute path
if ! command -v "$DEN_BIN" >/dev/null 2>&1; then
    # Try common installation locations
    for location in "/usr/local/bin/den" "$HOME/.local/bin/den" "/usr/bin/den"; do
        if [ -x "$location" ]; then
            DEN_BIN="$location"
            break
        fi
    done
fi

# Verify den binary exists
if ! command -v "$DEN_BIN" >/dev/null 2>&1; then
    echo "Error: Den Shell binary not found" >&2
    echo "Please ensure Den Shell is installed or set DEN_BIN environment variable" >&2
    exit 127
fi

# Set minimal environment for non-interactive use
export DEN_NONINTERACTIVE=1

# Preserve important environment variables
export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}"
export HOME="${HOME:-$(cd ~ && pwd)}"
export USER="${USER:-$(whoami)}"

# Execute den with all arguments
exec "$DEN_BIN" "$@"
