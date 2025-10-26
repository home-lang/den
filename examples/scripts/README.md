# Den Shell Example Scripts

This directory contains example scripts demonstrating various Den Shell features and common workflows.

## Available Scripts

### System & Backup

#### 1. backup.sh
**Description:** Automated backup script with compression and rotation.

**Features:**
- Incremental and full backups
- Automatic rotation (keep last N backups)
- Compression (tar.gz)
- Exclusion patterns
- Progress indicators

**Usage:**
```bash
./backup.sh /path/to/source /path/to/backup
./backup.sh --incremental /home/user /backup/home
```

#### 2. system-info.sh
**Description:** Comprehensive system information display.

**Features:**
- OS and kernel info
- CPU and memory usage
- Disk space
- Network information
- Running services

**Usage:**
```bash
./system-info.sh
./system-info.sh --json    # Output as JSON
```

### Development Workflows

#### 3. git-workflow.sh
**Description:** Git workflow automation scripts.

**Features:**
- Branch management
- Commit helpers
- PR creation
- Release tagging
- Changelog generation

**Usage:**
```bash
./git-workflow.sh feature "new-feature"     # Create feature branch
./git-workflow.sh commit "feat: add feature" # Conventional commit
./git-workflow.sh release patch             # Create patch release
```

#### 4. dev-setup.sh
**Description:** Development environment setup.

**Features:**
- Project initialization
- Dependency installation
- Git hooks setup
- Config file generation
- IDE configuration

**Usage:**
```bash
./dev-setup.sh init node    # Initialize Node.js project
./dev-setup.sh init python  # Initialize Python project
./dev-setup.sh init rust    # Initialize Rust project
```

### Deployment

#### 5. deploy.sh
**Description:** Application deployment script.

**Features:**
- Multi-environment support
- Pre-deployment checks
- Rollback capability
- Health checks
- Slack/Discord notifications

**Usage:**
```bash
./deploy.sh staging
./deploy.sh production --tag v1.2.3
./deploy.sh rollback production
```

#### 6. docker-manager.sh
**Description:** Docker container management.

**Features:**
- Build and push images
- Container lifecycle management
- Log streaming
- Resource cleanup
- Health monitoring

**Usage:**
```bash
./docker-manager.sh build myapp:latest
./docker-manager.sh deploy myapp production
./docker-manager.sh logs myapp -f
./docker-manager.sh cleanup --force
```

### Utilities

#### 7. env-manager.sh
**Description:** Environment variable management.

**Features:**
- Load/save environment configs
- Environment switching
- Secret management
- Validation
- Export to various formats

**Usage:**
```bash
./env-manager.sh load development
./env-manager.sh save production
./env-manager.sh switch staging
./env-manager.sh validate
```

#### 8. log-analyzer.sh
**Description:** Log file analysis and monitoring.

**Features:**
- Error detection
- Pattern matching
- Statistics generation
- Alert triggers
- Report generation

**Usage:**
```bash
./log-analyzer.sh /var/log/app.log
./log-analyzer.sh --errors --last 1h /var/log/app.log
./log-analyzer.sh --watch --alert email /var/log/app.log
```

#### 9. performance-monitor.sh
**Description:** System and application performance monitoring.

**Features:**
- CPU/Memory tracking
- Process monitoring
- Alert thresholds
- Historical data
- Report generation

**Usage:**
```bash
./performance-monitor.sh
./performance-monitor.sh --process node --threshold 80
./performance-monitor.sh --report daily
```

### Den Shell Specific

#### 10. plugin-manager.sh
**Description:** Den Shell plugin management.

**Features:**
- Plugin installation
- Plugin updates
- Plugin removal
- Plugin listing
- Dependency resolution

**Usage:**
```bash
./plugin-manager.sh install git-enhanced
./plugin-manager.sh update --all
./plugin-manager.sh list --enabled
./plugin-manager.sh remove old-plugin
```

## Script Conventions

### Shebang
All scripts use:
```bash
#!/usr/bin/env den
```

Or for shell-compatible scripts:
```bash
#!/bin/bash
# Compatible with Den Shell
```

### Exit Codes
- `0` - Success
- `1` - General error
- `2` - Misuse of command
- `126` - Command cannot execute
- `127` - Command not found
- `130` - Script terminated by Ctrl+C

### Error Handling
```bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Trap errors
trap 'error_handler $? $LINENO' ERR

error_handler() {
    echo "Error $1 occurred on line $2"
    cleanup
    exit "$1"
}
```

### Logging
```bash
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_success() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $*"
}
```

### Configuration
Scripts should support configuration via:
1. Command-line arguments
2. Environment variables
3. Configuration files (`.config/den/scripts/script-name.conf`)
4. Sensible defaults

### Help Text
All scripts should provide help:
```bash
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] COMMAND [ARGS]

Description of the script

OPTIONS:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose output
    -q, --quiet     Suppress output

COMMANDS:
    command1        Description
    command2        Description

EXAMPLES:
    $(basename "$0") command1 arg1
    $(basename "$0") --verbose command2

EOF
}
```

## Best Practices

### 1. Portability
- Use POSIX-compliant features when possible
- Test on multiple systems
- Handle platform differences gracefully

### 2. Security
- Never hardcode credentials
- Use proper file permissions (600 for sensitive files)
- Validate and sanitize inputs
- Avoid eval with user input

### 3. Performance
- Avoid unnecessary subshells
- Use built-in commands when possible
- Cache expensive operations
- Stream large files instead of loading into memory

### 4. User Experience
- Provide clear progress indicators
- Confirm destructive operations
- Support dry-run mode (`--dry-run`)
- Colorize output for clarity

### 5. Testing
- Include test cases
- Test error conditions
- Use shellcheck for linting
- Test with different inputs

## Color Output

Use Den Shell's color support:
```bash
# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

echo -e "${GREEN}Success${NC}"
echo -e "${RED}Error${NC}"
echo -e "${YELLOW}Warning${NC}"
```

## Progress Indicators

### Simple spinner
```bash
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}
```

### Progress bar
```bash
progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))

    printf "\r["
    printf "%${completed}s" | tr ' ' '='
    printf "%$((width - completed))s" | tr ' ' ' '
    printf "] %d%%" $percentage
}
```

## Integration with Den Shell

### Hook Integration
```bash
# Register with Den Shell hooks
if [ -n "$DEN_SHELL" ]; then
    # Running in Den Shell
    den hook register pre_command ./script.sh
fi
```

### Config Integration
```bash
# Read from Den Shell config
DEN_CONFIG="${DEN_CONFIG:-$HOME/.config/den/config.jsonc}"
if [ -f "$DEN_CONFIG" ]; then
    # Parse config (requires jq or similar)
    SETTING=$(jq -r '.scripts.my_setting' "$DEN_CONFIG")
fi
```

## Resources

- [Advanced Bash Scripting Guide](https://tldp.org/LDP/abs/html/)
- [ShellCheck](https://www.shellcheck.net/)
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- [Den Shell Documentation](../../docs/)

## Contributing

To contribute a script:

1. Follow the conventions above
2. Include comprehensive comments
3. Add usage examples
4. Test thoroughly
5. Update this README
6. Submit a pull request
