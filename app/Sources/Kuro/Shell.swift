import Foundation

/// Runs Kuro's own scripts and the tools it drives. Always an executable and an
/// argument list, never a shell string: nothing typed into the app can turn
/// into a command. The environment carries Homebrew's paths, which an app
/// started from the Finder does not have.
enum Shell {
    static let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path + ":" + (env["PATH"] ?? "")
        env["TERM"] = "dumb"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["NONINTERACTIVE"] = "1"
        // The app is not an agent: its own `open` calls stay where the user is.
        env["KURO_AGENT_OPEN"] = "off"
        // install.sh builds this app; not while this app is the one running it.
        env["KURO_APP_RUNNING"] = "1"
        return env
    }

    /// Finds a tool by name on the paths above.
    static func which(_ name: String) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    struct Result: Sendable {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Runs to the end and returns everything it printed. For quick questions
    /// (`pgrep`, `git status`), not for installs: those stream (`Console`).
    static func capture(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                        timeout: TimeInterval = 20) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            if let directory { process.currentDirectoryURL = directory }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let collected = Collected()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: Result(status: finished.terminationStatus, output: collected.text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// True when a process of exactly this name is running.
    static func running(_ name: String) async -> Bool {
        await capture("/usr/bin/pgrep", ["-xq", name], timeout: 5).ok
    }
}

/// Bytes from a pipe, gathered across threads.
final class Collected: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

extension String {
    /// Terminal colour codes out, so `install.sh`'s `==>` lines read as text.
    var withoutTerminalCodes: String {
        replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
