#!/bin/bash
# Run benchmarks for the Den shell project
#
# Usage:
#   ./scripts/bench.sh              # Run all benchmarks
#   ./scripts/bench.sh startup      # Run startup benchmark only
#   ./scripts/bench.sh comparison   # Compare with other shells

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Ensure we have a release build
echo "Building release version..."
zig build -Doptimize=ReleaseFast 2>/dev/null

DEN="./zig-out/bin/den"

if [ ! -x "$DEN" ]; then
    echo "Error: den binary not found at $DEN"
    exit 1
fi

echo ""
echo "=== Den Shell Benchmarks ==="
echo ""

# Helper function to run a benchmark
run_bench() {
    local name="$1"
    local iterations="${2:-100}"
    local cmd="$3"

    echo "Benchmark: $name ($iterations iterations)"

    local start=$(date +%s.%N)

    for ((i=0; i<iterations; i++)); do
        eval "$cmd" > /dev/null 2>&1
    done

    local end=$(date +%s.%N)
    local total=$(echo "$end - $start" | bc)
    local avg=$(echo "scale=3; $total / $iterations * 1000" | bc)

    echo "  Total: ${total}s"
    echo "  Average: ${avg}ms per iteration"
    echo ""
}

# Benchmark: Startup time
benchmark_startup() {
    echo "--- Startup Time ---"

    # Measure startup time (exit immediately)
    run_bench "Startup (exit 0)" 100 "echo 'exit 0' | $DEN"

    # Measure startup with simple command
    run_bench "Simple echo" 100 "echo 'echo hello' | $DEN"
}

# Benchmark: Command execution
benchmark_execution() {
    echo "--- Command Execution ---"

    # Simple builtin
    run_bench "Builtin (cd)" 100 "echo 'cd .' | $DEN"

    # Variable assignment
    run_bench "Variable assignment" 100 "echo 'FOO=bar' | $DEN"

    # Variable expansion
    run_bench "Variable expansion" 100 "echo 'FOO=bar; echo \$FOO' | $DEN"
}

# Benchmark: Pipelines
benchmark_pipelines() {
    echo "--- Pipelines ---"

    # Simple pipeline
    run_bench "2-stage pipeline" 50 "echo 'echo hello | cat' | $DEN"

    # Longer pipeline
    run_bench "4-stage pipeline" 50 "echo 'echo hello | cat | cat | cat' | $DEN"
}

# Benchmark: Scripting
benchmark_scripting() {
    echo "--- Scripting ---"

    # For loop
    run_bench "For loop (10 iterations)" 50 "echo 'for i in 1 2 3 4 5 6 7 8 9 10; do true; done' | $DEN"

    # Conditionals
    run_bench "If statement" 100 "echo 'if true; then echo yes; fi' | $DEN"

    # Function definition and call
    run_bench "Function call" 50 "echo 'f() { echo hi; }; f' | $DEN"
}

# Benchmark: Comparison with other shells
benchmark_comparison() {
    echo "--- Shell Comparison ---"

    local shells=("$DEN" "bash" "zsh" "sh")
    local test_cmd="echo hello"

    echo "Command: $test_cmd"
    echo ""

    for shell in "${shells[@]}"; do
        if command -v "$(echo $shell | awk '{print $1}')" >/dev/null 2>&1; then
            local name=$(basename "$shell")

            local start=$(date +%s.%N)
            for ((i=0; i<100; i++)); do
                echo "$test_cmd" | $shell > /dev/null 2>&1
            done
            local end=$(date +%s.%N)
            local avg=$(echo "scale=3; ($end - $start) / 100 * 1000" | bc)

            printf "  %-10s: %s ms/iteration\n" "$name" "$avg"
        fi
    done
    echo ""
}

# Parse arguments
case "${1:-all}" in
    startup)
        benchmark_startup
        ;;
    execution)
        benchmark_execution
        ;;
    pipelines)
        benchmark_pipelines
        ;;
    scripting)
        benchmark_scripting
        ;;
    comparison)
        benchmark_comparison
        ;;
    all)
        benchmark_startup
        benchmark_execution
        benchmark_pipelines
        benchmark_scripting
        ;;
    *)
        echo "Usage: $0 [startup|execution|pipelines|scripting|comparison|all]"
        exit 1
        ;;
esac

echo "=== Benchmark Complete ==="
