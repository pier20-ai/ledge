/** @jsxImportSource react */
// Settings — the *mockup* Settings panel, rendered inert so the demo catalog has
// the same five surfaces the design does. This is a picture, not the product:
// the real Settings app is host/reference/settings/app.jsx, which drives
// ctx.platform for enable/disable/reorder and is untouched by this file.
//
// The rows are static: the permission pills and the enable switches show state
// nobody here owns. The switches are the real §5 `toggle` (D6 "New kinds"), just
// with a fixed `on` and no handler — this panel is a picture of a settled state,
// and a toggle that flipped without changing anything would be a lie.
//
// There is no title row. The shell names the app in the panel's left wing, and
// the row that used to say "Settings · 4 workers · 38 MB" put the interesting
// half of that sentence directly under the camera housing.

export const meta = { name: "Settings", icon: "sf:slider.horizontal.3" };

const APPS = [
  { name: "Stocks", file: "stocks.jsx", pills: [{ label: "NET", granted: false }] },
  { name: "Music", file: "music.jsx", pills: [{ label: "APPLESCRIPT ✓", granted: true }] },
  {
    name: "Deal Watch",
    file: "deals.jsx",
    pills: [
      { label: "NET", granted: false },
      { label: "NOTIFY ✓", granted: true },
    ],
  },
];

const GENERAL = ["Launch at login", "Throttle monitors on battery"];

function Pill({ pill }) {
  return (
    <stack pad={5} radius={4} fill={pill.granted ? "greenTint" : "raisedHover"}>
      <text
        content={pill.label}
        size="xs"
        weight="semibold"
        color={pill.granted ? "green" : "secondary"}
        mono
      />
    </stack>
  );
}

export default function Settings() {
  return (
    <stack axis="v" pad={16} gap={10}>
      {/* The panel wing (spec §5): the zone left of the hardware cutout. The old
          title row said "Settings" — which the shell already puts there — and put
          the worker count dead centre, i.e. under the camera. Both problems have
          the same fix: hand the zone the one thing worth saying and delete the
          row. */}
      <wing side="left">
        {/* Not `mono`: the zone is ~95 pt on a 440 pt panel, and full monospace
            would truncate a line that fits proportionally. Nothing is lost —
            the renderer's default face already uses monospaced *digits*, so the
            counts still don't jitter as they tick (D3). */}
        <text content="4 workers · 38 MB" size="xs" weight="medium" color="secondary" />
      </wing>

      <text content="APPS" size="xs" weight="semibold" color="secondary" mono />
      {APPS.map((app) => (
        <stack key={app.file} axis="h" gap={8}>
          <text content={app.name} size="m" weight="semibold" />
          <text content={app.file} size="xs" weight="medium" color="secondary" mono />
          {app.pills.map((pill) => (
            <Pill key={pill.label} pill={pill} />
          ))}
          <spacer />
          <toggle on />
        </stack>
      ))}

      <text content="GENERAL" size="xs" weight="semibold" color="secondary" mono />
      {GENERAL.map((label) => (
        <stack key={label} axis="h" gap={8}>
          <text content={label} size="m" weight="semibold" />
          <spacer />
          <toggle on />
        </stack>
      ))}
    </stack>
  );
}
