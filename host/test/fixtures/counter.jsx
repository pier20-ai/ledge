/** @jsxImportSource react */
// Event-dispatch fixture: a button whose click bumps local state, so a
// host→worker `event` produces a follow-up commit batch.
import { useState } from "react";

export default function Counter() {
  const [n, setN] = useState(0);
  return (
    <stack axis="v" pad={12} gap={6}>
      <text content={`count ${n}`} />
      <button label="+" variant="glass" onClick={() => setN((c) => c + 1)} />
    </stack>
  );
}
