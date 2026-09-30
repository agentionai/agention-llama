#!/usr/bin/env bash
# Build the agention-llama images (and the portable tarball) from a llama.cpp
# fork checkout, without putting anything inside the fork tree.
#
#   scripts/build.sh                        # server image from ../llama.cpp
#   scripts/build.sh cli                    # cli image
#   scripts/build.sh dist                   # portable linux x64 tarball -> ./dist
#   scripts/build.sh server --ref main      # from a fresh clone of the fork
#   LLAMA_SRC=/path/to/llama.cpp scripts/build.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

TARGET="${1:-server}"
[ $# -gt 0 ] && shift || true

SRC="${LLAMA_SRC:-../llama.cpp}"
REF=""
IMAGE="${IMAGE:-agention-llama}"
TAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --src)  SRC="$2"; shift 2 ;;
        --ref)  REF="$2"; shift 2 ;;
        --tag)  TAG="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# --ref: clone the public fork at a ref into a local cache, then treat it like
# any other checkout. Pinning by SHA is what makes an image reproducible.
if [ -n "$REF" ]; then
    CACHE="$REPO_ROOT/.cache/llama-src"
    FORK_URL="${FORK_URL:-https://github.com/agentionai/llama.cpp.git}"
    if [ ! -d "$CACHE/.git" ]; then
        echo ">> cloning $FORK_URL"
        git clone "$FORK_URL" "$CACHE"
    fi
    git -C "$CACHE" fetch --all --tags --prune
    git -C "$CACHE" checkout --detach "$REF"
    SRC="$CACHE"
fi

SRC=$(cd "$SRC" && pwd)
[ -f "$SRC/CMakeLists.txt" ] || { echo "not a llama.cpp checkout: $SRC" >&2; exit 1; }

COMMIT=$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)
BRANCH=$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
NUMBER=$(git -C "$SRC" rev-list --count HEAD 2>/dev/null || echo 0)
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DIRTY=""
git -C "$SRC" diff --quiet 2>/dev/null || DIRTY=" (uncommitted changes included)"

[ -n "$TAG" ] || TAG="$TARGET"

echo ">> source  $SRC"
echo ">> commit  $COMMIT on $BRANCH (build $NUMBER)$DIRTY"
echo ">> target  $TARGET"

args=(
    --build-context "llamasrc=$SRC"
    --file docker/Dockerfile
    --target "$TARGET"
    --build-arg "APP_VERSION=$NUMBER"
    --build-arg "LLAMA_COMMIT=$COMMIT"
    --build-arg "LLAMA_BRANCH=$BRANCH"
    --build-arg "BUILD_DATE=$DATE"
)

case "$TARGET" in
    dist)
        mkdir -p dist
        args+=(--output "type=local,dest=$REPO_ROOT/dist")
        echo ">> output  $REPO_ROOT/dist"
        ;;
    *)
        args+=(--tag "$IMAGE:$TAG" --tag "$IMAGE:$TAG-$COMMIT" --load)
        echo ">> image   $IMAGE:$TAG (also tagged :$TAG-$COMMIT)"
        ;;
esac

docker buildx build "${args[@]}" .

if [ "$TARGET" = dist ]; then
    ls -lh dist/
else
    echo
    echo "done. try: scripts/doctor.sh   then   scripts/server.sh --help"
fi
