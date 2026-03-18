#!/bin/sh
set -e

REPO="refo/zipstream"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

# Detect OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)  os="linux" ;;
  Darwin) os="macos" ;;
  *)      echo "Unsupported OS: $OS" >&2; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64)  arch="x86_64" ;;
  aarch64|arm64) arch="aarch64" ;;
  *)             echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# Get latest release tag
if [ -n "$VERSION" ]; then
  tag="$VERSION"
else
  tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')"
fi

if [ -z "$tag" ]; then
  echo "Failed to determine latest version" >&2
  exit 1
fi

url="https://github.com/${REPO}/releases/download/${tag}/zipstream-${tag}-${arch}-${os}.tar.gz"

echo "Downloading zipstream ${tag} for ${arch}-${os}..."
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL "$url" | tar -xz -C "$tmpdir"

if [ ! -w "$INSTALL_DIR" ]; then
  echo "Installing to ${INSTALL_DIR} (requires sudo)..."
  sudo install -m 755 "$tmpdir/zipstream" "$INSTALL_DIR/zipstream"
else
  install -m 755 "$tmpdir/zipstream" "$INSTALL_DIR/zipstream"
fi

echo "zipstream ${tag} installed to ${INSTALL_DIR}/zipstream"
