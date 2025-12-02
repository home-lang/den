#!/bin/bash
# Shell Performance Comparison Benchmark
# Compares Den Shell against Bash and Zsh
#
# Usage: ./tests/bench_comparison.sh [iterations]
#
# Requires: hyperfine (brew install hyperfine)

set -e

ITERATIONS=${1:-100}
DEN_BIN="${DEN_BIN:-./zig-out/bin/den}"
RESULTS_DIR="benchmark_results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Shell Performance Comparison Benchmark${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Check dependencies
if ! command -v hyperfine &> /dev/null; then
    echo -e "${RED}Error: hyperfine is required but not installed.${NC}"
    echo "Install with: brew install hyperfine"
    exit 1
fi

if [ ! -f "$DEN_BIN" ]; then
    echo -e "${YELLOW}Building den...${NC}"
    zig build -Doptimize=ReleaseFast
fi

# Create results directory
mkdir -p "$RESULTS_DIR"

echo -e "${GREEN}Configuration:${NC}"
echo "  Iterations: $ITERATIONS"
echo "  Den binary: $DEN_BIN"
echo "  Bash: $(bash --version | head -1)"
echo "  Zsh:  $(zsh --version)"
echo ""

# ============================================================================
# Benchmark 1: Startup Time
# ============================================================================
echo -e "${YELLOW}Benchmark 1: Shell Startup Time${NC}"
echo "  Measuring time to start and exit immediately"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/startup.json" \
    --export-markdown "$RESULTS_DIR/startup.md" \
    "bash -c 'exit'" \
    "zsh -c 'exit'" \
    "$DEN_BIN -c 'exit'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 2: Simple Command Execution
# ============================================================================
echo -e "${YELLOW}Benchmark 2: Simple Command (echo)${NC}"
echo "  Measuring: echo 'hello world'"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/echo.json" \
    --export-markdown "$RESULTS_DIR/echo.md" \
    "bash -c 'echo hello world'" \
    "zsh -c 'echo hello world'" \
    "$DEN_BIN -c 'echo hello world'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 3: Variable Expansion
# ============================================================================
echo -e "${YELLOW}Benchmark 3: Variable Expansion${NC}"
echo "  Measuring: FOO=bar; echo \$FOO"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/variable.json" \
    --export-markdown "$RESULTS_DIR/variable.md" \
    "bash -c 'FOO=bar; echo \$FOO'" \
    "zsh -c 'FOO=bar; echo \$FOO'" \
    "$DEN_BIN -c 'FOO=bar; echo \$FOO'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 4: Command Substitution
# ============================================================================
echo -e "${YELLOW}Benchmark 4: Command Substitution${NC}"
echo "  Measuring: echo \$(echo nested)"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/subst.json" \
    --export-markdown "$RESULTS_DIR/subst.md" \
    "bash -c 'echo \$(echo nested)'" \
    "zsh -c 'echo \$(echo nested)'" \
    "$DEN_BIN -c 'echo \$(echo nested)'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 5: Pipeline Execution
# ============================================================================
echo -e "${YELLOW}Benchmark 5: Simple Pipeline${NC}"
echo "  Measuring: echo test | cat"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/pipeline.json" \
    --export-markdown "$RESULTS_DIR/pipeline.md" \
    "bash -c 'echo test | cat'" \
    "zsh -c 'echo test | cat'" \
    "$DEN_BIN -c 'echo test | cat'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 6: Arithmetic Expansion
# ============================================================================
echo -e "${YELLOW}Benchmark 6: Arithmetic Expansion${NC}"
echo "  Measuring: echo \$((1 + 2 * 3))"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/arithmetic.json" \
    --export-markdown "$RESULTS_DIR/arithmetic.md" \
    "bash -c 'echo \$((1 + 2 * 3))'" \
    "zsh -c 'echo \$((1 + 2 * 3))'" \
    "$DEN_BIN -c 'echo \$((1 + 2 * 3))'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 7: For Loop
# ============================================================================
echo -e "${YELLOW}Benchmark 7: For Loop (10 iterations)${NC}"
echo "  Measuring: for i in 1 2 3 4 5 6 7 8 9 10; do echo \$i; done"
echo ""

