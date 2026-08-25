#!/usr/bin/env sh
# Runs the doctor first so a misconfigured GPU shows up as a line of output
# rather than as mysteriously slow tokens, then hands off to the real binary.
set -eu

if [ "${AGENTION_SKIP_PREFLIGHT:-0}" != "1" ]; then
    /app/doctor.sh --brief || true
fi

exec "${AGENTION_BINARY:-/app/llama-server}" "$@"
