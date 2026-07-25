// A stand-in for the user's agent CLI, used through `LEDGE_AGENT_CMD` so no
// test ever spends a token or depends on `claude` being installed. It mimics the
// only part of the real contract Ledge relies on: print one JSON object with a
// `result` string (what `claude -p … --output-format json` does), and exit 0.
//
// Behaviour is driven by env vars the test sets before the run:
//   FAKE_AGENT_REPLY   the `result` string to print (default: an echo)
//   FAKE_AGENT_EXIT    exit with this code, printing FAKE_AGENT_REPLY to stderr
//   FAKE_AGENT_HANG_MS sleep this long before replying (timeout tests)
//   FAKE_AGENT_FLAKY   first invocation in this cwd replies with prose, the
//                      second with FAKE_AGENT_REPLY (the schema-retry path)
//
// The prompt arrives as the final argv entry (the runner appends it when the
// command template carries no `{prompt}` placeholder).

export {}; // a module, so top-level await is allowed and `prompt` is not the global

const askedFor = Bun.argv.at(-1) ?? "";
const env = Bun.env;

if (env.FAKE_AGENT_HANG_MS) {
  await Bun.sleep(Number(env.FAKE_AGENT_HANG_MS));
}

const reply = env.FAKE_AGENT_REPLY ?? `echo: ${askedFor}`;

if (env.FAKE_AGENT_EXIT) {
  process.stderr.write(reply);
  process.exit(Number(env.FAKE_AGENT_EXIT));
}

let body = reply;
if (env.FAKE_AGENT_FLAKY) {
  // A counter in the cwd (the app's own folder) makes "first call vs second
  // call" observable without any coordination back to the test process.
  const marker = Bun.file(".fake-agent-calls");
  const seen = (await marker.exists()) ? Number(await marker.text()) : 0;
  await Bun.write(".fake-agent-calls", String(seen + 1));
  if (seen === 0) body = "Sure! Here is the JSON you asked for.";
}

process.stdout.write(JSON.stringify({ type: "result", result: body }));
