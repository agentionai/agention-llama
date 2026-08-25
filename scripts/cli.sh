#!/usr/bin/env bash
# Interactive `llama cli` in the container, same GPU wiring as server.sh.
#
#   scripts/cli.sh -m /models/qwen3.8-27b.gguf -ngl 99
#   scripts/cli.sh --preset dflash-short -m /models/qwen3.8-27b.gguf
#
# Any other binary in the image:
#   BINARY=/app/llama-bench scripts/cli.sh -m /models/model.gguf
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-agention-llama}:${TAG:-cli}"
MODELS="${MODELS_DIR:-$HOME/models}"
ENVFILES=()
ENTRY=()

[ -f .env ] && ENVFILES+=(--env-file .env)
[ -n "${BINARY:-}" ] && ENTRY=(-e "AGENTION_BINARY=$BINARY")

ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --preset)
            f="presets/$2.env"
            [ -f "$f" ] || { echo "no such preset: $f" >&2; exit 1; }
            ENVFILES+=(--env-file "$f"); shift 2 ;;
        --models) MODELS="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

GROUPS_ARGS=()
for g in render video; do
    gid=$(getent group "$g" 2>/dev/null | cut -d: -f3 || true)
    [ -n "$gid" ] && GROUPS_ARGS+=(--group-add "$gid")
done

# `llama` is the unified launcher, so the default CMD is `cli`; when a specific
# binary is requested via BINARY there is no subcommand to insert.
if [ -z "${BINARY:-}" ]; then
    set -- cli "${ARGS[@]+"${ARGS[@]}"}"
else
    set -- "${ARGS[@]+"${ARGS[@]}"}"
fi

exec docker run --rm -it \
    --device /dev/dri \
    "${GROUPS_ARGS[@]}" \
    -v "$MODELS:/models" \
    "${ENVFILES[@]}" \
    "${ENTRY[@]+"${ENTRY[@]}"}" \
    "$IMAGE" "$@"
