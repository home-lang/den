#!/bin/bash
# Deployment Script for Den Shell
# Multi-environment deployment with checks and rollback

set -euo pipefail

# Configuration
ENVIRONMENTS=("development" "staging" "production")
DEPLOY_DIR="${DEPLOY_DIR:-/var/www/app}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/app}"
MAX_BACKUPS=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

# Show help
show_help() {
    cat << EOF
Usage: $(basename "$0") ENVIRONMENT [OPTIONS]

Deploy application to specified environment.

ENVIRONMENTS:
    development         Development environment
    staging            Staging environment
    production         Production environment

OPTIONS:
    -h, --help         Show this help message
    -t, --tag TAG      Deploy specific tag/commit
    -b, --branch NAME  Deploy specific branch
    --skip-tests       Skip running tests
    --skip-backup      Skip backup creation
    --force            Skip confirmation prompts
    --rollback         Rollback to previous version

COMMANDS:
    rollback ENV       Rollback environment to previous version
    list ENV           List available backups for environment

EXAMPLES:
    # Deploy current branch to staging
    $(basename "$0") staging

    # Deploy specific tag to production
    $(basename "$0") production --tag v1.2.3

    # Rollback production
    $(basename "$0") rollback production

EOF
}

# Environment config
load_environment() {
    local env=$1

    case $env in
        development)
            SERVER="dev.example.com"
            BRANCH="develop"
            RUN_TESTS=true
            REQUIRE_APPROVAL=false
            ;;
        staging)
            SERVER="staging.example.com"
            BRANCH="staging"
            RUN_TESTS=true
            REQUIRE_APPROVAL=false
            ;;
        production)
            SERVER="example.com"
            BRANCH="main"
            RUN_TESTS=true
            REQUIRE_APPROVAL=true
            ;;
        *)
            log_error "Invalid environment: $env"
            exit 1
            ;;
    esac
}

# Pre-deployment checks
pre_deploy_checks() {
    local env=$1

    log "Running pre-deployment checks..."

    # Check git status
    if ! git diff-index --quiet HEAD --; then
        log_error "Uncommitted changes present"
        exit 1
    fi

    # Check if branch exists
    if [ -n "${DEPLOY_BRANCH:-}" ]; then
        if ! git rev-parse --verify "$DEPLOY_BRANCH" > /dev/null 2>&1; then
            log_error "Branch does not exist: $DEPLOY_BRANCH"
            exit 1
        fi
    fi

    # Check if tag exists
    if [ -n "${DEPLOY_TAG:-}" ]; then
        if ! git rev-parse --verify "$DEPLOY_TAG" > /dev/null 2>&1; then
            log_error "Tag does not exist: $DEPLOY_TAG"
            exit 1
        fi
    fi

    # Check server connectivity
    log "Checking server connectivity..."
    if ! ping -c 1 "$SERVER" > /dev/null 2>&1; then
        log_warning "Cannot reach server: $SERVER"
    fi

    log_success "Pre-deployment checks passed"
}

# Run tests
run_tests() {
    if [ "${SKIP_TESTS:-false}" = true ]; then
        log_warning "Skipping tests (--skip-tests)"
        return
    fi

    log "Running tests..."

    # Run tests based on project type
    if [ -f "package.json" ]; then
        npm test
    elif [ -f "Cargo.toml" ]; then
        cargo test
    elif [ -f "requirements.txt" ]; then
        python -m pytest
    elif [ -f "build.zig" ]; then
        zig build test
    else
        log_warning "No test configuration found"
    fi

    log_success "Tests passed"
}

# Create backup
create_backup() {
    local env=$1

    if [ "${SKIP_BACKUP:-false}" = true ]; then
        log_warning "Skipping backup (--skip-backup)"
        return
    fi

    log "Creating backup..."

    local timestamp
    timestamp=$(date +'%Y%m%d_%H%M%S')
    local backup_path="$BACKUP_DIR/${env}_${timestamp}.tar.gz"

    mkdir -p "$BACKUP_DIR"

    # Create backup
    tar -czf "$backup_path" -C "$DEPLOY_DIR" .

    log_success "Backup created: $backup_path"

    # Rotate old backups
    cd "$BACKUP_DIR"
    ls -t "${env}_"*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f

    # Store backup path for potential rollback
    echo "$backup_path" > "$BACKUP_DIR/.last_backup_$env"
}

