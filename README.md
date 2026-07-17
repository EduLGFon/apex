# Apex

**Apex** updates every package manager on your system in parallel, safely, so
you spend less time waiting and more time doing something else.

It's built for Arch setups (pacman + AUR + flatpak + snap), but also understands
apt (Debian/Ubuntu) and dnf (Fedora/RHEL), and doesn't assume they're mutually
exclusive with pacman, so it works fine in containers, WSL, or any oddly-layered
setup where more than one shows up.

```
$ ./apex.sh
== Downloading system package updates (pacman, one at a time) ==
[✓] pacman downloads finished in 0m42s

== Starting installs + AUR update in the background ==
[✓] AUR download/resolve burst finished in 0m24s, starting flatpak/snap now while it keeps building.

== flatpak, then snap ==
[✓] flatpak updated in 0m18s
[✓] snap updated in 0m09s

== Summary ==
[✓] Everything updated successfully.

Time per step:
  pacman     download   0m42s
  pacman     install    0m30s
  aur        download   0m24s
  aur        build      1m46s
  flatpak               0m18s
  snap                  0m09s

Time without parallelization (sum of every step run back-to-back): 4m37s
Time with parallelization    (actual wall-clock time taken):       2m51s
Saved: 1m46s (38%)
```

The percentage you'll actually see depends heavily on your machine and what
needs updating (a system with a big AUR compile queue benefits far more than one
with only a couple of flatpak updates), but in typical mixed
pacman+AUR+flatpak+snap runs, **30-45% less total time** is a reasonable
expectation. The savings scale with how much CPU-bound work (installs, AUR
builds) you have relative to network-bound work.

---

## Table of contents

