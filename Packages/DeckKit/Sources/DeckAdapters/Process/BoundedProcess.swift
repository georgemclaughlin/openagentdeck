//
//  BoundedProcess.swift · DeckAdapters/Process
//
//  Running a child process without betting the deck on it finishing.
//
//  Used by the adapters that shell out (`CmuxHost`, `FleetCLI`). The naive
//  pattern is wrong in two ways:
//
//      let stdout = out.fileHandleForReading.readDataToEndOfFile()
//      let stderr = err.fileHandleForReading.readDataToEndOfFile()
//      process.waitUntilExit()
//
//  Pipe deadlock: stdout is drained to EOF before stderr is touched. A child
//  that writes more than a pipe buffer (~64 KB) to stderr before closing
//  stdout blocks on stderr while the deck blocks on stdout. Neither can move.
//
//  No deadline: `waitUntilExit()` waits as long as the child takes. That does
//  not block the main thread (the adapters' `async` methods are nonisolated),
//  but it blocks a cooperative-pool thread, and that pool is about as wide as
//  the core count. A wedged child plus a periodic poll starves it, and then
//  every `await` in the app stops progressing, including ones answering a
//  hook someone is waiting on.
//
//  So: both pipes drained concurrently, a real deadline with escalation, a
//  cap on what is kept, and the blocking moved onto a queue of its own.
//

import Foundation
import DeckPorts

enum BoundedProcess {

    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Where the blocking happens. A queue of its own rather than
    /// `DispatchQueue.global()`, so a wedged child is visible by name in a
    /// sample and cannot be confused with unrelated work.
    private static let queue = DispatchQueue(label: "deck.process", attributes: .concurrent)

    /// How much of a child's output is kept. Past this the reader keeps
    /// draining, so the child never blocks on a full pipe, and stops
    /// appending.
    static let outputCap = 1 << 20

    /// Run a process, or say why not. Never waits longer than `timeout`.
    static func run(executable: String, arguments: [String],
                    timeout: TimeInterval) async -> Result<Output, PortFailure> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: runSync(executable: executable,
                                                       arguments: arguments,
                                                       timeout: timeout))
            }
        }
    }

    private static func runSync(executable: String, arguments: [String],
                                timeout: TimeInterval) -> Result<Output, PortFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return .failure(.unavailable("could not run \(executable): \(error.localizedDescription)"))
        }

        // Both pipes at once, so neither reader waits on the other.
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [Bool: Data] = [:]
        for (handle, isOut) in [(out.fileHandleForReading, true),
                                (err.fileHandleForReading, false)] {
            group.enter()
            queue.async {
                let data = drain(handle)
                lock.lock(); collected[isOut] = data; lock.unlock()
                group.leave()
            }
        }

        // Escalating, because `terminate()` is only a request; a child
        // ignoring SIGTERM must not leave this waiting forever.
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if group.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                // If the readers are still not done after a KILL, no further
                // waiting will help; report rather than hang.
                _ = group.wait(timeout: .now() + 1)
            }
        }
        process.waitUntilExit()

        lock.lock()
        let stdout = String(decoding: collected[true] ?? Data(), as: UTF8.self)
        let stderr = String(decoding: collected[false] ?? Data(), as: UTF8.self)
        lock.unlock()

        if timedOut {
            return .failure(.unavailable(
                "\((executable as NSString).lastPathComponent) did not answer within "
                + "\(Int(timeout))s and was stopped"))
        }
        return .success(Output(stdout: stdout, stderr: stderr,
                               status: process.terminationStatus))
    }

    /// Read to EOF, keeping at most `outputCap` bytes but never stopping
    /// early. Stopping early would close the read end and hand the child a
    /// SIGPIPE for output it was entitled to finish writing.
    private static func drain(_ handle: FileHandle) -> Data {
        var kept = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if kept.count < outputCap {
                kept.append(chunk.prefix(outputCap - kept.count))
            }
        }
        return kept
    }
}
