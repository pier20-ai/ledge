import Foundation

/// The golden protocol fixtures live in the repo at `protocol/fixtures`, shared
/// with the Bun host tests. They are read at test runtime via a path relative to
/// this source file so the corpus is never copied into the shell package.
enum Fixtures {
    /// `…/protocol/fixtures`, resolved from this file's location.
    static func directory(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        // …/Tests/LedgeShellCoreTests/Fixtures.swift → repo root, four levels up.
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("protocol/fixtures", isDirectory: true)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory().appendingPathComponent(name))
    }

    /// Every `.json` fixture file name (excludes the `.jsonl` builder stream).
    static func jsonNames() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory().path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }
}
