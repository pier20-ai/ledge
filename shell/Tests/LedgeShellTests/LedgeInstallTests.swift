import CryptoKit
import Foundation
import Testing
@testable import LedgeShell

/// First-run seeding of `~/.ledge`.
///
/// The property under test is a promise to the user: **after the first launch,
/// Ledge never writes over your apps.** They are edited by the user and by their
/// agent, so an installer that "restores" a demo app on top of one is not a
/// cosmetic bug, it is lost work.
@Suite("Install seeding")
struct LedgeInstallTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A missing directory needs seeding")
    func missingNeedsSeeding() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("apps")
        #expect(LedgeInstall.needsSeeding(absent, manager: .default))
    }

    /// A dev run leaves an empty `~/.ledge/apps` behind. Treating "exists" as
    /// "installed" produced the worst possible first launch: a Ledge with no
    /// apps, no error, and nothing to say seeding had been skipped.
    @Test("An empty directory needs seeding; dotfiles are not content")
    func emptyNeedsSeeding() throws {
        let manager = FileManager.default
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }

        let apps = root.appendingPathComponent("apps")
        try manager.createDirectory(at: apps, withIntermediateDirectories: true)
        #expect(LedgeInstall.needsSeeding(apps, manager: manager))

        try Data().write(to: apps.appendingPathComponent(".DS_Store"))
        #expect(LedgeInstall.needsSeeding(apps, manager: manager))
    }

    /// The P1 this suite exists for. A populated apps directory must report that
    /// it needs nothing — seeding used to extract the WHOLE archive whenever
    /// either half was missing, so a missing node_modules untarred `apps/` over
    /// the user's own edited apps.
    @Test("A directory holding user work never needs seeding")
    func populatedIsLeftAlone() throws {
        let manager = FileManager.default
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }

        let apps = root.appendingPathComponent("apps")
        try manager.createDirectory(
            at: apps.appendingPathComponent("stocks"),
            withIntermediateDirectories: true
        )
        try "// my own edited app".write(
            to: apps.appendingPathComponent("stocks/app.jsx"),
            atomically: true,
            encoding: .utf8
        )

        #expect(!LedgeInstall.needsSeeding(apps, manager: manager))
        // …and the other half is judged independently, which is what stops one
        // missing piece from restoring the other.
        #expect(LedgeInstall.needsSeeding(root.appendingPathComponent("node_modules"), manager: manager))
    }

    @Test("A file where a directory belongs is not seeded over")
    func fileIsNotSeeded() throws {
        let manager = FileManager.default
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent("apps")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)
        #expect(!LedgeInstall.needsSeeding(file, manager: manager))
    }

    /// **The Settings app is retired, surgically.**
    ///
    /// Settings is a native window now, so an installation that still has the
    /// old app folder would keep showing a dead session in the strip — the host
    /// registers by scanning for `app.jsx`, and that app's switches no longer
    /// reach anything. So it is deleted on upgrade, but *only* if we wrote it.
    ///
    /// The question is the same one this decided when it was
    /// `settingsNeedsRefresh` ("did Ledge ship these exact bytes?"); only the
    /// consequence changed, from overwrite to remove. Which makes the negative
    /// cases the important ones: an edited file is somebody's work, and an
    /// unreadable one cannot be proven to be ours.
    @Test("The Settings app is retired only when it is byte-for-byte ours")
    func settingsRetirementIsSurgical() throws {
        let manager = FileManager.default
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        let entry = root.appendingPathComponent("apps/settings/app.jsx")

        // Nothing there is nothing to remove — and, unlike the old refresh
        // check, that now means "not ours" rather than "go ahead".
        #expect(!LedgeInstall.settingsIsOurs(entry, manager: manager))

        try manager.createDirectory(
            at: entry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let shipped = Data("the exact old Settings source".utf8)
        try shipped.write(to: entry)
        let digest = SHA256.hash(data: shipped).map { String(format: "%02x", $0) }.joined()
        #expect(LedgeInstall.settingsIsOurs(
            entry,
            manager: manager,
            legacyDigests: [digest]
        ))

        // Somebody edited it. That is their app now: it stays, and it is an
        // ordinary session like any other.
        try "// user edited Settings".write(to: entry, atomically: true, encoding: .utf8)
        #expect(!LedgeInstall.settingsIsOurs(
            entry,
            manager: manager,
            legacyDigests: [digest]
        ))
    }

    /// Every source Ledge ever shipped has to be in the digest set, including
    /// the *last* one — which is the version nearly every real installation is
    /// actually running. Missing it would make the retirement a no-op on exactly
    /// the machines that need it, which has happened before (see the note on
    /// `legacySettingsDigests`).
    @Test("The final shipped Settings app is recognised as ours")
    func theLastShippedSettingsIsKnown() throws {
        let archived = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()      // LedgeShellTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // shell
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("protocol/demo-apps-archive/settings-app/app.jsx")

        let manager = FileManager.default
        try #require(
            manager.fileExists(atPath: archived.path),
            "the archived Settings app moved — update this path and the digest"
        )
        #expect(LedgeInstall.settingsIsOurs(archived, manager: manager))
    }
}
