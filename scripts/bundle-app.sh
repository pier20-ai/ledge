#!/usr/bin/env bash
# Build Ledge.app: the Swift shell, the compiled Bun host, and the seed payload
# (demo apps + shared node_modules), signed so macOS will run it and TCC will
# remember it.
#
# Usage:
#   scripts/bundle-app.sh [--debug] [--output <dir>] [--identity <name>] [--notarize]
#
# --notarize (needs a "Developer ID Application" identity and a notarytool
#   keychain profile named "ledge-notary") submits the signed app to Apple and
#   staples the ticket to it. Do this BEFORE make-dmg.sh --notarize: a disk
#   image's ticket covers the app only while it is inside the image, and the
#   app the user drags to /Applications needs its own to verify offline.
#
# Signing identity (`--identity`, or $LEDGE_SIGN_IDENTITY):
#   Default is a self-signed certificate named "Ledge Dev" from the login
#   keychain — NOT ad-hoc ("-"). This matters more than it looks: TCC keys its
#   grants to the code signature, and an ad-hoc signature is just a hash of the
#   binary, so every rebuild is a brand-new app and you re-grant Screen
#   Recording / Automation / notifications every single time. A stable
#   self-signed identity gives a stable Designated Requirement, so the grants
#   survive rebuilds. Create one once (Keychain Access → Certificate Assistant →
#   Create a Certificate → name "Ledge Dev", type "Code Signing"), or pass a
#   Developer ID here when there is one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$REPO_ROOT/shell"
HOST_DIR="$REPO_ROOT/host"
DEMO_APPS="$REPO_ROOT/protocol/demo-apps"

CONFIGURATION="release"
OUTPUT_DIR="$REPO_ROOT/dist"
IDENTITY="${LEDGE_SIGN_IDENTITY:-Ledge Dev}"
BUNDLE_ID="dev.ledge.shell"
VERSION="1.0.0"
NOTARIZE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="debug"; shift ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

APP="$OUTPUT_DIR/Ledge.app"
CONTENTS="$APP/Contents"
ENTITLEMENTS="$OUTPUT_DIR/ledge-host.entitlements"

