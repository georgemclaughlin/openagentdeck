//
//  GitWorktree.swift · DeckAdapters/Files
//
//  The filesystem half of the derived-fails-to-nothing rule: a non-git `cwd`
//  renders no branch, never a placeholder. The rule itself is
//  `Derived.branch` in the core; this is the part that has to go and look.
//
//  It reads files; it does not run `git`. Spawning a process per hook event
//  would put an execve between a `PreToolUse` arriving and the deck answering
//  it, the one path with a human waiting. Two small reads answer the
//  question and cannot hang on a lock the way `git` can in a busy repository.
//
//  It also never writes. The deck writes `~/.claude` only through the config
//  adapter, and a component that only asks a question about the user's
//  repository has no reason to hold a write handle.
//

import Foundation
import DeckCore
import DeckPorts

/// An actor, so the walk happens off the caller's executor.
///
/// `DeckRuntime` is `@MainActor`, and a `struct` whose `async` methods carry
/// no isolation of their own runs them on the caller's executor, which would
/// put a filesystem walk on the main thread once per hook. Making the adapter
/// an actor is what makes the port's `async` real.
public actor GitWorktree: WorktreePort {

    public init() {}

    public func branch(at path: String) async -> String? {
        guard let root = gitRoot(from: path) else { return nil }
        // `Derived.branch` is the arbiter: this gathers evidence, the core
        // decides what may be shown.
        return Derived.branch(cwd: path, head: head(in: root), gitRoot: root)
    }

    /// Walk up until something looks like a repository, or the walk runs out.
    ///
    /// Bounded by construction: each step is strictly shorter than the last
    /// and the loop stops at the root, so a symlink cycle cannot spin it.
    func gitRoot(from path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            let dotGit = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: dotGit.path) { return current.path }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// `.git` is a directory in a normal clone and a *file* in a worktree or a
    /// submodule, where it holds `gitdir: <path>`. Both are read so the branch
    /// row works across worktrees.
    func head(in root: String) -> String? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var gitDir = dotGit
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue {
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                  let target = Self.gitdir(from: pointer) else { return nil }
            gitDir = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: root))
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"),
                                     encoding: .utf8) else { return nil }
        return Self.refName(from: head)
    }

    static func gitdir(from pointer: String) -> String? {
        let line = pointer.split(separator: "\n").first.map(String.init) ?? pointer
        guard line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// `ref: refs/heads/feature/x` -> `feature/x`.
    ///
    /// A detached head holds a bare object id instead. That is not a branch
    /// and must not be rendered as one.
    static func refName(from head: String) -> String? {
        let line = head.split(separator: "\n").first.map(String.init) ?? head
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref:") else { return nil }
        let ref = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
        guard ref.hasPrefix("refs/heads/") else { return nil }
        let name = String(ref.dropFirst("refs/heads/".count))
        return name.isEmpty ? nil : name
    }
}
