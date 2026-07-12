#!/usr/bin/env bash
# ============================================================================
# Deploy HappyHourly to production with an auto-bumped build version.
#
# Why: the in-app auto-update guard compares the page's embedded BUILD_VERSION
# against /version.json and reloads once when they differ — that's what defeats
# stale iOS Safari snapshots. For it to work, BOTH must be bumped together on
# every deploy. This script does that so it can't be forgotten.
#
# It also MINIFIES the app before shipping (build/minify.mjs): the readable
# happyhourly-complete.html stays the editable source of truth, but the copy that
# actually gets deployed is minified (~27% smaller, faster to open on phones).
# The readable file is always restored afterwards — the working tree never keeps
# the minified blob.
#
# Usage:  ./deploy.sh
#   (run AFTER committing your feature changes; commit the version bump after —
#    the script prints the exact command.)
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

HTML="happyhourly-complete.html"
VJSON="version.json"
V="$(date +%Y%m%d%H%M%S)"

# Were these files already clean? If so, the only change after the bump is the
# bump itself, so it's safe to auto-commit. If they had other edits, we won't
# stage them — we'll just print the manual command instead.
PRE_DIRTY="$(git status --porcelain -- "$HTML" "$VJSON" 2>/dev/null || true)"

# Bump the embedded version in the app + the server version file, in sync.
perl -i -pe "s/var BUILD_VERSION = '[^']*';/var BUILD_VERSION = '${V}';/" "$HTML"
printf '{ "v": "%s" }\n' "$V" > "$VJSON"

# Verify both actually changed before we ship anything.
grep -q "var BUILD_VERSION = '${V}';" "$HTML" || { echo "✗ BUILD_VERSION not bumped in $HTML"; exit 1; }
grep -q "\"v\": \"${V}\"" "$VJSON"            || { echo "✗ version.json not bumped"; exit 1; }
echo "→ build version bumped to ${V}"

# One-time: install the minifier.
if [ ! -d build/node_modules ]; then
  echo "→ installing build tools (one-time)…"
  ( cd build && npm install --no-audit --no-fund >/dev/null )
fi

# Ship a MINIFIED copy while keeping the readable source. Restore the readable
# file no matter how the script exits (success, error, Ctrl-C).
READABLE_BAK="$(mktemp)"
cp "$HTML" "$READABLE_BAK"
restore(){ if [ -f "$READABLE_BAK" ]; then cp "$READABLE_BAK" "$HTML"; rm -f "$READABLE_BAK"; fi; }
trap restore EXIT

echo "→ minifying…"
node build/minify.mjs "$HTML" "${HTML}.min"
mv "${HTML}.min" "$HTML"

echo "→ deploying to production…"
vercel deploy --prod --yes

# Put the readable source back BEFORE committing, so git tracks the readable file.
restore
trap - EXIT

echo ""
echo "✓ deployed build ${V} (minified)"

if [ -z "$PRE_DIRTY" ]; then
  # Tree was clean for these files → the only diff is the bump. Safe to commit.
  git add "$HTML" "$VJSON"
  git commit -m "chore(deploy): build ${V}" >/dev/null
  if git push >/dev/null 2>&1; then
    echo "✓ committed + pushed the version bump"
  else
    echo "✓ committed the version bump (push when ready: git push)"
  fi
else
  # They had other uncommitted edits — don't risk bundling them.
  echo "⚠ ${HTML}/${VJSON} had other uncommitted changes — NOT auto-committing."
  echo "  commit the bump yourself:  git add ${HTML} ${VJSON} && git commit -m \"chore(deploy): build ${V}\""
fi
