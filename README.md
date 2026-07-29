# Ledge

Apps that live in the notch.

A Ledge app is one folder with an `app.jsx` in it. You write React; it renders as
**native AppKit views** in a panel hanging off the MacBook's camera housing —
not a web view, not a menu-bar popover. Save the file and it hot-reloads in
about 300 ms. Ask the notch's own chat for a change and your own coding agent
makes it, in that folder, while you watch.

Three processes, and the split is the design:

| | what it owns |
|---|---|
| **Swift shell** (`shell/`) | the surface. AppKit views, focus, hover, animation — everything transient. Listens on `~/.ledge/ledge.sock`. |
| **Bun host** (`host/`) | the truth. Router, transpiler, file watcher, one worker per app. Connects to the shell. |
| **App workers** | one Bun Worker each, running a React reconciler over the user's `app.jsx`. |

Nothing round-trips another's half: on doubt the host re-renders and the shell
rebuilds. The wire format is in [`docs/design/spec.md`](docs/design/spec.md).

---

## Requirements

- **macOS 14 or later** (`Package.swift` sets the floor; developed on 15.7).
- **Swift 6** — Xcode or the command line tools. Built with 6.1.2.
- **Bun**, at the version in [`host/.bun-version`](host/.bun-version) — currently
  **1.3.9**. `bundle-app.sh` refuses to build against a different one rather than
  ship a runtime the app was never tested on.
- **[Codex](https://github.com/openai/codex)**, optional: `npm i -g @openai/codex`.
  It powers the notch's chat. Ledge never calls a model API itself — it drives
  the agent you already have — so without it everything works except the
  builder, and the panel says so.

## Setup

```bash
git clone <this repo> ledge && cd ledge
(cd host && bun install)
(cd protocol/demo-apps && bun install)
(cd editor && bun install)
```

Three installs, and they are three different things:

- `host/node_modules` — the host's own tooling.
- `protocol/demo-apps/node_modules` — the **apps root**: the copy of React that
  every app and the reconciler must share (spec §6). One React instance, or
  hooks throw on the first `useState`.
- `editor/node_modules` — the chat surface's React, bundled into the page.
  Needed by `scripts/build-editor.sh` and by the host suite, which tests the
  editor's markdown renderer where it lives.

## Run it

Two terminals. A development build **deliberately does not start the host** —
the dev loop is running one by hand, and two hosts on one socket is a confusing
failure.

```bash
cd shell && swift run LedgeShell
```

```bash
cd host && bun run start:demos
```

The panel appears under the notch with the demo apps in the strip. `start:demos`
points the host at `protocol/demo-apps` instead of `~/.ledge/apps`, so the repo's
apps are the ones you edit.

Useful flags: the shell takes `--socket <path>` and `--ledge-root <dir>`; the
host takes `--apps-root <dir>`. Use both whenever you want a run that cannot
touch your real install.

If you change anything under `editor/src` (the chat surface — HTML/CSS/JS inside
a WKWebView), rebuild it before the shell, because it is a SwiftPM *resource*:

```bash
scripts/build-editor.sh
```

The built bundle is committed, so a fresh clone does not need this.

## Build and install the app

```bash
scripts/bundle-app.sh
```

That builds the editor, the shell and the host, assembles `dist/Ledge.app` with
the Bun runtime and a seed payload inside it, and signs it.

**Signing.** The default identity is a self-signed certificate named
`Ledge Dev`, which you make once in Keychain Access (Certificate Assistant →
Create a Certificate → *Ledge Dev*, type *Code Signing*). This matters more than
it looks: macOS keys TCC grants to the code signature, so with an **ad-hoc**
signature every rebuild is a brand-new app and you re-grant Screen Recording,
Automation and notifications every single time. To sign ad-hoc anyway:

```bash
scripts/bundle-app.sh --identity -
```

Pass a Developer ID the same way when you have one. Shipping to other people
also needs notarization, which needs the paid Apple Developer Program.

**Install:**

```bash
cp -R dist/Ledge.app ~/Applications/
```

Delete any older copy first. Ledge is `LSUIElement` — no Dock icon and no
menu-bar item — so an old build in `~/Applications` will be launched by
Spotlight in preference to your new one, and a copy that predates the bundled
host can never start one. (The panel will tell you if that happens.)

**First launch** seeds `~/.ledge` from inside the app: the demo apps, the shared
`node_modules`, and the docs the agent reads. It never overwrites apps you have
edited.

## The `ledge` command

Not installed automatically — writing to `/usr/local/bin` needs a privilege the
app does not have and should not ask for:

```bash
ln -s ~/Applications/Ledge.app/Contents/Resources/ledge /usr/local/bin/ledge
```

```
ledge new <id>       scaffold an app
ledge list           installed apps
ledge status         the same, as JSON
ledge reload <id>    touch the entry point; the watcher does the rest
ledge logs <id>      what the app printed, and its last crash if any
ledge shot <id>      render the app's panel to a PNG and print the path
```

`shot` renders through the real reconciler and the real renderer with no shell
running and no screen-recording permission involved. It is how an agent editing
an app can see what it wrote — and how you can, from a terminal.

## Tests

```bash
cd shell && swift test      # the shell, the protocol engine, the renderer
cd host  && bun test        # the host, the workers, the CLI, the adapters
```

Two more that are worth running before you believe a change:

```bash
scripts/snapshot-demos.sh   # every demo app's panel to a PNG, through the real renderer
scripts/bundle-smoke.sh     # the built .app seeds, connects, and dies with its shell
```

Nothing in either suite touches your real `~/.ledge`, binds the real socket, or
spawns a real Codex — temp roots and fakes throughout. That is a rule, not a
convention: a test that spends your agent quota or eats your apps is worse than
no test.

## Layout

| | |
|---|---|
| `shell/` | the Swift app: panel, renderer, protocol client |
| `host/` | the Bun host: router, supervisor, watcher, `ledge` CLI, Codex adapter |
| `editor/` | the chat surface rendered inside the panel's web view |
| `protocol/` | the wire fixtures both sides assert against, and the demo apps |
| `protocol/demo-apps/AGENTS.md` | what an agent editing an app reads first |
| `protocol/demo-apps/REFERENCE.md` | the API: every component, prop and `ctx` call |
| `docs/design/spec.md` | the protocol |
| `scripts/` | bundling, snapshots, smoke tests, the icon pipeline |

## Where things live at runtime

Everything Ledge owns is under `~/.ledge`:

```
~/.ledge/
  apps/            one folder per app — yours, never overwritten after first launch
  node_modules/    the shared React the apps and the reconciler both resolve
  ledge.sock       the shell listens here; the host connects
  host.log         the host's log, and every app's console output
  settings.json    which apps are switched off
  .onboarded       the permission surface has been shown once
```

An app's own folder holds its `app.jsx`, whatever it persists, its
`console.log`, and a `crash.log` if it has ever crashed.
