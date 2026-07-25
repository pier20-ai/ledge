/** @jsxImportSource react */
// Crash fixture: the monitor throws, so the entry reports a `crash` message
// (phase "monitor") and the loop stops (spec §6 rule 2 / §7).
export async function monitor() {
  throw new Error("kaboom");
}

export default function Crasher() {
  return <text content="crash" />;
}
