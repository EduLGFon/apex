#!/usr/bin/env bash
#
# apex.sh — Parallelized system updater
# (Arch pacman+AUR, Debian/Ubuntu apt, Fedora/RHEL dnf,
#  plus flatpak and snap)
#
# The script does NOT assume these are mutually exclusive — pacman, apt,
# and dnf are each detected independently and handled if present, whether
# alone or side by side (e.g. inside containers/WSL/unusual setups).
#
# STRATEGY (minimize wall-clock time, without racing anything unsafe):
#
#   1. For every system package manager found (pacman, apt, dnf), run its
#      "download only, don't install" step, ONE AT A TIME. These are the
#      only steps guaranteed to compete for your download bandwidth, so
#      they're kept serialized against each other and against everything
#      else.
#
#   2. Once all of those download steps are done, everything below starts
#      together in the background:
#        - each manager's real install/upgrade step (reads from its cache,
#          so it's disk/CPU work, not network)
#        - your AUR helper (yay/paru), which resolves + clones + builds
#          AUR updates
#
#   3. As soon as the AUR helper finishes its upfront resolve/clone burst
#      and starts actually building packages, flatpak then snap are
#      started too — while the manager installs and the AUR build keep
#      running in the background.
#
#   4. Everything is joined at the end and a summary is printed.
#
# Anything not present (pacman, apt, dnf, yay/paru, flatpak, snap) is
# skipped automatically.
#
# HOW STEP 3'S AUR TIMING IS DETECTED
#   Both yay and paru shell out to the real `makepkg` binary to build
#   packages. makepkg's very first line of output for any package is
#   always:
#       ==> Making package: <name> <version> (<date>)
#   That line comes from makepkg itself (not the AUR helper's own wrapper
#   text), and has been stable across versions for years. We watch the AUR
#   helper's log for the first occurrence of that line and treat it as "the
#   upfront download burst is done, real building has started" — a
#   reasonable, if not perfectly exact, proxy. Per-package source downloads
#   inside individual builds can still trickle in after this point; those
#   are typically small next to compile time. LC_ALL=C is forced on that
#   one subprocess so the line is always in English regardless of your
#   system locale. Pass --conservative to skip this heuristic entirely and
#   just wait for the whole AUR job to finish first.
#
# NOTES ON apt / dnf
#   - apt runs with DEBIAN_FRONTEND=noninteractive and
#     --force-confdef/--force-confold so a config-file prompt can't
#     silently hang a background job; when in doubt it keeps your current
#     config file.
#   - dnf's --downloadonly needs the "download" plugin from
#     dnf-plugins-core. If it's missing, the download-only step will fail;
#     the script logs that but keeps going — the later install step still
#     does a normal (download+install) upgrade, it just won't have had the
#     benefit of pre-fetching.
#
# SAFETY NOTES
#   - To run the AUR helper unattended, this script auto-accepts
#     diffs/prompts (--noconfirm + answer flags). You lose the manual
#     "review the PKGBUILD" step. Review AUR packages separately/
#     periodically if that matters to you.
#   - In theory, a manager's own install step and the AUR helper's final
#     `pacman -U` could both want the pacman DB lock at once. In practice
#     this essentially never happens, since building AUR packages takes far
#     longer than installing already-cached packages — but if you ever see
#     "unable to lock database", just re-run the script.
#
set -uo pipefail

# ---------- options ----------
SKIP_PACMAN=0
SKIP_APT=0
SKIP_DNF=0
SKIP_AUR=0
SKIP_FLATPAK=0
SKIP_SNAP=0
NOTIFY=1
CONSERVATIVE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --no-pacman      Skip pacman even if present
  --no-apt         Skip apt even if present
  --no-dnf         Skip dnf even if present
  --no-aur         Skip AUR updates even if a helper is installed
  --no-flatpak     Skip flatpak updates
  --no-snap        Skip snap updates
  --no-notify      Don't send a desktop notification when finished
  --conservative   Wait for the AUR job to fully finish (not just its
                   initial download/resolve burst) before starting
                   flatpak/snap. Use this if the early-start detection
                   ever misbehaves for you.
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pacman) SKIP_PACMAN=1 ;;
        --no-apt) SKIP_APT=1 ;;
        --no-dnf) SKIP_DNF=1 ;;
        --no-aur) SKIP_AUR=1 ;;
        --no-flatpak) SKIP_FLATPAK=1 ;;
        --no-snap) SKIP_SNAP=1 ;;
        --no-notify) NOTIFY=0 ;;
        --conservative) CONSERVATIVE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

# ---------- logging helpers ----------
C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_RED='\033[1;31m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'

