/** @jsxImportSource react */
// Console-capture fixture: logs at import time (captureConsole is installed
// before the worker imports the module), so the host receives a `console`
// message without needing an event or monitor tick.
console.log("boot log", 7);

export default function Logger() {
  return <text content="logging" />;
}
