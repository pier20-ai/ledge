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
    /// `dump-commits --wing`: the collapsed-notch surface this app asked for
    /// (spec §3.3) and the frame it drew into it (§3.4). Absent for the ordinary
    /// panel-only dump.
    var wing: WingSpec?
    var wingOps: [JSONValue]?
    /// Every canvas the app painted during that same window (§3.4), keyed by
    /// node id. Replayed as `draw` envelopes once the panel has a size, which is
    /// what makes a **panel** canvas — weather's pane, chess's board, blocks's
    /// well — appear in the PNG instead of an empty slab.
    var draws: [String: [JSONValue]]?
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
            surface(presentation: .collapsed, content: nil, height: 0),
            named: "idle",
            to: directory
        )

        // Collapsed pill wearing a wing (spec §3.3 extension): a label on the
        // left, a live strip on the right. Replayed like everything else — the
        // draw ops go through the real coalescer and the real canvas view,
        // including the `image` op blitting a spritesheet cell (§3.4).
        let wings = wingSurface()
        try write(wings, cropping: wings.currentShapeRect, named: "wings", to: directory)

        // The same pill with a label and nothing else — the shape a countdown
        // app puts up, and the asymmetric case: the wing is entirely on one side
        // of the camera housing, so the pill hangs off one side of the cutout.
        let textWing = wingSurface(spec: WingSpec(text: "⏰ 14:53 · 10m"))
        try write(textWing, cropping: textWing.currentShapeRect, named: "wings-text", to: directory)

        // …and the same pill with the stock **meter** in the right wing (spec
        // §3.3 extension) — the timer's shape. Nothing here is drawn by an app:
        // the bar's width, thickness and ink are the shell's, which is the whole
        // difference between this and the canvas above.
        let meterWing = wingSurface(spec: WingSpec(text: "12:04", meter: WingMeterSpec(value: 0.42)))
        try write(meterWing, cropping: meterWing.currentShapeRect, named: "wings-meter", to: directory)

        // An app's own wing, when `dump-commits --wing` captured one: the same
        // pill as above, wearing what the app actually asked the notch for. This
        // is the only way an app's *signature* is reviewable without a live
        // player — a wing is never in the mount tree.
        for dump in dumps {
            guard let spec = dump.wing else { continue }
            let pill = wingSurface(spec: spec, ops: dump.wingOps ?? [])
            try write(pill, cropping: pill.currentShapeRect, named: "\(dump.app)-wing", to: directory)
        }

        // Replayed app panels.
        for dump in dumps {
            guard let resolved = session.content(for: dump.app) else {
                throw SnapshotError.noTree(dump.app)
            }
            let panel = surface(
                presentation: .expanded(app: dump.app),
                content: resolved.view,
                width: resolved.width,
                height: resolved.height
            )
            // …and then the pixels. A `canvas` node's content never travels in a
            // commit (§3.4), so up to here three of the demo apps rendered as an
            // empty well. The draws go in **after** `surface` has laid the panel
            // out, because `ProtocolCanvasView.apply(ops:)` rasterises into a
            // buffer the size of its own `bounds` and a canvas that has not been
            // measured yet has none — the frame would be dropped in silence.
            if let draws = dump.draws, !draws.isEmpty {
                try replay(draws: draws, app: dump.app, into: session)
                panel.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
            }
            try write(panel, named: dump.app, to: directory)
        }

        // **The summary swell** — the surface a rested pointer gets on a heavy
        // session (flow.md, principle 7), and the one surface in the product
        // that had no snapshot at all.
        //
        // That gap cost something real: the shell-drawn open affordance was a
        // bare `ink-3` chevron, nobody could find it on device, and no reviewer
        // could have caught it because no reviewer was ever shown it. It is a
        // bead now, and this is the picture that keeps it honest.
        for dump in dumps where session.declaresSummary(for: dump.app) {
            guard let summary = session.summaryView(for: dump.app) else { continue }
            let swell = MiniContentView()
            swell.setShowsOpenAffordance(true)
            swell.adopt(summary)
            let size = swell.preferredSize(
                cutoutWidth: NotchMetrics.fallback.closedWidth,
                maxWidth: PanelLimits.defaultWidth
            )
            let surface = surface(
                presentation: .summary(app: dump.app),
                content: swell,
                width: size.width,
                height: size.height + NotchMetrics.fallback.closedHeight
            )
            try write(
                surface,
                cropping: surface.currentShapeRect,
                named: "\(dump.app)-summary",
                to: directory
            )
            // Hand the node back untouched: it belongs to the app's tree, and a
            // later surface asking for the same app must not find it adopted.
            swell.adopt(nil)
        }

        // **Chat mode, over the first app's stage** (flow.md, "Visit modes").
        //
        // What this PNG is evidence for is the half a web view cannot show: the
        // panel body's glass running opaque under the notch to nearly clear at
        // the pill, and the session's live tree still mounted inside it, dimmed
        // and scaled one step back. The transcript itself is a `WKWebView` and
        // paints nothing inside a synchronous headless render, so the pane above
        // the stage is deliberately empty here — `scripts/snapshot-editor.swift`
        // renders that layer in a real web view, and the two compose.
        if let first = dumps.first, let resolved = session.content(for: first.app) {
            let chat = ChatSurfaceView()
            let stageHeight = max(0, resolved.height - session.chromeHeight)
            let height = ChatSurfaceView.panelHeight(stageHeight: stageHeight)
            chat.frame = CGRect(x: 0, y: 0, width: resolved.width, height: height)
            chat.setStage(resolved.view, height: stageHeight)
            chat.layoutSubtreeIfNeeded()
            try write(
                surface(
                    presentation: .chat(app: first.app),
                    content: chat,
                    width: resolved.width,
                    height: height + NotchMetrics.fallback.closedHeight
                ),
                named: "chat",
                to: directory
            )
            // Put the tree back where the stage snapshot left it, so a later
            // caller asking for this app's panel is not handed an empty box.
            chat.setStage(nil, height: 0)
        }

        // The blank slot: the same chat surface with nothing behind it — chat
        // only, full pane, no glass toggle (flow.md, "The strip"). The pane is
        // empty here for the same reason as above: its transcript is a web view.
        let blank = ChatSurfaceView()
        blank.frame = CGRect(
            x: 0, y: 0,
            width: PanelLimits.defaultWidth,
            height: ChatSurfaceView.panelHeight(stageHeight: nil)
        )
        blank.layoutSubtreeIfNeeded()
        try write(
            surface(
                presentation: .newApp,
                content: blank,
                height: ChatSurfaceView.panelHeight(stageHeight: nil)
                    + NotchMetrics.fallback.closedHeight
            ),
            named: "newApp",
            to: directory
        )
        try write(
            surface(
                presentation: .expanded(app: nil),
                content: HostPlaceholderView(phase: .noHost(detail: "cd host && bun run start")),
                height: HostPlaceholderView.panelHeight + NotchMetrics.fallback.closedHeight
            ),
            named: "no-host",
            to: directory
        )

        // **The ledge** (flow.md, "The strip"): the whole strip at once, as
        // slabs on a shelf, with the blank slot's dashed frame at the end. The
        // pointer is planted on the second slab so the PNG shows the rise —
        // static evidence of a gesture is the only kind a snapshot can give.
        try write(overviewSurface(catalog: catalog), named: "overview", to: directory)

        // **Parked** (flow.md, States): the same body, torn off the notch. The
        // first app's own tree is inside it, because what parks is the surface
        // and not a picture of one.
        if let first = dumps.first, let resolved = session.content(for: first.app) {
            try write(
                parkedSurface(
                    app: first.app,
                    content: resolved.view,
                    width: resolved.width,
                    height: resolved.height
                ),
                named: "parked",
                to: directory
            )
        }

        // **The Settings window** (G4): sidebar + pages, as furniture. Not a
        // panel surface — the window controller's own content view, over a
        // probe that answers from a dictionary, because a headless render
        // must never read (let alone prompt) TCC. One PNG per standing page,
        // and one of an app's declared controls when the catalog carries any.
        let settingsSession = HostSession()
        settingsSession.openReplay()
        var settingsCatalog = catalog
        if var first = settingsCatalog.first {
            // A specimen declaration, so the controls page is reviewable
            // without a live host: one of each control the vocabulary has.
            first.settings = [
                SettingSpec(key: "voice", label: "Voice", type: "toggle", defaultValue: .bool(true), hint: "Speak the answer as well as showing it."),
                SettingSpec(key: "region", label: "Region", type: "choice", defaultValue: .string("Global"), options: ["Global", "Europe", "US"]),
                SettingSpec(key: "model", label: "Model", type: "text", defaultValue: .string("gpt-5.6-luna")),
                SettingSpec(key: "depth", label: "Depth", type: "number", defaultValue: .int(24), min: 6, max: 36, step: 6),
            ]
            first.values = [
                "voice": .bool(true), "region": .string("Global"),
                "model": .string("gpt-5.6-luna"), "depth": .int(24),
            ]
            settingsCatalog[0] = first
        }
        settingsSession.inject(Envelope(
            app: "",
            seq: 1,
            type: "catalog",
            payload: try encode(CatalogPayload(apps: settingsCatalog))
        ))
        let settings = SettingsWindowController(
            session: settingsSession,
            probe: SnapshotPermissionProbe(),
            onQuit: {}
        )
        settings.loadForTesting()
        if let content = settings.windowForTesting?.contentView {
            for page in settings.pagesForTesting {
                settings.selectForTesting(page)
                // SwiftUI commits on the runloop, not on assignment: without
                // this beat every page renders as the first one selected.
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                try write(content, named: "settings-\(page)", to: directory)
            }
        }
    }

    /// The headless stand-in for `SystemPermissionProbe`: canned statuses, no
    /// framework, no prompt — the same dictionary trick as the test target's
    /// fake, re-stated here because a snapshot run is not a test run.
    private final class SnapshotPermissionProbe: PermissionProbing {
        func status(of permission: LedgePermission) -> PermissionStatus {
            switch permission {
            case .notifications, .calendar: .granted
            case .microphone: .notDetermined
            default: .notDetermined
            }
        }

        func ask(_ permission: LedgePermission, then: @escaping @MainActor (PermissionStatus) -> Void) {
            then(.notDetermined)
        }

        func openSettings(for permission: LedgePermission) {}
    }

    /// The ledge, rendered against a real catalog: one slab per enabled app plus
    /// the one blank slot (`SessionStrip.slots`).
    private static func overviewSurface(catalog: [CatalogApp]) -> ShellSurfaceView {
        let grid = OverviewSurfaceView()
        let strip = SessionStrip(catalog: catalog)
        let current = strip.apps.isEmpty ? nil : strip.apps[strip.apps.count / 2]
        grid.apply(cards: strip.slots.map { slot in
            switch slot {
            case .app(let app):
                let row = catalog.first { $0.id == app }
                return OverviewSurfaceView.Card(
                    app: app,
                    name: row?.name ?? app,
                    icon: row?.symbolName ?? "square.dashed"
                )
            case .blank:
                return .blank
            }
        }, current: current)
        let height = OverviewSurfaceView.panelHeight(count: grid.cards.count)
            + NotchMetrics.fallback.closedHeight
        let view = surface(
            presentation: .overview,
            content: grid,
            height: height
        )
        // **After** the last layout pass, not before: `layout` re-reads the live
        // pointer (which is nowhere near a headless view), so a swell applied
        // first is flattened by the pass that follows it.
        view.layoutSubtreeIfNeeded()
        // The cursor on the card the grid opened from: the gaussian puts that
        // one at 1 and its neighbours partway up, which is the shape of the
        // whole gesture — and it puts the ✕ where it belongs.
        if let current, let index = grid.cards.firstIndex(where: { $0.app == current }) {
            let frame = grid.cardFrames[index]
            grid.apply(pointer: CGPoint(x: frame.midX, y: frame.midY))
        }
        view.displayIfNeeded()
        return view
    }

    /// The parked window. The view carries its own shadow margin (it is the
    /// window, margin and all), so the window rung of the shadow ramp is in
    /// the PNG without a stage around it.
    private static func parkedSurface(
        app: String,
        content: NSView,
        width: CGFloat,
        height: CGFloat
    ) -> NSView {
        let body = ParkedSurfaceView(callbacks: .inert)
        body.rowHeight = NotchMetrics.fallback.closedHeight
        body.setPanelWing(mode: .stage, canToggleGlass: true)
        body.present(.expanded(app: app), content: content, animated: false)
        // The body's height, not the panel's: the window spends its own top
        // pad, and sized to the panel it clipped the content's last line.
        let size = ParkedSurfaceView.windowSize(
            forBody: CGSize(width: width, height: ParkedSurfaceView.bodyHeight(forPanelHeight: height))
        )
        body.frame = CGRect(origin: .zero, size: size)
        let stage = FlippedView(frame: CGRect(origin: .zero, size: size))
        stage.addSubview(body)
        stage.layoutSubtreeIfNeeded()
        stage.displayIfNeeded()
        return stage
    }

    // MARK: - Helpers

    /// Feed one app's captured canvas frames through the real §3.4 path: a
    /// `draw` envelope per canvas, then the coalescer's flush, which is exactly
    /// what the display-link tick does in a live shell. Nothing here paints
    /// directly — a snapshot that bypassed the engine would stop being evidence.
    ///
    /// Ids arrive as strings (JSON object keys) and are sorted numerically so a
    /// run is reproducible; the seq is pushed well past the commits' so the
    /// per-app gate (§1) lets every frame through.
    private static func replay(
        draws: [String: [JSONValue]],
        app: String,
        into session: HostSession
    ) throws {
        let frames = draws
            .compactMap { key, ops in Int(key).map { (id: $0, ops: ops) } }
            .sorted { $0.id < $1.id }
        for (offset, frame) in frames.enumerated() {
            session.inject(Envelope(
                app: app,
                seq: drawSeqBase + offset,
                type: "draw",
                payload: try encode(DrawPayload(id: frame.id, ops: frame.ops))
            ))
        }
        session.flushDraws()
    }

    /// Above any seq the commit replay above can reach (one per dump, and there
    /// are seven demo apps).
    private static let drawSeqBase = 1_000

    private static func surface(
        presentation: ShellPresentation,
        content: NSView?,
        width: CGFloat = PanelLimits.defaultWidth,
        height: CGFloat
    ) -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.setBodyMaterial(presentation.isConversation ? .chatGlass : .solid)
        let mode: PanelWingBarView.Mode = if presentation == .overview {
            .overview
        } else if presentation.isChat {
            .editor
        } else {
            .stage
        }
        surface.setPanelWing(
            mode: mode,
            // On the ledge the bead is **Back**, and it is always there.
            canToggleGlass: presentation == .overview || presentation.app != nil
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
    ///
    /// `ops` overrides the stock equalizer with a real app's frame — that is the
    /// `--wing` path, where the pixels in the strip came out of the app's own
    /// `ctx.draw` rather than out of this file.
    private static func wingSurface(
        spec: WingSpec = WingSpec(text: "AAPL ▲ 1.2%", canvas: WingCanvasSpec(id: 12, w: 64)),
        ops: [JSONValue]? = nil
    ) -> ShellSurfaceView {
        let view = ShellSurfaceView(callbacks: .inert)
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
        if let ops {
            view.wingCanvasView.apply(ops: ops)
            view.displayIfNeeded()
            return view
        }
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