log()  { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[✓]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
fail() { echo -e "${C_RED}[✗]${C_RESET} $*" >&2; }
section() { echo; echo -e "${C_BLUE}== $* ==${C_RESET}"; }

human_time() {
    local s=$1
    printf '%dm%02ds' $((s / 60)) $((s % 60))
}

SCRIPT_START=$(date +%s)

# ---------- detect system package managers (independently, no assumptions) ----------
MANAGERS=()
[[ $SKIP_PACMAN -eq 0 ]] && command -v pacman  &>/dev/null && MANAGERS+=(pacman)
[[ $SKIP_APT    -eq 0 ]] && command -v apt-get &>/dev/null && MANAGERS+=(apt)
[[ $SKIP_DNF    -eq 0 ]] && command -v dnf     &>/dev/null && MANAGERS+=(dnf)

if [[ ${#MANAGERS[@]} -eq 0 ]]; then
    warn "No supported system package manager (pacman/apt/dnf) found or all skipped."
fi

# ---------- detect AUR helper (only meaningful alongside pacman) ----------
AUR_HELPER=""
if [[ $SKIP_AUR -eq 0 ]]; then
    for helper in yay paru; do
        if command -v "$helper" &>/dev/null; then
            AUR_HELPER="$helper"
            break
        fi
    done
fi

HAS_FLATPAK=0
[[ $SKIP_FLATPAK -eq 0 ]] && command -v flatpak &>/dev/null && HAS_FLATPAK=1

HAS_SNAP=0
[[ $SKIP_SNAP -eq 0 ]] && command -v snap &>/dev/null && HAS_SNAP=1

# ---------- per-manager download / install commands ----------
manager_download() {
    case "$1" in
        pacman)
            sudo pacman -Syuw --noconfirm
            ;;
        apt)
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && \
            sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -d -y
            ;;
        dnf)
            sudo dnf upgrade --refresh --downloadonly -y
            ;;
    esac
}

manager_install() {
    case "$1" in
        pacman)
            sudo pacman -Su --noconfirm
            ;;
        apt)
            sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold"
            ;;
        dnf)
            sudo dnf upgrade -y
            ;;
    esac
}

