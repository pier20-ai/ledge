import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// File-backed images: the `image` component's `src` (spec §5) and the `image`
/// draw op (§3.4). Both read the same cache and the same files, so they are
/// tested against the same generated spritesheet.
///
/// The sheet is written at test time rather than committed: a checked-in binary
/// would be a second source of truth about what "cell (1, 2)" means, and the
/// point of these tests is the machinery, not the art.
@MainActor
@Suite("File images & the spritesheet draw op (spec §5, §3.4)")
struct ImageRenderingTests {
    // MARK: - A generated spritesheet

    private static let cell = 8
    private static let grid = 4

    /// Cell colours are a function of the cell's position, so a test can assert
    /// *which* cell it got rather than merely that it got one.
    private static func color(column: Int, row: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(column + 1) * 60 / 255,
            green: CGFloat(row + 1) * 60 / 255,
            blue: 0.5,
            alpha: 1
        )
    }

    /// A `grid × grid` sheet of `cell`-pixel cells. Each cell is a flat colour
    /// with a **white block in its top-left corner**, which is what makes an
    /// upside-down blit visible: `sy` counts down from the top of the image
    /// (spec §3.4's op space), so the marker has to come out at the top-left of
    /// the destination rect too.
    private static func writeSpriteSheet(marker: Int = 2) throws -> String {
        let side = cell * grid
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        for row in 0..<grid {
            for column in 0..<grid {
                // NSBitmapImageRep draws y-up; the sheet's rows are counted from
                // the top, so row 0 is the *last* band of pixels.
                let origin = CGPoint(x: column * cell, y: (grid - 1 - row) * cell)
                color(column: column, row: row).setFill()
                CGRect(x: origin.x, y: origin.y, width: CGFloat(cell), height: CGFloat(cell)).fill()
                NSColor.white.setFill()
                CGRect(
                    x: origin.x, y: origin.y + CGFloat(cell - marker),
                    width: CGFloat(marker), height: CGFloat(marker)
                ).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let png = try #require(representation.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sprites.png")
        try png.write(to: url)
        return url.path
    }

    // MARK: - Rendering helpers

    /// Draw an op list into a canvas and read the pixels back — the same path a
    /// live frame takes, cached display and all.
    private func render(_ ops: [JSONValue], size: CGSize) throws -> NSBitmapImageRep {
        let canvas = ProtocolCanvasView(frame: CGRect(origin: .zero, size: size))
        canvas.chromeless = true                 // no card behind the pixels
        canvas.apply(ops: ops)
        return try snapshot(canvas)
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }

    private func expectColor(
        _ representation: NSBitmapImageRep,
        x: Int,
        y: Int,
        matches expected: NSColor,
        tolerance: CGFloat = 0.08,
        _ label: String
    ) {
        guard let sampled = representation.colorAt(x: x, y: y)?
            .usingColorSpace(.sRGB) else {
            Issue.record("\(label): no pixel at (\(x), \(y))")
            return
        }
        let wanted = expected.usingColorSpace(.sRGB) ?? expected
        let distance = max(
            abs(sampled.redComponent - wanted.redComponent),
            max(
                abs(sampled.greenComponent - wanted.greenComponent),
                abs(sampled.blueComponent - wanted.blueComponent)
            )
        )
        #expect(
            distance <= tolerance,
            "\(label): (\(x), \(y)) was \(sampled), wanted \(wanted)"
        )
    }

    private func imageOp(
        src: String,
        destination: CGRect,
        source: CGRect? = nil
    ) -> JSONValue {
        var op: [String: JSONValue] = [
            "op": .string("image"),
            "src": .string(src),
            "x": .double(destination.minX), "y": .double(destination.minY),
            "w": .double(destination.width), "h": .double(destination.height),
        ]
        if let source {
            op["sx"] = .double(source.minX)
            op["sy"] = .double(source.minY)
            op["sw"] = .double(source.width)
            op["sh"] = .double(source.height)
        }
        return .object(op)
    }

    // MARK: - The draw op (spec §3.4)

    @Test("A whole-image blit lands the right way up in the op's y-down space")
    func wholeImageOrientation() throws {
        let sheet = try Self.writeSpriteSheet()
        let side = CGFloat(Self.cell * Self.grid)
        let pixels = try render(
            [imageOp(src: sheet, destination: CGRect(x: 0, y: 0, width: side, height: side))],
            size: CGSize(width: side, height: side)
        )
        // The marker belongs to cell (0, 0), which is the *top* row of the sheet.
        // If the blit were flipped it would come out at the bottom instead.
        expectColor(pixels, x: 0, y: 0, matches: .white, "top-left marker")
        expectColor(
            pixels, x: 5, y: 5,
            matches: Self.color(column: 0, row: 0),
            "cell (0, 0) body"
        )
        expectColor(
            pixels, x: 5, y: Self.cell * 3 + 5,
            matches: Self.color(column: 0, row: 3),
            "cell (0, 3) is the bottom row"
        )
    }

    @Test("sx/sy/sw/sh pick one spritesheet cell, in image pixels from the top-left")
    func sourceRectPicksACell() throws {
        let sheet = try Self.writeSpriteSheet()
        let cell = CGFloat(Self.cell)
        // Column 2, row 3 — asymmetric on purpose: a transposed source rect or a
        // flipped y would land on a different colour.
        let pixels = try render(
            [imageOp(
                src: sheet,
                destination: CGRect(x: 0, y: 0, width: 32, height: 32),
                source: CGRect(x: cell * 2, y: cell * 3, width: cell, height: cell)
            )],
            size: CGSize(width: 32, height: 32)
        )
        expectColor(
            pixels, x: 20, y: 20,
            matches: Self.color(column: 2, row: 3),
            "the selected cell"
        )
        expectColor(pixels, x: 2, y: 2, matches: .white, "the cell's own top-left marker")
    }

    @Test("A magnified pixel sprite stays crisp — no interpolation across its edges")
    func magnifiedSpriteIsNotBlurred() throws {
        let sheet = try Self.writeSpriteSheet(marker: 4)
        let cell = CGFloat(Self.cell)
        // One 8 px cell blown up 8×: the marker's edge falls exactly halfway
        // across the destination. Smoothing would smear white into the body over
        // several points; nearest-neighbour leaves a hard line.
        let pixels = try render(
            [imageOp(
                src: sheet,
                destination: CGRect(x: 0, y: 0, width: 64, height: 64),
                source: CGRect(x: 0, y: 0, width: cell, height: cell)
            )],
            size: CGSize(width: 64, height: 64)
        )
        expectColor(pixels, x: 28, y: 4, matches: .white, tolerance: 0.02, "inside the marker")
        expectColor(
            pixels, x: 36, y: 4,
            matches: Self.color(column: 0, row: 0),
            tolerance: 0.02,
            "immediately past the marker's edge"
        )
    }

    @Test("A src that does not resolve draws nothing — it is not a crash and not a glyph")
    func missingFileIsQuiet() throws {
        let ops: [JSONValue] = [
            .object(["op": .string("clear")]),
            imageOp(
                src: "/nonexistent/ledge/not-a-sprite-sheet.png",
                destination: CGRect(x: 0, y: 0, width: 32, height: 32)
            ),
        ]
        let pixels = try render(ops, size: CGSize(width: 32, height: 32))
        let sampled = try #require(pixels.colorAt(x: 16, y: 16))
        #expect(sampled.alphaComponent < 0.02, "a missing image must leave the canvas clear")

        // A relative path is refused for the same reason: it would resolve
        // against the shell's working directory, which is nowhere near the app.
        #expect(LedgeImageStore.shared.image(atPath: "sprites.png") == nil)
    }

    @Test("The notch wing's strip renders image ops through the very same canvas")
    func wingStripDrawsImages() throws {
        let sheet = try Self.writeSpriteSheet()
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 60)
        surface.setWing(WingSpec(canvas: WingCanvasSpec(id: 12, w: 64)), animated: false)
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()

        let strip = surface.wingCanvasView
        #expect(strip.bounds.width > 0)
        strip.apply(ops: [
            .object(["op": .string("clear")]),
            imageOp(
                src: sheet,
                destination: CGRect(x: 0, y: 0, width: 16, height: 16),
                source: CGRect(x: 8, y: 0, width: 8, height: 8)
            ),
        ])
        #expect(strip.hasBuffer)
        let pixels = try snapshot(strip)
        expectColor(
            pixels, x: 10, y: 10,
            matches: Self.color(column: 1, row: 0),
            "the sprite cell painted on the wing strip"
        )
    }

    // MARK: - The `image` component (spec §5)

    @Test("A file src aspect-fills its box; an sf: src is still a symbol")
    func componentResolvesBothKindsOfSrc() throws {
        let sheet = try Self.writeSpriteSheet()
        let renderer = ProtocolRenderer()
        renderer.applyCommit(app: "gallery", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: ["axis": .string("v")]),
            Mutation(op: .create, id: 2, kind: "image", props: [
                "src": .string(sheet), "w": .double(24), "h": .double(48), "radius": .double(6),
            ]),
            Mutation(op: .create, id: 3, kind: "image", props: ["src": .string("sf:alarm")]),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .insert, id: 3, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])

        let file = try #require(renderer.view(app: "gallery", id: 2) as? LedgeFileImageView)
        #expect(file.path == sheet)
        #expect(file.layer?.cornerRadius == 6)
        #expect(renderer.view(app: "gallery", id: 3) is LedgeSymbolView)

        // Aspect *fill*: a square sheet in a 24 × 48 box covers the whole box,
        // cropping the sides — a tile with letterbox bars in it is not a tile.
        file.frame = CGRect(x: 0, y: 0, width: 24, height: 48)
        let pixels = try snapshot(file)
        for point in [(2, 2), (21, 2), (2, 45), (21, 45), (12, 24)] {
            let sampled = try #require(pixels.colorAt(x: point.0, y: point.1))
            #expect(sampled.alphaComponent > 0.9, "the box is fully covered at \(point)")
        }
    }

    @Test("A src that changes lands on the same node (spec §3.1 partial update)")
    func componentUpdatesSrcInPlace() throws {
        let first = try Self.writeSpriteSheet()
        let second = try Self.writeSpriteSheet()
        let renderer = ProtocolRenderer()
        renderer.applyCommit(app: "gallery", mutations: [
            Mutation(op: .create, id: 1, kind: "image", props: ["src": .string(first)]),
            Mutation(op: .setRoot, id: 1),
        ])
        let view = try #require(renderer.view(app: "gallery", id: 1) as? LedgeFileImageView)

        renderer.applyCommit(app: "gallery", mutations: [
            Mutation(op: .update, id: 1, props: ["src": .string(second), "radius": .double(4)]),
        ])
        #expect(renderer.view(app: "gallery", id: 1) === view, "the node must not be rebuilt")
        #expect(view.path == second)
        #expect(view.layer?.cornerRadius == 4)
    }

    @Test("An unreadable src is a quiet placeholder, not a broken-image glyph")
    func componentPlaceholderIsQuiet() throws {
        let view = LedgeFileImageView(path: "/nonexistent/ledge/artwork.png", radius: 4)
        view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let pixels = try snapshot(view)
        let sampled = try #require(pixels.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB))
        // The raised token over nothing: faint, and nowhere near opaque.
        #expect(sampled.alphaComponent > 0, "the box is still drawn")
        #expect(sampled.alphaComponent < 0.2, "…but quietly")
    }

    // MARK: - The cache

    @Test("One decode per path, shared across canvases, and bounded")
    func cacheIsSharedAndBounded() throws {
        let sheet = try Self.writeSpriteSheet()
        let store = LedgeImageStore.shared
        let once = try #require(store.image(atPath: sheet))
        #expect(store.image(atPath: sheet) === once, "a second ask must not decode again")
        #expect(store.cgImage(atPath: sheet) != nil)

        // A miss is an answer too: asking again must not re-read the filesystem
        // to arrive at the same nil.
        #expect(store.image(atPath: "/nonexistent/ledge/absent.png") == nil)
        #expect(store.image(atPath: "/nonexistent/ledge/absent.png") == nil)

        // Past the cap the oldest entries go, so an app that names a new path
        // every frame cannot grow this without bound.
        for index in 0..<(LedgeImageStore.capacity + 8) {
            _ = store.image(atPath: "/nonexistent/ledge/sheet-\(index).png")
        }
        #expect(store.image(atPath: sheet) != nil, "an evicted path is re-read, not lost")
    }
}
