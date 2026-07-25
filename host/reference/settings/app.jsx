/** @jsxImportSource react */
// Settings — the reference app (spec §8). Written against the exact same worker
// + component API as user apps; it differs only in that the host can't disable
// it and boots its worker `privileged`, granting `ctx.platform` (enable/disable/
// reorder/stats). The protocol needs no special case for it — this file is the
// proof the component vocabulary (spec §5) and the four-bridge ctx suffice.
//
// It imports nothing from Ledge: JSX is transpiled by Bun's default automatic
// runtime (the pragma on line 1 pins the React runtime regardless of the
// surrounding tsconfig), and ctx arrives as the monitor's argument. There
// is no <toggle>/<switch> in §5, so enable state is rendered as a `button`
// whose label/variant reflect it — the whole point is to show the small
// vocabulary is enough. Action callbacks reach the UI as props (the component
// never sees ctx directly), supplied by the monitor via ctx.update.

export const meta = { name: "Settings", icon: "sf:gearshape" };

const DEFAULT_GENERAL = { launchAtLogin: false, showSeconds: true };

function reorderById(apps, id, delta) {
  const ids = apps.map((app) => app.id);
  const from = ids.indexOf(id);
  const to = from + delta;
  if (from < 0 || to < 0 || to >= ids.length) return ids;
  ids.splice(to, 0, ids.splice(from, 1)[0]);
  return ids;
}

// Invoked by the host in the sequential monitor loop (spec §6). Pulls the live
// catalog + worker stats over the privileged bridge and republishes them — plus
// the action callbacks — as props. Re-reading after each mutation keeps the UI
// a pure function of host truth (spec: the host owns durable truth).
export async function monitor(ctx) {
  const refresh = async () => {
    const stats = await ctx.platform.stats();
    const apps = stats?.apps ?? [];
    const general = { ...DEFAULT_GENERAL, ...(stats?.general ?? {}) };

    ctx.update({
      apps,
      general,
      onToggleApp: (app) => {
        const change = app.enabled ? ctx.platform.disable(app.id) : ctx.platform.enable(app.id);
        change.then(refresh);
      },
      onMoveUp: (app) => ctx.platform.reorder(reorderById(apps, app.id, -1)).then(refresh),
      onMoveDown: (app) => ctx.platform.reorder(reorderById(apps, app.id, +1)).then(refresh),
      onToggleGeneral: (key, value) => ctx.update({ general: { ...general, [key]: value } }),
    });
  };

  await refresh();
  // Settings state changes are user-driven (buttons), not polled; idle between
  // passes so the spin floor doesn't busy-loop.
  await new Promise((resolve) => setTimeout(resolve, 3000));
}

function AppRow({ app, onToggleApp, onMoveUp, onMoveDown }) {
  return (
    <stack axis="h" gap={8} align="center">
      <image src={app.icon} w={18} h={18} radius={4} />
      <text content={app.name} color={app.enabled ? "primary" : "secondary"} truncate />
      <spacer min={8} />
      <button label="↑" variant="plain" onClick={() => onMoveUp?.(app)} />
      <button label="↓" variant="plain" onClick={() => onMoveDown?.(app)} />
      <button
        label={app.enabled ? "On" : "Off"}
        variant={app.enabled ? "accent" : "glass"}
        onClick={() => onToggleApp?.(app)}
      />
    </stack>
  );
}

function GeneralRow({ label, value, onClick }) {
  return (
    <stack axis="h" gap={8} align="center">
      <text content={label} />
      <spacer min={8} />
      <button label={value ? "On" : "Off"} variant={value ? "accent" : "glass"} onClick={onClick} />
    </stack>
  );
}

export default function Settings({
  apps = [],
  general = DEFAULT_GENERAL,
  onToggleApp,
  onMoveUp,
  onMoveDown,
  onToggleGeneral,
}) {
  return (
    <stack axis="v" pad={14} gap={10}>
      <text content="Settings" size="xl" weight="bold" />

      <text content="Apps" size="s" weight="semibold" color="secondary" />
      <stack axis="v" gap={6}>
        {apps.map((app) => (
          <AppRow
            key={app.id}
            app={app}
            onToggleApp={onToggleApp}
            onMoveUp={onMoveUp}
            onMoveDown={onMoveDown}
          />
        ))}
      </stack>

      <text content="General" size="s" weight="semibold" color="secondary" />
      <stack axis="v" gap={6}>
        <GeneralRow
          label="Launch at login"
          value={general.launchAtLogin}
          onClick={() => onToggleGeneral?.("launchAtLogin", !general.launchAtLogin)}
        />
        <GeneralRow
          label="Show seconds"
          value={general.showSeconds}
          onClick={() => onToggleGeneral?.("showSeconds", !general.showSeconds)}
        />
      </stack>
    </stack>
  );
}
