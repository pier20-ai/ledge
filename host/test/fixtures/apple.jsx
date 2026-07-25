/** @jsxImportSource react */
// Apple-bridge fixture: the monitor awaits ctx.apple.script (resolved by a host
// `reply`), then folds the result into props via ctx.update — proving the
// request/reply Promise round-trips across the worker boundary. After that it
// parks; the test terminates the worker (spec §6 rule 3).
export async function monitor(ctx) {
  const result = await ctx.apple.script("return 7");
  ctx.update({ result: String(result) });
  await new Promise(() => {});
}

export default function Apple({ result = "?" }) {
  return <text content={`result ${result}`} />;
}
