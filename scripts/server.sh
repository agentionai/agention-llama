#!/usr/bin/env bash
# Run llama-server in the agention-llama container with the GPU wired up.
# Lower-level than `agention-llama run`; that is what most people want.
#
#   scripts/server.sh                                   # uses .env / defaults
#   scripts/server.sh --preset mtp-long
#   scripts/server.sh --models-ini examples/models.ini  # per-model config
#   scripts/server.sh --models ~/models -- -m /models/qwen3.8-27b.gguf -ngl 99
#
# With no model argument the server runs in router mode and serves everything
# in --models, configured by --models-ini. Everything after `--` goes straight
# to llama-server.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-agention-llama}:${TAG:-server}"
MODELS="${MODELS_DIR:-$HOME/models}"
PORT="${PORT:-8080}"
NAME="${NAME:-agention-llama}"
PRESET=""
MODELS_INI="${MODELS_INI:-presets/globals.ini}"
ENVFILES=()

[ -f .env ] && ENVFILES+=(--env-file .env)

while [ $# -gt 0 ]; do
    case "$1" in
        --preset) PRESET="$2"; shift 2 ;;
        --models-ini) MODELS_INI="$2"; shift 2 ;;
        --models) MODELS="$2"; shift 2 ;;
        --port)   PORT="$2";   shift 2 ;;
        --name)   NAME="$2";   shift 2 ;;
        --)       shift; break ;;
        --help|-h) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1 (put llama-server args after --)" >&2; exit 2 ;;
    esac
done

if [ -n "$PRESET" ]; then
    f="presets/$PRESET.env"
    [ -f "$f" ] || { echo "no such preset: $f" >&2; ls presets/*.env >&2; exit 1; }
    ENVFILES+=(--env-file "$f")
    echo ">> preset  $PRESET"
fi

mkdir -p "$MODELS"

# The INI carries per-model configuration (context, thinking, speculative
# decoding). Mounted read-only at a fixed path so the container never depends on
# where it lives on the host.
INI_ARGS=()
if [ -n "$MODELS_INI" ]; then
    [ -f "$MODELS_INI" ] || { echo "no such models ini: $MODELS_INI" >&2; exit 1; }
    INI_ARGS=(
        -v "$(cd "$(dirname "$MODELS_INI")" && pwd)/$(basename "$MODELS_INI"):/etc/agention/models.ini:ro"
        -e "LLAMA_ARG_MODELS_PRESET=/etc/agention/models.ini"
    )
    echo ">> ini     $MODELS_INI"
fi

# A container process can only touch /dev/dri/renderD* if it is in the host's
# render group. That gid differs per distro, so read it rather than hardcode it.
GROUPS_ARGS=()
for g in render video; do
    gid=$(getent group "$g" 2>/dev/null | cut -d: -f3 || true)
    [ -n "$gid" ] && GROUPS_ARGS+=(--group-add "$gid")
done

echo ">> image   $IMAGE"
echo ">> models  $MODELS -> /models"
echo ">> web ui  http://localhost:$PORT"

exec docker run --rm -it \
    --name "$NAME" \
    --device /dev/dri \
    "${GROUPS_ARGS[@]}" \
    -v "$MODELS:/models" \
    -w /models \
    -p "$PORT:8080" \
    "${INI_ARGS[@]+"${INI_ARGS[@]}"}" \
    "${ENVFILES[@]}" \
    "$IMAGE" "$@"
