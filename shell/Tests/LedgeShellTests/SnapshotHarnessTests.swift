import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The snapshot harness' `draws` field (G3) — the thing that makes a **panel**
/// canvas visible to `scripts/snapshot-demos.sh`.
///
/// Why it needed one: a `canvas` node carries no pixels in a commit (spec §3.4).
/// Its content arrives as `draw` frames from a loop the monitor starts, and the
/// replay had no monitor and no display link, so three of the nine demo apps —
/// weather, chess, tetris, each of which *is* a well — rendered as an empty
/// slab. Their whole signature was missing from the one picture that is supposed
/// to be evidence, and Weather was being reviewed through a scratchpad
/// rasteriser that duplicated renderer code.
///
/// What is asserted here is the property, not the pixels: the same tree, dumped
/// with and without frames, must produce **different** PNGs, and the one with
/// frames must contain the ink the app painted. Nothing is compared against a
/// golden image — a snapshot suite that pinned bytes would fail on every font
/// revision, and this harness exists to be *looked at*.
@MainActor
@Suite("Snapshot harness — panel canvases (G3)")
struct SnapshotHarnessTests {
    /// One dump on disk, in the shape `dump-commits.ts` writes: a 120 × 60
    /// canvas alone in a column, optionally with a frame for it.
    private func dump(draws: Bool) -> String {
        let frames = draws
            ? """
            , "draws": { "2": [
                { "op": "rect", "x": 0, "y": 0, "w": 120, "h": 60, "fill": "#FF0000" }
              ] }
            """
            : ""
        return """
        { "app": "well", "name": "Well", "icon": "sf:square", "order": 0,
          "mutations": [
            { "op": "create", "id": 1, "kind": "stack", "props": { "axis": "v", "pad": 12 } },
            { "op": "create", "id": 2, "kind": "canvas", "props": { "w": 120, "h": 60 } },
            { "op": "insert", "parent": 1, "id": 2, "before": null },
            { "op": "setRoot", "id": 1 }
          ]\(frames) }
        """
    }

    /// Render one dump and hand back the app's own panel PNG.
    private func panelPNG(draws: Bool) throws -> Data {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-harness-\(UUID().uuidString)")
        let commits = root.appendingPathComponent("commits")
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: commits, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(dump(draws: draws).utf8)
            .write(to: commits.appendingPathComponent("well.json"))
        try SnapshotRenderer.renderAll(to: out, commits: commits)
        return try Data(contentsOf: out.appendingPathComponent("well.png"))
    }

    /// Does this PNG contain the app's ink? Decoded rather than byte-compared:
    /// "the well is no longer empty" is the claim, and only a pixel can make it.
    private func containsRed(_ png: Data) throws -> Bool {
        let image = try #require(NSBitmapImageRep(data: png))
        for y in stride(from: 0, to: image.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                guard let pixel = image.colorAt(x: x, y: y) else { continue }
                if pixel.redComponent > 0.8, pixel.greenComponent < 0.2, pixel.blueComponent < 0.2 {
                    return true
                }
            }
        }
        return false
    }

    @Test("A dump with `draws` paints the panel's canvas; one without leaves it empty")
    func drawsReachThePanelCanvas() throws {
        let empty = try panelPNG(draws: false)
        let painted = try panelPNG(draws: true)

        // The bug, stated as a test: before this field the two were identical.
        #expect(empty != painted)
        #expect(try !containsRed(empty))
        #expect(try containsRed(painted))
    }

    @Test("The frames go through the engine, so a canvas that is not there is ignored")
    func aDrawAtAnAbsentNodeIsHarmless() throws {
        // Nothing here paints directly: the replay injects `draw` envelopes and
        // flushes the coalescer, exactly as the display-link tick does live. The
        // consequence worth pinning is that an id the tree does not contain is
        // dropped in the renderer rather than crashing the run — which is what
        // keeps a stale dump from breaking a whole snapshot pass.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-harness-\(UUID().uuidString)")
        let commits = root.appendingPathComponent("commits")
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: commits, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = """
        { "app": "well", "name": "Well", "icon": "sf:square", "order": 0,
          "mutations": [
            { "op": "create", "id": 1, "kind": "stack", "props": { "axis": "v", "pad": 12 } },
            { "op": "create", "id": 2, "kind": "text", "props": { "content": "no canvas here" } },
            { "op": "insert", "parent": 1, "id": 2, "before": null },
            { "op": "setRoot", "id": 1 }
          ],
          "draws": { "9": [ { "op": "rect", "x": 0, "y": 0, "w": 8, "h": 8, "fill": "#FF0000" } ] } }
        """
        try Data(stale.utf8).write(to: commits.appendingPathComponent("well.json"))
        try SnapshotRenderer.renderAll(to: out, commits: commits)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("well.png").path))
    }
}
