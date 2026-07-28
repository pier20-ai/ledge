import Foundation

/// First-run seeding of `~/.ledge` (spec §6: everything lives under `~/.ledge/`).
///
/// The bundle carries a `seed/` directory — the demo apps plus the shared
/// `node_modules` — and copies it out on first launch. After that `~/.ledge` is
/// the user's, and we never touch it again: these are their apps, edited by
/// their agent, and an installer that "restores" files over the top of that
/// would destroy work.
///
/// The `node_modules` copy is not a convenience. Apps resolve `react` from the
/// apps root, and so does the worker's reconciler (host/src/render/runtime.ts);
/// a compiled host carries no copy of its own. If seeding does not happen, every
/// app crashes on boot with "could not resolve react".
enum LedgeInstall {
    /// Overrides the install root (`--ledge-root`). Redirects seeding, the apps
    /// root and the host log together, so a test run can exercise the real
    /// first-launch path without writing into the user's actual `~/.ledge`.
    nonisolated(unsafe) static var rootOverride: String?

    /// `~/.ledge`, or `--ledge-root`.
    static var root: URL {
        if let rootOverride { return URL(fileURLWithPath: rootOverride) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ledge")
    }

    static var appsRoot: URL { root.appendingPathComponent("apps") }
    static var logURL: URL { root.appendingPathComponent("host.log") }

    /// The seed archive inside the bundle, or nil for a dev build. A tarball
    /// rather than a directory because codesign refuses a bundle containing
    /// symlinks that escape it, and node_modules is full of them (see
    /// scripts/bundle-app.sh).
    private static var seedArchive: URL? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/seed.tar.gz")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copy anything from the seed that isn't already there. Returns false only
    /// when the install is unusable (no apps root), which the caller surfaces —
    /// a silently empty Ledge is worse than a visible complaint.
    @discardableResult
    static func seedIfNeeded() -> Bool {
        let manager = FileManager.default
        guard let seedArchive else {
            // Dev build: `--apps-root` points at the repo, nothing to seed.
            return manager.fileExists(atPath: appsRoot.path)
        }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            NSLog("[ledge] could not create %@: %@", root.path, String(describing: error))
            return false
        }

        // Each half is seeded INDEPENDENTLY. They are two halves of one install —
        // apps without node_modules is ten apps that all crash on "could not
        // resolve react" — but that is a reason to check both, not a reason to
        // restore both. Extracting the whole archive because node_modules was
        // missing would untar `apps/` over the top of the user's own edited
        // apps, and "we never touch your apps after the first launch" is the
        // promise this file exists to keep.
        let modulesRoot = root.appendingPathComponent("node_modules")
        var seeded: [String] = []
        for (member, destination) in [("apps", appsRoot), ("node_modules", modulesRoot)] {
            guard needsSeeding(destination, manager: manager) else { continue }
            if extract(seedArchive, member: member, into: root) {
                seeded.append(member)
            } else {
                NSLog("[ledge] could not expand '%@' from the seed archive", member)
            }
        }
        if !seeded.isEmpty {
            NSLog("[ledge] seeded %@", seeded.joined(separator: " + "))
        }
        return manager.fileExists(atPath: appsRoot.path)
    }

    /// Expand ONE top-level member of the seed tarball into `destination`.
    ///
    /// Deliberately not Foundation: there is no unarchiver in the SDK for
    /// tar.gz, and tar restores the symlinks and modes inside node_modules
    /// correctly, which a hand-rolled copy would not.
    ///
    /// Naming the member is what keeps seeding surgical — see `seedIfNeeded`.
    private static func extract(_ archive: URL, member: String, into destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path, member]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[ledge] could not run tar: %@", String(describing: error))
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// True when `destination` is absent **or an empty directory**.
    ///
    /// "Exists" is the wrong question. An early `~/.ledge/apps` left behind by a
    /// dev run is an empty directory, and treating that as installed produces
    /// the worst possible first launch: a Ledge with no apps, no error, and
    /// nothing to suggest that seeding was skipped. An empty directory holds no
    /// user work, so filling it destroys nothing.
    static func needsSeeding(_ destination: URL, manager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
            return true
        }
        guard isDirectory.boolValue else { return false }
        let contents = (try? manager.contentsOfDirectory(atPath: destination.path)) ?? []
        // .DS_Store and friends don't count as content.
        return contents.allSatisfy { $0.hasPrefix(".") }
    }
}
