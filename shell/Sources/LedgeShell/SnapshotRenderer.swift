import AppKit
import LedgeShellCore

/// One dumped mount batch: what `host/scripts/dump-commits.ts` writes after
/// rendering an `app.jsx` once through the real reconciler.
private struct CommitDump: Decodable {
    var app: String
    var name: String
    var icon: String
    var order: Int
    /// The app's declared `meta.panel`, if it declared one (spec §5 extension).
    var panel: PanelSpec?
    var mutations: [Mutation]
}

/// Renders the shell's surfaces to PNGs without a window or a host process.
///
/// App panels are **replayed**, not scripted: each `<app>.json` produced by the
/// host's dump script goes through the same `ProtocolEngine` → `ProtocolRenderer`
/// path a live commit takes, so a snapshot that looks right is evidence the
/// protocol path is right. The chrome surfaces (idle pill, chat, [+]) have no
/// host tree behind them and are rendered directly.
@MainActor
enum SnapshotRenderer {
    static func renderAll(to directory: URL, commits: URL?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let dumps = try commits.map(loadDumps(from:)) ?? []
        let session = HostSession()
        session.openReplay()

        let catalog = dumps.map {
            CatalogApp(
                id: $0.app,
                name: $0.name,
                icon: $0.icon,
                order: $0.order,
                enabled: true,
                running: true,
                panel: $0.panel
            )
        }
        session.inject(Envelope(
            app: "",
            seq: 1,
            type: "catalog",
            payload: try encode(CatalogPayload(apps: catalog))
        ))
        for (index, dump) in dumps.enumerated() {
            session.inject(Envelope(
                app: dump.app,
                seq: index + 1,
                type: "commit",
                payload: try encode(CommitPayload(mutations: dump.mutations))
            ))
        }

        // Collapsed pill.
        try write(
            surface(catalog: catalog, presentation: .collapsed, content: nil, height: 0),
            named: "idle",
            to: directory
        )

        // Collapsed pill wearing a wing (spec §3.3 extension): a label on the
        // left, a live strip on the right. Replayed like everything else — the
        // draw ops go through the real coalescer and the real canvas view,
        // including the `image` op blitting a spritesheet cell (§3.4).
        let wings = wingSurface(catalog: catalog)
        try write(wings, cropping: wings.currentShapeRect, named: "wings", to: directory)

        // The same pill with a label and nothing else — the shape a countdown
        // app puts up, and the asymmetric case: the wing is entirely on one side
        // of the camera housing, so the pill hangs off one side of the cutout.
        let textWing = wingSurface(catalog: catalog, spec: WingSpec(text: "⏰ 14:53 · 10m"))
        try write(textWing, cropping: textWing.currentShapeRect, named: "wings-text", to: directory)

        // Replayed app panels.
        for dump in dumps {
            guard let resolved = session.content(for: dump.app) else {
                throw SnapshotError.noTree(dump.app)
            }
            try write(
                surface(
                    catalog: catalog,
                    presentation: .expanded(app: dump.app),
                    content: resolved.view,
                    wing: session.panelWing(for: dump.app),
                    name: session.name(for: dump.app),
                    width: resolved.width,
                    height: resolved.height
                ),
                named: dump.app,
                to: directory
            )
        }

        // Shell chrome surfaces (spec §8): inert, no host tree behind them.
        // No `chat` snapshot any more: that surface is a `WKWebView` now
        // (`EditorSurfaceView`), and a web view has nothing to draw until its
        // content process has loaded and painted — which never happens inside a
        // synchronous headless render. A PNG of it would be a black rectangle
        // asserting nothing. The editor is verified through `EditorBridge`
        // (unit) and by launching the built app (visually) instead.
        try write(
            surface(
                catalog: catalog,
                presentation: .newApp,
                content: NewAppContentView(callbacks: .inert),
                height: NewAppContentView.panelHeight + NotchMetrics.fallback.closedHeight
            ),
            named: "newApp",
            to: directory
        )
        try write(
            surface(
                catalog: catalog,
                presentation: .expanded(app: nil),
                content: HostPlaceholderView(phase: .noHost(detail: "cd host && bun run start")),
                height: HostPlaceholderView.panelHeight + NotchMetrics.fallback.closedHeight
            ),
            named: "no-host",
            to: directory
        )
    }

    // MARK: - Helpers

    private static func surface(
        catalog: [CatalogApp],
        presentation: ShellPresentation,
        content: NSView?,
        wing: NSView? = nil,
        name: String? = nil,
        width: CGFloat = PanelLimits.defaultWidth,
        height: CGFloat
    ) -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.setCatalog(catalog)
        surface.setPanelWing(
            name: name ?? presentation.app,
            content: wing,
            canEdit: presentation.app != nil
        )
        surface.frame = CGRect(
            origin: .zero,
            size: surface.shapeSize(expanded: presentation.isExpanded, width: width, height: height)
        )
        surface.present(
            presentation,
            content: content,
            width: width,
            height: height,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        surface.displayIfNeeded()
        return surface
    }

