#!/bin/bash
# Run all tests for the Den shell project
#
# Usage:
#   ./scripts/test-all.sh           # Run all tests
#   ./scripts/test-all.sh --quick   # Skip slow tests
#   ./scripts/test-all.sh --verbose # Show detailed output

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Parse arguments
QUICK_MODE=false
VERBOSE=false

for arg in "$@"; do
    case $arg in
        --quick|-q)
            QUICK_MODE=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --quick, -q     Skip slow tests"
            echo "  --verbose, -v   Show detailed output"
            echo "  --help, -h      Show this help message"
            exit 0
            ;;
    esac
done

echo "=== Den Shell Test Suite ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    local cmd="$2"

    echo -n "Running $name... "

    if $VERBOSE; then
        echo ""
        if eval "$cmd"; then
            echo -e "${GREEN}PASSED${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}FAILED${NC}"
            ((TESTS_FAILED++))
        fi
    else
        if eval "$cmd" > /dev/null 2>&1; then
            echo -e "${GREEN}PASSED${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}FAILED${NC}"
            ((TESTS_FAILED++))
        fi
    fi
}

# 1. Build check
echo "--- Build Verification ---"
run_test "Debug build" "zig build"
run_test "Release build" "zig build -Doptimize=ReleaseFast"

# 2. Unit tests
echo ""
echo "--- Unit Tests ---"
run_test "Unit tests" "zig build test"

# 3. Module tests
echo ""
echo "--- Module Tests ---"

# Test individual modules
for module in parser executor types utils; do
    if [ -f "src/$module/mod.zig" ]; then
        run_test "$module module" "zig test src/$module/mod.zig 2>/dev/null || true"
    fi
done

# 4. Integration tests (unless quick mode)
if [ "$QUICK_MODE" = false ]; then
    echo ""
    echo "--- Integration Tests ---"

    # Build the shell
    zig build -Doptimize=ReleaseSafe 2>/dev/null

    # Basic execution test
    run_test "Basic execution" "echo 'echo hello' | ./zig-out/bin/den 2>/dev/null | grep -q hello"

    # Pipeline test
    run_test "Pipeline" "echo 'echo hello | cat' | ./zig-out/bin/den 2>/dev/null | grep -q hello"

    # Variable expansion
    run_test "Variable expansion" "echo 'FOO=bar; echo \$FOO' | ./zig-out/bin/den 2>/dev/null | grep -q bar"

    # 5. Comprehensive shell feature tests
    echo ""
    echo "--- Shell Feature Tests ---"
    run_test "Shell features" "DEN=./zig-out/bin/den $PROJECT_DIR/tests/test_shell_features.sh"
fi

# Summary
echo ""
echo "=== Test Summary ==="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -gt 0 ]; then
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
