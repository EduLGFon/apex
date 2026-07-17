#!/usr/bin/env bash
#
# Apex — Parallelized system updater
# (Arch pacman+AUR, Debian/Ubuntu apt, Fedora/RHEL dnf,
#  plus flatpak and snap)
#
# The script does NOT assume these are mutually exclusive: pacman, apt,
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
#      started too, while the manager installs and the AUR build keep
#      running in the background.
#
#   4. Everything is joined at the end and a summary is printed, including
#      both the actual (parallel) time taken and what the same work would
#      have cost if every step had run one after another.
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
#   upfront download burst is done, real building has started" (a
#   reasonable, if not perfectly exact, proxy). Per-package source downloads
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
#     the script logs that but keeps going: the later install step still
#     does a normal (download+install) upgrade, it just won't have had the
#     benefit of pre-fetching.
#
# NOTE ON flatpak
#   - flatpak runs with --noninteractive. Without it, flatpak can drop to
#     a polkit authentication prompt for background helper actions (like
#     refreshing appstream metadata) with no timeout, which would hang the
#     script indefinitely since there's no terminal input to answer it.
#
# SAFETY NOTES
#   - To run the AUR helper unattended, this script auto-accepts
#     diffs/prompts (--noconfirm + answer flags). You lose the manual
#     "review the PKGBUILD" step. Review AUR packages separately/
#     periodically if that matters to you.
#   - In theory, a manager's own install step and the AUR helper's final
#     `pacman -U` could both want the pacman DB lock at once. In practice
#     this essentially never happens, since building AUR packages takes far
#     longer than installing already-cached packages, but if you ever see
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
declare -A DOWNLOAD_TIME=()
declare -A INSTALL_STATUS=()
declare -A INSTALL_TIME=()
declare -A INSTALL_START=()
AUR_STATUS=0
AUR_DOWNLOAD_TIME=0
AUR_BUILD_TIME=0
AUR_START_TS=0
AUR_BUILD_START_TS=0
AUR_NO_BUILD_END_TS=0
AUR_MARKER_FOUND=0
FLATPAK_STATUS=0
FLATPAK_TIME=0
SNAP_STATUS=0
SNAP_TIME=0

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
# Sets AUR_MARKER_FOUND=1 only in the first case, so callers can tell a
# real download/build split from "there was nothing to split."
wait_for_aur_build_start() {
    local marker='^==> Making package:'
    local waited=0
    local max_wait=1200  # 20 minutes safety cap

    while true; do
        if grep -qm1 -E "$marker" "$AUR_LOG" 2>/dev/null; then
            AUR_MARKER_FOUND=1
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
# The clock starts here, not at script launch. This excludes the sudo
# password prompt, tool detection, and setup from both timing numbers, so
# "time with/without parallelization" measures actual update work, not how
# long you took to type your password.
SCRIPT_START=$(date +%s)

if [[ ${#MANAGERS[@]} -gt 0 ]]; then
    section "Downloading system package updates (${MANAGERS[*]}, one at a time)"
    for mgr in "${MANAGERS[@]}"; do
        log "Downloading $mgr updates..."
        T0=$(date +%s)
        manager_download "$mgr"
        DOWNLOAD_STATUS[$mgr]=$?
        T1=$(date +%s)
        DOWNLOAD_TIME[$mgr]=$((T1 - T0))
        if [[ ${DOWNLOAD_STATUS[$mgr]} -eq 0 ]]; then
            ok "$mgr downloads finished in $(human_time ${DOWNLOAD_TIME[$mgr]})"
        else
            fail "$mgr download-only step failed (exit ${DOWNLOAD_STATUS[$mgr]})"
            if [[ "$mgr" == "dnf" ]]; then
                warn "This often means the 'download' plugin (dnf-plugins-core) isn't installed. Continuing: dnf's install step below will just download+install together."
            fi
        fi
    done
fi

# ---------- kick off all installs + AUR build in the background ----------
section "Starting installs + AUR update in the background"

for mgr in "${MANAGERS[@]}"; do
    log "Starting $mgr install..."
    INSTALL_START[$mgr]=$(date +%s)
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
    AUR_START_TS=$(date +%s)
    run_aur_and_log "${AUR_CMD[@]}" &
    AUR_PID=$!
else
    [[ $SKIP_AUR -eq 1 ]] && log "AUR updates skipped (--no-aur)."
    [[ $SKIP_AUR -eq 0 ]] && warn "No AUR helper (yay/paru) found, skipping AUR updates."
fi

# ---------- wait for the right moment to start flatpak/snap ----------
if [[ -n "$AUR_PID" ]]; then
    if [[ $CONSERVATIVE -eq 1 ]]; then
        log "Conservative mode: waiting for the AUR update to fully finish..."
        wait "$AUR_PID"
        AUR_STATUS=$?
        # No marker wait happened in this mode, so there's no real
        # download/build split to report: the whole run is timed as one
        # block. We attribute it to "build" since that's most of what
        # AUR jobs spend their time on.
        AUR_BUILD_TIME=$(( $(date +%s) - AUR_START_TS ))
        if [[ $AUR_STATUS -eq 0 ]]; then ok "AUR update finished in $(human_time $AUR_BUILD_TIME)"; else fail "AUR update failed (exit $AUR_STATUS)"; fi
        AUR_PID=""   # already reaped
    else
        log "Waiting for AUR's initial resolve/clone burst to finish before starting flatpak..."
        wait_for_aur_build_start
        AUR_BUILD_START_TS=$(date +%s)
        if [[ $AUR_MARKER_FOUND -eq 1 ]]; then
            AUR_DOWNLOAD_TIME=$(( AUR_BUILD_START_TS - AUR_START_TS ))
            ok "AUR download/resolve burst finished in $(human_time $AUR_DOWNLOAD_TIME), starting flatpak/snap now while it keeps building."
        else
            # The AUR job already exited before ever printing the build
            # marker (nothing to update, or it failed outright) or we hit
            # the safety timeout. Either way there's no build phase left
            # to time. Record its end time right now: the process may
            # already be dead, and a later `wait "$AUR_PID"` on an
            # already-dead PID returns instantly, so if we computed the
            # duration there instead, it would silently measure however
            # long *other* things (like pacman's install) took in the
            # meantime, not AUR's actual runtime.
            AUR_NO_BUILD_END_TS=$(date +%s)
            ok "AUR job finished before any build started, starting flatpak/snap now."
        fi
    fi
fi

# ---------- flatpak, then snap (foreground, sequential) ----------
section "flatpak, then snap"

if [[ $HAS_FLATPAK -eq 1 ]]; then
    log "Updating flatpak packages..."
    T0=$(date +%s)
    # --noninteractive keeps this from ever dropping to a polkit auth
    # prompt (e.g. for the appstream-update helper action) that would
    # otherwise hang the script forever with no visible terminal input.
    flatpak update -y --noninteractive
    FLATPAK_STATUS=$?
    T1=$(date +%s)
    FLATPAK_TIME=$((T1 - T0))
    if [[ $FLATPAK_STATUS -eq 0 ]]; then
        ok "flatpak updated in $(human_time $FLATPAK_TIME)"
    else
        fail "flatpak update failed (exit $FLATPAK_STATUS)"
    fi
elif [[ $SKIP_FLATPAK -eq 1 ]]; then
    log "flatpak skipped (--no-flatpak)."
else
    log "flatpak not installed, skipping."
fi

if [[ $HAS_SNAP -eq 1 ]]; then
    log "Updating snap packages..."
    T0=$(date +%s)
    sudo snap refresh
    SNAP_STATUS=$?
    T1=$(date +%s)
    SNAP_TIME=$((T1 - T0))
    if [[ $SNAP_STATUS -eq 0 ]]; then
        ok "snap updated in $(human_time $SNAP_TIME)"
    else
        fail "snap update failed (exit $SNAP_STATUS)"
    fi
elif [[ $SKIP_SNAP -eq 1 ]]; then
    log "snap skipped (--no-snap)."
else
    log "snap not installed, skipping."
fi

# ---------- join remaining background jobs ----------
section "Finishing up background jobs"

for mgr in "${MANAGERS[@]}"; do
    wait "${INSTALL_PID[$mgr]}"
    INSTALL_STATUS[$mgr]=$?
    INSTALL_TIME[$mgr]=$(( $(date +%s) - INSTALL_START[$mgr] ))
    if [[ ${INSTALL_STATUS[$mgr]} -eq 0 ]]; then
        ok "$mgr install finished in $(human_time ${INSTALL_TIME[$mgr]})"
    else
        fail "$mgr install failed (exit ${INSTALL_STATUS[$mgr]})"
    fi
done

if [[ -n "$AUR_PID" ]]; then
    wait "$AUR_PID"
    AUR_STATUS=$?
    if [[ $AUR_MARKER_FOUND -eq 1 ]]; then
        AUR_BUILD_TIME=$(( $(date +%s) - AUR_BUILD_START_TS ))
    else
        # No build marker ever fired. AUR_NO_BUILD_END_TS was captured
        # right when we detected that (see above), which is the AUR
        # job's real end time. `wait` above almost certainly returned
        # instantly since the process was already dead; using `date +%s`
        # here instead would measure however long unrelated background
        # work (pacman install, etc.) happened to still be running,
        # not AUR's actual runtime.
        AUR_BUILD_TIME=$(( AUR_NO_BUILD_END_TS - AUR_START_TS ))
    fi
    if [[ $AUR_STATUS -eq 0 ]]; then
        ok "AUR build finished in $(human_time $AUR_BUILD_TIME)"
    else
        fail "AUR update failed (exit $AUR_STATUS)"
    fi
fi

# ---------- summary ----------
SCRIPT_END=$(date +%s)
PARALLEL_TOTAL=$((SCRIPT_END - SCRIPT_START))

# "Without parallelization" = what it would have cost to run every single
# step back-to-back (downloads were already sequential either way; the
# difference comes entirely from overlapping installs/AUR/flatpak/snap).
SEQUENTIAL_TOTAL=0
for mgr in "${MANAGERS[@]}"; do
    SEQUENTIAL_TOTAL=$((SEQUENTIAL_TOTAL + ${DOWNLOAD_TIME[$mgr]:-0} + ${INSTALL_TIME[$mgr]:-0}))
done
SEQUENTIAL_TOTAL=$((SEQUENTIAL_TOTAL + AUR_DOWNLOAD_TIME + AUR_BUILD_TIME + FLATPAK_TIME + SNAP_TIME))

section "Summary"

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

echo
echo "Time per step:"
for mgr in "${MANAGERS[@]}"; do
    printf "  %-10s %-10s %s\n" "$mgr" "download" "$(human_time ${DOWNLOAD_TIME[$mgr]:-0})"
    printf "  %-10s %-10s %s\n" "$mgr" "install" "$(human_time ${INSTALL_TIME[$mgr]:-0})"
done
if [[ -n "$AUR_HELPER" ]]; then
    printf "  %-10s %-10s %s\n" "aur" "download" "$(human_time $AUR_DOWNLOAD_TIME)"
    printf "  %-10s %-10s %s\n" "aur" "build" "$(human_time $AUR_BUILD_TIME)"
fi
if [[ $HAS_FLATPAK -eq 1 ]]; then
    printf "  %-10s %-10s %s\n" "flatpak" "" "$(human_time $FLATPAK_TIME)"
fi
if [[ $HAS_SNAP -eq 1 ]]; then
    printf "  %-10s %-10s %s\n" "snap" "" "$(human_time $SNAP_TIME)"
fi

echo
echo "Time without parallelization (sum of every step run back-to-back): $(human_time $SEQUENTIAL_TOTAL)"
echo "Time with parallelization    (actual wall-clock time taken):       $(human_time $PARALLEL_TOTAL)"
if [[ $SEQUENTIAL_TOTAL -gt $PARALLEL_TOTAL ]]; then
    SAVED=$((SEQUENTIAL_TOTAL - PARALLEL_TOTAL))
    if [[ $SEQUENTIAL_TOTAL -gt 0 ]]; then
        PCT=$(( SAVED * 100 / SEQUENTIAL_TOTAL ))
    else
        PCT=0
    fi
    echo "Saved: $(human_time $SAVED) (${PCT}%)"
fi

if [[ $NOTIFY -eq 1 ]] && command -v notify-send &>/dev/null; then
    if [[ $OVERALL_STATUS -eq 0 ]]; then
        notify-send "System update complete" "Finished in $(human_time $PARALLEL_TOTAL) (would've been $(human_time $SEQUENTIAL_TOTAL) sequential)" 2>/dev/null || true
    else
        notify-send -u critical "System update finished with errors" "Check the terminal output" 2>/dev/null || true
    fi
fi

exit $OVERALL_STATUS