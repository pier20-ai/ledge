import { describe, expect, test } from "bun:test";
import { useState } from "react";
import { InMemorySink, type Mutation } from "../src/render/mutations";
import { createLedgeRenderer } from "../src/render/reconciler";
import { createAppSession } from "../src/render/session";

function ops(mutations: Mutation[]): string[] {
  return mutations.map((m) => m.op);
}

type Create = Extract<Mutation, { op: "create" }>;
type Update = Extract<Mutation, { op: "update" }>;

function created(sink: InMemorySink, kind: string): Create {
  const create = sink.all.find((m) => m.op === "create" && m.kind === kind);
  if (!create) throw new Error(`no create for kind ${kind}`);
  return create as Create;
}

/** The single update of the most recent commit — asserts the in-place path:
 * one update, no create/remove churn. */
function soleUpdate(sink: InMemorySink): Update {
  const last = sink.commits.at(-1)!;
  expect(ops(last)).toEqual(["update"]);
  return last[0] as Update;
}

describe("mount", () => {
  test("first commit creates children before parents attach, then sets root", () => {
    const sink = new InMemorySink();
    const renderer = createLedgeRenderer(sink);
    renderer.render(
      <stack axis="v" pad={14} gap={8}>
        <text content="AAPL" color="secondary" />
        <text content="$214.62" size="xl" weight="bold" mono />
        <chart points={[0.2, 0.4, 1]} color="green" fill />
      </stack>,
    );

    expect(sink.commits).toHaveLength(1);
    const batch = sink.commits[0]!;

    // Every create precedes the insert that references it; setRoot is last.
    const created = new Set<number>();
    for (const mutation of batch) {
      if (mutation.op === "create") created.add(mutation.id);
      if (mutation.op === "insert") {
        expect(created.has(mutation.id)).toBe(true);
        expect(created.has(mutation.parent)).toBe(true);
      }
    }
    expect(batch.at(-1)!.op).toBe("setRoot");

    const kinds = batch
      .filter((m): m is Extract<Mutation, { op: "create" }> => m.op === "create")
      .map((m) => m.kind)
      .sort();
    expect(kinds).toEqual(["chart", "stack", "text", "text"]);
  });

  test("raw text children are a hard error pointing at <text>", () => {
    const renderer = createLedgeRenderer(new InMemorySink());
    expect(() => renderer.render(<stack>oops</stack>)).toThrow(/use <text/);
  });

  test("ids are never reused across a session", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ n = 0 }) => (
        <stack>
          <text content={`v${n}`} key={n as number} />
        </stack>
      ),
      sink,
    );
    session.update({ n: 1 });
    session.update({ n: 2 });
    const createdIds = sink.all
      .filter((m) => m.op === "create")
      .map((m) => (m as Extract<Mutation, { op: "create" }>).id);
    expect(new Set(createdIds).size).toBe(createdIds.length);
  });
});

describe("updates", () => {
  test("prop changes emit partial updates only", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ price = "—", up = false }) => (
        <stack>
          <text content={String(price)} color={up ? "green" : "primary"} />
          <text content="static" />
        </stack>
      ),
      sink,
    );

    session.update({ price: "$215.10", up: true });

    const last = sink.commits.at(-1)!;
    expect(ops(last)).toEqual(["update"]);
    const update = last[0] as Extract<Mutation, { op: "update" }>;
    expect(update.props).toEqual({ content: "$215.10", color: "green" });
  });

  test("a dropped prop is deleted with null", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ dim = true }) =>
        dim ? <text content="x" color="secondary" /> : <text content="x" />,
      sink,
    );
    session.update({ dim: false });
    const update = sink.commits.at(-1)![0] as Extract<Mutation, { op: "update" }>;
    expect(update.props).toEqual({ color: null });
  });

  test("no-op re-render emits no commit", () => {
    const sink = new InMemorySink();
    const session = createAppSession(() => <text content="fixed" />, sink);
    const commitsBefore = sink.commits.length;
    session.update({});
    expect(sink.commits.length).toBe(commitsBefore);
  });

  test("conditional children produce insert/remove", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ alert = false }) => (
        <stack>
          <text content="always" />
          {alert ? <text content="ping!" color="accent" /> : null}
        </stack>
      ),
      sink,
    );

    session.update({ alert: true });
    expect(ops(sink.commits.at(-1)!)).toEqual(["create", "insert"]);

    session.update({ alert: false });
    expect(ops(sink.commits.at(-1)!)).toEqual(["remove"]);
  });
});

