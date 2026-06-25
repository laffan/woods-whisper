#!/usr/bin/env bash
#
# Generate WoodsWhisper.xcodeproj with your Apple signing team AND a unique bundle-ID prefix
# applied to EVERY target (app, watch app, the iOS widget/Control extension, and the watch
# complication) — so signing "just works" and the new App IDs don't collide with the generic
# com.woodswhisper.* identifiers (which are already registered to someone else).
#
# A free/personal Apple ID works — complications and widgets do NOT need a paid membership.
#
# Usage:
#   ./Scripts/generate.sh                       # auto-detect team, unique team-derived prefix
#   ./Scripts/generate.sh A1B2C3D4E5            # explicit Team ID
#   ./Scripts/generate.sh A1B2C3D4E5 com.you    # explicit Team ID + your own bundle prefix
#
# Or via environment variables: DEVELOPMENT_TEAM=… BUNDLE_ID_PREFIX=com.you ./Scripts/generate.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Pull the Team ID (the certificate's Organizational Unit) from your Apple Development cert.
detect_team() {
  security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F= '/organizationalUnitName/ { gsub(/[[:space:]]/, "", $2); print $2; exit }'
}

TEAM="${1:-${DEVELOPMENT_TEAM:-}}"
[ -z "$TEAM" ] && TEAM="$(detect_team || true)"

if [ -z "$TEAM" ]; then
  cat <<'EOF'
Couldn't auto-detect your Apple Development Team ID.

Find it in:  Xcode ▸ Settings ▸ Accounts ▸ (select your team)   — the 10-character ID,
        or:  https://developer.apple.com/account ▸ Membership.

Then run:    ./Scripts/generate.sh YOUR_TEAM_ID

(A free personal Apple ID is fine — no paid Developer Program membership needed. If you've never
built the app yet, open it in Xcode once and let it create a signing certificate, then re-run.)
EOF
  exit 1
fi

# Bundle-ID prefix. Default to a unique, team-derived value so the new App IDs are guaranteed not to
# collide with another team's existing registrations. Override with arg #2 or BUNDLE_ID_PREFIX for a
# prettier custom prefix (e.g. com.yourname). Keep ONE prefix across runs so you don't create a new
# set of App IDs each time (free accounts cap App IDs at ~10 per 7 days).
PREFIX="${2:-${BUNDLE_ID_PREFIX:-}}"
if [ -z "$PREFIX" ]; then
  team_lower="$(printf '%s' "$TEAM" | tr '[:upper:]' '[:lower:]')"
  PREFIX="com.ww${team_lower}"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with:  brew install xcodegen"
  exit 1
fi

echo "Team:        $TEAM"
echo "Bundle IDs:  ${PREFIX}.app  (+ .app.watchkitapp, .app.widgets, .app.watchkitapp.complication)"
echo "Generating project …"
DEVELOPMENT_TEAM="$TEAM" BUNDLE_ID_PREFIX="$PREFIX" xcodegen generate
echo
echo "Done. Open WoodsWhisper.xcodeproj, pick the WoodsWhisper scheme, and build to a device."
echo "If a build still says an App ID is 'not available', pass your own prefix:"
echo "    ./Scripts/generate.sh $TEAM com.yourname"
echo "and if it says you've hit the maximum number of App IDs, that's the free-account weekly"
echo "limit (~10 per 7 days) — wait a bit or reuse the same prefix you used before."
