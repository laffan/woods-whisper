#!/usr/bin/env bash
#
# Generate WoodsWhisper.xcodeproj with your Apple signing team applied to EVERY target
# (app, watch app, the iOS widget/Control extension, and the watch complication) — so you
# don't have to set the team on each target by hand and so the new extensions get
# provisioning profiles automatically.
#
# A free/personal Apple ID works — complications and widgets do NOT need a paid membership.
#
# Usage:
#   ./Scripts/generate.sh              # auto-detect your Team ID
#   ./Scripts/generate.sh A1B2C3D4E5   # or pass your 10-character Team ID explicitly
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

(A free personal Apple ID is fine — no paid Developer Program membership needed. If you've
never built the app yet, open it in Xcode once and let it create a signing certificate, then
re-run this script so it can detect the team.)
EOF
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with:  brew install xcodegen"
  exit 1
fi

echo "Generating project with DEVELOPMENT_TEAM=$TEAM …"
DEVELOPMENT_TEAM="$TEAM" xcodegen generate
echo
echo "Done. Open WoodsWhisper.xcodeproj, select the WoodsWhisper scheme, and build to a device."
