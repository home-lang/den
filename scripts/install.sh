#!/bin/bash
# Den Shell Installation Script
# Supports both system-wide (/usr/local/bin) and user-local (~/.local/bin) installation

set -euo pipefail

VERSION="${DEN_VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-}"
FORCE="${FORCE:-false}"

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

# Detect OS and architecture
detect_platform() {
    local os arch

    case "$(uname -s)" in
        Linux*)     os="linux" ;;
        Darwin*)    os="darwin" ;;
        *)
            error "Unsupported operating system: $(uname -s)"
            error "Den Shell currently supports Linux and macOS only."
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   arch="x64" ;;
        aarch64|arm64)  arch="arm64" ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            error "Den Shell currently supports x86_64 and ARM64 only."
            exit 1
            ;;
    esac

    echo "${os}-${arch}"
}

# Determine installation directory
determine_install_dir() {
    if [ -n "$INSTALL_DIR" ]; then
        echo "$INSTALL_DIR"
        return
    fi

    # Check if we have write access to /usr/local/bin (system-wide)
    if [ -w "/usr/local/bin" ] || [ "$(id -u)" -eq 0 ]; then
        echo "/usr/local/bin"
    else
        # Fall back to user-local installation
        echo "$HOME/.local/bin"
    fi
}

# Download binary from GitHub releases
download_binary() {
    local platform="$1"
    local install_dir="$2"
    local tmp_dir

    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    info "Downloading Den Shell v${VERSION} for ${platform}..."

    local archive_name="den-${VERSION}-${platform}.tar.gz"
    local download_url

    if [ "$VERSION" = "latest" ]; then
        download_url="https://github.com/stacksjs/den/releases/latest/download/${archive_name}"
    else
        download_url="https://github.com/stacksjs/den/releases/download/v${VERSION}/${archive_name}"
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$download_url" -o "$tmp_dir/$archive_name" || {
            error "Failed to download from $download_url"
            exit 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$download_url" -O "$tmp_dir/$archive_name" || {
            error "Failed to download from $download_url"
            exit 1
        }
    else
        error "Neither curl nor wget is available. Please install one of them."
        exit 1
    fi

    success "Downloaded Den Shell archive"

    # Extract archive
    info "Extracting archive..."
    tar -xzf "$tmp_dir/$archive_name" -C "$tmp_dir"

    # Install binary
    info "Installing to $install_dir..."
    mkdir -p "$install_dir"

    if [ -f "$install_dir/den" ] && [ "$FORCE" != "true" ]; then
        warn "Den Shell is already installed at $install_dir/den"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Installation cancelled"
            exit 1
        fi
    fi

    cp "$tmp_dir/den/den" "$install_dir/den"
    chmod +x "$install_dir/den"

    success "Installed Den Shell to $install_dir/den"
}

# Add to /etc/shells
add_to_shells() {
    local binary_path="$1"

    if [ ! -f "/etc/shells" ]; then
        warn "/etc/shells not found, skipping"
        return
    fi

    if grep -q "^${binary_path}$" /etc/shells 2>/dev/null; then
        info "Den Shell already in /etc/shells"
        return
    fi

    info "Adding Den Shell to /etc/shells..."

    if [ "$(id -u)" -eq 0 ]; then
        echo "$binary_path" >> /etc/shells
        success "Added to /etc/shells"
    else
        warn "Root access required to add to /etc/shells"
        info "Run: sudo sh -c 'echo \"$binary_path\" >> /etc/shells'"
    fi
}

# Update PATH if needed
update_path() {
    local install_dir="$1"

    if echo "$PATH" | grep -q "$install_dir"; then
        return
    fi

    info "Adding $install_dir to PATH..."

    local shell_rc
    case "$SHELL" in
        */bash)
            shell_rc="$HOME/.bashrc"
            ;;
        */zsh)
            shell_rc="$HOME/.zshrc"
            ;;
        */fish)
            shell_rc="$HOME/.config/fish/config.fish"
            warn "Fish shell detected. Please add manually:"
            info "  set -gx PATH $install_dir \$PATH"
            return
            ;;
        *)
            shell_rc="$HOME/.profile"
            ;;
    esac

    if [ -f "$shell_rc" ]; then
        if ! grep -q "$install_dir" "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "# Den Shell" >> "$shell_rc"
            echo "export PATH=\"$install_dir:\$PATH\"" >> "$shell_rc"
            success "Added to $shell_rc"
            warn "Please restart your shell or run: source $shell_rc"
        fi
    else
        warn "Shell configuration file not found: $shell_rc"
        info "Please add manually: export PATH=\"$install_dir:\$PATH\""
    fi
}

# Main installation function
main() {
    echo ""
    echo "╔═══════════════════════════════════╗"
    echo "║   Den Shell Installation Script  ║"
    echo "╚═══════════════════════════════════╝"
    echo ""

    # Detect platform
    local platform
    platform=$(detect_platform)
    info "Detected platform: $platform"

    # Determine install directory
    local install_dir
    install_dir=$(determine_install_dir)
    info "Installation directory: $install_dir"

    # Download and install binary
    download_binary "$platform" "$install_dir"

    # Add to /etc/shells
    add_to_shells "$install_dir/den"

    # Update PATH if needed
    if [ "$install_dir" != "/usr/local/bin" ]; then
        update_path "$install_dir"
    fi

    echo ""
    success "Den Shell v${VERSION} installed successfully!"
    echo ""
    info "To get started:"
    echo "  $ den              # Start interactive shell"
    echo "  $ den --help       # Show help"
    echo "  $ den version      # Show version"
    echo ""

    # Check if binary is in PATH
    if command -v den >/dev/null 2>&1; then
        success "Den Shell is in your PATH and ready to use!"
    else
        warn "Den Shell is not in your PATH yet"
        info "Restart your shell or run: export PATH=\"$install_dir:\$PATH\""
    fi

    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --force|-f)
            FORCE="true"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --version VERSION       Install specific version (default: latest)"
            echo "  --install-dir DIR       Install to specific directory"
            echo "  --force, -f             Force overwrite existing installation"
            echo "  --help, -h              Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Install latest to auto-detected location"
            echo "  $0 --version 0.1.0                   # Install specific version"
            echo "  $0 --install-dir /usr/local/bin     # Install system-wide"
            echo "  $0 --install-dir ~/.local/bin       # Install user-local"
            echo ""
            echo "Environment variables:"
            echo "  DEN_VERSION             Version to install (default: latest)"
            echo "  INSTALL_DIR             Installation directory"
            echo "  FORCE                   Force overwrite (true/false)"
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
