#!/bin/sh
# Build a distributable Pigeon.app: Release configuration, signed with
# the team's "Developer ID Application" certificate under the hardened
# runtime, notarized by Apple, stapled, and zipped. The result opens
# without a Gatekeeper warning on any Mac and is the artifact the
# Sparkle appcast points at.
#
#   scripts/release.sh                       # version from project.yml
#   scripts/release.sh --version 0.2.0 --build 42
#   scripts/release.sh --no-notarize         # sign only (local smoke test)
#   scripts/release.sh --universal           # arm64 + x86_64 (needs
#                                            # scripts/build-ghostty.sh universal)
#
# Output: dist/Pigeon-<version>.zip (+ dist/Pigeon.app, stapled).
#
# Notarization credentials, one of:
#   - keychain profile (local): scripts/notary-setup.sh, name in
#     PIGEON_NOTARY_PROFILE (default pigeon-notary)
#   - App Store Connect API key (CI): PIGEON_NOTARY_KEY (path to .p8),
#     PIGEON_NOTARY_KEY_ID, PIGEON_NOTARY_ISSUER
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY_NAME="Developer ID Application"
TEAM_ID="L7GVXT64TV"
PROFILE="${PIGEON_NOTARY_PROFILE:-pigeon-notary}"
DERIVED="$ROOT/build/release"
DIST="$ROOT/dist"

VERSION="" BUILD="" NOTARIZE=1 ARCHS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version)      VERSION="$2"; shift 2 ;;
        --build)        BUILD="$2"; shift 2 ;;
        --no-notarize)  NOTARIZE=0; shift ;;
        --universal)    ARCHS="arm64 x86_64"; shift ;;
        -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# ---- preflight --------------------------------------------------------

security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME: .* ($TEAM_ID)" \
    || die "no '$IDENTITY_NAME' certificate for team $TEAM_ID in the keychain
(Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)"

# notarytool argument list, resolved once so both submit and log use it.
if [ "$NOTARIZE" = 1 ]; then
    if [ -n "${PIGEON_NOTARY_KEY:-}" ]; then
        [ -f "$PIGEON_NOTARY_KEY" ] || die "PIGEON_NOTARY_KEY not found: $PIGEON_NOTARY_KEY"
        [ -n "${PIGEON_NOTARY_KEY_ID:-}" ] && [ -n "${PIGEON_NOTARY_ISSUER:-}" ] \
            || die "PIGEON_NOTARY_KEY needs PIGEON_NOTARY_KEY_ID and PIGEON_NOTARY_ISSUER"
        notary() { xcrun notarytool "$@" --key "$PIGEON_NOTARY_KEY" \
            --key-id "$PIGEON_NOTARY_KEY_ID" --issuer "$PIGEON_NOTARY_ISSUER"; }
    else
        notary() { xcrun notarytool "$@" --keychain-profile "$PROFILE"; }
    fi
    log "checking notary credentials"
    notary history >/dev/null 2>&1 \
        || die "notary service rejected the credentials (profile '$PROFILE').
Run scripts/notary-setup.sh once, or pass --no-notarize for a sign-only build."
fi

if [ ! -d "$ROOT/vendor/ghostty/zig-out/share/ghostty" ]; then
    die "libghostty not built — run scripts/setup.sh (or scripts/build-ghostty.sh)"
fi
[ -d "$ROOT/Pigeon.xcodeproj" ] || xcodegen generate

if [ -z "$VERSION" ]; then
    VERSION=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1)
fi
if [ -z "$BUILD" ]; then
    BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *//p' project.yml | head -1)
fi
[ -n "$VERSION" ] && [ -n "$BUILD" ] || die "could not determine version/build"

# ---- build ------------------------------------------------------------

# Fresh derived data: stale incremental state after an xcodegen run has
# produced apps whose ghostty_surface_new fails (see CLAUDE.md). This
# path is separate from build/ so the running dev instance is untouched.
log "building Pigeon $VERSION ($BUILD) — Release, $IDENTITY_NAME"
rm -rf "$DERIVED" "$DERIVED.log"
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: the `build` action otherwise
# injects com.apple.security.get-task-allow (debuggable), which the
# notary service rejects.
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon \
    -configuration Release -derivedDataPath "$DERIVED" \
    ${ARCHS:+ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO} \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    build > "$DERIVED.log" 2>&1 \
    || { grep -E "error:|BUILD FAILED" "$DERIVED.log" | head -20; die "build failed (full log: $DERIVED.log)"; }
APP="$DERIVED/Build/Products/Release/Pigeon.app"
[ -d "$APP" ] || die "build produced no $APP (log: $DERIVED.log)"

# ---- verify signature -------------------------------------------------

log "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
INFO=$(codesign -dvv "$APP" 2>&1)
echo "$INFO" | grep -q "Authority=$IDENTITY_NAME" \
    || die "app is not signed with $IDENTITY_NAME:
$INFO"
echo "$INFO" | grep -q "flags=.*runtime" || die "hardened runtime flag missing on the app"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q get-task-allow; then
    die "get-task-allow entitlement present — notarization would reject it"
fi
# Every nested Mach-O (Sparkle framework, its XPC services, Autoupdate,
# Updater.app) must carry the hardened runtime too, or notarization
# fails on that item.
find "$APP/Contents/Frameworks" \( -name "*.xpc" -o -name "*.app" -o -name Autoupdate \) -prune -print \
| while read -r nested; do
    NESTED=$(codesign -dvv "$nested" 2>&1)
    echo "$NESTED" | grep -q "flags=.*runtime" \
        || die "hardened runtime flag missing on nested code: $nested"
    echo "$NESTED" | grep -q "TeamIdentifier=$TEAM_ID" \
        || die "nested code not signed by team $TEAM_ID: $nested"
done

# ---- notarize + staple ------------------------------------------------

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$DIST/Pigeon-$VERSION.zip"

if [ "$NOTARIZE" = 1 ]; then
    log "submitting to Apple notary service (waits for the verdict)"
    # ditto preserves everything codesign cares about (symlinks, xattrs).
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    SUBMIT=$(notary submit "$DIST/notarize.zip" --wait 2>&1) || true
    echo "$SUBMIT"
    ID=$(echo "$SUBMIT" | sed -n 's/^ *id: *//p' | head -1)
    if ! echo "$SUBMIT" | grep -q "status: Accepted"; then
        [ -n "$ID" ] && notary log "$ID" || true
        die "notarization failed"
    fi
    rm -f "$DIST/notarize.zip"

    log "stapling ticket"
    xcrun stapler staple "$APP"
fi

ditto "$APP" "$DIST/Pigeon.app"
ditto -c -k --keepParent "$DIST/Pigeon.app" "$ZIP"

# ---- gatekeeper verdict ------------------------------------------------

log "gatekeeper assessment"
if [ "$NOTARIZE" = 1 ]; then
    spctl --assess --type execute --verbose=2 "$DIST/Pigeon.app"
    xcrun stapler validate "$DIST/Pigeon.app"
else
    spctl --assess --type execute --verbose=2 "$DIST/Pigeon.app" \
        || echo "(expected without notarization: Gatekeeper only accepts notarized Developer ID apps)"
fi

log "done: $ZIP"
