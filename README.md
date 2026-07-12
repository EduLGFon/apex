# apex.sh — Parallelized system updater for Linux (Arch pacman+AUR, Debian/Ubuntu apt, Fedora/RHEL dnf, plus flatpak and snap)

> The script does NOT assume these are mutually exclusive — pacman, apt,
 and dnf are each detected independently and handled if present, whether
 alone or side by side (e.g. inside containers/WSL/unusual setups).

## STRATEGY (minimize wall-clock time, without racing anything unsafe):

   1. For every system package manager found (pacman, apt, dnf), run its
      **"download only, don't install"** step, ONE AT A TIME. These are the
      only steps guaranteed to compete for your download bandwidth, so
      they're kept serialized against each other and against everything
      else.

   2. Once all of those download steps are done, everything below starts
      together in the background:
        - each manager's real **install/upgrade step (reads from its cache,
          so it's disk/CPU work, not network)**
        - your **AUR helper (yay/paru), which resolves + clones + builds
          AUR updates**

   3. **As soon as the AUR helper finishes its upfront resolve/clone burst**
      and starts actually building packages, **flatpak then snap are
      started too** — while the manager installs and the AUR build keep
      running in the background.

   4. Everything is joined at the end and a summary is printed, includind both the actual (parallel) time taken and what the same work would have cost if every step had run one after another.

 Anything not present (pacman, apt, dnf, yay/paru, flatpak, snap) is
 skipped automatically.

## HOW STEP 3'S AUR TIMING IS DETECTED
   Both yay and paru shell out to the real `makepkg` binary to build
   packages. makepkg's very first line of output for any package is
   always: "==> Making package: \<name> \<version> (\<date>)"
  
   That line comes from makepkg itself (not the AUR helper's own wrapper
   text), and has been stable across versions for years. We watch the AUR
   helper's log for the first occurrence of that line and treat it as "the
   upfront download burst is done, real building has started" — a
   reasonable, if not perfectly exact, proxy. Per-package source downloads
   inside individual builds can still trickle in after this point; those
   are typically small next to compile time. LC_ALL=C is forced on that
   one subprocess so the line is always in English regardless of your
   system locale. Pass --conservative to skip this heuristic entirely and
   just wait for the whole AUR job to finish first.

## NOTES ON apt / dnf
   - apt runs with DEBIAN_FRONTEND=noninteractive and
     --force-confdef/--force-confold so a config-file prompt can't
     silently hang a background job; when in doubt it keeps your current
     config file.
   - dnf's --downloadonly needs the "download" plugin from
     dnf-plugins-core. If it's missing, the download-only step will fail;
     the script logs that but keeps going — the later install step still
     does a normal (download+install) upgrade, it just won't have had the
     benefit of pre-fetching.

## SAFETY NOTES
   - To run the AUR helper unattended, this script auto-accepts
     diffs/prompts (--noconfirm + answer flags). You lose the manual
     "review the PKGBUILD" step. Review AUR packages separately/
     periodically if that matters to you.
   - In theory, a manager's own install step and the AUR helper's final
     `pacman -U` could both want the pacman DB lock at once. In practice
     this essentially never happens, since building AUR packages takes far
     longer than installing already-cached packages — but if you ever see
     "unable to lock database", just re-run the script.

