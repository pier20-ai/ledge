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
// There is no title row — the shell names the app in the panel's left wing —
// and there is no "General" section: it used to hold "Launch at login" and
// "Throttle monitors on battery", neither of which anything implemented. A
// switch that does nothing is worse than a missing feature, so they are gone
// rather than pending.

import { useState } from "react";

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
      // The shell's, not the host's: only the process with the run loop can end
      // itself, and the host is its child. It resolves just before the process
      // goes, so there is nothing useful to do after the await.
      onQuit: () => {
        ctx.platform.quit().catch((error) => console.log(`could not quit: ${error}`));
      },
      // Chrome, not a call: the shell raises its permission surface or silently
      // does not, and there is no answer worth waiting for.
      onPermissions: () => ctx.permissions(),
    });
  };

  await refresh();
  await Bun.sleep(POLL_MS);
}

function AppRow({ app, onToggle }) {
  // Settings cannot be disabled (spec §8) — it is the only way back from
  // everything else on this panel. The switch is shown, on and dead, rather
  // than hidden: the row should still read as a row.
  const locked = app.id === "settings";
  return (
    <stack axis="h" gap={8} align="center" pad={6}>
      <image src={app.icon} w={16} h={16} radius={4} />
      <text
        content={app.name}
        size="m"
        weight="semibold"
        color={app.enabled ? "primary" : "secondary"}
        truncate
      />
      <text content={app.id} size="xs" weight="medium" color="tertiary" mono />
      <spacer />
      <toggle
        on={app.enabled}
        disabled={locked}
        onChange={(data) => onToggle?.(app.id, data?.on ?? !app.enabled)}
      />
    </stack>
  );
}

/**
 * Quitting, in two presses.
 *
 * Not a modal — §5 has no modal, and quitting is not destructive (apps are
 * files on disk, and the host exits with the shell). But Ledge is
 * `LSUIElement`: no Dock icon, and no menu-bar item since the status menu was
 * removed, so an accidental quit costs the user a trip to Finder to get their
 * notch back. Arming in place is the cheapest thing that makes that impossible
 * to do by accident, and it costs one deliberate press when you meant it.
 *
 * It lives OUTSIDE the scroller on purpose: with enough apps installed, a
 * footer inside the list would be a quit you have to go looking for, and this
 * is the only one there is.
 */
function QuitRow({ onQuit, onPermissions }) {
  const [armed, setArmed] = useState(false);
  if (!armed) {
    return (
      <stack axis="h" gap={8} align="center" pad={12}>
        <text content="Quit Ledge" size="m" weight="semibold" />
        <spacer />
        {/* The way back to the permission surface. It sits here rather than in
            the list because it is about Ledge, not about any app — and because
            with the menu bar gone this panel is the only door left. */}
        <button label="Permissions…" variant="plain" onClick={() => onPermissions?.()} />
        <button label="Quit" variant="glass" onClick={() => setArmed(true)} />
      </stack>
    );
  }
  return (
    <stack axis="h" gap={8} align="center" pad={12} fill="redTint" radius={8}>
      <text content="Quit Ledge?" size="m" weight="semibold" />
      <spacer />
      <button label="Cancel" variant="plain" onClick={() => setArmed(false)} />
      <button label="Quit" variant="accent" onClick={() => onQuit?.()} />
    </stack>
  );
}

export default function Settings({ apps = [], ready = false, onToggle, onQuit, onPermissions }) {
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

      {/* Padding inside the scroller, not on the root: a scroller's ceiling is
          the panel's whole content height, and every point spent above it is a
          point the list asks for and cannot have (see stocks). */}
      <stack axis="v" scroll pad={12} gap={0}>
        {apps.length === 0 ? (
          <text
            content={ready ? "No apps installed." : "Reading the catalog…"}
            size="s"
            color="secondary"
          />
        ) : (
          apps.flatMap((app, index) => [
            index === 0 ? null : <divider key={`rule-${app.id}`} />,
            <AppRow key={app.id} app={app} onToggle={onToggle} />,
          ])
        )}
      </stack>

      <divider />
      <QuitRow onQuit={onQuit} onPermissions={onPermissions} />
    </stack>
  );
}
