#!/bin/bash
# Git Workflow Automation for Den Shell
# Streamlines common git operations and enforces conventions

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
COMMIT_TYPES=("feat" "fix" "docs" "style" "refactor" "perf" "test" "build" "ci" "chore" "revert")

# Logging
log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"
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
Usage: $(basename "$0") COMMAND [OPTIONS] [ARGS]

Git workflow automation with conventions.

COMMANDS:
    feature NAME         Create a new feature branch
    bugfix NAME          Create a new bugfix branch
    hotfix NAME          Create a new hotfix branch
    commit TYPE MSG      Create a conventional commit
    push                 Push current branch with tracking
    pr [TITLE]           Create a pull request
    release VERSION      Create a release tag
    changelog [TAG]      Generate changelog
    clean                Clean merged branches
    sync                 Sync with upstream
    status               Show enhanced status

COMMIT TYPES:
    feat        New feature
    fix         Bug fix
    docs        Documentation
    style       Code style
    refactor    Code refactoring
    perf        Performance
    test        Tests
    build       Build system
    ci          CI/CD
    chore       Maintenance
    revert      Revert changes

EXAMPLES:
    # Create feature branch
    $(basename "$0") feature user-authentication

    # Conventional commit
    $(basename "$0") commit feat "add user login"

    # Create release
    $(basename "$0") release v1.2.0

    # Generate changelog
    $(basename "$0") changelog

EOF
}

# Check if we're in a git repo
check_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not a git repository"
        exit 1
    fi
}

# Get current branch
get_current_branch() {
    git rev-parse --abbrev-ref HEAD
}

# Create branch
create_branch() {
    local branch_type=$1
    local branch_name=$2

    check_git_repo

    # Ensure we're on default branch
    local current_branch
    current_branch=$(get_current_branch)

    if [ "$current_branch" != "$DEFAULT_BRANCH" ]; then
        log_warning "Not on $DEFAULT_BRANCH branch"
        read -p "Switch to $DEFAULT_BRANCH? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git checkout "$DEFAULT_BRANCH"
        else
            log "Creating branch from $current_branch"
        fi
    fi

    # Pull latest
    log "Pulling latest changes..."
    git pull origin "$DEFAULT_BRANCH" || true

    # Create branch
    local full_branch_name="${branch_type}/${branch_name}"
    log "Creating branch: $full_branch_name"

    git checkout -b "$full_branch_name"
    log_success "Branch created and checked out: $full_branch_name"
}

# Conventional commit
conventional_commit() {
    local commit_type=$1
    local message=$2
    local scope=${3:-}

    check_git_repo

    # Validate commit type
    if [[ ! " ${COMMIT_TYPES[*]} " =~ " ${commit_type} " ]]; then
        log_error "Invalid commit type: $commit_type"
        log "Valid types: ${COMMIT_TYPES[*]}"
        exit 1
    fi

    # Build commit message
    local commit_msg="$commit_type"
    [ -n "$scope" ] && commit_msg="$commit_msg($scope)"
    commit_msg="$commit_msg: $message"

    log "Creating commit: $commit_msg"

    # Show staged changes
    if git diff --cached --quiet; then
        log_warning "No staged changes"
        read -p "Stage all changes? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git add -A
        else
            log_error "No changes to commit"
            exit 1
        fi
    fi

    # Show what will be committed
    echo ""
    git diff --cached --stat
    echo ""

    # Confirm
    read -p "Create commit? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        git commit -m "$commit_msg"
        log_success "Commit created"

        # Show commit
        git log -1 --oneline
    fi
}

# Push with tracking
push_branch() {
    check_git_repo

    local current_branch
    current_branch=$(get_current_branch)

    log "Pushing $current_branch..."

    # Check if branch exists on remote
    if git ls-remote --exit-code --heads origin "$current_branch" > /dev/null 2>&1; then
        git push
    else
        log "Setting up tracking branch"
        git push -u origin "$current_branch"
    fi

    log_success "Push complete"
}

# Create PR
create_pr() {
    local title=${1:-}

    check_git_repo

    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) not installed"
        log "Install from: https://cli.github.com/"
        exit 1
    fi

    # Ensure branch is pushed
    local current_branch
    current_branch=$(get_current_branch)

    if ! git ls-remote --exit-code --heads origin "$current_branch" > /dev/null 2>&1; then
        log "Branch not pushed, pushing now..."
        push_branch
    fi

    # Create PR
    log "Creating pull request..."

    if [ -n "$title" ]; then
        gh pr create --title "$title" --body "" --web
    else
        gh pr create --fill --web
    fi
}