describe("events", () => {
  test("handler props serialize as true and dispatch by (id, name)", () => {
    const sink = new InMemorySink();
    const clicks: string[] = [];
    const renderer = createLedgeRenderer(sink);
    renderer.render(
      <stack>
        <button label="Refresh" variant="glass" onClick={() => clicks.push("hit")} />
      </stack>,
    );

    const create = sink.all.find(
      (m) => m.op === "create" && m.kind === "button",
    ) as Extract<Mutation, { op: "create" }>;
    expect(create.props.onClick).toBe(true);
    expect(typeof create.props.onClick).toBe("boolean");

    expect(renderer.dispatchEvent(create.id, "click")).toBe(true);
    expect(clicks).toEqual(["hit"]);
    expect(renderer.dispatchEvent(999, "click")).toBe(false);
  });

  test("state set inside a handler re-renders synchronously with a partial update", () => {
    const sink = new InMemorySink();
    const renderer = createLedgeRenderer(sink);

    function Counter() {
      const [count, setCount] = useState(0);
      return (
        <stack>
          <text content={`count ${count}`} />
          <button label="+" onClick={() => setCount((c) => c + 1)} />
        </stack>
      );
    }
    renderer.render(<Counter />);

    const button = sink.all.find(
      (m) => m.op === "create" && m.kind === "button",
    ) as Extract<Mutation, { op: "create" }>;
    renderer.dispatchEvent(button.id, "click");

    const last = sink.commits.at(-1)!;
    expect(ops(last)).toEqual(["update"]);
    expect((last[0] as Extract<Mutation, { op: "update" }>).props).toEqual({
      content: "count 1",
    });
  });

  test("handler identity swap re-registers without a wire update", () => {
    const sink = new InMemorySink();
    const seen: string[] = [];
    const session = createAppSession(
      ({ label = "a" }) => (
        <button label="b" onClick={() => seen.push(String(label))} />
      ),
      sink,
    );
    const button = sink.all.find(
      (m) => m.op === "create" && m.kind === "button",
    ) as Extract<Mutation, { op: "create" }>;

    session.update({ label: "z" });
    // The commit for that update must not mention onClick…
    for (const mutation of sink.commits.at(-1)!) {
      if (mutation.op === "update") {
        expect("onClick" in mutation.props).toBe(false);
      }
    }
    // …but dispatch reaches the NEW closure.
    session.dispatchEvent(button.id, "click");
    expect(seen).toEqual(["z"]);
  });

  test("removing an instance drops its handlers", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ show = true }) =>
        show ? <button label="x" onClick={() => {}} /> : <text content="gone" />,
      sink,
    );
    const button = sink.all.find(
      (m) => m.op === "create" && m.kind === "button",
    ) as Extract<Mutation, { op: "create" }>;

    session.update({ show: false });
    expect(session.dispatchEvent(button.id, "click")).toBe(false);
  });
});

