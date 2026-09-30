#!/usr/bin/env bash
#
# git-session installer
#
# Usage:
#   ./install.sh                    # install the latest release to ~/.local/bin
#   ./install.sh --prefix ~         # install to ~/bin
#   ./install.sh --version v1.0.0   # install a specific release
#   ./install.sh --from-source      # build from source instead of downloading
#   ./install.sh --help             # show usage
#
# By default the installer downloads the prebuilt binary for the current
# platform from GitHub Releases, verifies its SHA-256 checksum against the
# release's SHA256SUMS file, and installs it to PREFIX/bin.
#
# If the platform has no prebuilt binary, the download fails, or
# --from-source is given, the installer falls back to building from source
# (which requires Zig 0.16+ and must be run from the repository root).

set -euo pipefail

# --- Defaults ---
PREFIX="$HOME/.local"
BINARY_NAME="git-session"
REPO="okcompute/git-session"
VERSION="latest"
FROM_SOURCE=0

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

Install git-session.

By default the prebuilt binary for this platform is downloaded from GitHub
Releases and installed to PREFIX/bin. Use --from-source to build instead.

Options:
  --prefix DIR     Installation prefix (default: ~/.local)
                   Binary is placed in DIR/bin/
  --version VER    Release to install: "latest" (default) or a tag such as v1.0.0
  --from-source    Build from source instead of downloading a release
  --help           Show this help message

Examples:
  ./install.sh                    # Install the latest release to ~/.local/bin
  ./install.sh --prefix ~         # Install to ~/bin
  ./install.sh --version v1.0.0   # Install a specific release
  ./install.sh --from-source      # Build from source
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
        --version)
            [ $# -ge 2 ] || die "--version requires an argument"
            VERSION="$2"
            shift 2
            ;;
        --version=*)
            VERSION="${1#--version=}"
            shift
            ;;
        --from-source)
            FROM_SOURCE=1
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

# Normalize a bare version (1.0.0) to its tag (v1.0.0)
if [ "$VERSION" != "latest" ] && [ "${VERSION#v}" = "$VERSION" ]; then
    VERSION="v${VERSION}"
fi

# --- Refuse to run as root ---
if [ "$(id -u)" -eq 0 ]; then
    die "Do not run this script as root or with sudo. It installs to ~/.local/bin by default, which does not require elevated privileges."
fi

# --- Download helper ---
download() {
    # download <url> <dest>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        return 1
    fi
}

sha256_of() {
    # sha256_of <file> -> hex digest on stdout
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

detect_target() {
    # Maps the host to a release asset target, e.g. aarch64-macos.
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Linux)  os="linux" ;;
        Darwin) os="macos" ;;
        *) return 1 ;;
    esac
    case "$arch" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *) return 1 ;;
    esac
    printf '%s-%s' "$arch" "$os"
}

# --- Check runtime prerequisites (git, tmux) ---
check_runtime_deps() {
    info "Checking prerequisites..."

    MISSING=0

    if ! command -v git >/dev/null 2>&1; then
        error "git is not installed."
        printf "  Install it from: https://git-scm.com/\n" >&2
        MISSING=1
    else
        ok "git $(git --version | awk '{print $3}')"
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        error "tmux is not installed."
        printf "  Install it from: https://github.com/tmux/tmux\n" >&2
        MISSING=1
    else
        ok "tmux $(tmux -V | awk '{print $2}')"
    fi

    [ "$MISSING" -eq 0 ] || die "Missing prerequisites. Install the tools listed above and try again."
}

