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
echo "  commit the bump:  git add ${HTML} ${VJSON} && git commit -m \"chore(deploy): build ${V}\""
