import { describe, expect, test } from "bun:test";
import { InMemorySink, type Mutation } from "../src/render/mutations";
import { mountApp } from "./helpers/react-runtime";

// The Settings reference app (spec §8) rendered in-process against InMemorySink,
// with no worker/host — proof that the §5 component vocabulary and props-driven
// callbacks suffice to build it. The path is a runtime-computed URL so tsc does
// not try to resolve the untyped .jsx module.
const settingsUrl = new URL("../reference/settings/app.jsx", import.meta.url).href;

// Every kind Settings is allowed to use (spec §5). Enable state is a `button`
// (there is no <toggle>), which is the whole point of the exercise.
const ALLOWED_KINDS = new Set(["stack", "text", "image", "button", "spacer"]);

type Create = Extract<Mutation, { op: "create" }>;

describe("settings reference app", () => {
  test("renders app rows + general toggles using only §5 kinds", async () => {
    const mod = await import(settingsUrl);
    const Settings = mod.default as Parameters<typeof mountApp>[0];

    const sink = new InMemorySink();
    const session = mountApp(Settings, sink);
    session.update({
      apps: [
        { id: "stocks", name: "Stocks", icon: "sf:chart.line.uptrend.xyaxis", enabled: true },
        { id: "music", name: "Music", icon: "sf:music.note", enabled: false },
      ],
      general: { launchAtLogin: false, showSeconds: true },
    });

    const creates = sink.all.filter((m): m is Create => m.op === "create");
    const kinds = new Set(creates.map((m) => m.kind));

    // Uses the expected structural kinds…
    for (const kind of ["stack", "text", "image", "button"]) {
      expect(kinds.has(kind)).toBe(true);
    }
    // …and nothing outside the §5 vocabulary.
    for (const kind of kinds) {
      expect(ALLOWED_KINDS.has(kind)).toBe(true);
    }

    // One image per app row, and the enable toggles render their On/Off labels.
    const images = creates.filter((m) => m.kind === "image");
    expect(images.length).toBe(2);
    const buttonLabels = creates
      .filter((m) => m.kind === "button")
      .map((m) => m.props.label);
    expect(buttonLabels).toContain("On");
    expect(buttonLabels).toContain("Off");
  });
});
