#!/bin/sh
# One-time (per machine) setup of notarization credentials for
# scripts/release.sh. Stores them in the login keychain under the
# notarytool profile "pigeon-notary" (override: PIGEON_NOTARY_PROFILE).
#
# Two ways to authenticate with Apple's notary service:
#
#   1. App Store Connect API key (recommended — also what CI uses):
#        App Store Connect → Users and Access → Integrations → Team Keys
#        → "+" → role Developer → download AuthKey_XXXXXXXXXX.p8
#      scripts/notary-setup.sh --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
#          --key-id XXXXXXXXXX --issuer <issuer-uuid>
#
#   2. Apple ID + app-specific password (https://account.apple.com →
#      Sign-In and Security → App-Specific Passwords):
#      scripts/notary-setup.sh --apple-id you@example.com
#      (notarytool prompts for the app-specific password)
#
# Verify afterwards: xcrun notarytool history --keychain-profile pigeon-notary
set -eu

TEAM_ID="L7GVXT64TV"
PROFILE="${PIGEON_NOTARY_PROFILE:-pigeon-notary}"

KEY="" KEY_ID="" ISSUER="" APPLE_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --key)      KEY="$2"; shift 2 ;;
        --key-id)   KEY_ID="$2"; shift 2 ;;
        --issuer)   ISSUER="$2"; shift 2 ;;
        --apple-id) APPLE_ID="$2"; shift 2 ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -n "$KEY" ]; then
    if [ -z "$KEY_ID" ] || [ -z "$ISSUER" ]; then
        echo "--key requires --key-id and --issuer" >&2
        exit 2
    fi
    if [ ! -f "$KEY" ]; then
        echo "key file not found: $KEY" >&2
        exit 2
    fi
    xcrun notarytool store-credentials "$PROFILE" \
        --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER"
elif [ -n "$APPLE_ID" ]; then
    xcrun notarytool store-credentials "$PROFILE" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
else
    echo "usage: $0 --key <AuthKey.p8> --key-id <id> --issuer <uuid>" >&2
    echo "   or: $0 --apple-id <email>" >&2
    exit 2
fi

echo "==> profile '$PROFILE' stored. checking access to the notary service…"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
echo "==> ok. scripts/release.sh will notarize with this profile."
