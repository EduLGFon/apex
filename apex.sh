#!/usr/bin/env bash
#
# apex.sh — Parallelized system updater for Linux (Arch, Flatpak, Snap).
#
# STRATEGY (minimize wall-clock time, without racing anything unsafe):
#
#   1. pacman downloads all official-repo updates WITHOUT installing (-w).
#      This is the only phase that's guaranteed to compete for your download
#      bandwidth, so nothing else starts until it's finished.
#
#   2. The instant that download finishes, two things start at once:
#        a) pacman installs the already-downloaded packages (disk/CPU only,
#           no network)
#        b) your AUR helper (yay/paru) starts resolving + cloning + building
#           AUR updates
#
#   3. As soon as the AUR helper finishes its upfront dependency
#      resolution/cloning burst and starts actually building packages, we
#      start flatpak, then snap, one after another — all while pacman's
#      install and the AUR build keep running in the background.
#
#   4. Everything is joined at the end and a summary is printed.
#
# Anything you don't have installed (yay/paru, flatpak, snap) is skipped
# automatically.
#
# HOW STEP 3 IS DETECTED
#   Both yay and paru shell out to the real `makepkg` binary to build
#   packages. makepkg's very first line of output for any package is
#   always:
#       ==> Making package: <name> <version> (<date>)
#   That line is emitted by makepkg itself (not the AUR helper), and has
#   been stable across versions for years — it's a much steadier target
#   than parsing yay/paru's own wrapper output. We watch the AUR helper's
#   log for the first occurrence of that line and treat it as "the bulk
#   download burst (dependency resolution + AUR git clones) is done, real
#   building has started" — a reasonable, if not perfectly exact, proxy.
#   Per-package source downloads inside individual builds can still trickle
#   in after this point; those are typically small next to compile time, so
#   the residual bandwidth overlap is an acceptable trade for not blocking
#   flatpak/snap on the *entire* AUR job.
#   To make sure that line is always in English no matter your system
#   locale, we force LC_ALL=C for just that one subprocess.
#   If you'd rather not rely on this heuristic at all, pass --conservative
#   to wait for the whole AUR job to finish before starting flatpak/snap.
#
# SAFETY NOTES
#   - To run the AUR helper unattended, this script auto-accepts
#     diffs/prompts (--noconfirm + answer flags). You lose the manual
#     "review the PKGBUILD" step. Review AUR packages separately/
#     periodically if that matters to you.
#   - In theory, pacman's install step and the AUR helper's own final
#     `pacman -U` could both want the pacman DB lock at once. In practice
#     this essentially never happens, since building AUR packages takes far
#     longer than installing already-cached repo packages — but if you ever
#     see "unable to lock database", just re-run the script.
#
set -uo pipefail

# ---------- options ----------
SKIP_AUR=0
SKIP_FLATPAK=0
SKIP_SNAP=0
NOTIFY=1
CONSERVATIVE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

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

# ---------- detect what we have ----------
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

# ---------- sudo keep-alive ----------
log "Requesting sudo access up front (needed for pacman/snap)..."
if ! sudo -v; then
    fail "Could not get sudo access. Aborting."
    exit 1
fi
( while true; do sudo -n -v; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!

AUR_LOG=""
AUR_PID=""
PACMAN_INSTALL_PID=""

cleanup() {
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    [[ -n "$AUR_PID" ]] && kill "$AUR_PID" 2>/dev/null
    [[ -n "$PACMAN_INSTALL_PID" ]] && kill "$PACMAN_INSTALL_PID" 2>/dev/null
    [[ -n "$AUR_LOG" && -f "$AUR_LOG" ]] && rm -f "$AUR_LOG"
}
trap cleanup EXIT INT TERM

PACMAN_DL_STATUS=0
PACMAN_INSTALL_STATUS=0
AUR_STATUS=0
FLATPAK_STATUS=0
SNAP_STATUS=0

# Runs the AUR helper with output forced to English (for reliable marker
# detection) and line-buffered (so the log fills in real time, not in
# big chunks), tee'd to both the terminal and a log file we can grep.
run_aur_and_log() {
    LC_ALL=C LANG=C stdbuf -oL -eL "$@" 2>&1 | tee "$AUR_LOG"
    return "${PIPESTATUS[0]}"
}

# Blocks until makepkg's "Making package:" line shows up in the AUR log
# (i.e. the AUR helper has moved from resolving/cloning into building),
# or until the AUR job exits on its own (nothing to build / errored out),
# or until a generous safety timeout elapses.
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

# ---------- phase: pacman download-only ----------
section "pacman — downloading official repo updates"
T0=$(date +%s)
sudo pacman -Syuw --noconfirm
PACMAN_DL_STATUS=$?
T1=$(date +%s)
if [[ $PACMAN_DL_STATUS -eq 0 ]]; then
    ok "pacman downloads finished in $(human_time $((T1 - T0)))"
else
    fail "pacman download phase failed (exit $PACMAN_DL_STATUS)"
    exit 1
fi

# ---------- kick off pacman install + AUR build in the background ----------
section "Starting pacman install + AUR update in the background"

log "Starting pacman install (from cache, no network use)..."
sudo pacman -Su --noconfirm &
PACMAN_INSTALL_PID=$!

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

wait "$PACMAN_INSTALL_PID"
PACMAN_INSTALL_STATUS=$?
if [[ $PACMAN_INSTALL_STATUS -eq 0 ]]; then
    ok "pacman install finished"
else
    fail "pacman install failed (exit $PACMAN_INSTALL_STATUS)"
fi

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
for pair in "pacman-download:$PACMAN_DL_STATUS" "pacman-install:$PACMAN_INSTALL_STATUS" \
            "aur:$AUR_STATUS" "flatpak:$FLATPAK_STATUS" "snap:$SNAP_STATUS"; do
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