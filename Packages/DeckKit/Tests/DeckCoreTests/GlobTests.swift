//
//  GlobTests.swift · Tests/DeckCoreTests
//
//  `Glob.matches(pattern:path:)` is TRANSCRIBED, not designed here — the
//  algorithm is settled (`Glob.swift`'s own header comment carries the
//  linearity argument) and already validated against the 21 cases below,
//  including the pathological one. What these tests hold the transcription
//  to is that it actually behaves the way the header comment claims: the
//  documented examples, every documented semantic, and the one input
//  shaped to break a naive backtracking matcher.
//
//  Every path and pattern here is invented for this file — none of them
//  names a real directory this repository, or any session that ran in it,
//  has ever used.
//

import Testing
@testable import DeckCore

struct GlobTests {

    // ---------------------------------------------------------- worked examples

    /// Matching, and a NON-match
    /// against a path shaped just like it. `*/alpha-sight*` is not a typo
    /// of `*/alpha-site*`'s own target directory, it is a different word
    /// in the same position — the two must not be confused by a matcher that
    /// is secretly looser than it claims.
    @Test("*/alpha-site* matches a path containing it, and not a similarly-shaped one that does not")
    func alphaExample() {
        #expect(Glob.matches(pattern: "*/alpha-site*", path: "/Users/dev/projects/alpha-site/deck"))
        #expect(!Glob.matches(pattern: "*/alpha-site*", path: "/Users/dev/projects/alpha-sight/deck"),
                "a similarly-named directory matched a pattern naming a specific one")
    }

    /// Same shape, same proof.
    @Test("*/kilo* matches a path containing it, and not a similarly-shaped one that does not")
    func kiloExample() {
        #expect(Glob.matches(pattern: "*/kilo*", path: "/Users/dev/projects/kilo-integration"))
        #expect(!Glob.matches(pattern: "*/kilo*", path: "/Users/dev/projects/lima-integration"),
                "an unrelated project directory matched a pattern naming a specific one")
    }

    // ------------------------------------------------------------------ ? arity

    /// `?` matches exactly one character — never zero, never two.
    @Test("? matches exactly one character")
    func questionMarkArity() {
        #expect(Glob.matches(pattern: "/tmp/log?.txt", path: "/tmp/log1.txt"))
        #expect(Glob.matches(pattern: "/tmp/log?.txt", path: "/tmp/logA.txt"))
        #expect(!Glob.matches(pattern: "/tmp/log?.txt", path: "/tmp/log.txt"),
                "? matched zero characters")
        #expect(!Glob.matches(pattern: "/tmp/log?.txt", path: "/tmp/log12.txt"),
                "? matched two characters")
    }

    // -------------------------------------------------------------- * spans /

    /// `*` crosses the path separator freely — there is no "stop at `/`"
    /// rule the way a shell's own filename globbing sometimes has one. The
    /// worked examples depend on exactly this.
    @Test("* spans the path separator")
    func starSpansSeparator() {
        #expect(Glob.matches(pattern: "/a*z", path: "/a/b/c/z"))
        #expect(Glob.matches(pattern: "/a*z", path: "/az"), "* did not match zero characters, including the run")
    }

    // ------------------------------------------------------- case-insensitivity

    /// Both directions: an uppercase pattern against a lowercase path, and
    /// the reverse. Neither side is folded by the caller — the function
    /// itself lowercases both, once.
    @Test("matching is case-insensitive in both directions")
    func caseInsensitiveBothWays() {
        #expect(Glob.matches(pattern: "*/ALPHA-SITE*", path: "/users/dev/alpha-site/proj"))
        #expect(Glob.matches(pattern: "*/alpha-site*", path: "/USERS/DEV/ALPHA-SITE/PROJ"))
        #expect(Glob.matches(pattern: "*/AlPhA-sItE*", path: "/Users/Dev/aLpHa-SiTe/Proj"),
                "a mixed-case pattern against a mixed-case path, differently mixed, did not match")
    }

    // ------------------------------------------------------------- empty pattern

    /// An empty pattern matches nothing that has any characters at all —
    /// and matches the empty path, because there both sides run out of
    /// input at the same instant.
    @Test("an empty pattern matches only the empty path")
    func emptyPattern() {
        #expect(!Glob.matches(pattern: "", path: "/Users/dev/anything"),
                "an empty pattern matched a non-empty path")
        #expect(Glob.matches(pattern: "", path: ""),
                "an empty pattern did not match the empty path")
    }

    // ---------------------------------------------------------------- * alone

    /// `*` by itself matches anything, including nothing.
    @Test("a bare * matches anything, including the empty path")
    func starAlone() {
        #expect(Glob.matches(pattern: "*", path: ""))
        #expect(Glob.matches(pattern: "*", path: "/Users/dev/projects/anything/at/all"))
    }

    // ------------------------------------------------------------------- ***

    /// Redundant, adjacent stars collapse to the same behaviour as one —
    /// nothing in the algorithm treats a run of `*` specially, and nothing
    /// needs to.
    @Test("*** behaves exactly like a single *")
    func multipleAdjacentStars() {
        #expect(Glob.matches(pattern: "***", path: ""))
        #expect(Glob.matches(pattern: "***", path: "/Users/dev/projects/anything/at/all"))
        #expect(Glob.matches(pattern: "/a***z", path: "/a/b/c/z"))
    }

    // --------------------------------------------------- exact match, near miss

    /// A pattern with no wildcard at all matches only the identical string —
    /// and a one-character difference anywhere, prefix or suffix, is a miss.
    @Test("a pattern with no wildcard matches only the exact string")
    func exactMatchAndNearMiss() {
        let pattern = "/Users/dev/projects/exact-path/deck"
        #expect(Glob.matches(pattern: pattern, path: pattern))
        #expect(!Glob.matches(pattern: pattern, path: pattern + "/extra"),
                "a longer path with the pattern as a prefix matched")
        #expect(!Glob.matches(pattern: pattern, path: String(pattern.dropLast())),
                "a one-character-shorter near miss matched")
        #expect(!Glob.matches(pattern: pattern, path: "/Users/dev/projects/exact-path/decks"),
                "a one-character-longer near miss matched")
    }

    // --------------------------------------------------------- the bare word

    /// **The rule most likely to surprise, pinned directly.** A bare word
    /// with no wildcard is a WHOLE-STRING pattern, so it matches nothing a
    /// realistic directory would ever hand it — `*/kilo*` is what the
    /// examples use for exactly this reason.
    @Test("a bare word with no wildcard matches nothing a realistic directory contains it in")
    func bareWordMatchesNothing() {
        #expect(!Glob.matches(pattern: "kilo", path: "/Users/dev/projects/kilo/deck"))
        #expect(!Glob.matches(pattern: "kilo", path: "kilo-clone"))
        // The one thing it DOES match: itself, whole.
        #expect(Glob.matches(pattern: "kilo", path: "kilo"))
    }

    // ------------------------------------------------------------ pathological

    /// **The shape that actually forces the backtrack branch — the two tests below
    /// never do.**
    ///
    /// `"*" + "a"×m + "b"` against `"a"×n`: the star matches, the literal run
    /// of `a`s matches, then `b` fails against an `a` — so the matcher
    /// advances the star by one and re-walks the entire literal run, O(n)
    /// times. This is the input the header's own timing table was measured
    /// on, and the one a regression in the `star`/`mark` bookkeeping would
    /// actually blow up.
    ///
    /// No timing assertion, deliberately — this suite has been burned by
    /// wall-clock ratios before. A regression to exponential backtracking
    /// hangs the suite, which is a stronger falsifier than any duration this
    /// test could assert.
    @Test("a backtrack-forcing pattern re-walks its literal run without blowing up")
    func backtrackForcingInputReturnsPromptly() {
        let pattern = "*" + String(repeating: "a", count: 40) + "b"
        let path = String(repeating: "a", count: 4000)
        #expect(Glob.matches(pattern: pattern, path: path) == false,
                "a path of only a's cannot satisfy a pattern ending in a literal b")

        // And the same shape where it SHOULD match, so the test is not
        // merely asserting that everything fails.
        #expect(Glob.matches(pattern: pattern, path: path + "b"),
                "the same pattern must still match once the final literal is present")
    }

    /// **The case a naive backtracking matcher would not return from.**
    /// Twenty `"a*"` pairs against two hundred `a`s: a matcher that
    /// re-explored every prior star's own possibilities on each mismatch
    /// would branch exponentially here. `Glob.matches` remembers only the
    /// MOST RECENT star, so this returns promptly.
    ///
    /// **Kept, but its evidentiary claim corrected.** An earlier revision
    /// cited this as verifying the header's linearity argument. It does not:
    /// every literal `a` here matches on the FIRST attempt, so the backtrack
    /// branch never fires in anger and the test would pass unchanged against
    /// a quadratic implementation. `backtrackForcingInputReturnsPromptly`
    /// above is the one with teeth; this one pins the no-exponential-branch
    /// property specifically.
    @Test("a pathological pattern of twenty \"a*\" pairs against two hundred a's returns promptly")
    func pathologicalInputReturnsPromptly() {
        let pattern = String(repeating: "a*", count: 20)
        let path = String(repeating: "a", count: 200)
        #expect(Glob.matches(pattern: pattern, path: path),
                "two hundred a's should satisfy twenty literal a's each followed by a wildcard")
    }

    /// The same shape, but ONE character short of what the literal `a`s
    /// alone require — twenty literal `a`s need at least twenty characters,
    /// and this path has nineteen, so no placement of the twenty stars can
    /// ever satisfy it. The miss has to stay CHEAP too, not merely the hit.
    @Test("the pathological pattern's own near miss is also prompt")
    func pathologicalNearMissReturnsPromptly() {
        let pattern = String(repeating: "a*", count: 20)
        let path = String(repeating: "a", count: 19)
        #expect(!Glob.matches(pattern: pattern, path: path))
    }
}