# --- Install from a GitHub release ---
install_prebuilt() {
    local target
    if ! target="$(detect_target)"; then
        warn "No prebuilt binary for this platform ($(uname -s)/$(uname -m))."
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        warn "Neither curl nor wget is available to download the release."
        return 1
    fi

    local base asset tmp
    if [ "$VERSION" = "latest" ]; then
        base="https://github.com/${REPO}/releases/latest/download"
    else
        base="https://github.com/${REPO}/releases/download/${VERSION}"
    fi
    asset="git-session-${target}.tar.gz"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    info "Downloading ${asset} (${VERSION})..."
    if ! download "${base}/${asset}" "${tmp}/${asset}"; then
        if [ "$VERSION" != "latest" ]; then
            die "Release ${VERSION} does not provide ${asset}. Check that the tag exists and supports this platform."
        fi
        # No release published yet: fall back to a source build.
        warn "No release asset available at ${base}/${asset}."
        trap - EXIT
        rm -rf "$tmp"
        return 1
    fi

    # Verification is mandatory: every release ships a SHA256SUMS file.
    if ! download "${base}/SHA256SUMS" "${tmp}/SHA256SUMS" 2>/dev/null; then
        die "Could not download SHA256SUMS for ${VERSION}; refusing to install an unverified binary."
    fi

    local expected actual
    expected="$(awk -v f="$asset" '$2 == f { print $1 }' "${tmp}/SHA256SUMS" | head -n1)"
    if [ -z "$expected" ]; then
        die "SHA256SUMS does not list ${asset}; refusing to install an unverified binary."
    fi

    if ! actual="$(sha256_of "${tmp}/${asset}")"; then
        die "Neither sha256sum nor shasum is available; cannot verify the download."
    fi

    if [ "$expected" != "$actual" ]; then
        error "Checksum mismatch for ${asset}"
        printf "  expected %s\n  got      %s\n" "$expected" "$actual" >&2
        die "Refusing to install a binary whose checksum does not match."
    fi
    ok "Checksum verified"

    info "Installing to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR" || { error "Cannot create $INSTALL_DIR"; exit 1; }

    if ! tar -xzf "${tmp}/${asset}" -C "$tmp" "$BINARY_NAME"; then
        die "Failed to extract ${asset}."
    fi

    cp "${tmp}/${BINARY_NAME}" "$INSTALL_DIR/$BINARY_NAME" || {
        error "Cannot copy to $INSTALL_DIR/$BINARY_NAME"
        exit 1
    }
    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    trap - EXIT
    rm -rf "$tmp"

    ok "Installed $BINARY_NAME to $INSTALL_DIR/$BINARY_NAME"
    return 0
}

# --- Build from source ---
build_from_source() {
    info "Building from source..."

    if ! command -v zig >/dev/null 2>&1; then
        error "zig is not installed (required to build from source)."
        printf "  Install it from: https://ziglang.org/download/\n" >&2
        die "Cannot build from source without Zig 0.16+."
    fi

    ZIG_VERSION=$(zig version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    ZIG_MAJOR=$(echo "$ZIG_VERSION" | cut -d. -f1)
    ZIG_MINOR=$(echo "$ZIG_VERSION" | cut -d. -f2)
    if [ "$ZIG_MAJOR" -eq 0 ] && [ "$ZIG_MINOR" -lt 16 ]; then
        error "Zig 0.16+ is required (found $ZIG_VERSION)"
        printf "  Update from: https://ziglang.org/download/\n" >&2
        die "Cannot build from source with an older Zig."
    fi
    ok "zig $ZIG_VERSION"

    # Use the current directory when it is the repository root; otherwise
    # clone the repository into a temporary directory so that
    # `curl ... | bash -s -- --from-source` works from anywhere.
    local src_dir="$PWD"
    local clone_dir=""
    if [ ! -f "build.zig" ] || [ ! -f "src/main.zig" ]; then
        clone_dir="$(mktemp -d)"
        trap 'rm -rf "$clone_dir"' EXIT
        info "Cloning ${REPO}..."
        if ! git clone --depth 1 "https://github.com/${REPO}.git" "$clone_dir" >/dev/null 2>&1; then
            die "Could not clone ${REPO}. Run this script from the repository root to build from source."
        fi
        src_dir="$clone_dir"
    fi

    info "Building git-session..."
    if ! ( cd "$src_dir" && zig build -Doptimize=ReleaseSafe ); then
        die "Build failed. Check the output above for errors."
    fi
    ok "Build complete"

    local build_output="$src_dir/zig-out/bin/$BINARY_NAME"
    if [ ! -f "$build_output" ]; then
        die "Build output not found at $build_output"
    fi

    info "Installing to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR" || { error "Cannot create $INSTALL_DIR"; exit 1; }
    cp "$build_output" "$INSTALL_DIR/$BINARY_NAME" || {
        error "Cannot copy to $INSTALL_DIR/$BINARY_NAME"
        exit 1
    }
    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    if [ -n "$clone_dir" ]; then
        trap - EXIT
        rm -rf "$clone_dir"
    fi

    ok "Installed $BINARY_NAME to $INSTALL_DIR/$BINARY_NAME"
}

# --- Install ---
check_runtime_deps

INSTALLED=0
if [ "$FROM_SOURCE" -eq 0 ]; then
    if install_prebuilt; then
        INSTALLED=1
    else
        warn "Falling back to building from source."
    fi
fi
if [ "$INSTALLED" -eq 0 ]; then
    build_from_source
fi

# --- Verify the installed binary runs ---
if ! "$INSTALL_DIR/$BINARY_NAME" --version >/dev/null 2>&1; then
    warn "Installed binary did not run cleanly; check that it matches your platform."
fi

# --- Verify PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    warn "$INSTALL_DIR is not in your PATH"
    printf "  Add it to your shell profile:\n"
    printf "    export PATH=\"%s:\$PATH\"\n" "$INSTALL_DIR"
fi

# --- Done ---
printf "\n"
ok "Installation complete! Run 'git-session' to get started."
