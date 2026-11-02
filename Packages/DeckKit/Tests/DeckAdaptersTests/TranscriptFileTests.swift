//
//  TranscriptFileTests.swift · Tests/DeckAdaptersTests
//
//  `TranscriptFile.tail(of:maxBytes:)` AND `.size(of:)`, against a REAL
//  file on disk — the one adapter test in this suite that is allowed to
//  touch the real filesystem, since it exists specifically to hold that
//  adapter to account (the whole point of `GitWorktree` having no sibling
//  test file is that `RecordingWorktree`, in `DeckAppTests`, already
//  stands in for it everywhere else; THIS adapter's own byte-boundary
//  behavior can only be proven against real seek/read semantics, not a
//  scripted port).
//

import Testing
import Foundation
import DeckCore
@testable import DeckAdapters

struct TranscriptFileTests {

    private func writeTemp(_ content: String) -> String {
        let path = NSTemporaryDirectory() + "transcript-file-test-\(UUID().uuidString).jsonl"
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("a tail read that happens to land on a clean line boundary reads normally")
    func cleanBoundaryReadsNormally() async throws {
        let line = #"{"type":"user","message":{"role":"user","content":"hello"}}"#
        let path = writeTemp(line + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let text = await TranscriptFile().tail(of: path, maxBytes: 4096)
        #expect(text == line + "\n")
    }

    @Test("a missing file reads as nil")
    func missingFileReadsAsNil() async {
        let text = await TranscriptFile().tail(of: "/does/not/exist/\(UUID().uuidString).jsonl", maxBytes: 4096)
        #expect(text == nil)
    }

    // ------------------------------------------------------------------ size(of:)

    /// **The backfill ladder's own first read, against a REAL file — the
    /// same reason this whole suite is allowed to touch the real
    /// filesystem.** `size(of:)` shares `tail(of:maxBytes:)`'s own
    /// `FileHandle.seekToEnd()` call; this holds it accountable as its
    /// own question, not merely as a side effect of a bigger one.
    @Test("size(of:) answers a real file's own exact byte count")
    func sizeAnswersTheRealFileByteCount() async {
        let content = #"{"type":"user","message":{"role":"user","content":"hello"}}"# + "\n"
        let path = writeTemp(content)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let size = await TranscriptFile().size(of: path)
        #expect(size == content.utf8.count,
                Comment(rawValue: "expected \(content.utf8.count), got \(String(describing: size))"))
    }

    @Test("a missing file's size reads as nil — the same collapsed failure tail(of:maxBytes:) already answers")
    func missingFileSizeReadsAsNil() async {
        let size = await TranscriptFile().size(of: "/does/not/exist/\(UUID().uuidString).jsonl")
        #expect(size == nil)
    }

    /// **A `maxBytes` seek that lands mid-
    /// character must not fail the WHOLE read.** Engineered precisely,
    /// not hoped for — the emoji's own UTF-8 byte range inside the
    /// leading (soon-to-be-truncated) line is located first, and
    /// `maxBytes` is computed so the seek offset falls exactly TWO bytes
    /// into that four-byte sequence, splitting it for real rather than
    /// merely landing "somewhere near" it.
    @Test("a tail read that splits a multibyte character survives — the truncated line is dropped, not the whole read")
    func splitMultibyteCharacterSurvives() async throws {
        let emoji = "🎉"   // U+1F389, 4 UTF-8 bytes — confirmed below, not assumed
        #expect(emoji.utf8.count == 4)

        let leadingLine = #"{"type":"user","message":{"role":"user","content":"an earlier prompt with "# + emoji
            + #" right in it"}}"#
        let survivingLine = #"{"type":"user","message":{"role":"user","content":"real prompt survives the split"}}"#
        let content = leadingLine + "\n" + survivingLine + "\n"
        let path = writeTemp(content)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let totalBytes = content.utf8.count
        let emojiRange = try #require(content.range(of: emoji))
        let emojiStartOffset = content.utf8.distance(from: content.utf8.startIndex, to: emojiRange.lowerBound)
        // Two bytes into the emoji's own four-byte sequence — genuinely
        // mid-character, not merely mid-line.
        let cutOffset = emojiStartOffset + 2
        let maxBytes = totalBytes - cutOffset

        let text = await TranscriptFile().tail(of: path, maxBytes: maxBytes)
        let raw = try #require(text, "a split multibyte character must not fail the whole read (the strict-decode regression this test guards)")

        // The truncated leading line decodes to replacement characters,
        // not valid JSON — `TranscriptTail`'s own leniency (confirmed
        // directly here, not merely cited) skips it as malformed, exactly
        // like any other line a bounded tail read can start mid-way
        // through. Only the fully-intact trailing line survives.
        let prompts = TranscriptTail.humanPrompts(fromJSONL: raw)
        #expect(prompts.map(\.value) == ["real prompt survives the split"],
                Comment(rawValue: "expected only the intact trailing line to survive a split-character tail — "
                        + "got \(prompts.map(\.value))"))
    }
}
