//
//  ConfigFile.swift · DeckAdapters/Files
//
//  The only module allowed to know where `~/.claude` is.
//
//  It executes a `[WriteStep]` and never a document. That split is what makes
//  the atomic-write rule testable: the *ordering* is decided in `DeckCore`,
//  where a test can read it, and only the syscalls happen here.
//

import Foundation
import DeckCore
import DeckPorts

public struct ConfigFile: ConfigPort {
    public let path: String

    public init(path: String? = nil) {
        self.path = path ?? NSHomeDirectory() + "/.claude/settings.json"
    }

    public func read() async -> ConfigDocument {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .unreadable("the file exists but could not be opened — check its permissions")
        }
        // An empty file is not a broken one. `touch ~/.claude/settings.json`
        // is a thing people do, and treating it as corrupt would refuse an
        // install that is perfectly safe.
        if data.isEmpty || String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .absent
        }
        guard let value = JSONValue.parse(data) else {
            return .unreadable("the file is not valid JSON, so the deck cannot merge into it "
                               + "without replacing what is already there")
        }
        return .present(value)
    }

    public func apply(_ steps: [WriteStep]) async throws {
        for step in steps {
            switch step {
            case .backup(let from, let to):
                // A backup of a file that does not exist yet is not an error —
                // installing onto a machine with no settings at all is the
                // commonest case there is.
                if FileManager.default.fileExists(atPath: from) {
                    try? FileManager.default.removeItem(atPath: to)
                    try FileManager.default.copyItem(atPath: from, toPath: to)
                }
            case .writeTemp(let temp, let contents):
                try FileManager.default.createDirectory(
                    atPath: (temp as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: URL(fileURLWithPath: temp), options: .atomic)
            case .rename(let from, let to):
                // The atomic half. `replaceItemAt` is rename(2) underneath,
                // so a crash here leaves either the old file or the new one,
                // never a half-written document.
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: to),
                                                          withItemAt: URL(fileURLWithPath: from))
            case .truncateAndWrite:
                // Unreachable by construction: `WritePlan` never emits one, and
                // `WritePlan.violations` fails any plan that does. Refused here
                // as well, because a boundary that trusts its caller is a
                // boundary that stops being one after a refactor.
                throw PortFailure.refused("a truncating write reached the config adapter")
            }
        }
    }
}
