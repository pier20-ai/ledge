import AppKit
import Foundation
import Testing
@testable import LedgeShell

/// Why the panel says there is no host.
///
/// This exists because of a real hour lost: Ledge.app sat in ~/Applications from
/// a build that predates the bundled host, Spotlight launched that one in
/// preference to the new one, and the panel said `cd host && bun run start` —
/// a developer's command, in a shipped app, for a repository the reader may not
/// have. The actual cause was written to NSLog, where nobody looks.
///
/// The property under test is narrow and worth keeping: **the card's words match
/// the reason**, and no reason produces the developer hint except a developer
/// build.
@MainActor
@Suite("Why there is no host")
struct HostStatusTests {

    @Test("A bundle with no host in it says so, and says it is replaceable")
    func incompleteBundleExplainsItself() {
        let detail = AppDelegate.hostDetail(for: .bundleIncomplete("no ledge-host in Ledge.app"))
        #expect(detail.contains("no host"))
        #expect(detail.contains("ledge-host"))
        // The remedy, because waiting is not one.
        #expect(detail.lowercased().contains("replace"))
        // And NOT the thing it used to say to everyone.
        #expect(!detail.contains("bun run start"))
    }

    @Test("Only a developer build gets the developer's command")
    func onlyDevBuildGetsTheDevHint() {
        #expect(AppDelegate.hostDetail(for: .developerBuild).contains("bun run start"))
        for status: HostStatus in [
            .starting,
            .bundleIncomplete("no host sources in Ledge.app"),
            .failed("it stopped 5 times — see ~/.ledge/host.log"),
        ] {
            #expect(!AppDelegate.hostDetail(for: status).contains("bun run start"), "\(status)")
        }
    }

    @Test("A host that gave up points at the log rather than at nothing")
    func failureNamesTheLog() {
        let detail = AppDelegate.hostDetail(for: .failed("it stopped 5 times — see ~/.ledge/host.log"))
        #expect(detail.contains("host.log"))
    }

    /// `locateHost` is what decides which of those the user gets, and it decided
    /// wrong for the case that actually happened — an .app containing only the
    /// shell binary. Asserted against a real directory layout rather than a
    /// mock, because the thing being tested IS the layout.
    @Test("An .app with only the shell in it is incomplete, not a dev build")
    func locateHostTellsTheCasesApart() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-locate-\(UUID().uuidString)")
        let app = base.appendingPathComponent("Ledge.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Exactly what was in ~/Applications: the shell, and nothing else.
        let shellBinary = macOS.appendingPathComponent("LedgeShell")
        try Data("#!/bin/sh\n".utf8).write(to: shellBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellBinary.path)

        let bundle = try #require(Bundle(url: app))
        guard case .incomplete(let what) = HostProcess.locateHost(bundle: bundle) else {
            Issue.record("an .app with no host should be incomplete")
            return
        }
        #expect(what.contains("ledge-host"))

        // A directory that is not a bundle at all is the dev loop, which starts
        // its own host on purpose.
        let plain = try #require(Bundle(url: base))
        #expect(HostProcess.locateHost(bundle: plain) == .developerBuild)
    }

    /// The wording is only worth anything if it reaches the card. The phase
    /// carries the string now, so a change to it has to rebuild a view that is
    /// otherwise cached by phase — the exact kind of thing that silently does
    /// nothing.
    @Test("The detail reaches the card's own text")
    func detailReachesTheCard() {
        let card = HostPlaceholderView(
            phase: .noHost(detail: "This copy has no host (no ledge-host in Ledge.app).")
        )
        card.layoutSubtreeIfNeeded()
        #expect(Self.allText(in: card).contains { $0.contains("no ledge-host") })
        // And the phase compares by its contents, which is what makes the cache
        // rebuild rather than hand back the previous card.
        #expect(HostPlaceholderView.Phase.noHost(detail: "a") != .noHost(detail: "b"))
    }

    /// Every string drawn anywhere in a view tree.
    private static func allText(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        for child in view.subviews { found.append(contentsOf: allText(in: child)) }
        return found
    }
}