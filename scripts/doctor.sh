#!/usr/bin/env sh
# agention-llama doctor — is this machine set up to get the fork's speed?
#
# Runs on the host, inside the container (as the server preflight) and from the
# binary tarball. Plain sh, no dependencies beyond vulkaninfo.
#
#   doctor.sh            full report
#   doctor.sh --brief    one-screen summary, never fails the caller
set -eu

BRIEF=0
[ "${1:-}" = "--brief" ] && BRIEF=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    R=$(printf '\033[31m'); Y=$(printf '\033[33m'); G=$(printf '\033[32m')
    B=$(printf '\033[1m');  Z=$(printf '\033[0m')
else
    R=; Y=; G=; B=; Z=
fi

WARNINGS=0
ok()   { printf '%s  ok %s %s\n'   "$G" "$Z" "$1"; }
warn() { printf '%s warn%s %s\n'   "$Y" "$Z" "$1"; WARNINGS=$((WARNINGS+1)); }
bad()  { printf '%s fail%s %s\n'   "$R" "$Z" "$1"; WARNINGS=$((WARNINGS+1)); }
info() { printf '      %s\n' "$1"; }

in_container() { [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; }

printf '%sagention-llama doctor%s' "$B" "$Z"
if in_container; then printf ' (in container)'; fi
printf '\n\n'

# --------------------------------------------------------------- build identity
if [ -f "$(dirname "$0")/BUILD_INFO" ]; then
    info "build: $(tr '\n' ' ' < "$(dirname "$0")/BUILD_INFO")"
    printf '\n'
fi

# ------------------------------------------------------------------- gpu access
if [ -d /dev/dri ]; then
    ok "/dev/dri present: $(ls /dev/dri | tr '\n' ' ')"
    node=$(ls /dev/dri/renderD* 2>/dev/null | head -1 || true)
    if [ -z "$node" ]; then
        bad "no render node (/dev/dri/renderD*) — the GPU will not be usable"
    elif [ ! -r "$node" ] || [ ! -w "$node" ]; then
        if in_container; then
            bad "$node is not readable/writable by uid $(id -u)"
            info "add the host's render group to the container: --group-add \$(getent group render | cut -d: -f3)"
        else
            bad "$node is not readable/writable by $(id -un)"
            info "fix with: sudo usermod -aG render,video $(id -un)   (then log out and back in)"
        fi
    fi
else
    bad "/dev/dri missing — pass --device /dev/dri to the container, or check the amdgpu driver"
fi

# ---------------------------------------------------------------- vulkan device
if ! command -v vulkaninfo >/dev/null 2>&1; then
    warn "vulkaninfo not found — cannot check the driver (install vulkan-tools)"
    DRIVER=; DRIVER_INFO=; DEVICE=
else
    SUMMARY=$(vulkaninfo --summary 2>/dev/null || true)
    DEVICE=$(printf '%s\n' "$SUMMARY" | grep -m1 'deviceName' | sed 's/.*= *//' || true)
    DRIVER=$(printf '%s\n' "$SUMMARY" | grep -m1 'driverName' | sed 's/.*= *//' || true)
    DRIVER_INFO=$(printf '%s\n' "$SUMMARY" | grep -m1 'driverInfo' | sed 's/.*= *//' || true)

    if [ -z "$DEVICE" ]; then
        bad "no Vulkan device found — llama will fall back to CPU"
    else
        ok "device: $DEVICE"
        info "driver: $DRIVER $DRIVER_INFO"
    fi
fi

# ------------------------------------------------------- the LDS pad driver gate
# ggml_vk_coopmat_shmem_pad(): pad 2 (the +12-14% prefill fix) is taken only on
# RADV >= 25.3, because older RADV lowers coopMatLoad to ds_read_b128 and the
# misaligned stride then costs more than the bank spread wins.
if [ -n "${GGML_VK_SHMEM_PAD:-}" ]; then
    warn "GGML_VK_SHMEM_PAD=$GGML_VK_SHMEM_PAD is set — overriding the driver gate (probing mode)"
elif [ "${DRIVER:-}" = "radv" ]; then
    MESA=$(printf '%s\n' "$DRIVER_INFO" | sed -n 's/.*Mesa \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    MAJ=${MESA%%.*}; MIN=${MESA#*.}
    if [ -n "$MESA" ] && { [ "$MAJ" -gt 25 ] || { [ "$MAJ" -eq 25 ] && [ "$MIN" -ge 3 ]; }; }; then
        ok "RADV $MESA >= 25.3 — LDS stride fix active (pad 2, ~+12-14% prefill)"
    else
        warn "RADV ${MESA:-?} < 25.3 — LDS stride fix stays off (pad 4, upstream default)"
        info "this is correct behaviour, not a bug: pad 2 on older RADV is >2x SLOWER"
        info "to get the fix, upgrade Mesa; the container images ship a new enough one"
    fi
elif [ -n "${DRIVER:-}" ]; then
    info "driver is not RADV — the LDS stride fix is RADV-only; everything else in the fork still applies"
fi

# --------------------------------------------------------------- other overrides
for v in GGML_VK_DENSE_F16B GGML_VK_DISABLE_F16 GGML_VK_VISIBLE_DEVICES; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && info "env: $v=$val"
done

if [ "$BRIEF" -eq 1 ]; then
    printf '\n'
    exit 0
fi

# ------------------------------------------------------------------- host extras
if ! in_container; then
    printf '\n%shost%s\n' "$B" "$Z"
    if command -v docker >/dev/null 2>&1; then
        ok "docker $(docker --version | sed 's/Docker version //;s/,.*//')"
        rgid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
        [ -n "$rgid" ] && info "render group gid: $rgid (scripts/server.sh passes this through)"
    else
        warn "docker not found — use the binary tarball instead"
    fi
    total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    info "system memory: $((total_kb / 1024 / 1024)) GiB (an APU shares this with the GPU)"
fi

printf '\n'
if [ "$WARNINGS" -eq 0 ]; then
    printf '%sall good.%s\n' "$G" "$Z"
else
    printf '%s%d thing(s) to look at above.%s\n' "$Y" "$WARNINGS" "$Z"
fi
