// Message envelope (spec §2). Every frame in both directions carries one.

export const PROTOCOL_VERSION = 1;

export interface Envelope {
  v: number;
  app: string;
  seq: number;
  type: string;
  payload: Record<string, unknown>;
}

export class EnvelopeError extends Error {}

export function parseEnvelope(value: unknown): Envelope {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new EnvelopeError("envelope must be a JSON object");
  }
  const record = value as Record<string, unknown>;
  const { v, app, seq, type, payload } = record;
  if (typeof v !== "number") throw new EnvelopeError("envelope.v must be a number");
  if (typeof app !== "string") throw new EnvelopeError("envelope.app must be a string");
  if (typeof seq !== "number" || !Number.isInteger(seq) || seq < 1) {
    throw new EnvelopeError("envelope.seq must be a positive integer");
  }
  if (typeof type !== "string" || type.length === 0) {
    throw new EnvelopeError("envelope.type must be a non-empty string");
  }
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    throw new EnvelopeError("envelope.payload must be a JSON object");
  }
  return { v, app, seq, type, payload: payload as Record<string, unknown> };
}

/** Per-(app) inbound seq bookkeeping for one connection generation: stale
 * (`<= last`) seq for a scope is dropped (spec §2). Reconnect makes a new
 * tracker — seq scoping is per generation by construction (spec §1). */
export class SeqTracker {
  private last = new Map<string, number>();

  /** Returns false when the envelope is stale and must be ignored. */
  accept(envelope: Envelope): boolean {
    const previous = this.last.get(envelope.app) ?? 0;
    if (envelope.seq <= previous) {
      return false;
    }
    this.last.set(envelope.app, envelope.seq);
    return true;
  }
}

/** Outbound per-app seq allocation for one connection generation. */
export class SeqAllocator {
  private next = new Map<string, number>();

  allocate(app: string): number {
    const seq = this.next.get(app) ?? 1;
    this.next.set(app, seq + 1);
    return seq;
  }
}

export function makeEnvelope(
  app: string,
  type: string,
  payload: Record<string, unknown>,
  allocator: SeqAllocator,
): Envelope {
  return { v: PROTOCOL_VERSION, app, seq: allocator.allocate(app), type, payload };
}
