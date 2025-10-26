#!/bin/bash
# Release script for Den Shell
# Builds binaries for all platforms, creates archives, and generates checksums

set -euo pipefail

VERSION="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$PROJECT_ROOT/zig-out/release"
DIST_DIR="$PROJECT_ROOT/dist"

echo "🚀 Den Shell Release Builder"
echo "================================"
echo "Version: $VERSION"
echo ""

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf "$RELEASE_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build all release targets
echo "🔨 Building release binaries for all platforms..."
cd "$PROJECT_ROOT"
zig build release

# Check if builds succeeded
if [ ! -d "$RELEASE_DIR" ]; then
    echo "❌ Error: Release directory not found. Build may have failed."
    exit 1
fi

# Package each platform
echo ""
echo "📦 Creating release archives..."

declare -a PLATFORMS=(
    "linux-x64:den:tar.gz"
    "linux-arm64:den:tar.gz"
    "darwin-x64:den:tar.gz"
    "darwin-arm64:den:tar.gz"
    # Windows support deferred - requires Windows-specific process management
    # "windows-x64:den.exe:zip"
)

for platform_config in "${PLATFORMS[@]}"; do
    IFS=: read -r platform binary_name archive_type <<< "$platform_config"

    platform_dir="$RELEASE_DIR/$platform"

    if [ ! -d "$platform_dir" ]; then
        echo "⚠️  Warning: $platform directory not found, skipping..."
        continue
    fi

    echo "  📦 Packaging $platform..."

    binary_path="$platform_dir/$binary_name"
    if [ ! -f "$binary_path" ]; then
        echo "⚠️  Warning: Binary not found at $binary_path, skipping..."
        continue
    fi

    # Create a temporary directory for the archive contents
    temp_dir="$DIST_DIR/tmp-$platform"
    mkdir -p "$temp_dir/den"

    # Copy binary
    cp "$binary_path" "$temp_dir/den/"

    # Copy additional files if they exist
    [ -f "$PROJECT_ROOT/README.md" ] && cp "$PROJECT_ROOT/README.md" "$temp_dir/den/" || true
    [ -f "$PROJECT_ROOT/LICENSE" ] && cp "$PROJECT_ROOT/LICENSE" "$temp_dir/den/" || true

    # Create version file
    echo "$VERSION" > "$temp_dir/den/VERSION"

    # Create archive
    archive_name="den-$VERSION-$platform"

    if [ "$archive_type" = "tar.gz" ]; then
        tar -czf "$DIST_DIR/${archive_name}.tar.gz" -C "$temp_dir" den
        echo "    ✅ Created ${archive_name}.tar.gz"
    else
        (cd "$temp_dir" && zip -r "$DIST_DIR/${archive_name}.zip" den > /dev/null)
        echo "    ✅ Created ${archive_name}.zip"
    fi

    # Cleanup temp directory
    rm -rf "$temp_dir"
done

# Generate checksums
echo ""
echo "🔐 Generating checksums..."
cd "$DIST_DIR"

# Create checksums file
checksums_file="checksums-$VERSION.txt"
rm -f "$checksums_file"

for archive in *.tar.gz *.zip; do
    [ -e "$archive" ] || continue
    echo "  🔐 $archive"
    sha256sum "$archive" >> "$checksums_file"
done

if [ -f "$checksums_file" ]; then
    echo ""
    echo "✅ Checksums saved to $checksums_file"
    echo ""
    cat "$checksums_file"
fi

# Summary
echo ""
echo "================================"
echo "✅ Release build complete!"
echo ""
echo "📦 Archives created in: $DIST_DIR"
ls -lh "$DIST_DIR"/*.{tar.gz,zip} 2>/dev/null || true
echo ""
echo "🔐 Checksums: $DIST_DIR/$checksums_file"
echo ""
echo "Ready for distribution! 🎉"
