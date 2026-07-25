import Foundation

/// `ctx.capture()` — an interactive screenshot, taken by the shell (spec §6
/// extension). Same reasoning as `ctx.apple`: Screen Recording consent is per
/// process, and the process the user can recognize is the one with the notch.
/// The **first** capture therefore raises the system's Screen Recording prompt
/// attributed to Ledge; that is the intended behavior, not an accident.
///
/// The file is the shell's: a PNG in the user's temp directory, whose path is
/// handed to the app. Ledge never deletes it — an app that captured a boarding
/// pass may still be reading it a minute later, and temp cleanup is the OS's
/// job.
public final class ScreenCaptureExecutor: Sendable {
    /// Serial: `screencapture -i` takes over the whole screen, so a second one
    /// running underneath it would be a UI the user cannot make sense of.
    private let queue: DispatchQueue
    private let directory: URL

    public init(
        label: String = "com.ledge.shell.capture",
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.directory = directory
    }

    /// Capture asynchronously; `completion` fires on the executor's own queue
    /// with the PNG's path. Interactive capture waits for the user, so this can
    /// take as long as they take — there is deliberately no timeout here (the
    /// host has one, and it is generous).
    public func capture(
        interactive: Bool,
        completion: @escaping @Sendable (Result<String, CapabilityError>) -> Void
    ) {
        let destination = directory.appendingPathComponent("ledge-capture-\(UUID().uuidString).png")
        queue.async { completion(Self.run(interactive: interactive, destination: destination)) }
    }

    /// The testable core. `screencapture` exits non-zero when the user cancels
    /// an interactive selection (Esc), and — depending on the OS build — can
    /// also exit zero having written nothing, so both are checked.
    public static func run(interactive: Bool, destination: URL) -> Result<String, CapabilityError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = (interactive ? ["-i"] : []) + [destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return .failure(CapabilityError("could not run screencapture: \(error.localizedDescription)"))
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CapabilityError(message.isEmpty ? "capture cancelled" : message))
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return .failure(CapabilityError("capture cancelled"))
        }
        return .success(destination.path)
    }
}