// The six kinds ratified in design D6 "New kinds". The reconciler is generic, so
// what these prove is that the *vocabulary* is reachable from JSX and that each
// kind updates in place — a kind that silently remounted would look identical in
// a mount-only test and destroy toggle state on every render.
describe("new kinds (D6)", () => {
  test("toggle creates with on/disabled and serializes onChange as true", () => {
    const sink = new InMemorySink();
    const changes: boolean[] = [];
    const renderer = createLedgeRenderer(sink);
    renderer.render(
      <stack>
        <toggle on={true} onChange={({ on }) => changes.push(on)} />
        <toggle on={false} disabled />
      </stack>,
    );

    const toggles = sink.all.filter(
      (m): m is Create => m.op === "create" && m.kind === "toggle",
    );
    expect(toggles).toHaveLength(2);
    expect(toggles[0]!.props).toEqual({ on: true, onChange: true });
    expect(toggles[1]!.props).toEqual({ on: false, disabled: true });

    // "change" — the wire name eventName() derives from onChange.
    expect(renderer.dispatchEvent(toggles[0]!.id, "change", { on: false })).toBe(true);
    expect(changes).toEqual([false]);
  });

  test("toggle flips in place", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ on = false }) => <toggle on={on as boolean} onChange={() => {}} />,
      sink,
    );
    session.update({ on: true });
    expect(soleUpdate(sink).props).toEqual({ on: true });
  });

  test("segment carries its options array and reports the chosen id", () => {
    const sink = new InMemorySink();
    const picked: string[] = [];
    const options = [
      { id: "1d", label: "1D" },
      { id: "1w", label: "1W" },
      { id: "1m", label: "1M" },
    ];
    const session = createAppSession(
      ({ range = "1w" }) => (
        <segment
          options={options}
          value={range as string}
          onChange={({ value }) => picked.push(value)}
        />
      ),
      sink,
    );

    const create = created(sink, "segment");
    expect(create.props).toEqual({ options, value: "1w", onChange: true });

    session.dispatchEvent(create.id, "change", { value: "1m" });
    expect(picked).toEqual(["1m"]);

    // The selection moves without the (unchanged) options array riding along.
    session.update({ range: "1m" });
    expect(soleUpdate(sink).props).toEqual({ value: "1m" });
  });

  test("stepper carries min/max/step and an app-formatted display string", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ minutes = 450 }) => (
        <stepper
          value={minutes as number}
          min={0}
          max={1439}
          step={5}
          format={`0${Math.floor((minutes as number) / 60)}:${(minutes as number) % 60}`}
          onChange={() => {}}
        />
      ),
      sink,
    );

    expect(created(sink, "stepper").props).toEqual({
      value: 450,
      min: 0,
      max: 1439,
      step: 5,
      format: "07:30",
      onChange: true,
    });

    session.update({ minutes: 465 });
    expect(soleUpdate(sink).props).toEqual({ value: 465, format: "07:45" });
  });

  test("progress is value-only — no handler crosses the wire", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ done = 0.64 }) => <progress value={done as number} />,
      sink,
    );
    expect(created(sink, "progress").props).toEqual({ value: 0.64 });
    session.update({ done: 0.2 });
    expect(soleUpdate(sink).props).toEqual({ value: 0.2 });
  });

  test("spinner creates with empty props and survives its parent's updates", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ pad = 12 }) => (
        <stack pad={pad as number}>
          <spinner />
        </stack>
      ),
      sink,
    );
    const spinner = created(sink, "spinner");
    expect(spinner.props).toEqual({});

    session.update({ pad: 16 });
    const update = soleUpdate(sink);
    expect(update.id).not.toBe(spinner.id);
    expect(update.props).toEqual({ pad: 16 });
  });

  test("pill updates label and tone together", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ live = false }) => (
        <pill label={live ? "LIVE" : "PAPER"} tone={live ? "green" : "accent"} />
      ),
      sink,
    );
    expect(created(sink, "pill").props).toEqual({ label: "PAPER", tone: "accent" });
    session.update({ live: true });
    expect(soleUpdate(sink).props).toEqual({ label: "LIVE", tone: "green" });
  });

  test("a tone dropped entirely deletes the key rather than guessing neutral", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ toned = true }) =>
        toned ? <pill label="DRAFT" tone="violet" /> : <pill label="DRAFT" />,
      sink,
    );
    session.update({ toned: false });
    expect(soleUpdate(sink).props).toEqual({ tone: null });
  });

  test("all six new kinds mount in one tree", () => {
    const sink = new InMemorySink();
    createLedgeRenderer(sink).render(
      <stack axis="v" gap={8} pad={12} scroll>
        <toggle on={true} />
        <segment options={[{ id: "a", label: "A" }]} value="a" />
        <stepper value={7} />
        <progress value={0.5} />
        <spinner />
        <pill label="PAPER" />
      </stack>,
    );
    const kinds = sink.all
      .filter((m): m is Create => m.op === "create")
      .map((m) => m.kind);
    expect(kinds).toEqual([
      "toggle",
      "segment",
      "stepper",
      "progress",
      "spinner",
      "pill",
      "stack",
    ]);
  });
});

