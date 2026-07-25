import Foundation

/// AppleScript + Shortcuts execution (spec §6, `ctx.apple`). This runs in the
/// **shell** process and nowhere else, for one reason: macOS attributes an
/// Automation / Shortcuts consent prompt to the process that asked, and a Bun
/// worker is a faceless thread the user has no way to recognize or approve. The
/// shell is the process with the icon, so the shell is the process that asks.
///
/// Both paths run off the main queue: an AppleScript that drives another app can
/// block for seconds, and the notch must keep animating while it does.
public final class AppleExecutor: Sendable {
    /// Serial on purpose: two concurrent AppleScripts are two concurrent Apple
    /// events into the same target, which is a good way to get a timeout instead
    /// of a result. Per-app serialization also lives host-side (one in-flight
    /// bridge call at a time is not enforced there, but ordering here is).
    private let queue: DispatchQueue

    public init(label: String = "com.ledge.shell.apple") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Execute asynchronously; `completion` fires on the executor's own queue.
    public func run(
        _ invocation: AppleInvocation,
        completion: @escaping @Sendable (Result<JSONValue, CapabilityError>) -> Void
    ) {
        queue.async { completion(Self.execute(invocation)) }
    }

    /// Synchronous execution — the testable core. Never call it on the main
    /// queue in the running shell.
    public static func execute(_ invocation: AppleInvocation) -> Result<JSONValue, CapabilityError> {
        switch invocation {
        case let .script(source):
            return runScript(source)
        case let .shortcut(name, input):
            return runShortcut(name: name, input: input)
        }
    }

    // MARK: - AppleScript

    private static func runScript(_ source: String) -> Result<JSONValue, CapabilityError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(CapabilityError("could not compile the AppleScript"))
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
                ?? "AppleScript failed"
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            return .failure(CapabilityError(number.map { "\(message) (\($0))" } ?? message))
        }
        return .success(json(from: descriptor))
    }

    /// Best-effort descriptor → JSON. AppleScript's type system is bigger than
    /// JSON's, so the rule is: keep the shapes JSON has (bool / number / list /
    /// nothing) and let everything else arrive as the string AppleScript itself
    /// would have shown — an app gets a usable value from `return 1 + 2`,
    /// `return {1, 2}` and `return name of window 1` alike, and never a null it
    /// has to guess about.
    public static func json(from descriptor: NSAppleEventDescriptor) -> JSONValue {
        switch descriptor.descriptorType {
        case typeAEList:
            // AEDesc lists are 1-based, and an empty list is a real answer.
            let items = stride(from: 1, through: descriptor.numberOfItems, by: 1)
                .compactMap { descriptor.atIndex($0) }
                .map { json(from: $0) }
            return .array(items)
        case typeAERecord:
            // Records carry four-char-code keys; there is no faithful JSON for
            // them, so an app that wants structure should build a string in the
            // script. Fall through to the description rather than inventing keys.
            return .string(descriptor.stringValue ?? String(describing: descriptor))
        case typeTrue, typeFalse, typeBoolean:
            return .bool(descriptor.booleanValue)
        case typeSInt16, typeSInt32, typeUInt16, typeUInt32, typeSInt64, typeUInt64:
            return .int(Int(descriptor.int32Value))
        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint, type128BitFloatingPoint:
            return .double(descriptor.doubleValue)
        case typeNull:
            return .null
        default:
            if let string = descriptor.stringValue { return .string(string) }
            return .null
        }
    }

    // MARK: - Shortcuts

    private static func runShortcut(name: String, input: JSONValue?) -> Result<JSONValue, CapabilityError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        // `-i -` makes the Shortcut read its input from our stdin, which is the
        // only way to pass a value without writing a file we would then own.
        process.arguments = input == nil ? ["run", name] : ["run", name, "-i", "-"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(CapabilityError("could not run /usr/bin/shortcuts: \(error.localizedDescription)"))
        }

        if let input {
            let data: Data = if case let .string(text) = input {
                Data(text.utf8)                               // a string is itself
            } else {
                (try? JSONEncoder().encode(input)) ?? Data()  // anything else is JSON
            }
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CapabilityError(
                message.isEmpty
                    ? "shortcut '\(name)' exited with status \(process.terminationStatus)"
                    : message
            ))
        }
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(text.isEmpty ? .null : .string(text))
    }
}
