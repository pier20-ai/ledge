#!/usr/bin/env bash
# Build Ledge.app: the Swift shell, the compiled Bun host, and the seed payload
# (demo apps + shared node_modules), signed so macOS will run it and TCC will
# remember it.
#
# Usage:
#   scripts/bundle-app.sh [--debug] [--output <dir>] [--identity <name>]
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
VERSION="0.4.0"

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="debug"; shift ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
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
BUN_BIN="$(command -v bun)" || fail "bun is not on PATH"
PINNED_BUN="$(cat "$HOST_DIR/.bun-version" 2>/dev/null || echo "")"
ACTUAL_BUN="$("$BUN_BIN" --version)"
if [ -n "$PINNED_BUN" ] && [ "$PINNED_BUN" != "$ACTUAL_BUN" ]; then
  fail "bun $ACTUAL_BUN is on PATH but host/.bun-version pins $PINNED_BUN"
fi
log "bundling bun $ACTUAL_BUN"

# --- Assemble ---------------------------------------------------------------

log "assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/host/src"

cp "$SHELL_BIN" "$CONTENTS/MacOS/LedgeShell"
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
rsync -a --exclude '.build' --exclude 'crash.log' --exclude 'node_modules' \
  "$DEMO_APPS/" "$SEED_STAGE/apps/"
rsync -a "$DEMO_APPS/node_modules/" "$SEED_STAGE/node_modules/"
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
# Ledge CLI (spec §8). Symlink this somewhere on your PATH:
#   ln -s "/Applications/Ledge.app/Contents/Resources/ledge" /usr/local/bin/ledge
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/../MacOS/ledge-host" "$HERE/host/src/cli.ts" "$@"
SHIM
chmod +x "$CONTENTS/Resources/ledge"

# A placeholder icon until Manu's lands: rendered from an SF Symbol so the
# bundle has *an* icon rather than the generic one. Replaced by dropping a real
# AppIcon.icns in scripts/assets/.
if [ -f "$REPO_ROOT/scripts/assets/AppIcon.icns" ]; then
  cp "$REPO_ROOT/scripts/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
  ICON_ENTRY='<key>CFBundleIconFile</key><string>AppIcon</string>'
  log "icon: scripts/assets/AppIcon.icns"
else
  ICON_ENTRY=''
  log "icon: none yet (drop one at scripts/assets/AppIcon.icns)"
fi

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
  <!-- ctx.apple (spec §6) drives other apps; macOS shows this in the prompt. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Ledge apps use AppleScript and Shortcuts to talk to your other apps.</string>
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
log "signing the host…"
codesign --remove-signature "$CONTENTS/MacOS/ledge-host" 2>/dev/null || true
codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --identifier "dev.ledge.host" \
  --options runtime \
  "$CONTENTS/MacOS/ledge-host" >/dev/null 2>&1 \
  || fail "could not sign the host"

log "signing the app…"
# Inside-out: nested code first (done above), then the bundle.
codesign --force --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  "$CONTENTS/MacOS/LedgeShell" >/dev/null 2>&1 \
  || fail "could not sign the shell binary"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
  || fail "could not sign the bundle"

codesign --verify --deep --strict "$APP" \
  || fail "signature verification failed"
log "✓ signature verifies"

log "PASS — $APP"
log "run it:  open '$APP'"
log "logs:    tail -f ~/.ledge/host.log"