// New props on kinds that already existed (design D8/Q4, L7, slider fix). These
// ride the ordinary partial-update path — the point of the wave is that no
// envelope or reconciler change was needed for any of them.
describe("control props (D8)", () => {
  test("button size and disabled create and update in place", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ stale = true }) => (
        <button
          label="Execute"
          variant="accent"
          size={stale ? "s" : "l"}
          disabled={stale ? true : undefined}
          onClick={() => {}}
        />
      ),
      sink,
    );

    expect(created(sink, "button").props).toEqual({
      label: "Execute",
      variant: "accent",
      size: "s",
      disabled: true,
      onClick: true,
    });

    session.update({ stale: false });
    // `disabled` gone ⇒ null (delete), not `false`; size swaps in place.
    expect(soleUpdate(sink).props).toEqual({ size: "l", disabled: null });
  });

  test("a button with no size omits the key — the shell's default is m", () => {
    const sink = new InMemorySink();
    createLedgeRenderer(sink).render(<button label="Medium" variant="glass" />);
    expect("size" in created(sink, "button").props).toBe(false);
  });

  test("slider min/max/step ride the wire and value moves alone", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ bpm = 90 }) => (
        <slider value={bpm as number} min={60} max={200} step={5} onChange={() => {}} />
      ),
      sink,
    );
    expect(created(sink, "slider").props).toEqual({
      value: 90,
      min: 60,
      max: 200,
      step: 5,
      onChange: true,
    });

    session.update({ bpm: 145 });
    expect(soleUpdate(sink).props).toEqual({ value: 145 });
  });

  test("text maxLines and truncate=false create and update", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ expanded = true }) => (
        <stack>
          <text content="a long clinical note" maxLines={expanded ? 3 : 1} />
          <text content="clipped" size="s" truncate={expanded ? false : true} />
        </stack>
      ),
      sink,
    );

    const texts = sink.all.filter(
      (m): m is Create => m.op === "create" && m.kind === "text",
    );
    expect(texts[0]!.props).toEqual({ content: "a long clinical note", maxLines: 3 });
    expect(texts[1]!.props).toEqual({ content: "clipped", size: "s", truncate: false });

    session.update({ expanded: false });
    const last = sink.commits.at(-1)!;
    expect(ops(last)).toEqual(["update", "update"]);
    expect((last[0] as Update).props).toEqual({ maxLines: 1 });
    expect((last[1] as Update).props).toEqual({ truncate: true });
  });

  test("stack scroll is an ordinary boolean prop, toggled in place", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ long = false }) => (
        <stack axis="v" scroll={long ? true : undefined}>
          <text content="row" />
        </stack>
      ),
      sink,
    );
    expect("scroll" in created(sink, "stack").props).toBe(false);
    session.update({ long: true });
    expect(soleUpdate(sink).props).toEqual({ scroll: true });
  });

  test("`wing` is an ordinary attachable kind with a `side` prop (§5 panel wings)", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ status = "starting…" }) => (
        <stack axis="v" pad={14}>
          <wing side="left">
            <text content="●" size="xs" color="green" />
            <text content={String(status)} size="s" weight="semibold" />
          </wing>
          <text content="body" />
        </stack>
      ),
      sink,
    );

    const wing = created(sink, "wing");
    expect(wing.props).toEqual({ side: "left" });

    // The reconciler treats it like any other container: its children attach to
    // it, and it attaches to the root. Where the *view* goes is the shell's
    // business — nothing about the wire says "chrome".
    const batch = sink.commits[0]!;
    const inserts = batch.filter((m) => m.op === "insert") as Extract<
      Mutation,
      { op: "insert" }
    >[];
    const root = batch.find((m) => m.op === "setRoot") as Extract<Mutation, { op: "setRoot" }>;
    expect(inserts.filter((m) => m.parent === wing.id)).toHaveLength(2);
    expect(inserts.some((m) => m.id === wing.id && m.parent === root.id)).toBe(true);

    // Wing children update in place like everything else.
    session.update({ status: "live" });
    expect(soleUpdate(sink).props).toEqual({ content: "live" });
  });

  test("`rate` on slider and progress is an ordinary number prop (§5)", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ playing = true }) => (
        <stack axis="v">
          <slider value={64} min={0} max={224} rate={playing ? 1 : 0} />
          <progress value={0.2} />
        </stack>
      ),
      sink,
    );
    expect(created(sink, "slider").props).toEqual({
      value: 64,
      min: 0,
      max: 224,
      rate: 1,
    });
    // A control that never mentions `rate` is on the wire exactly as it was
    // before the prop existed — which is what "additive" has to mean.
    expect("rate" in created(sink, "progress").props).toBe(false);

    // Pausing is a partial update on the same node, not a remount.
    session.update({ playing: false });
    expect(soleUpdate(sink).props).toEqual({ rate: 0 });
  });
});

describe("session", () => {
  test("update() shallow-merges props across calls", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ a = "-", b = "-" }) => <text content={`${a}/${b}`} />,
      sink,
    );
    session.update({ a: "1" });
    session.update({ b: "2" });
    expect(session.props).toEqual({ a: "1", b: "2" });
    const update = sink.commits.at(-1)![0] as Extract<Mutation, { op: "update" }>;
    expect(update.props).toEqual({ content: "1/2" });
  });

  test("unmount removes the root", () => {
    const sink = new InMemorySink();
    const session = createAppSession(() => <text content="bye" />, sink);
    session.unmount();
    expect(ops(sink.commits.at(-1)!)).toContain("remove");
  });
});
