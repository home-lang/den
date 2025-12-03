# Continuous Integration & Deployment

Den Shell uses GitHub Actions for comprehensive CI/CD automation across multiple platforms.

## Table of Contents

- [Overview](#overview)
- [Workflows](#workflows)
- [Build Matrix](#build-matrix)
- [Testing](#testing)
- [Releases](#releases)
- [Contributing](#contributing)

---

## Overview

Our CI/CD pipeline ensures code quality, cross-platform compatibility, and automated releases through four main workflows:

1. **CI** - TypeScript/JavaScript linting and testing
2. **Tests** - Zig build and unit tests across platforms
3. **Integration** - End-to-end and integration testing
4. **Release** - Automated multi-platform releases

---

## Workflows

### CI Workflow

**File:** `.github/workflows/ci.yml`

**Triggers:**
- Push to `main` branch
- Pull requests to `main`

**Jobs:**

1. **Lint** - ESLint and code formatting checks
2. **Typecheck** - TypeScript type checking
3. **Test** - Unit tests with Bun
4. **Publish Commit** - Preview deployments

**Platform:** Ubuntu Latest

---

### Test Workflow

**File:** `.github/workflows/test.yml`

**Triggers:**
- Push to `main` or `develop` branches
- Pull requests to `main` or `develop`

**Jobs:**

1. **Run Tests**
   - Platforms: Ubuntu, macOS, Windows
   - Zig version: 0.16-dev
   - Tests all core modules:
     - Tokenizer tests
     - Parser tests
     - Expander tests
     - Executor tests
     - Plugin tests
     - Hook tests
     - Theme tests

2. **Code Coverage**
   - Platform: Ubuntu Latest
   - Generates coverage reports
   - Uploads to Codecov

3. **Lint and Format Check**
   - Platform: Ubuntu Latest
   - Runs `zig fmt --check .`

4. **Build Release**
   - Platforms: Ubuntu, macOS
   - Builds release binaries
   - Uploads artifacts

**Caching:**
- Zig artifacts cached per OS and version
- Significantly reduces build times

---

### Integration Test Workflow

**File:** `.github/workflows/integration.yml`

**Triggers:**
- Push to `main` or `develop` branches
- Pull requests to `main` or `develop`
- Scheduled daily at 2 AM UTC

**Jobs:**

#### 1. Integration Tests

**Platforms:** Ubuntu, macOS, Windows

Tests include:
- **Shell startup**: Verify shell initializes correctly
- **Builtin commands**: `pwd`, `echo`, `cd`
- **ls command**: All flags (`-l`, `-la`, `-lart`)
- **Productivity builtins**: `date`, `calc`, `seq`
- **File operations**: Create, read, delete files
- **Environment variables**: `export` and variable expansion
- **Command chaining**: `&&`, `||` operators
- **Pipes**: Command piping functionality
- **Script execution**: Shell script compatibility

#### 2. End-to-End Shell Session

**Platform:** Ubuntu Latest

Comprehensive workflow testing:
```bash
# Basic commands
pwd
echo 'Hello World'

# Directory navigation
cd test_dir && pwd

# File manipulation
echo 'test' > temp.txt
cat temp.txt
rm temp.txt

# Builtins
calc 10 + 20
seq 1 3
date

# Complex commands
ls -la | head -5
echo 'test' && echo 'success'
```

#### 3. Plugin Integration

**Platform:** Ubuntu Latest

- Tests plugin loading and execution
- Validates hook system
- Placeholder for future plugin tests

#### 4. Performance Benchmarks

**Platform:** Ubuntu Latest

Benchmarks:
- **Startup time**: Time to initialize shell
- **Command execution**: Time for command processing
- **ls performance**: Directory listing speed

---

### Release Workflow

**File:** `.github/workflows/release.yml`

**Triggers:**
- Tag push matching `v*` pattern (e.g., `v1.0.0`)

**Permissions:**
- `contents: write` for creating releases

**Process:**

1. **Checkout code** with full history
2. **Setup Zig** (version 0.16-dev)
3. **Extract version** from git tag
4. **Build release binaries** for all platforms:
   - Linux x64
   - Linux ARM64
   - macOS x64 (Intel)
   - macOS ARM64 (Apple Silicon)
   - Windows x64

5. **Create release archives**:
   - `.tar.gz` for Unix/Linux/macOS
   - `.zip` for Windows
   - Include README, LICENSE, VERSION file

6. **Generate checksums** (SHA-256)

7. **Create GitHub Release** with:
   - Release notes from CHANGELOG.md
   - All platform binaries
   - Checksum file

**Output artifacts:**
```
dist/den-1.0.0-linux-x64.tar.gz
dist/den-1.0.0-linux-arm64.tar.gz
dist/den-1.0.0-darwin-x64.tar.gz
dist/den-1.0.0-darwin-arm64.tar.gz
dist/den-1.0.0-windows-x64.zip
dist/checksums-1.0.0.txt
```

---

## Build Matrix

### Supported Platforms

| OS | Architecture | CI Tests | Release Builds |
|----|-------------|----------|----------------|
| Ubuntu Latest | x64 | ✅ | ✅ |
| Ubuntu Latest | ARM64 | ➖ | ✅ |
| macOS Latest | x64 (Intel) | ✅ | ✅ |
| macOS Latest | ARM64 (M1/M2) | ✅ | ✅ |
| Windows Latest | x64 | ✅ | ✅ |

### Zig Version

- **Current:** 0.16-dev
- **Update frequency:** Following Zig stable releases
- **Compatibility:** Backward compatible within minor versions

---

## Testing

### Test Types

#### Unit Tests

**Command:** `zig build test-<module>`

Modules tested:
- **Tokenizer**: Lexical analysis
- **Parser**: Syntax parsing
- **Expander**: Variable and path expansion
- **Executor**: Command execution
- **Plugins**: Plugin system
- **Hooks**: Hook execution
- **Theme**: Theme loading and parsing

#### Integration Tests

**Command:** `./e2e_test.sh`

Tests:
- Complete shell workflows
- Cross-module interactions
- Real-world usage scenarios

#### Performance Tests

**Command:** Automated benchmarks

Metrics:
- Startup latency
- Command throughput
- Memory usage

### Running Tests Locally

```bash
# All tests
zig build test

# Specific module
zig build test-tokenizer
zig build test-parser

# Integration tests
bash e2e_test.sh

# With coverage
zig build test -Dtest-coverage=true
```

### Test Results

Test results and logs are uploaded as artifacts for failed runs:
```
integration-test-logs-ubuntu-latest/
integration-test-logs-macos-latest/
integration-test-logs-windows-latest/
```

---

## Releases

### Creating a Release

1. **Update version numbers:**
   - `build.zig`
   - `package.json`
   - `README.md`

2. **Update CHANGELOG.md:**
   ```markdown
   ## [1.0.0] - 2025-01-15
   ### Added
   - Feature description

   ### Fixed
   - Bug fix description
   ```

3. **Commit changes:**
   ```bash
   git add .
   git commit -m "chore: bump version to 1.0.0"
   ```

4. **Create and push tag:**
   ```bash
   git tag v1.0.0
   git push origin main
   git push origin v1.0.0
   ```

5. **GitHub Actions automatically:**
   - Builds all platform binaries
   - Creates release archives
   - Generates checksums
   - Publishes GitHub Release

### Versioning

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: Incompatible API changes
- **MINOR**: Backward-compatible functionality
- **PATCH**: Backward-compatible bug fixes

Format: `vMAJOR.MINOR.PATCH` (e.g., `v1.2.3`)

### Release Artifacts

Each release includes:

**Binaries:**
- Compressed archives for each platform
- Include shell executable, README, LICENSE

**Checksums:**
- SHA-256 checksums for verification
- Format: `<checksum> <filename>`

**Release Notes:**
- Extracted from CHANGELOG.md
- Includes all changes since last release

---

## Contributing

### Pre-commit Checks

Before submitting a PR, ensure:

1. **Code formatting:**
   ```bash
   zig fmt .
   ```

2. **Linting:**
   ```bash
   bun run lint
   ```

3. **Type checking:**
   ```bash
   bun run typecheck
   ```

4. **Tests pass:**
   ```bash
   zig build test
   ```

### Pull Request Requirements

All PRs must:
- ✅ Pass all CI checks
- ✅ Include tests for new features
- ✅ Update documentation
- ✅ Follow code style guidelines
- ✅ Include clear commit messages

### CI Status Badges

Add these to your fork's README to track CI status:

```markdown
![CI](https://github.com/username/den/workflows/CI/badge.svg)
![Tests](https://github.com/username/den/workflows/Tests/badge.svg)
```

---

## Troubleshooting

### Build Failures

**Zig version mismatch:**
```bash
# Check Zig version
zig version
# Should output: 0.16-dev

# Update Zig if needed
brew upgrade zig  # macOS
```

**Cache issues:**
```bash
# Clear Zig cache
rm -rf .zig-cache
rm -rf ~/.cache/zig
```

### Test Failures

**Timeout errors:**
- Increase timeout in test files
- Check for infinite loops

**Platform-specific failures:**
- Review platform-specific code paths
- Check file path separators (/ vs \)

### Release Issues

**Tag not triggering release:**
- Verify tag format: `v*` pattern
- Ensure tag is pushed to origin
- Check GitHub Actions permissions

**Missing artifacts:**
- Check release.yml workflow logs
- Verify build script (scripts/release.sh)
- Check file permissions

---

## Performance Optimization

### Build Caching

GitHub Actions caches:
- **Zig cache:** `~/.cache/zig` and `.zig-cache`
- **Node modules:** `node_modules/`

Cache is invalidated on:
- Zig version change
- Lock file change (bun.lock)
- Build file change (build.zig)

### Parallel Execution

Workflows use job matrices for parallel execution:
```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
```

Reduces total CI time by ~60%

---

## Security

### Secrets Management

No secrets are required for public CI/CD.

For private forks:
- Use GitHub Secrets for tokens
- Never commit credentials
- Use environment variables

### Dependency Scanning

Automated security scanning:
- Dependabot for npm packages
- Zig dependency updates monitored manually

---

## See Also

- [Contributing Guidelines](../CONTRIBUTING.md)
- [Release Process](../README.md#releases)
- [Build System](./ARCHITECTURE.md#build-system)
