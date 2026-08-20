// Prop wire preparation (spec §5): event-handler props (`onClick`, …)
// serialize as `true`; the reconciler keeps the function keyed by (id, name).
// Updates are partial — only changed keys; `null` deletes a key.

import type { Props } from "./mutations";

export const HANDLER_PROPS = new Set([
  "onClick",
  "onChange",
  "onSubmit",
  "onHover",
  "onKey",
  // `canvas` press-drag-release (spec §4.1 `drag`): the handler receives
  // `{ phase, x, y }`, with `move` already throttled shell-side.
  "onDrag",
]);

/** click ← onClick etc. — the wire event name for a handler prop. */
export function eventName(handlerProp: string): string {
  return handlerProp.slice(2).toLowerCase();
}

export type HandlerKey = `${number}:${string}`;

export class HandlerRegistry {
  private handlers = new Map<HandlerKey, (data: Record<string, unknown>) => void>();

  set(id: number, name: string, handler: unknown): void {
    const key: HandlerKey = `${id}:${name}`;
    if (typeof handler === "function") {
      this.handlers.set(key, handler as (data: Record<string, unknown>) => void);
    } else {
      this.handlers.delete(key);
    }
  }

  /** Drop every handler for an instance (on remove). */
  removeInstance(id: number): void {
    for (const key of this.handlers.keys()) {
      if (key.startsWith(`${id}:`)) this.handlers.delete(key);
    }
  }

  /** Returns false for an unknown (id, name) — stale after reload, dropped
   * silently per spec §4.1. */
  dispatch(id: number, name: string, data: Record<string, unknown>): boolean {
    const handler = this.handlers.get(`${id}:${name}`);
    if (!handler) return false;
    handler(data);
    return true;
  }
}

/** Serializes initial props for the wire, registering handlers. `children`
 * never crosses the wire — the tree does. */
export function serializeProps(
  id: number,
  props: Props,
  registry: HandlerRegistry,
): Props {
  const wire: Props = {};
  for (const [key, value] of Object.entries(props)) {
    if (key === "children") continue;
    if (HANDLER_PROPS.has(key)) {
      registry.set(id, eventName(key), value);
      if (typeof value === "function") wire[key] = true;
      continue;
    }
    if (value !== undefined) wire[key] = value;
  }
  return wire;
}

/** Partial diff for updates: only changed keys; removed keys become null.
 * Returns null when nothing changed. Handler identity changes re-register
 * without touching the wire (the wire value stays `true`). */
export function diffProps(
  id: number,
  previous: Props,
  next: Props,
  registry: HandlerRegistry,
): Props | null {
  const patch: Props = {};
  let changed = false;

  for (const [key, value] of Object.entries(next)) {
    if (key === "children") continue;
    if (HANDLER_PROPS.has(key)) {
      registry.set(id, eventName(key), value);
      const was = typeof previous[key] === "function";
      const is = typeof value === "function";
      if (was !== is) {
        patch[key] = is ? true : null;
        changed = true;
      }
      continue;
    }
    if (!deepEqual(previous[key], value)) {
      patch[key] = value === undefined ? null : value;
      changed = true;
    }
  }

  for (const key of Object.keys(previous)) {
    if (key === "children" || key in next) continue;
    if (HANDLER_PROPS.has(key)) {
      registry.set(id, eventName(key), undefined);
      patch[key] = null;
      changed = true;
      continue;
    }
    patch[key] = null;
    changed = true;
  }

  return changed ? patch : null;
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) {
    return false;
  }
  return JSON.stringify(a) === JSON.stringify(b);
}
