# Ledge editor

The app's builder/chat surface (spec §8), rendered by a `WKWebView` inside the
notch panel. It is **not** a Ledge app: it renders `builder` events (§3.6) and
originates `builderInput` (§4.3), and it is the only web content in the shell.

```sh
scripts/build-editor.sh          # → shell/Sources/LedgeShell/Resources/editor/
cd shell && swift build
```

`scripts/bundle-app.sh` runs the build itself, so a packaged `.app` always
carries a bundle that matches the sources.

The **built output is tracked**, not gitignored. SwiftPM's `.copy` fails outright
when the declared resource path does not exist, so an ignored bundle would mean
a fresh clone could not run `swift build` at all — and the alternative (commit
`index.html`, ignore the rest) trades a legible "editor bundle missing" card for
a blank panel and a 404. The cost is a churny diff on `editor.js` whenever the
page changes; the alternative is a repo that does not build.

## Constraints, and why

- **One self-contained bundle, loaded from `file://`.** No CDN, no remote fonts,
  no `fetch` at runtime. The CSP in `src/index.html` denies `connect-src`
  outright: the transcript is model output, and a surface that could reach the
  network on its instructions is an exfiltration path through the user's notch.
- **Transparent background.** The panel is black glass. The page paints no
  background of its own (`html`/`body` stay transparent) and the Swift side
  turns off `drawsBackground` — a white page does not tint the glass, it
  replaces it.
- **Never `innerHTML` model output.** Everything the agent produced goes through
  React as text. `src/markdown.js` is a deliberately small renderer that emits
  React elements, not HTML strings — there is no path from a `builder` event to
  parsed markup.
- **No layout above the panel's first row.** The shell mounts the page below the
  cutout exclusion row, so the page's own origin is already clear of the camera.

## The bridge

Swift injects one global and reads one message channel. Both halves are in
`shell/Sources/LedgeShell/EditorBridge.swift`; the page's half is `src/bridge.js`.

```js
window.ledge.onEvent(event => { … })   // → unsubscribe()
window.ledge.send("make the price green when it's up")
window.ledge.cancel()
```

Events arriving from Swift:

| `event`    | fields                                                |
|------------|-------------------------------------------------------|
| `thread`   | `app` — start a fresh transcript for this app          |
| `text`     | `delta`                                                |
| `tool`     | `name`, `detail`, `state` (`started` \| `completed`)   |
| `status`   | `text`                                                 |
| `done`     | `status` (`completed` \| `interrupted` \| `failed`)    |
| `error`    | `message`                                              |

Every event also carries `app` and `turn`. Unknown `event` values are forwarded
verbatim rather than dropped, so the host and the shell can ship separately.

`window.ledge.send`/`cancel` post `{type:"input",text}` / `{type:"cancel"}` to
the `ledge` message handler; Swift turns them into a `builderInput` envelope for
whichever app is **presented** — the page never names an app.

The page must call `window.ledge.ready()` once (the bridge module does it on
load). Swift queues events until it does, because `builder` frames routinely
arrive before `loadFileURL` has finished parsing the bundle.

## Layout note

`src/app.jsx` is a placeholder UI, on purpose: the deliverable is the pipe. It
renders the transcript, the tool chips, the status line and the composer, and
nothing else.
