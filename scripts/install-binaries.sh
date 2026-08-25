#!/usr/bin/env sh
# Install this tarball into /opt/agention-llama and symlink the binaries.
#   ./install.sh [prefix]        default prefix: /opt/agention-llama
set -eu

PREFIX="${1:-/opt/agention-llama}"
BINDIR="${BINDIR:-/usr/local/bin}"
HERE=$(cd "$(dirname "$0")" && pwd)

SUDO=
[ -w "$(dirname "$PREFIX")" ] || SUDO=sudo

echo "installing to $PREFIX"
$SUDO rm -rf "$PREFIX"
$SUDO mkdir -p "$PREFIX"
$SUDO cp -a "$HERE/." "$PREFIX/"

# $ORIGIN in the rpath resolves through the symlink to the real directory, so
# the .so files stay next to the binaries and only the names get linked.
for b in llama llama-cli llama-server llama-bench llama-quantize; do
    $SUDO ln -sf "$PREFIX/$b" "$BINDIR/$b"
done
$SUDO ln -sf "$PREFIX/doctor.sh" "$BINDIR/agention-llama-doctor"

echo "installed. next: agention-llama-doctor"