# Create release
create_release() {
    local version=$1

    check_git_repo

    # Validate version format
    if [[ ! $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid version format: $version"
        log "Expected format: v1.2.3 or 1.2.3"
        exit 1
    fi

    # Add v prefix if not present
    [[ $version != v* ]] && version="v$version"

    # Confirm on main branch
    local current_branch
    current_branch=$(get_current_branch)

    if [ "$current_branch" != "$DEFAULT_BRANCH" ]; then
        log_error "Must be on $DEFAULT_BRANCH branch to create release"
        exit 1
    fi

    # Pull latest
    log "Pulling latest changes..."
    git pull origin "$DEFAULT_BRANCH"

    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD --; then
        log_error "Uncommitted changes present"
        exit 1
    fi

    # Create tag
    log "Creating release tag: $version"

    git tag -a "$version" -m "Release $version"
    git push origin "$version"

    log_success "Release tag created: $version"

    # Create GitHub release if gh CLI available
    if command -v gh &> /dev/null; then
        read -p "Create GitHub release? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            gh release create "$version" --generate-notes
        fi
    fi
}

# Generate changelog
generate_changelog() {
    local since_tag=${1:-}

    check_git_repo

    log "Generating changelog..."

    if [ -z "$since_tag" ]; then
        # Get latest tag
        since_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    fi

    if [ -z "$since_tag" ]; then
        log "Generating full changelog"
        git log --pretty=format:"- %s (%h)" --reverse
    else
        log "Generating changelog since $since_tag"
        git log "$since_tag"..HEAD --pretty=format:"- %s (%h)" --reverse
    fi
}

# Clean merged branches
clean_branches() {
    check_git_repo

    log "Finding merged branches..."

    # Get merged branches
    local merged_branches
    merged_branches=$(git branch --merged "$DEFAULT_BRANCH" | grep -v "$DEFAULT_BRANCH" | grep -v "^\*" || true)

    if [ -z "$merged_branches" ]; then
        log_success "No merged branches to clean"
        return
    fi

    echo "$merged_branches"
    echo ""

    read -p "Delete these branches? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$merged_branches" | xargs -n 1 git branch -d
        log_success "Branches cleaned"
    fi
}

# Enhanced status
show_status() {
    check_git_repo

    echo -e "${CYAN}Repository Status${NC}"
    echo "=================="
    echo ""

    # Current branch
    local current_branch
    current_branch=$(get_current_branch)
    echo -e "Branch: ${GREEN}$current_branch${NC}"

    # Upstream status
    if git rev-parse --abbrev-ref --symbolic-full-name @{u} > /dev/null 2>&1; then
        local ahead behind
        ahead=$(git rev-list --count @{u}..HEAD)
        behind=$(git rev-list --count HEAD..@{u})

        [ "$ahead" -gt 0 ] && echo -e "Ahead: ${GREEN}+$ahead${NC}"
        [ "$behind" -gt 0 ] && echo -e "Behind: ${RED}-$behind${NC}"
    fi

    echo ""

    # Git status
    git status --short

    echo ""

    # Recent commits
    echo -e "${CYAN}Recent Commits${NC}"
    git log --oneline -5

    echo ""

    # Stashes
    local stash_count
    stash_count=$(git stash list | wc -l | tr -d ' ')
    if [ "$stash_count" -gt 0 ]; then
        echo -e "${YELLOW}Stashes: $stash_count${NC}"
        git stash list
    fi
}

# Main command dispatcher
case "${1:-help}" in
    feature|bugfix|hotfix)
        [ -z "${2:-}" ] && { log_error "Branch name required"; exit 1; }
        create_branch "$1" "$2"
        ;;
    commit)
        [ -z "${2:-}" ] && { log_error "Commit type required"; exit 1; }
        [ -z "${3:-}" ] && { log_error "Commit message required"; exit 1; }
        conventional_commit "$2" "$3" "${4:-}"
        ;;
    push)
        push_branch
        ;;
    pr)
        create_pr "${2:-}"
        ;;
    release)
        [ -z "${2:-}" ] && { log_error "Version required"; exit 1; }
        create_release "$2"
        ;;
    changelog)
        generate_changelog "${2:-}"
        ;;
    clean)
        clean_branches
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
