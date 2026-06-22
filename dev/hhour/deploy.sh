#!/usr/bin/env bash
# ============================================================================
# Deploy HappyHourly to production with an auto-bumped build version.
#
# Why: the in-app auto-update guard compares the page's embedded BUILD_VERSION
# against /version.json and reloads once when they differ — that's what defeats
# stale iOS Safari snapshots. For it to work, BOTH must be bumped together on
# every deploy. This script does that so it can't be forgotten.
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

echo "→ deploying to production…"
vercel deploy --prod --yes

echo ""
echo "✓ deployed build ${V}"

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
