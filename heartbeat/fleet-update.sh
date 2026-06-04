#!/usr/bin/env bash
#
# Fleet self-update — runs on each bot host on a timer (systemd/launchd),
# separate from and slower than the heartbeat itself. Keeps the local checkout
# at the RELEASED tag so every machine converges on the code you've blessed.
#
# Release model (the safety gate):
#   • You push to `main` as often as you like — nothing deploys.
#   • When a commit is fleet-ready, move the tag and push it:
#       git tag -f released <commit>    # default: current HEAD
#       git push -f origin released
#   • Each host's updater fetches and checks out THAT tag on its next run.
# A half-finished push to main never reaches the fleet; only the tag does.
#
# Install layout note: the schedulers run heartbeat.sh DIRECTLY FROM THIS
# CHECKOUT (no /usr/local/bin copy), so updating the checkout *is* the deploy —
# no sudo, no reinstall step. This script only ever touches the checkout it
# lives in, as the user who owns it.
#
# Configure via environment (the timer/agent sets these, or accept defaults):
#   FLEET_REPO_DIR   path to the checkout (default: this script's repo root)
#   FLEET_REF        ref to converge on   (default: "released")
#   FLEET_REMOTE     remote name          (default: "origin")
#
# Exit code is always 0 so the scheduler never spams its own mail. All outcomes
# go to stderr (the scheduler's StandardErrorPath / journal), timestamped.

set -u

log() { printf '%s fleet-update: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Resolve the repo dir: explicit override, else the git root containing this
# script. Using the script's own location means the updater works no matter
# where the checkout lives (~/fleet-watchdog, /mnt/user/appdata/..., etc.).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="${FLEET_REPO_DIR:-$(cd "${SCRIPT_DIR}" && git rev-parse --show-toplevel 2>/dev/null)}"
REF="${FLEET_REF:-released}"
REMOTE="${FLEET_REMOTE:-origin}"

if [ -z "${REPO_DIR}" ] || [ ! -d "${REPO_DIR}/.git" ]; then
  log "no git checkout found (REPO_DIR='${REPO_DIR}') — nothing to update"
  exit 0
fi
cd "${REPO_DIR}" || { log "cannot cd into ${REPO_DIR}"; exit 0; }

before="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Fetch quietly; a roaming laptop offline right now just retries next tick.
if ! git fetch --quiet --tags --force "${REMOTE}" 2>/dev/null; then
  log "fetch from ${REMOTE} failed (offline?) — staying on ${before}, will retry"
  exit 0
fi

# Resolve the target ref to a concrete commit. Prefer the remote-fetched tag so
# a force-moved tag is honored even though we --force-fetched above.
target="$(git rev-parse --verify --quiet "${REF}^{commit}" \
          || git rev-parse --verify --quiet "${REMOTE}/${REF}^{commit}")"
if [ -z "${target}" ]; then
  log "ref '${REF}' not found locally or on ${REMOTE} — has it been pushed? staying on ${before}"
  exit 0
fi
target_short="$(git rev-parse --short "${target}")"

if [ "$(git rev-parse HEAD)" = "${target}" ]; then
  # Already there — silent on the happy path so the .err stays quiet day-to-day.
  exit 0
fi

# SAFETY GATE: validate the incoming heartbeat.sh BEFORE moving the working tree
# onto it. The schedulers run that file live, so a syntax-broken commit would
# break every beat the moment we check it out. Read it straight from the target
# tree (no checkout yet) and bash -n it; bail if it doesn't parse.
hb_path="heartbeat/heartbeat.sh"
if git cat-file -e "${target}:${hb_path}" 2>/dev/null; then
  if ! git show "${target}:${hb_path}" | bash -n 2>/dev/null; then
    log "REFUSING update: ${hb_path} at ${target_short} fails 'bash -n' — staying on ${before}"
    exit 0
  fi
else
  log "warning: ${hb_path} absent at ${target_short}; proceeding (layout may have changed)"
fi

# Refuse to clobber local edits — a host with a hand-tweaked checkout shouldn't
# be silently reset. (Untracked files like .env are fine; we only guard tracked
# changes.)
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "local tracked changes in ${REPO_DIR} — not updating (resolve by hand). staying on ${before}"
  exit 0
fi

# Move the working tree to the released commit. Detached HEAD is intentional:
# hosts track a release, not a moving branch.
if git checkout --quiet --detach "${target}" 2>/dev/null; then
  log "updated ${before} -> ${target_short} (ref '${REF}'); live heartbeat.sh now current"
else
  log "checkout of ${target_short} failed — staying on ${before}"
fi

exit 0
