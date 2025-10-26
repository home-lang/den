#!/bin/bash
# Build Debian package for Den Shell

set -euo pipefail

VERSION="${1:-0.1.0}"
ARCH="${2:-amd64}"  # amd64 or arm64
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/deb"

echo "Building Den Shell .deb package"
echo "Version: $VERSION"
echo "Architecture: $ARCH"
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/den_${VERSION}_${ARCH}"

# Create package directory structure
PKG_DIR="$BUILD_DIR/den_${VERSION}_${ARCH}"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/usr/share/doc/den"
mkdir -p "$PKG_DIR/usr/share/man/man1"

# Copy binary
if [ "$ARCH" = "amd64" ]; then
    BINARY="$PROJECT_ROOT/zig-out/release/linux-x64/den"
else
    BINARY="$PROJECT_ROOT/zig-out/release/linux-arm64/den"
fi

if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    echo "Run 'zig build release' first"
    exit 1
fi

cp "$BINARY" "$PKG_DIR/usr/bin/den"
chmod 755 "$PKG_DIR/usr/bin/den"

# Copy control file
sed "s/Architecture: amd64/Architecture: $ARCH/" \
    "$SCRIPT_DIR/debian/control" > "$PKG_DIR/DEBIAN/control"

# Copy post-install and post-remove scripts
cp "$SCRIPT_DIR/debian/postinst" "$PKG_DIR/DEBIAN/postinst"
cp "$SCRIPT_DIR/debian/postrm" "$PKG_DIR/DEBIAN/postrm"
chmod 755 "$PKG_DIR/DEBIAN/postinst"
chmod 755 "$PKG_DIR/DEBIAN/postrm"

# Copy documentation
if [ -f "$PROJECT_ROOT/README.md" ]; then
    cp "$PROJECT_ROOT/README.md" "$PKG_DIR/usr/share/doc/den/"
fi
if [ -f "$PROJECT_ROOT/LICENSE" ]; then
    cp "$PROJECT_ROOT/LICENSE" "$PKG_DIR/usr/share/doc/den/copyright"
fi

# Create changelog
cat > "$PKG_DIR/usr/share/doc/den/changelog.Debian" <<EOF
den ($VERSION) unstable; urgency=low

  * Initial release

 -- Stacks.js <support@stacksjs.org>  $(date -R)
EOF
gzip -9 "$PKG_DIR/usr/share/doc/den/changelog.Debian"

# Build package
echo "Building package..."
dpkg-deb --build "$PKG_DIR"

# Move to dist
mkdir -p "$PROJECT_ROOT/dist"
mv "$BUILD_DIR/den_${VERSION}_${ARCH}.deb" "$PROJECT_ROOT/dist/"

echo ""
echo "✅ Package built: dist/den_${VERSION}_${ARCH}.deb"
echo ""
echo "To install:"
echo "  sudo dpkg -i dist/den_${VERSION}_${ARCH}.deb"
echo ""
echo "To install dependencies if needed:"
echo "  sudo apt-get install -f"
