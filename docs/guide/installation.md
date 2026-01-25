# Installation

Den can be built from source using the Zig build system. This guide covers all installation methods.

## Requirements

- **Zig 0.16-dev** or later
- **macOS, Linux, or BSD** (Windows support planned)

## Building from Source

### Quick Build

```bash
# Clone the repository
git clone https://github.com/stacksjs/den.git
cd den

# Build Den (debug build)
zig build

# The binary will be at ./zig-out/bin/den
./zig-out/bin/den
```

### Release Build

For production use, build with optimizations:

```bash
# Optimized build for maximum performance
zig build -Doptimize=ReleaseFast
```

### Install System-Wide

Install Den to your local bin directory:

```bash
# Install to ~/.local/bin
zig build install --prefix ~/.local

# Or install to /usr/local
sudo zig build install --prefix /usr/local
```

Add to your PATH if needed:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Build Options

| Option | Description | Default |
|--------|-------------|---------|
| `-Doptimize=Debug` | Debug build with symbols | Yes |
| `-Doptimize=ReleaseFast` | Maximum performance | No |
| `-Doptimize=ReleaseSafe` | Performance with safety checks | No |
| `-Doptimize=ReleaseSmall` | Smallest binary size | No |

## Running Tests

Verify your build with the test suite:

```bash
zig build test
```

## Verifying Installation

After installation, verify Den is working:

```bash
den --version
# or
den --help
```

## Setting as Default Shell

To use Den as your default shell:

1. Add Den to `/etc/shells`:

```bash
# Find where den is installed
which den

# Add to shells list (requires sudo)
echo /path/to/den | sudo tee -a /etc/shells
```

2. Change your default shell:

```bash
chsh -s /path/to/den
```

## Uninstalling

To remove Den:

```bash
# If installed with prefix
rm ~/.local/bin/den

# Or remove from /usr/local
sudo rm /usr/local/bin/den
```

## Troubleshooting

### Zig Version Issues

Make sure you have Zig 0.16-dev or later:

```bash
zig version
```

If you have an older version, download the latest from [ziglang.org](https://ziglang.org/download/).

### Build Errors

If you encounter build errors:

1. Clean the build cache:
   ```bash
   rm -rf zig-cache zig-out
   ```

2. Rebuild:
   ```bash
   zig build
   ```

### Permission Errors

If you get permission errors when setting as default shell, ensure:

1. Den is in `/etc/shells`
2. The Den binary is executable (`chmod +x /path/to/den`)

## Next Steps

Now that Den is installed, proceed to the [Quick Start](/guide/quick-start) guide to learn the basics.
