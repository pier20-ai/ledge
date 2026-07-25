import Foundation
import LedgeShellCore

/// Shared golden fixtures, read from the repo relative to this file (see the
/// Core test target's copy — kept per-target so neither imports the other).
enum Fixtures {
    static func directory(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        // …/Tests/LedgeShellTests/Fixtures.swift → repo root, four levels up.
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("protocol/fixtures", isDirectory: true)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory().appendingPathComponent(name))
    }

    /// One golden fixture decoded as an envelope, ready to inject.
    static func envelope(_ name: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data(name))
    }
}
