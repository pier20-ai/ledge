/** @jsxImportSource react */
// Settings — the one app the host boots privileged (spec §8), and the only one
// that can turn other apps off.
//
// It is an ordinary Ledge app in every other respect: same worker, same
// component vocabulary (§5), same monitor→props bridge. The privilege is two
// extra calls on `ctx.platform` — `stats()` to read the host's catalog, and
// `enable`/`disable` to change it — and both are answered by the HOST rather
// than forwarded to the shell, because enabling an app means starting a worker
// and re-publishing the catalog, which is host state end to end.
//
// The rows are a pure function of what the host just said. Nothing here keeps
// its own copy of "is this app on": the switch reports what it is moving to, we
// ask the host to move, and the next `stats()` is what actually flips the
// picture. A toggle that flipped locally and then had to un-flip when the host
// disagreed would be lying for as long as it took to find out.
//
// Laws: 1 (hairlines and rows; nothing filled anywhere on this panel) · 2 (the
// shell owns chrome — no title row, because the shell names the app in the
// panel's left wing, and no Quit, because quitting is the shell's context menu
// and always was) · 4 (a name and a switch; the loading state is one quiet
// line) · 5 (the row *is* the control — the switch is the datum, and Permissions
// is a row you press, not a row with a button parked in it).
//
// Diet, against the pre-reset panel (G3.2):
//   CUT   the filled "Quit" capsule and its armed red confirmation · the whole
//         "Quit Ledge" footer row · the "Permissions…" text button · the
//         `ctx.platform.quit()` call site · the monospaced app id beside every
//         name (UI *about* the datum, and the name already is the datum).
//   KEPT  the privileged plumbing, `ctx.permissions()`, the `<wing side="left">`
//         exercise, and the rule that Settings cannot switch itself off.
//
// Quit lives in the right-click menu on Ledge's glass (`NotchPanelController`'s
// `glassMenu`, flow.md). One way out, drawn by the shell, on every surface —
// which is exactly why an app-drawn second one had to go: two Quits is two
// answers to one question, and the app's was the one that could be scrolled
// past.

export const meta = { name: "Settings", icon: "sf:slider.horizontal.3" };

/** How long between catalog reads. The only writer of this state is this app,
 * so the poll is not how a toggle takes effect (that is the refresh below) —
 * it is how an app scaffolded by the builder, or a folder deleted in Finder,
 * shows up here without a relaunch. */
const POLL_MS = 2_000;

export async function monitor(ctx) {
  // Re-read after every change rather than patching the array we already have:
  // the host owns durable truth, and "what the host says now" is the only
  // version of this list that can be wrong in exactly one place.
  const refresh = async () => {
    const stats = await ctx.platform.stats();
    const apps = stats?.apps ?? [];
    ctx.update({
      apps,
      ready: true,
      onToggle: (id, on) => {
        const change = on ? ctx.platform.enable(id) : ctx.platform.disable(id);
        // A refused change (Settings asked to disable itself, an app deleted
        // since the last poll) still refreshes: AppKit has already moved the
        // switch, and the next snapshot is what puts it back. Handled here and
        // not thrown, because a rejection escaping an event handler is not the
        // monitor's crash to take (spec §6 rule 2).
        change
          .catch((error) => console.log(`could not ${on ? "enable" : "disable"} ${id}: ${error}`))
          .then(refresh)
          .catch((error) => console.log(`could not re-read the catalog: ${error}`));
      },
      // Chrome, not a call: the shell raises its permission surface or silently
      // does not, and there is no answer worth waiting for.
      onPermissions: () => ctx.permissions(),
    });
  };

  await refresh();
  await Bun.sleep(POLL_MS);
}

/** A row: a glyph, a name, and the platform switch. Full-bleed — the padding is
 * the row's own, so the `<divider />` between two of them runs the whole width
 * of the panel instead of stopping short of it. */
function AppRow({ app, onToggle }) {
  // Settings cannot be disabled (spec §8) — it is the only way back from
  // everything else on this panel. The switch is shown, on and dead, rather
  // than hidden: the row should still read as a row.
  const locked = app.id === "settings";
  return (
    <stack axis="h" gap={10} align="center" pad={10}>
      <image src={app.icon} w={16} h={16} radius={4} />
      <text
        content={app.name}
        size="m"
        weight="semibold"
        color={app.enabled ? "primary" : "secondary"}
        truncate
      />
      <spacer />
      <toggle
        on={app.enabled}
        disabled={locked}
        onChange={(data) => onToggle?.(app.id, data?.on ?? !app.enabled)}
      />
    </stack>
  );
}

export default function Settings({ apps = [], ready = false, onToggle, onPermissions }) {
  const on = apps.filter((app) => app.enabled).length;
  return (
    <stack axis="v">
      {/* The panel wing (spec §5): the zone left of the hardware cutout. The
          count belongs here and not in a title row, whose middle is the camera
          housing. */}
      <wing side="left">
        <text
          content={ready ? `${on} of ${apps.length} on` : "reading…"}
          size="xs"
          weight="medium"
          color="secondary"
        />
      </wing>

      {/* No padding on the scroller and none on the root: the rows carry their
          own, so every hairline is full-bleed — and a scroller's ceiling is the
          panel's whole content height, so a point spent above it is a point the
          list asks for and cannot have (see stocks). */}
      <stack axis="v" scroll gap={0}>
        {apps.length === 0 ? (
          // One quiet line, indented to the rows' own inset so the empty state
          // stands where the first row would.
          <stack axis="h" pad={10}>
            <text content={ready ? "No apps installed" : "Reading…"} size="s" color="secondary" />
          </stack>
        ) : (
          apps.flatMap((app, index) => [
            index === 0 ? null : <divider key={`rule-${app.id}`} />,
            <AppRow key={app.id} app={app} onToggle={onToggle} />,
          ])
        )}
      </stack>

      {/* Permissions is about Ledge, not about any app, so it is not in the
          list — and it is pinned below the scroller rather than sitting at the
          bottom of it, because with enough apps installed a door you have to
          scroll to find is a door most people never open.

          The whole row is the press target (REFERENCE.md, "a row is a button
          with a child"): a chevron parked at the end of a row that is not
          itself pressable makes the other 90% of it a dead zone. */}
      <divider />
      <button variant="plain" onClick={() => onPermissions?.()}>
        <stack axis="h" gap={10} align="center" pad={10}>
          <image src="sf:hand.raised" w={16} h={16} />
          <text content="Permissions" size="m" weight="semibold" />
          <spacer />
          <text content="›" size="m" color="tertiary" />
        </stack>
      </button>
    </stack>
  );
}
