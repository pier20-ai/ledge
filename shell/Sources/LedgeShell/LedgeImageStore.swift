import AppKit
import QuartzCore

/// Decoded file images for the `image` component (spec §5) and the `image` draw
/// op (§3.4), cached process-wide and shared by every canvas.
///
/// Apps build their paths from `import.meta.dir` (spec §6), so what arrives is
/// an absolute path to a file inside the app's own folder — a relative path
/// would resolve against the *shell's* working directory, which is nowhere near
/// the app, so it is refused rather than guessed at.
///
/// Three properties, in the order of how much they cost when missing:
///
/// - **Misses are cached too.** A path that does not resolve is the normal case
///   for a half-written app, and re-`stat`ing it every frame costs what a hit
///   costs without any of the benefit.
/// - **A file that changes is picked up.** The user regenerates a spritesheet
///   while the shell is running; needing a restart to see it would make this
///   cache a trap. Entries are revalidated against the file's modification time
///   — but at most once a second per path, so a 60 Hz blit pays one `stat` a
///   second instead of sixty.
/// - **It is bounded.** `capacity` entries, oldest inserted evicted first. A
///   spritesheet is megabytes decoded; an unbounded cache keyed by a string an
///   app chooses is a leak an app can drive.
///
/// `@unchecked Sendable` because the invariant is the lock, not the type: every
/// access to the two dictionaries goes through `entry(for:)`, which holds it.
final class LedgeImageStore: @unchecked Sendable {
    static let shared = LedgeImageStore()

    /// Enough for every spritesheet and artwork tile a handful of apps can have
    /// on screen at once. Past this, the oldest entry goes.
    static let capacity = 64
    /// How stale an entry may be before its file is re-`stat`ed.
    private static let revalidateAfter: CFTimeInterval = 1.0

    private struct Entry {
        /// nil = the path did not resolve; a miss is a cached answer, not a gap.
        var image: NSImage?
        /// Kept beside the `NSImage` because the draw op crops in pixels, and
        /// asking `NSImage` for one per frame is not free.
        var cgImage: CGImage?
        var modified: TimeInterval
        var checked: CFTimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Insertion order, oldest first — the eviction queue.
    private var order: [String] = []

    /// The decoded image at `path`, or nil if it does not resolve.
    func image(atPath path: String) -> NSImage? { entry(for: path).image }

    /// The same image as a `CGImage`, which is what the draw op crops and blits.
    func cgImage(atPath path: String) -> CGImage? { entry(for: path).cgImage }

    /// Forget everything. Only used by tests, which write a file, read it, and
    /// then write a different file to the same path faster than any revalidation
    /// window.
    func purge() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    private func entry(for path: String) -> Entry {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        if let cached = entries[path], now - cached.checked < Self.revalidateAfter {
            return cached
        }
        let modified = Self.modificationTime(of: path)
        if var cached = entries[path], cached.modified == modified {
            cached.checked = now
            entries[path] = cached
            return cached
        }

        let image = Self.load(path)
        let entry = Entry(
            image: image,
            cgImage: image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            modified: modified,
            checked: now
        )
        entries[path] = entry
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
        return entry
    }

    private static func load(_ path: String) -> NSImage? {
        // Absolute only (see above), and `isValid` because NSImage happily
        // hands back an empty image for a file that is not one.
        guard path.hasPrefix("/"), let image = NSImage(contentsOfFile: path), image.isValid else {
            return nil
        }
        return image
    }

    /// A missing file gets a stable sentinel rather than "now", so a miss stays
    /// a miss until the file actually appears. Only ever called on the slow
    /// path — at most once a second per path.
    private static func modificationTime(of path: String) -> TimeInterval {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let modified = attributes?[.modificationDate] as? Date else { return -1 }
        return modified.timeIntervalSinceReferenceDate
    }
}