# Deploy
deploy() {
    local env=$1

    log "Deploying to $env..."

    # Checkout appropriate version
    if [ -n "${DEPLOY_TAG:-}" ]; then
        log "Deploying tag: $DEPLOY_TAG"
        git checkout "$DEPLOY_TAG"
    elif [ -n "${DEPLOY_BRANCH:-}" ]; then
        log "Deploying branch: $DEPLOY_BRANCH"
        git checkout "$DEPLOY_BRANCH"
        git pull origin "$DEPLOY_BRANCH"
    else
        log "Deploying branch: $BRANCH"
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
    fi

    # Build if necessary
    if [ -f "package.json" ] && [ -f "package-lock.json" ]; then
        log "Installing dependencies..."
        npm ci

        if [ "$(jq -r '.scripts.build // empty' package.json)" != "" ]; then
            log "Building application..."
            npm run build
        fi
    fi

    # Deploy files
    log "Copying files to $SERVER:$DEPLOY_DIR..."

    # Use rsync for deployment
    rsync -avz --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='.env' \
        --exclude='*.log' \
        ./ "$SERVER:$DEPLOY_DIR/"

    # Restart services
    log "Restarting services..."
    ssh "$SERVER" "sudo systemctl restart app"

    log_success "Deployment complete"
}

# Health check
health_check() {
    local env=$1

    log "Running health checks..."

    # Wait a moment for services to start
    sleep 5

    # Check HTTP endpoint
    local health_url="http://${SERVER}/health"
    local max_attempts=10
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -sf "$health_url" > /dev/null 2>&1; then
            log_success "Health check passed"
            return 0
        fi

        attempt=$((attempt + 1))
        log "Health check attempt $attempt/$max_attempts..."
        sleep 2
    done

    log_error "Health check failed after $max_attempts attempts"
    return 1
}

# Rollback
rollback() {
    local env=$1

    log_warning "Rolling back $env environment..."

    local last_backup_file="$BACKUP_DIR/.last_backup_$env"

    if [ ! -f "$last_backup_file" ]; then
        log_error "No backup found for rollback"
        exit 1
    fi

    local backup_path
    backup_path=$(cat "$last_backup_file")

    if [ ! -f "$backup_path" ]; then
        log_error "Backup file not found: $backup_path"
        exit 1
    fi

    log "Restoring from backup: $backup_path"

    # Extract backup
    ssh "$SERVER" "cd $DEPLOY_DIR && tar -xzf $backup_path"

    # Restart services
    log "Restarting services..."
    ssh "$SERVER" "sudo systemctl restart app"

    log_success "Rollback complete"

    # Health check
    if ! health_check "$env"; then
        log_error "Rollback health check failed"
        exit 1
    fi
}

# List backups
list_backups() {
    local env=$1

    log "Available backups for $env:"
    echo ""

    cd "$BACKUP_DIR" 2>/dev/null || { log_error "No backups found"; exit 1; }

    ls -lh "${env}_"*.tar.gz 2>/dev/null | while read -r line; do
        echo "  $line"
    done
}

# Parse arguments
COMMAND="${1:-}"
ENVIRONMENT=""
SKIP_TESTS=false
SKIP_BACKUP=false
FORCE=false
DEPLOY_TAG=""
DEPLOY_BRANCH=""

if [ "$COMMAND" = "rollback" ]; then
    ENVIRONMENT="${2:-}"
    [ -z "$ENVIRONMENT" ] && { log_error "Environment required"; exit 1; }
    load_environment "$ENVIRONMENT"
    rollback "$ENVIRONMENT"
    exit 0
elif [ "$COMMAND" = "list" ]; then
    ENVIRONMENT="${2:-}"
    [ -z "$ENVIRONMENT" ] && { log_error "Environment required"; exit 1; }
    list_backups "$ENVIRONMENT"
    exit 0
fi

ENVIRONMENT="$COMMAND"

shift 1 || true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -t|--tag)
            DEPLOY_TAG="$2"
            shift 2
            ;;
        -b|--branch)
            DEPLOY_BRANCH="$2"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate environment
if [ -z "$ENVIRONMENT" ]; then
    log_error "Environment required"
    show_help
    exit 1
fi

if [[ ! " ${ENVIRONMENTS[*]} " =~ " ${ENVIRONMENT} " ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log "Valid environments: ${ENVIRONMENTS[*]}"
    exit 1
fi

# Load environment config
load_environment "$ENVIRONMENT"

# Confirmation for production
if [ "$REQUIRE_APPROVAL" = true ] && [ "$FORCE" = false ]; then
    echo ""
    log_warning "PRODUCTION DEPLOYMENT"
    echo "Environment: $ENVIRONMENT"
    echo "Server: $SERVER"
    [ -n "$DEPLOY_TAG" ] && echo "Tag: $DEPLOY_TAG"
    [ -n "$DEPLOY_BRANCH" ] && echo "Branch: $DEPLOY_BRANCH"
    echo ""
    read -p "Continue with deployment? (yes/NO): " -r
    if [ "$REPLY" != "yes" ]; then
        log "Deployment cancelled"
        exit 0
    fi
fi

# Execute deployment
pre_deploy_checks "$ENVIRONMENT"
run_tests
create_backup "$ENVIRONMENT"
deploy "$ENVIRONMENT"

if ! health_check "$ENVIRONMENT"; then
    log_error "Deployment failed health check"
    read -p "Rollback? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        rollback "$ENVIRONMENT"
    fi
    exit 1
fi

log_success "Deployment to $ENVIRONMENT completed successfully"