    /// The winged pill (spec §3.3 extension), drawn the way a live app produces
    /// it: a wing spec sets the geometry, and a §3.4 op list paints the strip.
    ///
    /// The view is deliberately wider than the pill and the PNG is cropped back
    /// to `currentShapeRect`, because the collapsed shape is anchored to the
    /// hardware cutout rather than centred on itself — a one-sided wing sits off
    /// centre by design (see `ShellSurfaceView.shapeRect`).
    private static func wingSurface(
        catalog: [CatalogApp],
        spec: WingSpec = WingSpec(text: "AAPL ▲ 1.2%", canvas: WingCanvasSpec(id: 12, w: 64))
    ) -> ShellSurfaceView {
        let view = ShellSurfaceView(callbacks: .inert)
        view.setCatalog(catalog)
        view.setWing(spec, animated: false)
        // Room for the widest pill either wing can reach, so the anchored shape
        // is never clipped by the view it is drawn in.
        view.frame = CGRect(
            x: 0, y: 0,
            width: NotchMetrics.fallback.closedWidth + PanelLimits.maxWingWidth * 2
                + ShellSurfaceView.fillet * 2,
            height: NotchMetrics.fallback.closedHeight
        )
        view.present(.collapsed, content: nil, height: 0, animated: false)
        view.layoutSubtreeIfNeeded()
        // A three-bar equalizer, the mockup's own right-wing content, plus one
        // cell of a spritesheet — the `image` op reaches the wing strip through
        // exactly the same canvas the panel uses.
        view.wingCanvasView.apply(ops: [
            .object(["op": .string("clear")]),
            .object(["op": .string("rect"), "x": .int(6), "y": .int(14), "w": .int(3),
                     "h": .int(7), "fill": .string("#FFB454"), "radius": .double(1.5)]),
            .object(["op": .string("rect"), "x": .int(12), "y": .int(10), "w": .int(3),
                     "h": .int(11), "fill": .string("#FFB454"), "radius": .double(1.5)]),
            .object(["op": .string("rect"), "x": .int(18), "y": .int(16), "w": .int(3),
                     "h": .int(5), "fill": .string("#FFB454"), "radius": .double(1.5)]),
        ] + spriteOps())
        view.displayIfNeeded()
        return view
    }

    /// One cell of a spritesheet, blitted into the wing strip. The sheet is
    /// generated into a temp file rather than committed: the machinery is what
    /// the snapshot is evidence for, and a real app points `src` at its own
    /// folder (`import.meta.dir`, spec §6).
    private static func spriteOps() -> [JSONValue] {
        guard let sheet = try? writeSpriteSheet() else { return [] }
        return [
            .object([
                "op": .string("image"), "src": .string(sheet.path),
                // Cell (1, 0) of a 4 × 4, 8 px sheet, blown up 2× — pixel art
                // must not blur, which is what the op's interpolation rule buys.
                "sx": .int(8), "sy": .int(0), "sw": .int(8), "sh": .int(8),
                "x": .int(28), "y": .int(9), "w": .int(16), "h": .int(16),
            ]),
        ]
    }

    /// A 4 × 4 grid of 8 px cells, each a flat colour with a lighter top-left
    /// pixel block — enough to see that the right cell was picked and that it
    /// landed the right way up.
    private static func writeSpriteSheet() throws -> URL {
        let cell = 8
        let grid = 4
        let side = cell * grid
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw SnapshotError.couldNotCreateBitmap("sprites")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        for row in 0..<grid {
            for column in 0..<grid {
                let index = row * grid + column
                let hue = CGFloat(index) / CGFloat(grid * grid)
                let origin = CGPoint(x: column * cell, y: (grid - 1 - row) * cell)
                NSColor(hue: hue, saturation: 0.8, brightness: 0.95, alpha: 1).setFill()
                CGRect(x: origin.x, y: origin.y, width: CGFloat(cell), height: CGFloat(cell)).fill()
                NSColor.white.setFill()          // top-left corner marker
                CGRect(x: origin.x, y: origin.y + CGFloat(cell) - 2, width: 2, height: 2).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncodePNG("sprites")
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-snapshot-sprites.png")
        try png.write(to: url)
        LedgeImageStore.shared.purge()           // the path is reused between runs
        return url
    }

    /// `cropping` limits the PNG to part of the view — what the winged pill
    /// needs, since it is drawn inside a view wider than itself.
    private static func write(
        _ surface: NSView,
        cropping crop: CGRect? = nil,
        named name: String,
        to directory: URL
    ) throws {
        let region = crop ?? surface.bounds
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(region.width),
            pixelsHigh: Int(region.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw SnapshotError.couldNotCreateBitmap(name)
        }
        surface.cacheDisplay(in: region, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncodePNG(name)
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func loadDumps(from directory: URL) throws -> [CommitDump] {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        return try files
            .map { try decoder.decode(CommitDump.self, from: Data(contentsOf: $0)) }
            .sorted { $0.order < $1.order }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

enum SnapshotError: Error {
    case couldNotCreateBitmap(String)
    case couldNotEncodePNG(String)
    case noTree(String)
}
