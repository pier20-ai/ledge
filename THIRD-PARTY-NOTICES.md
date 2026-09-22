# Third-party notices

Ledge's own code is MIT (see [LICENSE](LICENSE)). The built app and disk image
redistribute the following third-party software:

## Bun

The app bundles the [Bun](https://bun.sh) runtime as `Contents/MacOS/ledge-host`.
Bun is MIT-licensed — © Oven and contributors — and statically includes
JavaScriptCore (LGPL-2.1) and other dependencies; see
[Bun's acknowledgements](https://github.com/oven-sh/bun/blob/main/LICENSE.md)
for its full list. Source: <https://github.com/oven-sh/bun>.

## Stockfish

The chess demo app uses [stockfish.js](https://github.com/nmrugg/stockfish.js)
(the WASM build of [Stockfish](https://github.com/official-stockfish/Stockfish)),
which is licensed under the **GPL-3.0**, and a copy ships inside the app's seed
payload. Stockfish is © the Stockfish developers (see their
[AUTHORS](https://github.com/official-stockfish/Stockfish/blob/master/AUTHORS)).
Its complete corresponding source is available at the links above, at the
version pinned in [protocol/demo-apps/package.json](protocol/demo-apps/package.json).
The GPL applies to Stockfish itself; it is an independent engine invoked by the
chess app, not a part of Ledge's own MIT-licensed code.

## React

The seed payload includes [React](https://react.dev) and `react-reconciler`
(MIT, © Meta Platforms) as the shared apps-root dependency, and
[chess.js](https://github.com/jhlywa/chess.js) (BSD-2-Clause, © Jeff Hlywa)
for the chess demo.
