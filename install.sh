#!/usr/bin/env bash
#
# git-session installer
#
# Usage:
#   ./install.sh              # Build and install to ~/.local/bin
#   ./install.sh --prefix ~   # Install to ~/bin
#   ./install.sh --help       # Show usage
#
# This script:
#   1. Checks that required tools are present (Zig 0.16+, Git, tmux)
#   2. Builds git-session from source
#   3. Installs the binary to PREFIX/bin
#

set -euo pipefail

# --- Defaults ---
PREFIX="$HOME/.local"
BINARY_NAME="git-session"

# --- Colors (disabled if not a terminal) ---
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# --- Helpers ---
info()  { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}==>${RESET} ${BOLD}%s${RESET}\n" "$*"; }
warn()  { printf "${YELLOW}warning:${RESET} %s\n" "$*"; }
error() { printf "${RED}error:${RESET} %s\n" "$*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install git-session from source.

Options:
  --prefix DIR    Installation prefix (default: ~/.local)
                  Binary is placed in DIR/bin/
  --help          Show this help message

Examples:
  ./install.sh                    # Install to ~/.local/bin
  ./install.sh --prefix ~/.local  # Install to ~/.local/bin
EOF
    exit 0
}

# --- Parse arguments ---
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || die "--prefix requires a directory argument"
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

# Expand ~ in PREFIX
PREFIX="${PREFIX/#\~/$HOME}"
INSTALL_DIR="$PREFIX/bin"

# --- Refuse to run as root ---
if [ "$(id -u)" -eq 0 ]; then
    die "Do not run this script as root or with sudo. It installs to ~/.local/bin by default, which does not require elevated privileges."
fi

# --- Prerequisite checks ---
info "Checking prerequisites..."

MISSING=0

# Check Zig
if ! command -v zig &>/dev/null; then
    error "zig is not installed."
    printf "  Install it from: https://ziglang.org/download/\n" >&2
    MISSING=1
else
    ZIG_VERSION=$(zig version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    ZIG_MAJOR=$(echo "$ZIG_VERSION" | cut -d. -f1)
    ZIG_MINOR=$(echo "$ZIG_VERSION" | cut -d. -f2)

    if [ "$ZIG_MAJOR" -eq 0 ] && [ "$ZIG_MINOR" -lt 16 ]; then
        error "Zig 0.16+ is required (found $ZIG_VERSION)"
        printf "  Update from: https://ziglang.org/download/\n" >&2
        MISSING=1
    else
        ok "zig $ZIG_VERSION"
    fi
fi

# Check Git
if ! command -v git &>/dev/null; then
    error "git is not installed."
    printf "  Install it from: https://git-scm.com/\n" >&2
    MISSING=1
else
    ok "git $(git --version | awk '{print $3}')"
fi

# Check tmux
if ! command -v tmux &>/dev/null; then
    error "tmux is not installed."
    printf "  Install it from: https://github.com/tmux/tmux\n" >&2
    MISSING=1
else
    ok "tmux $(tmux -V | awk '{print $2}')"
fi

[ "$MISSING" -eq 0 ] || die "Missing prerequisites. Install the tools listed above and try again."

# --- Verify we're in the right directory ---
if [ ! -f "build.zig" ] || [ ! -f "src/main.zig" ]; then
    die "This script must be run from the git-session repository root."
fi

# --- Build ---
BUILD_OUTPUT="zig-out/bin/$BINARY_NAME"

info "Building git-session..."
if ! zig build -Doptimize=ReleaseSafe; then
    die "Build failed. Check the output above for errors."
fi
ok "Build complete"

# --- Install ---
info "Installing to $INSTALL_DIR..."

# Create bin directory if needed
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" || {
        error "Cannot create $INSTALL_DIR"
        exit 1
    }
fi

if [ ! -f "$BUILD_OUTPUT" ]; then
    die "Build output not found at $BUILD_OUTPUT"
fi

cp "$BUILD_OUTPUT" "$INSTALL_DIR/$BINARY_NAME" || {
    error "Cannot copy to $INSTALL_DIR/$BINARY_NAME"
    exit 1
}

chmod +x "$INSTALL_DIR/$BINARY_NAME"

ok "Installed $BINARY_NAME to $INSTALL_DIR/$BINARY_NAME"

# --- Verify PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    warn "$INSTALL_DIR is not in your PATH"
    printf "  Add it to your shell profile:\n"
    printf "    export PATH=\"%s:\$PATH\"\n" "$INSTALL_DIR"
fi

# --- Done ---
printf "\n"
ok "Installation complete! Run 'git-session' to get started."
