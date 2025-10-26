#!/bin/bash
# Build RPM package for Den Shell

set -euo pipefail

VERSION="${1:-0.1.0}"
ARCH="${2:-x86_64}"  # x86_64 or aarch64
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Building Den Shell RPM package"
echo "Version: $VERSION"
echo "Architecture: $ARCH"
echo ""

# Setup RPM build environment
RPMBUILD_DIR="$HOME/rpmbuild"
mkdir -p "$RPMBUILD_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Create source tarball
SOURCE_DIR="$RPMBUILD_DIR/SOURCES"
TAR_NAME="den-$VERSION-linux-$ARCH"

mkdir -p "/tmp/$TAR_NAME/den"

if [ "$ARCH" = "x86_64" ]; then
    BINARY="$PROJECT_ROOT/zig-out/release/linux-x64/den"
else
    BINARY="$PROJECT_ROOT/zig-out/release/linux-arm64/den"
fi

if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    echo "Run 'zig build release' first"
    exit 1
fi

cp "$BINARY" "/tmp/$TAR_NAME/den/"
tar -czf "$SOURCE_DIR/$TAR_NAME.tar.gz" -C "/tmp" "$TAR_NAME"
rm -rf "/tmp/$TAR_NAME"

# Copy spec file
cp "$SCRIPT_DIR/den.spec" "$RPMBUILD_DIR/SPECS/"

# Build RPM
echo "Building RPM..."
rpmbuild -ba "$RPMBUILD_DIR/SPECS/den.spec"

# Copy to dist
mkdir -p "$PROJECT_ROOT/dist"
cp "$RPMBUILD_DIR/RPMS/$ARCH/den-${VERSION}-1."*".${ARCH}.rpm" "$PROJECT_ROOT/dist/" || true
cp "$RPMBUILD_DIR/RPMS/noarch/den-${VERSION}-1."*".noarch.rpm" "$PROJECT_ROOT/dist/" || true

echo ""
echo "✅ RPM package built"
echo ""
echo "Package location: $RPMBUILD_DIR/RPMS/$ARCH/"
ls -lh "$RPMBUILD_DIR/RPMS/$ARCH/"*.rpm 2>/dev/null || echo "Check $RPMBUILD_DIR/RPMS/ for packages"
echo ""
echo "To install:"
echo "  sudo rpm -i $RPMBUILD_DIR/RPMS/$ARCH/den-${VERSION}-1.*.rpm"
echo "  or"
echo "  sudo dnf install $RPMBUILD_DIR/RPMS/$ARCH/den-${VERSION}-1.*.rpm"
