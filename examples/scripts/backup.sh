#!/bin/bash
# Automated Backup Script for Den Shell
# Features: Incremental/full backups, compression, rotation

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
COMPRESSION="${COMPRESSION:-gz}"
INCREMENTAL="${INCREMENTAL:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

# Error handler
error_handler() {
    log_error "Script failed on line $1"
    cleanup
    exit 1
}

trap 'error_handler $LINENO' ERR

# Cleanup function
cleanup() {
    if [ -n "${TEMP_FILE:-}" ] && [ -f "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
    fi
}

trap cleanup EXIT

# Show help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] SOURCE [DESTINATION]

Automated backup script with compression and rotation.

OPTIONS:
    -h, --help              Show this help message
    -i, --incremental       Create incremental backup
    -f, --full              Create full backup (default)
    -k, --keep NUM          Keep NUM backups (default: $KEEP_BACKUPS)
    -c, --compression TYPE  Compression type: gz, bz2, xz (default: $COMPRESSION)
    -e, --exclude PATTERN   Exclude pattern (can be used multiple times)
    -v, --verbose           Verbose output
    -q, --quiet             Quiet mode
    --dry-run               Show what would be done

ARGUMENTS:
    SOURCE                  Source directory to backup
    DESTINATION             Backup destination (default: $BACKUP_DIR)

EXAMPLES:
    # Simple backup
    $(basename "$0") /home/user

    # Incremental backup with custom destination
    $(basename "$0") --incremental /home/user /backup/home

    # Keep last 14 backups, exclude cache directories
    $(basename "$0") --keep 14 --exclude "*.cache" --exclude "node_modules" /home/user

EOF
}

# Parse arguments
VERBOSE=false
QUIET=false
DRY_RUN=false
EXCLUDE_PATTERNS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--incremental)
            INCREMENTAL=true
            shift
            ;;
        -f|--full)
            INCREMENTAL=false
            shift
            ;;
        -k|--keep)
            KEEP_BACKUPS="$2"
            shift 2
            ;;
        -c|--compression)
            COMPRESSION="$2"
            shift 2
            ;;
        -e|--exclude)
            EXCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            if [ -z "${SOURCE:-}" ]; then
                SOURCE="$1"
            elif [ -z "${DESTINATION:-}" ]; then
                DESTINATION="$1"
            else
                log_error "Too many arguments"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "${SOURCE:-}" ]; then
    log_error "Source directory required"
    show_help
    exit 1
fi

if [ ! -d "$SOURCE" ]; then
    log_error "Source directory does not exist: $SOURCE"
    exit 1
fi

DESTINATION="${DESTINATION:-$BACKUP_DIR}"

# Create backup directory
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$DESTINATION"
fi

# Generate backup filename
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
SOURCE_NAME=$(basename "$SOURCE")
BACKUP_TYPE=$( [ "$INCREMENTAL" = true ] && echo "incremental" || echo "full" )
BACKUP_NAME="${SOURCE_NAME}_${BACKUP_TYPE}_${TIMESTAMP}.tar.${COMPRESSION}"
BACKUP_PATH="${DESTINATION}/${BACKUP_NAME}"

# Build tar command
TAR_CMD="tar"
[ "$VERBOSE" = true ] && TAR_CMD="$TAR_CMD -v"

case $COMPRESSION in
    gz)
        TAR_CMD="$TAR_CMD -czf"
        ;;
    bz2)
        TAR_CMD="$TAR_CMD -cjf"
        ;;
    xz)
        TAR_CMD="$TAR_CMD -cJf"
        ;;
    *)
        log_error "Unknown compression type: $COMPRESSION"
        exit 1
        ;;
esac

# Add exclude patterns
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    TAR_CMD="$TAR_CMD --exclude='$pattern'"
done

# Incremental backup setup
if [ "$INCREMENTAL" = true ]; then
    SNAPSHOT_FILE="${DESTINATION}/.${SOURCE_NAME}.snapshot"
    if [ -f "$SNAPSHOT_FILE" ]; then
        TAR_CMD="$TAR_CMD --listed-incremental='$SNAPSHOT_FILE'"
    else
        log_warning "No previous snapshot found, creating full backup"
        INCREMENTAL=false
    fi
fi

# Execute backup
log "Starting $BACKUP_TYPE backup of $SOURCE"
log "Destination: $BACKUP_PATH"

if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would execute: $TAR_CMD $BACKUP_PATH -C $(dirname "$SOURCE") $(basename "$SOURCE")"
else
    eval "$TAR_CMD '$BACKUP_PATH' -C '$(dirname "$SOURCE")' '$(basename "$SOURCE")'"

    if [ -f "$BACKUP_PATH" ]; then
        BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
        log_success "Backup created successfully: $BACKUP_PATH ($BACKUP_SIZE)"
    else
        log_error "Backup failed"
        exit 1
    fi
fi

# Rotate old backups
log "Rotating old backups (keeping last $KEEP_BACKUPS)"

if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would remove old backups"
else
    cd "$DESTINATION"
    ls -t "${SOURCE_NAME}_${BACKUP_TYPE}_"*.tar.* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old_backup; do
        log "Removing old backup: $old_backup"
        rm -f "$old_backup"
    done
fi

log_success "Backup completed successfully"

# Show backup summary
if [ "$QUIET" = false ]; then
    echo ""
    log "Backup Summary:"
    log "  Type: $BACKUP_TYPE"
    log "  Source: $SOURCE"
    log "  Destination: $BACKUP_PATH"
    [ -n "${BACKUP_SIZE:-}" ] && log "  Size: $BACKUP_SIZE"
    log "  Timestamp: $TIMESTAMP"

    echo ""
    log "Available backups:"
    ls -lh "$DESTINATION/${SOURCE_NAME}_"*.tar.* 2>/dev/null | tail -n "$KEEP_BACKUPS" || log "  No previous backups"
fi

exit 0
