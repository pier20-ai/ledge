// `./bridge.js` first: it installs `window.ledge` and `window.__ledgeDeliver`
// and announces the page to Swift. Everything below assumes both exist.
import "./bridge.js";

import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./app.jsx";

createRoot(document.getElementById("root")).render(<App />);
