//
//  TranscriptFile.swift · DeckAdapters/Files
//
//  The transcript-well backfill's file read: bounded, and the ONLY place in
//  the program that opens a session's own `.jsonl` transcript.
//  `TranscriptTail` (DeckCore) decides what the bytes MEAN; this decides
//  which bytes it gets to look at.
//
//  Reads are bounded to the last `maxBytes`, seeking rather than reading the
//  whole file (as `GitWorktree` does with two small reads instead of a `git`
//  invocation): a long session's transcript can run to many megabytes, and
//  the well renders only a few lines. `FileHandle.seekToEnd()` finds the size
//  without reading, and `seek(toOffset:)` jumps straight to the tail.
//
//  The bounds form a ladder. `DeckRuntime.seedTranscript(for:path:)` reads
//  the current size once via `size(of:)`, hands it to
//  `TranscriptTail.backfillWindows(fileSize:)` (DeckCore plans the
//  escalation; this adapter only supplies the filesystem fact), and calls
//  `tail(of:maxBytes:)` once per rung until enough prompts surface or the
//  ladder runs out. The trigger in `DeckRuntime.handle(_:)` still fires once
//  per session per launch, but a busy session can cost several reads here.
//

import Foundation
import DeckPorts

/// An actor, so the read happens off the caller's executor. `DeckRuntime`
/// is `@MainActor`, and a non-isolated `async` method on a plain `struct`
/// would still run on the caller's executor (see `GitWorktree`).
public actor TranscriptFile: TranscriptFilePort {

    public init() {}

    /// The backfill ladder's first read: `FileHandle.seekToEnd()` alone, the
    /// same call `tail(of:maxBytes:)` makes to find where to start. Uses
    /// `Int(exactly:)` because `seekToEnd()` returns a `UInt64` and a
    /// trapping conversion would break `TranscriptFilePort`'s rule that nil
    /// is a real answer, never a crash.
    public func size(of path: String) async -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        return Int(exactly: size)
    }

    public func tail(of path: String, maxBytes: Int) async -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return nil
        }
        let bound = UInt64(max(0, maxBytes))
        let start = size > bound ? size - bound : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd() else { return nil }
        // Lossy, not strict: the seek can land mid-character, which is
        // expected. `String(data:encoding:)` would fail the whole decode on
        // one split multibyte sequence and lose the entire backfill for any
        // non-ASCII transcript. `String(decoding:as:)` turns it into U+FFFD
        // in the partial leading line, which `TranscriptTail` already skips
        // as malformed ("a tail read may start mid-line").
        return String(decoding: data, as: UTF8.self)
    }
}
