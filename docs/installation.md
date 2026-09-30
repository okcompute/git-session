# Installation

git-session is distributed as prebuilt binaries attached to [GitHub Releases](https://github.com/okcompute/git-session/releases). Each release contains one archive per supported platform plus a `SHA256SUMS` file with the SHA-256 checksum of every archive.

## Supported platforms

| Platform | Asset |
|---|---|
| Linux (x86_64) | `git-session-x86_64-linux.tar.gz` |
| Linux (arm64) | `git-session-aarch64-linux.tar.gz` |
| macOS (Apple silicon) | `git-session-aarch64-macos.tar.gz` |
| macOS (Intel) | `git-session-x86_64-macos.tar.gz` |

The Linux binaries are statically linked, so they run on any x86_64 or arm64 Linux distribution without libc version constraints.

## Quick install (recommended)

The install script detects your platform, downloads the matching release asset, verifies its checksum against `SHA256SUMS`, and installs the binary to `~/.local/bin`:

```bash
curl -fsSL https://raw.githubusercontent.com/okcompute/git-session/main/install.sh | bash
```

Pass options to the script with `bash -s --`:

```bash
# Install a specific release
curl -fsSL https://raw.githubusercontent.com/okcompute/git-session/main/install.sh | bash -s -- --version v1.0.0

# Install to a different prefix (binary goes to PREFIX/bin)
curl -fsSL https://raw.githubusercontent.com/okcompute/git-session/main/install.sh | bash -s -- --prefix ~

# Build from source instead of downloading (requires Zig 0.16+)
curl -fsSL https://raw.githubusercontent.com/okcompute/git-session/main/install.sh | bash -s -- --from-source
```

You can also clone the repository and run `./install.sh` with the same options. If the platform has no prebuilt binary or the download fails, the script falls back to building from source.

## Manual install

Download the archive for your platform, verify it, and extract the binary:

```bash
VERSION=v1.0.0
TARGET=aarch64-macos          # see the platform table above

curl -fLO "https://github.com/okcompute/git-session/releases/download/${VERSION}/git-session-${TARGET}.tar.gz"
curl -fLO "https://github.com/okcompute/git-session/releases/download/${VERSION}/SHA256SUMS"

# Verify the checksum
expected=$(awk -v f="git-session-${TARGET}.tar.gz" '$2 == f { print $1 }' SHA256SUMS)
actual=$(shasum -a 256 "git-session-${TARGET}.tar.gz" | awk '{print $1}')   # macOS
# actual=$(sha256sum "git-session-${TARGET}.tar.gz" | awk '{print $1}')     # Linux
[ "$expected" = "$actual" ] && echo "checksum OK" || { echo "checksum MISMATCH"; exit 1; }

tar -xzf "git-session-${TARGET}.tar.gz"
install -m 755 git-session ~/.local/bin/git-session
```

To always fetch the newest release, replace `releases/download/${VERSION}` with `releases/latest/download` in the URLs above.

## Requirements

- Git
- tmux >= 3.0

Zig 0.16+ is required only when building from source.

## Verifying the installation

```bash
git-session --version
```

The version string matches the release tag (the `v` is dropped): release `v1.0.0` reports `git-session 1.0.0`.
