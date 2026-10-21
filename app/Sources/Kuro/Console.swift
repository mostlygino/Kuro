import Foundation
import Observation

/// The live output pane: what Kuro is running, as it runs. Every install,
/// start, check and update goes through here, so nothing happens out of sight.
@MainActor @Observable
final class Console {
    enum Kind { case command, output, success, failure, note }

    struct Line: Identifiable {
        let id = UUID()
        let kind: Kind
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var isRunning = false
    /// When set, commands are not run: the script plays instead. `--demo`.
    var script: ((String, [String]) -> [String])?

    func clear() { lines.removeAll() }

    func note(_ text: String) { lines.append(Line(kind: .note, text: text)) }

    /// Runs one command, streaming its output, and says how it ended.
    @discardableResult
    func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
             title: String? = nil) async -> Bool {
        isRunning = true
        defer { isRunning = false }
        let shown = title ?? ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        lines.append(Line(kind: .command, text: shown))

        if let script {
            for text in script(executable, arguments) {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 60...240)))
                append(text)
            }
            lines.append(Line(kind: .success, text: "Done"))
            return true
        }

        let status = await stream(executable, arguments, in: directory)
        if status == 0 {
            lines.append(Line(kind: .success, text: "Done"))
        } else {
            lines.append(Line(kind: .failure, text: "Stopped with exit status \(status)"))
        }
        return status == 0
    }

    private func append(_ text: String) {
        for raw in text.withoutTerminalCodes.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append(Line(kind: .output, text: line))
        }
        // A long brew install should not grow without end.
        if lines.count > 1500 { lines.removeFirst(lines.count - 1500) }
    }

    private func stream(_ executable: String, _ arguments: [String], in directory: URL?) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = Shell.environment
            if let directory { process.currentDirectoryURL = directory }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let pending = Collected()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                pending.append(data)
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.append(text) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                let status = finished.terminationStatus
                Task { @MainActor [weak self] in
                    if !rest.isEmpty { self?.append(String(decoding: rest, as: UTF8.self)) }
                    continuation.resume(returning: status)
                }
            }
            do {
                try process.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.lines.append(Line(kind: .failure, text: error.localizedDescription))
                    continuation.resume(returning: -1)
                }
            }
        }
    }
}
