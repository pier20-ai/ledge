# Writing Ledge apps

You are editing an app that lives in the macOS notch. A **Ledge app is one
folder**; `app.jsx` is its entry; the folder's name is the app's id. Save the
file and it hot-reloads in about 300 ms — the loop is files, so edit and look.

This file is the orientation: what an app is, what will break one, and how to
see what you built. **[REFERENCE.md](REFERENCE.md) beside it is the API** —
every export, component, prop and `ctx` call, with the tables. Read it when you
need a specific answer; you do not need it to start.

---

## The smallest app

```jsx
/** @jsxImportSource react */
export const meta = { name: "Flights", icon: "sf:airplane" };

export default function App({ status = "—" }) {
  return (
    <stack axis="v" pad={14} gap={8}>
      <text content={status} size="l" weight="bold" />
    </stack>
  );
}
```

That is a complete, working app.

## Five rules that will break your app if you miss them

1. **`/** @jsxImportSource react */` on line 1 of every `.jsx` file.** Without
   it the JSX does not compile.
2. **Never put raw text inside an element.** `<button>Save</button>` is a hard
   error. Text is always `<text content="Save" />`, and buttons take
   `label="Save"`.
3. **Never add `react` to an app's own `node_modules`.** Both your app and the
   renderer must resolve the *same* React instance from the apps root; a second
   copy means every `useState` throws `dispatcher.useState of null`.
4. **`<wing side="left">` only.** The right side of the panel's top row is
   reserved by the shell.
5. **You cannot set the panel's width from JSX.** Ask via `meta.panel`.

## Where things are

| you want | it is in |
|---|---|
| every component and its props | `REFERENCE.md`, "Components" |
| `ctx` — the whole surface | `REFERENCE.md`, "`ctx`" |
| wings, the mini view, peeking | `REFERENCE.md`, "Three sizes of attention" |
| canvas drawing and its ops | `REFERENCE.md`, "Canvas and games" |
| storage, dependencies, splitting a file | `REFERENCE.md`, end |
| a working example of any of it | a sibling app — `ls ..`, then read one |

Two things that are **not** anywhere, and are worth knowing before you look:

- **The shell is not on this machine.** Ledge's Swift source lives in a separate
  repository; searching your home directory for `*.swift` finds nothing, slowly.
  If a prop is not in `REFERENCE.md`, it does not exist.
- **You cannot see the screen.** `screencapture` returns the wallpaper without a
  Screen Recording grant this process does not have. Use `ledge shot` below —
  it renders the app itself, which is better evidence anyway.

## The `ledge` command

```
ledge new <id>       scaffold an app (refuses to overwrite an existing one)
ledge list           installed apps
ledge status         the same, as JSON
ledge reload <id>    touch the entry point; the watcher reloads it
ledge logs <id>      what the app printed, and its last crash if any
ledge shot <id>      render the app's panel to a PNG and print the path
```

## Seeing what you built

You have two ways to check your work, and neither of them is a screenshot of the
screen:

**`ledge logs <id>`** prints what the app printed. `console.log` anywhere in an
app — render, monitor, an event handler — lands in `console.log` in the app's
folder, crash or no crash, with a `--- reloaded ---` marker at each reload so
you can see what happened *after* your change. `-n 200` for more.

**`ledge shot <id>`** renders the app's panel to a PNG through the real
renderer, with no running shell and no screen-recording permission involved, and
prints the path. `--click N` presses the N-th clickable node first, which is how
you see a page you can only reach by pressing something.

Between them: print what you believe, reload, read it back, and look at the
result. `~/.ledge/host.log` is the *host's* log, not yours — it says when your
app started and crashed, and nothing about what it did.

## When something breaks

1. `ledge logs <id>` — what the app printed, then the stack from the last crash.
2. `crash.log` in the app's folder is that same crash on its own.
3. A syntax error never starts a worker; it is reported as a crash with the
   parse error.
4. A crash loop backs off (1 s → 2 min, 5 attempts) and then stops. Fix the
   file and save — a save always restarts it.
