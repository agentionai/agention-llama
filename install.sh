#!/usr/bin/env sh
# agention-llama installer.
#
#   curl -fsSL https://raw.githubusercontent.com/agentionai/agention-llama/main/install.sh | sh
#
# Clones this repo to ~/.local/share/agention-llama and links the CLI into
# ~/.local/bin. Cloning rather than embedding is deliberate: the recipes are
# short env files meant to be read and edited, and a single self-contained
# script would take that away.
#
# It installs no binaries and pulls no images — `agention-llama run` does that
# on first use, once you have run the doctor and know the machine is set up.
set -eu

REPO="${AGENTION_REPO:-https://github.com/agentionai/agention-llama.git}"
BRANCH="${AGENTION_BRANCH:-main}"
SHARE="${AGENTION_HOME:-$HOME/.local/share/agention-llama}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

command -v git >/dev/null 2>&1 || { echo "install.sh: git is required" >&2; exit 1; }

if [ -d "$SHARE/.git" ]; then
    echo ">> updating $SHARE"
    git -C "$SHARE" fetch --quiet origin "$BRANCH"
    git -C "$SHARE" reset --quiet --hard "origin/$BRANCH"
else
    echo ">> cloning into $SHARE"
    mkdir -p "$(dirname "$SHARE")"
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$SHARE"
fi

mkdir -p "$BINDIR"
ln -sf "$SHARE/bin/agention-llama" "$BINDIR/agention-llama"
echo ">> linked $BINDIR/agention-llama"

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) echo
       echo "   $BINDIR is not on your PATH. Add it:"
       echo "     echo 'export PATH=\"\$PATH:$BINDIR\"' >> ~/.bashrc && exec \$SHELL"
       ;;
esac

cat <<'EOF'

installed. next:

  agention-llama doctor      is this machine set up to be fast?
  agention-llama recipes     the configurations, one per use case
  agention-llama run plain -- -m /path/to/model.gguf

The doctor first. It takes a second and tells you whether the GPU is reachable
and whether the fork's headline prefill fix is actually on — which is driver-
gated, and silent when it is not taken.
EOF
