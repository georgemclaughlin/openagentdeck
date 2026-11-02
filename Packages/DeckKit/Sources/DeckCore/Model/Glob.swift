//
//  Glob.swift · DeckCore/Model
//
//  Whether a stored pattern names the directory a session is sitting in.
//
//  Example: "show a `/status` action only on `*/bravo*` sessions." One
//  question, decided once, here: every reader of `QuickAction.Scope.folders(_:)`
//  (`QuickAction.shows(in:)`, and through it the per-session frame projection)
//  asks it through this function and never re-derives its own answer.
//
//  **Why a glob, and not `NSRegularExpression`.** A regular expression can
//  THROW (a user-authored malformed pattern is a runtime error) and can HANG
//  (catastrophic backtracking is a documented ICU hazard), and a folder
//  pattern is evaluated inside the frame projection on EVERY refresh, the same
//  hot path where `QuickAction.rejection(at:among:)` already had to close an
//  exponential blowup. A pattern language whose worst case is a measured
//  polynomial closes the hazard by construction.
//
//  **The algorithm and its real bound.** One remembered `*` (`star`, its
//  position in the pattern) and the string position it last matched at
//  (`mark`) are the entire state: on a literal or `?` mismatch with a star
//  remembered, the matcher advances that star's claimed match by one
//  character and resumes. Only the MOST RECENT `*` is ever reconsidered, so
//  there is no exponential branch tree.
//
//  It is NOT linear in `path`. Against `pattern = "*" + "a"×m + "b"` and
//  `path = "a"×n` (a star, a long literal run, then a final literal the path
//  never contains) every one of the O(n) star advances re-walks the O(m)
//  literal run before failing again:
//
//        n = 2000   0.0018s      n = 16000   0.1102s
//        n = 4000   0.0065s      n = 32000   0.4863s
//        n = 8000   0.0264s
//
//  Four times the work per doubling of n: O(pattern × path), the textbook
//  bound for this matcher. That is acceptable: it is a polynomial with no
//  cliff over two small inputs (a `cwd` is a path, a rule is a phrase typed
//  into a settings field). A 100-character path against a 50-character
//  pattern costs a few thousand comparisons.
//
//  **Where this is paid.** `QuickAction.offerable(_:in:)` calls `shows(in:)`
//  per row, and `DeckState.arm(_:at:)` calls that once per session inside a
//  loop over every lane, on every reducer event. Per-event worst case is
//  O(S × (N² + N × pattern × path)) for S sessions and N stored rows (the N²
//  being `rejection`'s duplicate prefix scan). All factors are small in a
//  real deck.
//
//  Covered by `GlobTests.swift`, including the backtrack-forcing shape above
//  (a pattern like `"a*" × 20` against 200 `a`s does NOT exercise the
//  backtrack branch, since every literal matches on first attempt).
//

public enum Glob {

    /// Does `path` match `pattern`, as a WHOLE STRING — never a substring.
    ///
    /// Semantics, deliberately this small:
    ///   - `*` matches any run of characters, INCLUDING none, and INCLUDING
    ///     the path separator — there is no "stop at `/`" rule. A folder rule
    ///     is matched against the WHOLE `cwd`, and a pattern like `*/bravo*`
    ///     depends on `*` crossing however many path components surround the
    ///     literal middle.
    ///   - `?` matches exactly one character — no more, no fewer.
    ///   - every other character is LITERAL, compared CASE-INSENSITIVELY —
    ///     both `pattern` and `path` are lowercased once, up front, rather
    ///     than folded rune-by-rune, so a directory a person typed in any
    ///     case reads the same rule. **Known limit**: a few code points change
    ///     LENGTH when lowercased. `İ` (U+0130) lowercases to `i` plus a
    ///     combining dot, a different `Character` from plain `i`, so
    ///     `İstanbul` does not match `istanbul`. Normalising would also
    ///     collapse accents somebody may mean to keep apart; a rule that
    ///     visibly matches nothing beats one that quietly matches more than
    ///     it says.
    ///   - nothing else. No `[...]` character classes, no `{...}` brace
    ///     expansion, no `\` escape — a mistyped bracket is a LITERAL bracket,
    ///     never a syntax error to reject.
    ///
    /// **Matches the WHOLE path, not a substring** (the rule most likely to
    /// surprise). A bare `alpha`, with no wildcard, matches NOTHING a realistic
    /// `cwd` would hand it: `/Users/dev/projects/alpha` merely contains the
    /// string, and `*/alpha*` is what a person typing the bare word probably
    /// meant. **This function does not auto-wrap a wildcard-free pattern in
    /// `*…*`**: a rule that silently means something other than what it says
    /// is worse than one that visibly matches nothing. The editor's
    /// pre-filled pattern and live match count give the feedback instead.
    public static func matches(pattern: String, path: String) -> Bool {
        let p = Array(pattern.lowercased()), s = Array(path.lowercased())
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] { pi += 1; si += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
