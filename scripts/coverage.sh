#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test coverage for git-session using kcov
#
# Prerequisites:
#   macOS:  brew install kcov
#   Linux:  apt install kcov   (or build from source)
#
# Usage:
#   ./scripts/coverage.sh          # run tests with coverage, open report
#   ./scripts/coverage.sh --no-open  # run without opening browser
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COVERAGE_DIR="$PROJECT_ROOT/zig-coverage"
OPEN_REPORT=true

for arg in "$@"; do
    case "$arg" in
        --no-open) OPEN_REPORT=false ;;
    esac
done

# Check for kcov
if ! command -v kcov &>/dev/null; then
    echo "Error: kcov is not installed."
    echo ""
    echo "Install it with:"
    echo "  macOS:  brew install kcov"
    echo "  Linux:  sudo apt install kcov"
    echo ""
    echo "Then re-run this script."
    exit 1
fi

# Source files to collect coverage for
SRC_MODULES=(
    "src/config.zig"
    "src/git.zig"
    "src/tmux.zig"
    "src/io.zig"
    "src/repo.zig"
)

echo "Building test binaries..."

# Clean previous coverage data
rm -rf "$COVERAGE_DIR"
mkdir -p "$COVERAGE_DIR"

# Build test binaries (one per module) and run through kcov
for src in "${SRC_MODULES[@]}"; do
    module_name="$(basename "$src" .zig)"
    echo "  Testing $module_name..."

    # Build the test binary without running it
    test_bin=$(zig test \
        --test-no-exec \
        "$PROJECT_ROOT/$src" \
        2>&1)

    # zig test --test-no-exec prints the path to the test binary
    if [ ! -f "$test_bin" ]; then
        echo "    Warning: could not locate test binary for $module_name, skipping."
        continue
    fi

    # Run through kcov, collecting coverage only for our src/ files
    kcov \
        --include-path="$PROJECT_ROOT/src" \
        "$COVERAGE_DIR/$module_name" \
        "$test_bin"
done

# Merge individual module reports into a combined report
echo ""
echo "Merging coverage reports..."
kcov --merge "$COVERAGE_DIR/merged" "$COVERAGE_DIR"/*/

echo ""
echo "Coverage report: $COVERAGE_DIR/merged/index.html"

if $OPEN_REPORT; then
    if command -v open &>/dev/null; then
        open "$COVERAGE_DIR/merged/index.html"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$COVERAGE_DIR/merged/index.html"
    fi
fi