log()  { printf '\033[1;34m[bundle]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[bundle] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Signing identity -------------------------------------------------------

if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  cat >&2 <<EOF
No code-signing identity named "$IDENTITY" was found.

Create one (once):
  Keychain Access → Certificate Assistant → Create a Certificate…
    Name: $IDENTITY
    Identity Type: Self Signed Root
    Certificate Type: Code Signing

Then re-run. To sign ad-hoc instead, pass --identity -, but note that TCC
grants (Screen Recording, Automation, notifications) will reset on EVERY
rebuild, because an ad-hoc signature has no stable identity.
EOF
  exit 1
fi
log "signing as: $IDENTITY"

# --- Build ------------------------------------------------------------------

# Before the shell: the editor surface (spec §8) is a SwiftPM *resource* of the
# shell target, so it has to exist on disk before `swift build` stages it — a
# shell built without it ships a panel that says the bundle is missing.
log "building the editor surface…"
"$REPO_ROOT/scripts/build-editor.sh" >/dev/null || fail "editor build failed"

log "building the shell ($CONFIGURATION)…"
( cd "$SHELL_DIR" && swift build -c "$CONFIGURATION" ) >/dev/null \
  || fail "swift build failed"
SHELL_BIN="$SHELL_DIR/.build/$CONFIGURATION/LedgeShell"
[ -x "$SHELL_BIN" ] || fail "no shell binary at $SHELL_BIN"

# The host ships as the Bun RUNTIME plus its TypeScript sources, rather than as
# a `bun build --compile` binary. Both work (the compile path is still supported
# — `bun run build` in host/, and the e2e covers it via LEDGE_HOST_CMD); this one
# is shipped because:
#
#   * It is the same size. A compiled host IS bun plus ~1 MB of JS: 58 MB vs the
#     57 MB runtime, so the "single binary" buys nothing here.
#   * Spec §6 lets an app declare `// deps: some-pkg`, and the host answers by
#     running `bun install` in that app's folder. A compiled host cannot — there
#     is no bun CLI inside it — so that feature would force us to ship the
#     runtime anyway, i.e. BOTH binaries (~115 MB).
#   * The host needs no node_modules of its own. Every `react` import in src/ is
#     type-only; the runtime copy is resolved from the apps root at boot
#     (src/render/runtime.ts). So "ship the sources" is 208 KB of .ts with no
#     dependency tree — and therefore no symlinks for codesign to reject.
#   * It sidesteps both --compile hazards (nested worker entrypoints, and extra
#     entrypoints being embedded as .js).
log "staging the host runtime + sources…"
mkdir -p "$OUTPUT_DIR"

# The shipped runtime is the release pinned in host/.bun-version, downloaded
# from Bun's official GitHub releases and checksum-verified — never whatever
# `bun` happens to be on this machine's PATH. That makes the pin the single
# source of truth (any machine, incl. CI, ships the same bytes) and keeps a
# bun upgrade a deliberate one-line bump. arm64-only by design: Ledge lives in
# the notch, and every notched Mac is Apple Silicon.
[ "$(uname -m)" = "arm64" ] || fail "release bundles are arm64-only; build on Apple Silicon"
PINNED_BUN="$(cat "$HOST_DIR/.bun-version" 2>/dev/null || echo "")"
[ -n "$PINNED_BUN" ] || fail "host/.bun-version is missing or empty"
BUN_CACHE="${LEDGE_BUN_CACHE:-$HOME/Library/Caches/ledge-build}/bun-v$PINNED_BUN"
BUN_BIN="$BUN_CACHE/bun-darwin-aarch64/bun"
if [ ! -x "$BUN_BIN" ]; then
  log "downloading bun v$PINNED_BUN (darwin-aarch64)…"
  BUN_RELEASE="https://github.com/oven-sh/bun/releases/download/bun-v$PINNED_BUN"
  mkdir -p "$BUN_CACHE"
  curl -fsSL --proto '=https' -o "$BUN_CACHE/bun-darwin-aarch64.zip" \
    "$BUN_RELEASE/bun-darwin-aarch64.zip" || fail "could not download bun v$PINNED_BUN"
  curl -fsSL --proto '=https' -o "$BUN_CACHE/SHASUMS256.txt" \
    "$BUN_RELEASE/SHASUMS256.txt" || fail "could not download bun's SHASUMS256.txt"
  ( cd "$BUN_CACHE" \
      && grep ' bun-darwin-aarch64.zip$' SHASUMS256.txt | shasum -a 256 -c - >/dev/null ) \
    || fail "bun v$PINNED_BUN failed checksum verification"
  unzip -oq "$BUN_CACHE/bun-darwin-aarch64.zip" -d "$BUN_CACHE" \
    || fail "could not unzip the bun release"
  rm -f "$BUN_CACHE/bun-darwin-aarch64.zip"
  [ -x "$BUN_BIN" ] || fail "bun release unpacked to an unexpected layout"
fi
ACTUAL_BUN="$("$BUN_BIN" --version)"
[ "$ACTUAL_BUN" = "$PINNED_BUN" ] \
  || fail "cached bun at $BUN_BIN reports $ACTUAL_BUN, expected $PINNED_BUN"
log "bundling bun $ACTUAL_BUN"

# --- Assemble ---------------------------------------------------------------

log "assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/host/src"

cp "$SHELL_BIN" "$CONTENTS/MacOS/LedgeShell"
# SwiftPM emits target resources as a sibling bundle of the binary, and
# `Bundle.module` finds it by looking in `Bundle.main.resourceURL` first — which
# inside an .app is Contents/Resources. So the whole bundle goes there, name
# intact: rename it and the generated accessor traps at first use.
SHELL_RESOURCES="$SHELL_DIR/.build/$CONFIGURATION/LedgeShell_LedgeShell.bundle"
[ -d "$SHELL_RESOURCES" ] || fail "no shell resource bundle at $SHELL_RESOURCES"
# SwiftPM emits the bundle flat on older toolchains and as a full macOS
# bundle (Contents/Resources/…) on newer ones; Bundle.module handles either.
[ -f "$SHELL_RESOURCES/editor/index.html" ] \
  || [ -f "$SHELL_RESOURCES/Contents/Resources/editor/index.html" ] \
  || fail "the resource bundle carries no editor"
rsync -a "$SHELL_RESOURCES" "$CONTENTS/Resources/"
# The Bun runtime, named for its job rather than its implementation: this
# process IS the Ledge host, and "ledge-host" in Activity Monitor (or in a
# pkill) is both clearer to the user and impossible to confuse with a `bun` the
# user is running themselves.
cp "$BUN_BIN" "$CONTENTS/MacOS/ledge-host"
chmod +x "$CONTENTS/MacOS/ledge-host"
# The host's TypeScript, transpiled by bun on load (spec §6 — the same thing it
# does for every app.jsx).
rsync -a --exclude 'fakes' "$HOST_DIR/src/" "$CONTENTS/Resources/host/src/"

# The seed payload expanded into ~/.ledge on first launch (LedgeInstall.swift).
# node_modules is NOT optional: apps and the worker's reconciler both resolve
# react from the apps root, and a compiled host has no copy of its own.
#
# Shipped as a tarball rather than a directory tree, for two reasons found the
# hard way: (1) codesign REJECTS a bundle containing symlinks that point outside
# it ("invalid destination for symbolic link in bundle"), and node_modules is
# full of them — `.bin` shims now, and whatever an app's own `bun install`
# creates later; (2) it is ~1,400 files that codesign would otherwise hash
# individually on every build. One opaque resource sidesteps both.
log "staging seed payload (apps + node_modules)…"
[ -d "$DEMO_APPS/node_modules" ] || ( cd "$DEMO_APPS" && bun install >/dev/null )
SEED_STAGE="$OUTPUT_DIR/seed-stage"
rm -rf "$SEED_STAGE"
mkdir -p "$SEED_STAGE/apps"
# Only what git tracks. The apps write their runtime state beside themselves
# — every app's console.log, weather's cache.json (the last forecast AND the
# IP fix that located it), nowplaying's pulled artwork — and all of it is
# gitignored for exactly that reason: data, not source. A build on a machine
# that has run the apps must not carry the developer's last hour into a
# stranger's ~/.ledge. So the exclusions are git's own, not a hand-kept list.
SEED_EXCLUDES="$OUTPUT_DIR/seed-excludes"
{
  git -C "$REPO_ROOT" ls-files --others --ignored --exclude-standard --directory -- protocol/demo-apps
  git -C "$REPO_ROOT" ls-files --others --exclude-standard --directory -- protocol/demo-apps
} | sed 's|^protocol/demo-apps/|/|' > "$SEED_EXCLUDES"
rsync -a --exclude '.build' --exclude 'crash.log' --exclude 'node_modules' \
  --exclude-from="$SEED_EXCLUDES" "$DEMO_APPS/" "$SEED_STAGE/apps/"
# …and the guard, because the list above is only as good as .gitignore.
STRAY="$(find "$SEED_STAGE/apps" \( -name 'console.log' -o -name 'crash.log' -o -name 'cache.json' -o -name 'art-*.jpg' -o -name '*.sqlite*' \) -print)"
[ -z "$STRAY" ] || fail "runtime artifacts in the seed payload — a developer's data would ship:
$STRAY"
rsync -a "$DEMO_APPS/node_modules/" "$SEED_STAGE/node_modules/"

# The stockfish prune, restored in D4 when chess came back to the apps root.
# The package ships every build it knows how to make — asm.js, and full and
# lite WASM — and the NNUE net inside each full build is ~100 MB, so the whole
# thing is 239 MB. Chess loads exactly one of them: `stockfish-18-lite-single`,
# the single-threaded build, which is the only shape that survives being
# spawned as someone else's child (see the app's header). Keeping just that
# pair takes the dependency from 239 MB to ~7 MB. Nothing here is conditional
# on chess being installed: if the package is absent the glob matches nothing
# and the loop is a no-op.
SF_BIN="$SEED_STAGE/node_modules/stockfish/bin"
if [ -d "$SF_BIN" ]; then
  before="$(du -sh "$SF_BIN" | cut -f1)"
  find "$SF_BIN" -type f ! -name 'stockfish-18-lite-single.*' -delete
  log "pruned stockfish builds: $before -> $(du -sh "$SF_BIN" | cut -f1) (lite-single only)"
fi

tar -czf "$CONTENTS/Resources/seed.tar.gz" -C "$SEED_STAGE" apps node_modules
rm -rf "$SEED_STAGE"
log "seed payload: $(du -h "$CONTENTS/Resources/seed.tar.gz" | cut -f1)"

# `ledge` on the user's PATH, as a shim rather than a second binary: it runs the
# bundled runtime against the bundled CLI source, so it can never drift from the
# host it manages. Not installed automatically — writing to /usr/local/bin needs
# a privilege the app does not have and should not ask for.
#
# In Resources/, NOT MacOS/. Signing the main executable treats everything in
# MacOS/ as nested *code* that must itself be signed, and a shell script is not
# Mach-O — putting it there fails the whole bundle with "code object is not
# signed at all". As a resource it is sealed with the rest of the bundle.
cat > "$CONTENTS/Resources/ledge" <<'SHIM'
#!/bin/sh
# Ledge CLI (spec §8). The app symlinks this to ~/.local/bin/ledge on every
# launch (LedgeInstall.installCLIIfPossible) and re-points the link when the
# app moves — nothing to run by hand. Relocatable on purpose: everything is
# resolved from where this file actually is.
HERE="$(cd "$(dirname "$0")" && pwd)"
# `ledge shot` renders an app through the shell binary. It is right here, and
# saying so beats making the CLI guess where the app was installed.
LEDGE_SHELL_BIN="$HERE/../MacOS/LedgeShell"
export LEDGE_SHELL_BIN
exec "$HERE/../MacOS/ledge-host" "$HERE/host/src/cli.ts" "$@"
SHIM
chmod +x "$CONTENTS/Resources/ledge"

if [ -f "$REPO_ROOT/scripts/assets/AppIcon.icns" ]; then
  cp "$REPO_ROOT/scripts/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
  ICON_ENTRY='<key>CFBundleIconFile</key><string>AppIcon</string>'
  log "icon: scripts/assets/AppIcon.icns"
else
  ICON_ENTRY=''
  log "icon: none yet (drop one at scripts/assets/AppIcon.icns)"
fi

# Backticks in here are ESCAPED. This heredoc is unquoted, because it has to
# interpolate $BUNDLE_ID/$VERSION/$ICON_ENTRY — which means the shell also
# performs command substitution inside it, and a comment mentioning
# `ctx.platform.calendar` in the ordinary prose style of this repo silently RAN
# it. The output landed inside an XML comment, so nothing broke; that is worse
# than breaking, not better.
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ledge</string>
  <key>CFBundleDisplayName</key><string>Ledge</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>LedgeShell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  $ICON_ENTRY
  <!-- Menubar-only: no Dock tile, no menu bar of its own. -->
  <key>LSUIElement</key><true/>
  <!-- The consent strings macOS shows in Ledge's own prompts. Every capability
       an app reaches through the shell (spec §6) that has a usage-description
       key needs one HERE, in this file, or the API does not fail politely — it
       TERMINATES the process on the first call. That is not hypothetical: the
       calendar and location keys were missing until the permission surface went
       looking for them, so \`ctx.platform.calendar\` would have killed the shell
       (and every app's panel with it) the first time an app asked for events.
       \`shell/Sources/LedgeShellCore/Capabilities/PermissionCatalog.swift\` names
       the same three keys, and a test asserts them — keep the two in step. -->
  <!-- ctx.apple (spec §6) drives other apps; macOS shows this in the prompt. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Ledge apps use AppleScript and Shortcuts to talk to your other apps.</string>
  <!-- ctx.platform.calendar. Read-only: nothing in Ledge writes an event. -->
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Ledge apps show your upcoming events in the notch.</string>
  <!-- ctx.platform.location, at reduced accuracy (see SystemLocation). -->
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Ledge apps use your rough location for things like local weather.</string>
  <!-- ctx.record (G3): the mic and the system tap, each its own consent. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Ledge apps record your side of a conversation when you press record.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Ledge apps record what the machine plays — the other side of a call.</string>
</dict>
</plist>
EOF

# --- Sign -------------------------------------------------------------------

# JSC needs these five; without them a hardened/compiled Bun binary is killed on
# launch. https://bun.com/docs/guides/runtime/codesign-macos-executable
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
EOF

# `bun build --compile` emits a binary whose linker-signed signature does not
# validate (oven-sh/bun#32159) — harmless on macOS 15, fatal on 27 betas, and it
# blocks re-signing either way. Strip first, then sign for real.

# Notarization requires a secure timestamp on every signature. Apple's
# timestamp server only countersigns real Apple-issued identities, so ask for
# one exactly when we hold one ("Ledge Dev" and ad-hoc stay offline-friendly).
case "$IDENTITY" in
  "Developer ID Application"*) TIMESTAMP="--timestamp" ;;
  *)                           TIMESTAMP="--timestamp=none" ;;
esac

log "signing the host…"
codesign --remove-signature "$CONTENTS/MacOS/ledge-host" 2>/dev/null || true
# Keep codesign's own words in the failure: the usual first-run culprits (the
# keychain wanting authorization for the key, the timestamp server) are
# indistinguishable without them. On the keychain one, running any codesign by
# hand once — approving the prompt — primes the key, and a rerun passes.
OUT="$(codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --identifier "dev.ledge.host" \
  --options runtime "$TIMESTAMP" \
  "$CONTENTS/MacOS/ledge-host" 2>&1)" \
  || fail "could not sign the host: $OUT"

log "signing the app…"
# Inside-out: nested code first (done above), then the bundle. The bundle pass
# re-signs the main executable, so it must carry the same hardened-runtime flag.
OUT="$(codesign --force --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime "$TIMESTAMP" \
  "$CONTENTS/MacOS/LedgeShell" 2>&1)" \
  || fail "could not sign the shell binary: $OUT"
OUT="$(codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
  --options runtime "$TIMESTAMP" \
  "$APP" 2>&1)" \
  || fail "could not sign the bundle: $OUT"

codesign --verify --deep --strict "$APP" \
  || fail "signature verification failed"
log "✓ signature verifies"

# --- Notarize (optional) ----------------------------------------------------

if [ "$NOTARIZE" = 1 ]; then
  case "$IDENTITY" in
    "Developer ID Application"*) ;;
    *) fail "--notarize needs a \"Developer ID Application\" identity (signing as: $IDENTITY)" ;;
  esac
  ZIP="$OUTPUT_DIR/Ledge-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP" || fail "could not zip the app for notarization"
  log "notarizing the app (this can take a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile ledge-notary --wait \
    || fail "notarization failed (xcrun notarytool log <submission-id> --keychain-profile ledge-notary)"
  xcrun stapler staple "$APP" || fail "stapling failed"
  rm -f "$ZIP"
  log "✓ notarized and stapled"
fi

log "PASS — $APP"
log "run it:  open '$APP'"
log "logs:    tail -f ~/.ledge/host.log"