- [Why](#why)
- [Installation](#installation)
- [Usage](#usage)
- [How it works](#how-it-works)
- [The strategy, in detail](#the-strategy-in-detail)
- [How AUR timing is detected](#how-aur-timing-is-detected)
- [Safety notes](#safety-notes)
- [Known limitations & concerns](#known-limitations--concerns)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

---

## Why

If you run more than one package format like me (I need to use pacman, AUR,
flatpak and even snap), the naive way to update everything is to run each
updater one after another. Most of that time is wasted: downloads sit idle while
a previous manager is busy installing, and installs/builds sit idle while
nothing is downloading.

Apex's only real trick: **downloads are the one resource that's actually shared
and scarce** (your bandwidth). Installing, building, and unpacking are disk/CPU
work and don't compete with downloads at all. So Apex keeps every _download_
step serialized against every other download step, but lets _install/build_
steps run fully in parallel with each other and with the next thing's downloads.

## Installation

Apex is a single self-contained bash script. No dependencies beyond what's
already on your system (`bash`, `coreutils`, specifically `stdbuf`, and `sudo`).

```bash
git clone https://github.com/EduLGFon/apex.git
cd apex
chmod +x apex.sh
```

Run it directly:

```bash
./apex.sh
```

Or drop it somewhere on your `$PATH` for convenience:

```bash
sudo cp apex.sh /usr/local/bin/apex
apex
```

There's nothing to configure. Apex detects what's installed on your system
(pacman, apt, dnf, yay, paru, flatpak, snap) at runtime and only touches what's
actually there.

## Usage

```
Usage: apex.sh [options]

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
```

You'll be prompted for your sudo password once, up front. Apex keeps the sudo
timestamp alive in the background for the rest of the run so nothing prompts
again mid-update.

## How it works

Apex runs in four stages:

**1. Download, one manager at a time.** For every system package manager it
finds (pacman, apt, dnf), Apex runs its "download-only" mode: nothing gets
installed yet, packages just land in the local cache. This happens one manager
at a time, in sequence, because these are the only steps guaranteed to compete
for your bandwidth.

**2. Install + AUR build, all at once, in the background.** The instant all
downloads are done, every manager's real install step starts, reading straight
from the cache that was just filled, so it's pure disk/CPU work. At the same
moment, your AUR helper (`yay` or `paru`) starts resolving, cloning, and
building AUR packages. None of this competes for bandwidth with anything else,
so it all runs concurrently.

**3. flatpak, then snap, started as soon as it's safe.** As soon as the AUR
helper's upfront download burst is done and it's moved into actually compiling
packages (see [below](#how-aur-timing-is-detected) for how that moment is
detected), Apex starts flatpak, then snap, one after another, while the manager
installs and the AUR build keep running in the background the whole time.

**4. Join everything, print a summary.** Apex waits for every background job to
finish, reports what succeeded/failed, and prints both a per-step timing
breakdown and how long the run actually took compared to how long the same work
would have taken run strictly one step at a time.

## The strategy, in detail

The core insight is simple: **only downloads share a bottleneck (your internet
connection).** Installing, unpacking, and compiling don't touch the network, so
there's no reason to make them wait their turn.

```
        DOWNLOAD PHASE                  INSTALL/BUILD PHASE
        (serialized)                    (fully parallel)

pacman  [=====download=====]
apt                          [==dl==]
dnf                                   [====dl====]
                                                    │
                                                    ▼
                                    pacman install  [===]
                                    apt install         [==]
                                    dnf install             [====]
                                    AUR build               [==================]
                                                                        │
                                                            (AUR build-phase reached)
                                                                        ▼
                                                            flatpak    [====]
                                                            snap            [==]
```

Everything to the left of the vertical line only ever runs one thing at a time.
Everything to the right runs concurrently, because none of it is network-bound
(aside from flatpak/snap's own downloads, which is why they wait for the AUR
download burst specifically, not the whole AUR job).

apt and dnf get the same download/install split pacman does:

- `apt-get -d dist-upgrade`: download only
- `dnf upgrade --downloadonly`: download only (needs the `download` plugin from
  `dnf-plugins-core`, usually preinstalled on Fedora; if it's missing, Apex logs
  it and falls back to a combined download+install for dnf instead of failing
  the whole run)

## How AUR timing is detected

There's no clean "download only" mode for AUR helpers the way there is for
pacman/apt/dnf. `yay`/`paru` resolve dependencies, clone AUR repos, and build in
one continuous run. So Apex needs another way to know when it's safe to start
flatpak without stepping on AUR's own downloads.

The trick: both `yay` and `paru` shell out to the real `makepkg` binary to
actually build packages, and makepkg's very first line of output for _any_
package is always:

```
==> Making package: <name> <version> (<date>)
```

That line comes from makepkg itself, not from the AUR helper's own wrapper text,
and its wording has been stable for years across both helpers. Apex captures the
AUR helper's output (line-buffered, piped to a log file) and watches for the
first occurrence of that line. Once it shows up, the big upfront burst,
dependency resolution and cloning every outdated AUR package's repo, is done,
and flatpak/snap are free to start.

The same marker is what splits `aur download` from `aur build` in the final
summary: everything before that line counts as download, everything from that
line to the job finishing counts as build. In `--conservative` mode there's no
marker wait, so there's no real boundary to report; the whole AUR run is
attributed to `build` rather than guessing where the split would have been.

To make sure that line is always in English (and therefore always matches), Apex
forces `LC_ALL=C` on just that one subprocess. Your shell's actual locale is
untouched everywhere else.

This is a heuristic, not a guarantee:

- Per-package source downloads that happen _during_ each individual build can
  still trickle in after this point. Those are usually small relative to compile
  time, so the residual bandwidth overlap is a reasonable trade-off.
- If the AUR job finishes before ever printing that line (nothing needed
  building, or it failed immediately), Apex notices the process has exited and
  moves on instead of waiting.
- A 20-minute safety timeout exists in case detection genuinely never triggers,
  so the script can't hang forever.
- If you don't trust any of this, `--conservative` disables it entirely: Apex
  will just wait for the whole AUR job to finish before starting flatpak/snap,
  trading some parallelism for certainty.

## Safety notes

- **AUR runs fully unattended.** To build AUR packages in the background without
  something silently blocking on a prompt, Apex passes `--noconfirm` plus the
  "auto-answer" flags
  (`--answerclean None --answerdiff None --answeredit None --answerupgrade All`
  for yay, `--skipreview` for paru). This means **you don't get to review
  PKGBUILD diffs before they build.** If reviewing AUR changes matters to you,
  do it separately and periodically (`yay -Pw`/similar) rather than relying on
  this script for that.
- **apt is forced noninteractive**, with `--force-confdef`/`--force-confold` so
  a config-file merge prompt can't hang the background job. When in doubt, it
  keeps your existing config file rather than the packaged default.
- **flatpak runs with `--noninteractive`.** Without it, flatpak can drop to a
  polkit authentication prompt for background helper actions (like refreshing
  appstream metadata), which has no timeout and would hang the script
  indefinitely waiting for input nobody's there to give.
- **A theoretical pacman DB lock race exists.** A manager's install step and the
  AUR helper's own final `pacman -U` could, in principle, both want the pacman
  database lock at the same moment. In practice this essentially never happens,
  since building AUR packages takes far longer than installing already-cached
  packages, but if you ever see `unable to lock database`, just re-run Apex.
- Nothing in Apex escalates privileges beyond what a normal manual update would
  need. `sudo` is requested once up front and kept alive via a background
  refresh loop; it isn't cached to disk or reused beyond the life of the script.

## Known limitations & concerns

- **The AUR-phase detection is a heuristic**, not something Apex can verify
  structurally (see above). It's designed to fail safe (falls through to
  "proceed anyway" rather than hanging), but it's inherently coupled to
  makepkg's current output format.
- **dnf's `--downloadonly` depends on a plugin** that isn't guaranteed to be
  installed. Apex handles its absence gracefully, but you won't get the
  pre-fetch benefit for dnf without `dnf-plugins-core`.
- **No interactive AUR review.** This is the main safety/speed trade-off in the
  whole design; see [Safety notes](#safety-notes).
- **The "time saved" percentage is inherently variable.** A run with a heavy AUR
  compile queue and light downloads will show much bigger savings than a run
  that's 90% downloading and 10% installing, because there's less overlap to
  exploit.
- Apex doesn't do any cleanup (`pacman -Sc`, `apt autoremove`, `dnf autoremove`,
  orphan removal, etc.). It only updates. That's intentionally out of scope.

## Troubleshooting

**"unable to lock database"** Two processes both reached for the pacman lock at
once, see the note above. Just run Apex again.

**dnf download-only step fails immediately** Install `dnf-plugins-core`
(`sudo dnf install dnf-plugins-core`) if you want the pre-fetch benefit. Apex
will still complete the update either way.

**apt seems to hang** Shouldn't happen. `DEBIAN_FRONTEND=noninteractive` plus
the forced dpkg options are meant to prevent this. If you do hit a hang, please
open an issue with the package that triggered it.

**flatpak/snap started earlier than expected / later than expected** That's the
AUR-phase heuristic at work. Run with `--conservative` if you want deterministic
(if slower) sequencing instead.

## Contributing

Issues and PRs welcome at
[github.com/EduLGFon/apex](https://github.com/EduLGFon/apex). If you're
reporting a timing/detection issue with the AUR heuristic, please include your
AUR helper and version (`yay --version` / `paru --version`), that's the part
most likely to need adjusting as those tools evolve.