hyperfine \
    --warmup 5 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/forloop.json" \
    --export-markdown "$RESULTS_DIR/forloop.md" \
    "bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do echo \$i; done'" \
    "zsh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do echo \$i; done'" \
    "$DEN_BIN -c 'for i in 1 2 3 4 5 6 7 8 9 10; do echo \$i; done'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 8: Conditional (if/else)
# ============================================================================
echo -e "${YELLOW}Benchmark 8: Conditional Statement${NC}"
echo "  Measuring: if true; then echo yes; else echo no; fi"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/conditional.json" \
    --export-markdown "$RESULTS_DIR/conditional.md" \
    "bash -c 'if true; then echo yes; else echo no; fi'" \
    "zsh -c 'if true; then echo yes; else echo no; fi'" \
    "$DEN_BIN -c 'if true; then echo yes; else echo no; fi'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 9: Brace Expansion
# ============================================================================
echo -e "${YELLOW}Benchmark 9: Brace Expansion${NC}"
echo "  Measuring: echo {a,b,c}{1,2,3}"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/brace.json" \
    --export-markdown "$RESULTS_DIR/brace.md" \
    "bash -c 'echo {a,b,c}{1,2,3}'" \
    "zsh -c 'echo {a,b,c}{1,2,3}'" \
    "$DEN_BIN -c 'echo {a,b,c}{1,2,3}'" \
    2>&1

echo ""

# ============================================================================
# Benchmark 10: Function Definition & Call
# ============================================================================
echo -e "${YELLOW}Benchmark 10: Function Definition & Call${NC}"
echo "  Measuring: greet() { echo Hello; }; greet"
echo ""

hyperfine \
    --warmup 10 \
    --runs "$ITERATIONS" \
    --export-json "$RESULTS_DIR/function.json" \
    --export-markdown "$RESULTS_DIR/function.md" \
    "bash -c 'greet() { echo Hello; }; greet'" \
    "zsh -c 'greet() { echo Hello; }; greet'" \
    "$DEN_BIN -c 'greet() { echo Hello; }; greet'" \
    2>&1

echo ""

# ============================================================================
# Generate Summary Report
# ============================================================================
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Generating Summary Report${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

cat > "$RESULTS_DIR/SUMMARY.md" << 'HEADER'
# Shell Performance Comparison Report

Comparing Den Shell against Bash and Zsh.

## Test Environment
HEADER

echo "- Date: $(date)" >> "$RESULTS_DIR/SUMMARY.md"
echo "- Platform: $(uname -s) $(uname -m)" >> "$RESULTS_DIR/SUMMARY.md"
echo "- Bash: $(bash --version | head -1)" >> "$RESULTS_DIR/SUMMARY.md"
echo "- Zsh: $(zsh --version)" >> "$RESULTS_DIR/SUMMARY.md"
echo "- Den: $($DEN_BIN --version 2>/dev/null || echo 'dev')" >> "$RESULTS_DIR/SUMMARY.md"
echo "- Iterations: $ITERATIONS" >> "$RESULTS_DIR/SUMMARY.md"
echo "" >> "$RESULTS_DIR/SUMMARY.md"

echo "## Results" >> "$RESULTS_DIR/SUMMARY.md"
echo "" >> "$RESULTS_DIR/SUMMARY.md"

# Append individual benchmark results
for md_file in "$RESULTS_DIR"/*.md; do
    if [ "$md_file" != "$RESULTS_DIR/SUMMARY.md" ]; then
        name=$(basename "$md_file" .md)
        echo "### $name" >> "$RESULTS_DIR/SUMMARY.md"
        echo "" >> "$RESULTS_DIR/SUMMARY.md"
        cat "$md_file" >> "$RESULTS_DIR/SUMMARY.md"
        echo "" >> "$RESULTS_DIR/SUMMARY.md"
    fi
done

echo -e "${GREEN}Results saved to: $RESULTS_DIR/${NC}"
echo ""
echo "Individual results:"
ls -la "$RESULTS_DIR"/*.{json,md} 2>/dev/null || true
echo ""
echo -e "${GREEN}Summary: $RESULTS_DIR/SUMMARY.md${NC}"
