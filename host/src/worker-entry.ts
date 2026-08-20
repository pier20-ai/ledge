// The app worker's entrypoint, at a FLAT path on purpose.
//
// `bun build --compile` embeds each extra entrypoint at the bundle root, and a
// worker spawned inside the compiled binary can only resolve it there:
//
//   new Worker(new URL("./worker/entry.ts", …))  → ModuleNotFound (oven-sh/bun#29124)
//   new Worker(new URL("./worker-entry.js", …))  → resolves
//
// Two things bite here, both measured rather than read:
//   1. Nested paths do not resolve from `$bunfs` — hence this file sitting
//      beside host.ts rather than the real entry staying one directory down.
//   2. The embedded copy is named **.js**, whatever the source extension was.
//      `./worker-entry.ts` fails inside the binary; `./worker-entry.js` works.
//      That is undocumented, so worker-factory.ts picks the extension by mode.
//
// The implementation stays in worker/entry.ts — that is where its tests and its
// siblings live, and moving it would have bought nothing but churn. This file is
// only the address the bundler needs.
import "./worker/entry";
