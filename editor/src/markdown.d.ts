/**
 * The renderer is intentionally plain JavaScript because it ships directly in
 * the WebKit bundle. This declaration keeps the host's cross-package behavior
 * tests inside the repository's strict TypeScript check.
 */
export function renderMarkdown(source: unknown): unknown[];
