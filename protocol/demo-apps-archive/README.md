# Archive

Apps that are kept but not loaded. This folder is **not** an apps root: nothing
scans it, nothing installs its dependencies, and nothing in it is a model for
new work.

Most of these predate the design reset (`docs/design/principles.md`) and are
here so the rewrites can cite them — `chess` and `blocks` came back *out* of
this folder in D4, and each new file's header quotes the old one line by line
for what was cut.

**`settings-app`** is here for a different reason. Settings is a native macOS
window in the shell now (spec §8): it enables and disables apps over the
`appControl` control-plane envelope, so there is no worker left to hold the
switches and the demo app was retired from the strip. It is kept rather than
deleted because it is still the only worked example of the privileged
`ctx.platform.*` surface — `stats`, `enable`, `disable`, `quit`, `permissions`
— which the host still gates to the app id `settings` (`host/src/router.ts`).
It is a reference, not a live app: nothing upgrades it and nothing tests it.
