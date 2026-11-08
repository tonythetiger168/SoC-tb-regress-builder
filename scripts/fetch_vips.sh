#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fetch the packaged subsystem VIP benches (<IP>-UVM-VIP.zip) from
# open-vip-portfolio into ext/open-vip-portfolio/vips/, where the phone_*
# and vip_axim_kit suites look for them. Suites whose zip is missing are
# reported as "not run", so the regression still works without this step.
# Env: OPEN_VIP_REPO (URL or local checkout, default the GitHub repo),
#      OPEN_VIP_REF (branch/tag/commit, default main),
#      GH_TOKEN (optional, for a private repo over HTTPS)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${OPEN_VIP_REPO:-https://github.com/tonythetiger168/open-vip-portfolio.git}"
REF="${OPEN_VIP_REF:-main}"
DEST="$REPO/ext/open-vip-portfolio/vips"
mkdir -p "$DEST"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch -q origin "$REF" || true
  WORK="$SRC"; COMMIT="$(git -C "$SRC" rev-parse --verify -q "origin/$REF" || git -C "$SRC" rev-parse "$REF")"
else
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  URL="$SRC"
  if [ -n "${GH_TOKEN:-}" ]; then URL="${SRC/https:\/\//https://x-access-token:${GH_TOKEN}@}"; fi
  git -C "$WORK" init -q && git -C "$WORK" remote add origin "$URL"
  git -C "$WORK" fetch -q --depth 1 origin "$REF"
  COMMIT=FETCH_HEAD
fi
n=0
for f in $(git -C "$WORK" ls-tree --name-only "$COMMIT" vips/ | grep -- '-UVM-VIP\.zip$'); do
  git -C "$WORK" show "$COMMIT:$f" > "$DEST/$(basename "$f")"; n=$((n + 1))
done
echo "fetched $n VIP zips from $SRC@$REF into ${DEST#$REPO/}"