# ---------- sudo keep-alive ----------
if [[ ${#MANAGERS[@]} -gt 0 || $HAS_SNAP -eq 1 ]]; then
    log "Requesting sudo access up front..."
    if ! sudo -v; then
        fail "Could not get sudo access. Aborting."
        exit 1
    fi
    ( while true; do sudo -n -v; sleep 60; done ) &
    SUDO_KEEPALIVE_PID=$!
else
    SUDO_KEEPALIVE_PID=""
fi

AUR_LOG=""
AUR_PID=""
declare -A INSTALL_PID=()

cleanup() {
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    [[ -n "$AUR_PID" ]] && kill "$AUR_PID" 2>/dev/null
    for mgr in "${!INSTALL_PID[@]}"; do
        kill "${INSTALL_PID[$mgr]}" 2>/dev/null
    done
    [[ -n "$AUR_LOG" && -f "$AUR_LOG" ]] && rm -f "$AUR_LOG"
}
trap cleanup EXIT INT TERM

declare -A DOWNLOAD_STATUS=()
declare -A INSTALL_STATUS=()
AUR_STATUS=0
FLATPAK_STATUS=0
SNAP_STATUS=0

# Runs the AUR helper with output forced to English (for reliable marker
# detection) and line-buffered (so the log fills in real time), tee'd to
# both the terminal and a log file we can grep.
run_aur_and_log() {
    LC_ALL=C LANG=C stdbuf -oL -eL "$@" 2>&1 | tee "$AUR_LOG"
    return "${PIPESTATUS[0]}"
}

# Blocks until makepkg's "Making package:" line shows up in the AUR log
# (AUR helper moved from resolving/cloning into building), or the AUR job
# exits on its own (nothing to build / errored), or a safety timeout hits.
wait_for_aur_build_start() {
    local marker='^==> Making package:'
    local waited=0
    local max_wait=1200  # 20 minutes safety cap

    while true; do
        if grep -qm1 -E "$marker" "$AUR_LOG" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$AUR_PID" 2>/dev/null; then
            return 0
        fi
        if (( waited >= max_wait )); then
            warn "Timed out waiting for AUR build phase to start; proceeding anyway."
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# ---------- phase: download-only for each system package manager, serialized ----------
if [[ ${#MANAGERS[@]} -gt 0 ]]; then
    section "Downloading system package updates (${MANAGERS[*]}, one at a time)"
    for mgr in "${MANAGERS[@]}"; do
        log "Downloading $mgr updates..."
        T0=$(date +%s)
        manager_download "$mgr"
        DOWNLOAD_STATUS[$mgr]=$?
        T1=$(date +%s)
        if [[ ${DOWNLOAD_STATUS[$mgr]} -eq 0 ]]; then
            ok "$mgr downloads finished in $(human_time $((T1 - T0)))"
        else
            fail "$mgr download-only step failed (exit ${DOWNLOAD_STATUS[$mgr]})"
            if [[ "$mgr" == "dnf" ]]; then
                warn "This often means the 'download' plugin (dnf-plugins-core) isn't installed. Continuing — dnf's install step below will just download+install together."
            fi
        fi
    done
fi

# ---------- kick off all installs + AUR build in the background ----------
section "Starting installs + AUR update in the background"

for mgr in "${MANAGERS[@]}"; do
    log "Starting $mgr install..."
    manager_install "$mgr" &
    INSTALL_PID[$mgr]=$!
done

if [[ -n "$AUR_HELPER" ]]; then
    AUR_LOG=$(mktemp /tmp/aur-update-log.XXXXXX)
    log "Starting AUR update via $AUR_HELPER (noninteractive)..."
    case "$AUR_HELPER" in
        yay)
            AUR_CMD=("$AUR_HELPER" -Sua --noconfirm
                     --answerclean None --answerdiff None
                     --answeredit None --answerupgrade All)
            ;;
        paru)
            AUR_CMD=("$AUR_HELPER" -Sua --noconfirm --skipreview)
            ;;
    esac
    run_aur_and_log "${AUR_CMD[@]}" &
    AUR_PID=$!
else
    [[ $SKIP_AUR -eq 1 ]] && log "AUR updates skipped (--no-aur)."
    [[ $SKIP_AUR -eq 0 ]] && warn "No AUR helper (yay/paru) found — skipping AUR updates."
fi

# ---------- wait for the right moment to start flatpak/snap ----------
if [[ -n "$AUR_PID" ]]; then
    if [[ $CONSERVATIVE -eq 1 ]]; then
        log "Conservative mode: waiting for the AUR update to fully finish..."
        wait "$AUR_PID"
        AUR_STATUS=$?
        if [[ $AUR_STATUS -eq 0 ]]; then ok "AUR update finished"; else fail "AUR update failed (exit $AUR_STATUS)"; fi
        AUR_PID=""   # already reaped
    else
        log "Waiting for AUR's initial resolve/clone burst to finish before starting flatpak..."
        wait_for_aur_build_start
        ok "AUR build phase reached — starting flatpak/snap now while it keeps building."
    fi
fi

# ---------- flatpak, then snap (foreground, sequential) ----------
section "flatpak, then snap"

if [[ $HAS_FLATPAK -eq 1 ]]; then
    log "Updating flatpak packages..."
    T0=$(date +%s)
    flatpak update -y
    FLATPAK_STATUS=$?
    T1=$(date +%s)
    if [[ $FLATPAK_STATUS -eq 0 ]]; then
        ok "flatpak updated in $(human_time $((T1 - T0)))"
    else
        fail "flatpak update failed (exit $FLATPAK_STATUS)"
    fi
elif [[ $SKIP_FLATPAK -eq 1 ]]; then
    log "flatpak skipped (--no-flatpak)."
else
    log "flatpak not installed — skipping."
fi

if [[ $HAS_SNAP -eq 1 ]]; then
    log "Updating snap packages..."
    T0=$(date +%s)
    sudo snap refresh
    SNAP_STATUS=$?
    T1=$(date +%s)
    if [[ $SNAP_STATUS -eq 0 ]]; then
        ok "snap updated in $(human_time $((T1 - T0)))"
    else
        fail "snap update failed (exit $SNAP_STATUS)"
    fi
elif [[ $SKIP_SNAP -eq 1 ]]; then
    log "snap skipped (--no-snap)."
else
    log "snap not installed — skipping."
fi

# ---------- join remaining background jobs ----------
section "Finishing up background jobs"

for mgr in "${MANAGERS[@]}"; do
    wait "${INSTALL_PID[$mgr]}"
    INSTALL_STATUS[$mgr]=$?
    if [[ ${INSTALL_STATUS[$mgr]} -eq 0 ]]; then
        ok "$mgr install finished"
    else
        fail "$mgr install failed (exit ${INSTALL_STATUS[$mgr]})"
    fi
done

if [[ -n "$AUR_PID" ]]; then
    wait "$AUR_PID"
    AUR_STATUS=$?
    if [[ $AUR_STATUS -eq 0 ]]; then
        ok "AUR update finished"
    else
        fail "AUR update failed (exit $AUR_STATUS)"
    fi
fi

# ---------- summary ----------
SCRIPT_END=$(date +%s)
TOTAL=$((SCRIPT_END - SCRIPT_START))

section "Summary"
echo "Total time: $(human_time $TOTAL)"

OVERALL_STATUS=0

for mgr in "${MANAGERS[@]}"; do
    if [[ ${INSTALL_STATUS[$mgr]:-0} -ne 0 ]]; then
        fail "$mgr failed (exit ${INSTALL_STATUS[$mgr]})"
        OVERALL_STATUS=1
    fi
done
for pair in "aur:$AUR_STATUS" "flatpak:$FLATPAK_STATUS" "snap:$SNAP_STATUS"; do
    name="${pair%%:*}"
    status="${pair##*:}"
    if [[ "$status" -ne 0 ]]; then
        fail "$name failed (exit $status)"
        OVERALL_STATUS=1
    fi
done
[[ $OVERALL_STATUS -eq 0 ]] && ok "Everything updated successfully."

if [[ $NOTIFY -eq 1 ]] && command -v notify-send &>/dev/null; then
    if [[ $OVERALL_STATUS -eq 0 ]]; then
        notify-send "System update complete" "Finished in $(human_time $TOTAL)" 2>/dev/null || true
    else
        notify-send -u critical "System update finished with errors" "Check the terminal output" 2>/dev/null || true
    fi
fi

exit $OVERALL_STATUS