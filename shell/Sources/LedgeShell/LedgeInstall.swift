import CryptoKit
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
    /// Exact historical Settings sources that were shipped as inert pictures.
    ///
    /// Settings is shell-owned chrome in practice — the only in-app route to
    /// Quit, Permissions, and app management — but it lives beside user apps so
    /// the host can render it through the same protocol. That makes upgrades a
    /// narrow migration problem: replace only a source Ledge itself shipped,
    /// identified byte-for-byte, and leave every edited variant alone.
    static let legacySettingsDigests: Set<String> = [
        // 790668b: inert Settings mockup.
        "2cb03dc92cf9f0c82eb95a2b43c0b96f61f5abc97f9c44ff048ffbfd64e988db",
        // 33a5e62: working app toggles and Quit, but no route back to Permissions.
        "8e55f92d07814ed65d893b9dc71b274e3e3144095d6a0d6238233ab87f9ef10f",
        // c492b16..HEAD: Permissions called the obsolete ctx.platform API.
        "41d6114988791705aa95a6cc5b2fa9c613d7bf8e5636f21391c372c6a01a8d4d",
    ]

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

    /// The "we have introduced ourselves" marker (see `PermissionsCardView`).
    ///
    /// A file rather than `UserDefaults` for one reason that matters here: it
    /// lives under `--ledge-root`, so a smoke test or a snapshot run gets a
    /// genuine first launch without touching the user's, and clearing it is
    /// `rm ~/.ledge/.onboarded` rather than a `defaults` incantation.
    static var onboardedMarker: URL { root.appendingPathComponent(".onboarded") }

    /// Whether the first-run permission surface has already been shown.
    ///
    /// Written when it is *presented*, not when the user finishes with it: there
    /// is nothing to finish, dismissing is a legitimate answer, and a marker
    /// that only lands on "Done" would re-open the panel on every launch until
    /// the user pressed a button they were entitled to ignore.
    static var hasOnboarded: Bool {
        FileManager.default.fileExists(atPath: onboardedMarker.path)
    }

    static func markOnboarded() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: onboardedMarker)
        } catch {
            // Not fatal, and deliberately not retried: the cost of failing is
            // that the surface appears again next launch, which is a nuisance,
            // not a broken install.
            NSLog("[ledge] could not write %@: %@", onboardedMarker.path, String(describing: error))
        }
    }

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

        // Settings is the one app an upgrade may have to restore. Older bundles
        // seeded an inert mockup or a Settings implementation with no working
        // route to Permissions, and this release removes the menu-bar escape
        // hatch because the real Settings app owns Quit and Permissions. Keeping
        // one of those exact old files would strand an existing installation.
        //
        // A digest, not a marker comment: an agent may have edited the old source
        // without removing its header. Only the exact bytes Ledge shipped are
        // replaceable; anything else is user work and remains untouched.
        let settingsEntry = appsRoot.appendingPathComponent("settings/app.jsx")
        if settingsNeedsRefresh(settingsEntry, manager: manager) {
            if extract(seedArchive, member: "apps/settings/app.jsx", into: root) {
                NSLog("[ledge] installed current Settings app")
            } else {
                NSLog("[ledge] could not refresh the Settings app")
            }
        }

        // The DOCS are replaced on every launch, unlike everything else here.
        //
        // They are not the user's files and never were: they are how this version
        // of Ledge describes itself to the agent editing an app, and an install
        // from six months ago would otherwise keep handing out six-month-old
        // documentation forever — for surfaces that have since changed and
        // commands that did not exist when it was written. The failure mode is
        // silent and expensive: the agent believes it, goes looking for things
        // that are not there, and burns a turn finding out.
        //
        // Safe precisely because nobody edits it. Anything a user or an agent
        // writes lives in an app's own folder, and every other member here is
        // still restored only when it is missing.
        for doc in ["apps/AGENTS.md", "apps/REFERENCE.md"] where !extract(seedArchive, member: doc, into: root) {
            NSLog("[ledge] could not refresh %@ from the seed archive", doc)
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

    /// Whether the shell-owned Settings entry may safely be installed.
    ///
    /// Missing is safe. Unreadable is not: inability to prove a file is ours is
    /// never permission to overwrite it.
    static func settingsNeedsRefresh(
        _ entry: URL,
        manager: FileManager,
        legacyDigests: Set<String> = legacySettingsDigests
    ) -> Bool {
        guard manager.fileExists(atPath: entry.path) else { return true }
        guard let data = try? Data(contentsOf: entry) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return legacyDigests.contains(digest)
    }
}
