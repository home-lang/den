#!/bin/bash
# Den Shell Uninstallation Script
# Removes Den Shell from system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
info() {
    echo -e "${BLUE}ℹ${NC}  $*"
}

success() {
    echo -e "${GREEN}✓${NC}  $*"
}

warn() {
    echo -e "${YELLOW}⚠${NC}  $*"
}

error() {
    echo -e "${RED}✗${NC}  $*" >&2
}

# Find Den Shell installation
find_installation() {
    local locations=(
        "/usr/local/bin/den"
        "$HOME/.local/bin/den"
        "/usr/bin/den"
        "/opt/den/bin/den"
    )

    for location in "${locations[@]}"; do
        if [ -f "$location" ]; then
            echo "$location"
            return 0
        fi
    done

    # Check if den is in PATH
    if command -v den >/dev/null 2>&1; then
        which den
        return 0
    fi

    return 1
}

# Remove from /etc/shells
remove_from_shells() {
    local binary_path="$1"

    if [ ! -f "/etc/shells" ]; then
        return
    fi

    if ! grep -q "^${binary_path}$" /etc/shells 2>/dev/null; then
        return
    fi

    info "Removing from /etc/shells..."

    if [ "$(id -u)" -eq 0 ]; then
        # Create temporary file without the den entry
        grep -v "^${binary_path}$" /etc/shells > /tmp/shells.tmp
        mv /tmp/shells.tmp /etc/shells
        success "Removed from /etc/shells"
    else
        warn "Root access required to remove from /etc/shells"
        info "Run: sudo sed -i.bak \"\\|^${binary_path}\$|d\" /etc/shells"
    fi
}

# Remove PATH entries from shell configs
remove_from_path() {
    local install_dir="$1"

    local shell_configs=(
        "$HOME/.bashrc"
        "$HOME/.zshrc"
        "$HOME/.profile"
    )

    for config in "${shell_configs[@]}"; do
        if [ ! -f "$config" ]; then
            continue
        fi

        if grep -q "$install_dir" "$config" 2>/dev/null; then
            info "Removing PATH entry from $config..."

            # Create backup
            cp "$config" "${config}.bak"

            # Remove Den Shell PATH entries
            sed -i.tmp "/# Den Shell/d" "$config"
            sed -i.tmp "\\|${install_dir}|d" "$config"
            rm -f "${config}.tmp"

            success "Removed from $config (backup: ${config}.bak)"
        fi
    done
}

# Clean up configuration and data
cleanup_data() {
    local items_to_remove=(
        "$HOME/.den_history"
        "$HOME/.config/den"
        "$HOME/.local/share/den"
    )

    local found_data=false

    for item in "${items_to_remove[@]}"; do
        if [ -e "$item" ]; then
            found_data=true
            break
        fi
    done

    if [ "$found_data" = false ]; then
        return
    fi

    echo ""
    warn "Den Shell configuration and data found:"
    for item in "${items_to_remove[@]}"; do
        if [ -e "$item" ]; then
            echo "  - $item"
        fi
    done

    read -p "Remove these files? [y/N] " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for item in "${items_to_remove[@]}"; do
            if [ -e "$item" ]; then
                rm -rf "$item"
                success "Removed $item"
            fi
        done
    else
        info "Keeping user data"
    fi
}

# Main uninstallation function
main() {
    echo ""
    echo "╔═══════════════════════════════════╗"
    echo "║ Den Shell Uninstallation Script  ║"
    echo "╚═══════════════════════════════════╝"
    echo ""

    # Find installation
    local binary_path
    if ! binary_path=$(find_installation); then
        error "Den Shell is not installed or could not be found"
        exit 1
    fi

    info "Found Den Shell at: $binary_path"

    # Confirm uninstallation
    echo ""
    read -p "Are you sure you want to uninstall Den Shell? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Uninstallation cancelled"
        exit 0
    fi

    # Get installation directory
    local install_dir
    install_dir=$(dirname "$binary_path")

    # Remove binary
    info "Removing binary..."
    if [ -w "$binary_path" ]; then
        rm -f "$binary_path"
        success "Removed $binary_path"
    else
        warn "Cannot remove $binary_path (permission denied)"
        info "Run: sudo rm $binary_path"
    fi

    # Remove from /etc/shells
    remove_from_shells "$binary_path"

    # Remove PATH entries
    if [ "$install_dir" != "/usr/local/bin" ] && [ "$install_dir" != "/usr/bin" ]; then
        remove_from_path "$install_dir"
    fi

    # Clean up user data
    cleanup_data

    echo ""
    success "Den Shell has been uninstalled"
    echo ""
    info "If you used Den Shell as your default shell, remember to change it back:"
    echo "  $ chsh -s /bin/bash    # or /bin/zsh, etc."
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Uninstalls Den Shell from your system."
            echo ""
            echo "Options:"
            echo "  --help, -h              Show this help"
            echo ""
            echo "The script will:"
            echo "  1. Find Den Shell installation"
            echo "  2. Remove the binary"
            echo "  3. Remove from /etc/shells (if present)"
            echo "  4. Remove PATH entries from shell configs"
            echo "  5. Optionally remove user data and configuration"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Run '$0 --help' for usage information"
            exit 1
            ;;
    esac
done

main
