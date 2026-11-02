//
//  CrashRecovery.swift · DeckApp
//
//  Process-level resurrection for a crash no in-process handler can catch.
//  The full account is on `CrashRecovery`'s doc comment below.
//

import AppKit
import Darwin
import Foundation

/// Relaunches the deck after a crash, from a second process watching the first.
///
/// The crash this answers (macOS 26.5.2): `SIGABRT` during a live window
/// resize. Inside `-[NSWindow(NSWindowResizing) _resizeWithEvent:]`'s nested
/// event loop, a display-cycle flush entered AppKit's constraint-update phase;
/// SwiftUI's `NSHostingView` found the hosted content's min/max size had
/// CHANGED and notified `SplitViewChildController` (the `.inspector` split
/// machinery). That enqueued a SwiftUI layout invalidation which, with no
/// SwiftUI Update in flight to defer into, drained synchronously and called
/// `-[NSView setNeedsUpdateConstraints:]` on a window still inside its own
/// constraint flush. AppKit's display-cycle reentrancy guard threw an
/// `NSException`; AppKit's observer rethrew it, and the rethrow unwound through
/// QuartzCore's noexcept `CA::Transaction::run_commit_handlers` frames, so
/// `std::terminate` -> `abort()`.
///
/// Three facts follow.
///
/// 1. No app frames appear anywhere in the trace: this is an OS/SwiftUI defect
///    (a split controller's synchronous invalidation from inside the
///    constraint pass). An Apple Feedback is the upstream half and is NOT YET
///    FILED; this type is the downstream half regardless.
/// 2. The app-side trigger was a discrete layout flip that swapped the split
///    pane's interior between compositions with very different minimum sizes
///    (band vs inspector, row vs grid). A drag crossing a boundary changed the
///    pane's minimum mid-flight, a narrow race that scripted boundary-crossing
///    drags could not reproduce on demand. The surface is now closed: the
///    `.inspector` split is gone from the view tree (the band is always used
///    and shrinks in place, a size change rather than a composition swap), so
///    there is nothing left for that notification path to hit. The watchdog
///    stays load-bearing because the general class (a display-cycle flush
///    triggering a synchronous layout invalidation inside AppKit's constraint
///    pass) is not specific to `.inspector`.
/// 3. No in-process catch can survive it: the terminate fires inside
///    QuartzCore's noexcept boundary before application exception handling
///    could see it. Surviving means PROCESS-level resilience, so the deck
///    relaunches itself after a crash. That is safe because cold-start recovery
///    is complete by construction (lanes reseed from `claude agents --json`,
///    the prompt well backfills from the transcript, colors/prefs persist); the
///    one honest loss is any in-memory hold, whose hook connection died with
///    the process.
///
/// Mechanism: a detached POSIX-`sh` process (`watchdogScript`, spawned by
/// `arm()`) outlives the app (a child `Process` is not killed when its parent
/// dies; it reparents to `launchd`) and polls the app's PID with `kill -0`.
/// When the PID disappears, a PID-stamped sentinel file written only from
/// `NSApplication.willTerminateNotification` distinguishes THIS instance's
/// clean quit (stay down) from anything else (relaunch). It is stamped, not a
/// bare marker, because the state directory is shared by every deck instance on
/// the machine (see `sentinelURL`). A timestamped log caps relaunches at 3
/// inside 10 minutes so a deck that crashes on arrival goes down for a human.
///
/// It deliberately does not catch the exception (it cannot, see fact 3) or run
/// inside the crashing process; it watches from outside, the one vantage point
/// `std::terminate` cannot reach.
public enum CrashRecovery {

    /// `~/Library/Application Support/OpenAgentDeck/` — created on demand
    /// by `arm()` (step 2 below), never assumed to exist by a reader.
    static var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAgentDeck", isDirectory: true)
    }

    /// Names the PID whose exit was intentional. Not a bare marker, because
    /// `stateDirectory` is shared by every deck instance on the machine (a second
    /// default-port deck, or an Xcode debug build beside a release build). A bare
    /// marker cannot say WHICH instance's exit it recorded, and that fails in the
    /// dangerous direction: B's clean quit writes the marker, A's LATER REAL CRASH
    /// finds it, reads "the last exit was clean", and stays down. With the PID
    /// stamped and compared against the watchdog's own `$PID`, a crash is
    /// recognised by "no sentinel, or a sentinel naming some other PID".
    ///
    /// Erased at the START of every run (`arm()` step 2) and written back only by
    /// THIS run's clean `willTerminateNotification` (step 4), so an unwritten
    /// sentinel is the default for "fate unknown", of which a crash is a case.
    ///
    /// Residual race: the file is still one shared slot. If A and B both quit
    /// CLEANLY within the same ~1 s poll interval (`POLL`), A's write can overwrite
    /// B's before B's watchdog polls, B's watchdog then reads a sentinel naming A,
    /// and relaunches B despite its intentional exit. One spurious relaunch is
    /// fail-open, bounded by the 3-in-10-minutes loop guard, and strictly better
    /// than a stale marker keeping a crashed deck down forever.
    static var sentinelURL: URL { stateDirectory.appendingPathComponent("clean-exit") }

    /// One epoch-seconds line per crash relaunch. Pruned to the trailing 10-minute
    /// window by the watchdog on every read, so it never grows without bound.
    /// PRIVACY: timestamps and nothing else.
    static var crashLogURL: URL { stateDirectory.appendingPathComponent("crash-relaunches") }

    /// The watchdog, verbatim. POSIX `/bin/sh` only, no bashisms: the string is
    /// handed to `/bin/sh -c` directly. Exact semantics are load-bearing;
    /// `CrashRecoveryTests` runs this literal string against real processes.
    ///
    /// Positional: `sh -c watchdogScript watchdog <pid> <bundle> <sentinel>
    /// <crashlog> <poll> [open]`. `"watchdog"` fills the conventional `$0` slot,
    /// so `$1` is the first REAL argument. `arm()` is the one production caller
    /// and supplies all six.
    ///
    /// - `$6` (`OPEN`, defaulting to `/usr/bin/open`) exists ONLY so
    ///   `CrashRecoveryTests` can substitute a recording stub; a real relaunch
    ///   starts a second app instance a test cannot safely tear down.
    /// - No `-n`: `open` without it ACTIVATES an existing instance rather than
    ///   starting a second, so a fresh deck that already exists gets focus instead
    ///   of a duplicate.
    /// - `[ -f "$SENTINEL" ] && [ "$(cat "$SENTINEL")" = "$PID" ]`: the sentinel
    ///   must both EXIST and NAME THIS WATCHDOG'S `$PID` (see `sentinelURL` for the
    ///   multi-instance case this guards against and the residual race).
    /// - `TMP="$CRASHLOG.tmp.$$"`: `$$` is THIS SHELL's pid, so two watchdogs
    ///   pruning the SAME `$CRASHLOG` at once never share a temp file. A single
    ///   shared `.tmp` name let one instance's prune `mv` another's half-written
    ///   file over the log.
    /// - `[ "$T" -le "$NOW" ] &&` before the age check: after a clock set
    ///   backward, `NOW - T` would be NEGATIVE, always `-lt 600`, and that entry
    ///   could never age out. A future-dated stamp is treated as stale and pruned.
    /// - The crash-loop guard (`RECENT -ge 3` inside a 600-second window): a deck
    ///   that crashes on arrival (bad build, corrupt prefs) would otherwise
    ///   resurrect into the same crash forever. Past three relaunches in ten
    ///   minutes it stays down for a human. The log self-prunes on every read. The
    ///   boundary is pinned from both sides: `aCrashLoopStopsRelaunching` holds
    ///   `-ge 3` at 3, `twoRecentCrashesStillAllowRelaunch` (`CrashRecoveryTests`)
    ///   holds it at 2, so a regression to `-ge 2` fails the second.
    /// - PRIVACY: the script and its files carry a PID, a bundle path and
    ///   epoch-second timestamps; nothing about a session, transcript or hook
    ///   payload.
    static let watchdogScript = #"""
    PID="$1"; BUNDLE="$2"; SENTINEL="$3"; CRASHLOG="$4"; POLL="$5"; OPEN="${6:-/usr/bin/open}"
    while kill -0 "$PID" 2>/dev/null; do sleep "$POLL"; done
    [ -f "$SENTINEL" ] && [ "$(cat "$SENTINEL")" = "$PID" ] && exit 0
    NOW=$(date +%s)
    RECENT=0
    if [ -f "$CRASHLOG" ]; then
      TMP="$CRASHLOG.tmp.$$"; : > "$TMP"
      while IFS= read -r T; do
        case "$T" in (*[!0-9]*|"") continue;; esac
        [ "$T" -le "$NOW" ] && [ $((NOW - T)) -lt 600 ] && { printf '%s\n' "$T" >> "$TMP"; RECENT=$((RECENT+1)); }
      done < "$CRASHLOG"
      mv "$TMP" "$CRASHLOG"
    fi
    [ "$RECENT" -ge 3 ] && exit 0
    printf '%s\n' "$NOW" >> "$CRASHLOG"
    exec "$OPEN" "$BUNDLE"
    """#

    /// A second `arm()` is a no-op: one deck, one watchdog. `@MainActor` on each
    /// piece of stored state makes the compiler enforce that they agree on their
    /// owning actor.
    @MainActor private static var armed = false
    @MainActor private static var sigtermSource: DispatchSourceSignal?
    @MainActor private static var sigintSource: DispatchSourceSignal?
    @MainActor private static var terminationObserver: NSObjectProtocol?

    /// True while a debugger has THIS process attached (`P_TRACED`), via the
    /// standard `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, ...)` query (no private
    /// API). Guards `arm()` against Xcode-Stop resurrection: Xcode's Stop kills the
    /// debuggee through `lldb`, which is neither a graceful `NSApp.terminate` nor a
    /// signal this type handles, so `willTerminateNotification` never fires and no
    /// sentinel is written. The watchdog would read that as a crash, resurrect the
    /// deck after EVERY debugger stop, and stamp the shared crash log other
    /// instances' loop guards read. Not arming while traced is simpler than
    /// telling a debugger kill from a real one, and a debugger session already has
    /// a human's full attention on the process.
    private static func isBeingTraced() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Called once, from `DeckScene.init`. See this type's doc comment for the
    /// crash this answers.
    @MainActor public static func arm() {
        // Refuse to arm outside a real deck run. `OAD_HOOK_PORT` addresses a scratch
        // instance on a private port (probe harness, UI tests), which is killed with
        // SIGTERM constantly and must never self-resurrect. Previews and a hosted
        // `XCTestCase` run are the same rule. `isBeingTraced` is the fourth: a
        // debugger-attached run (see its doc comment).
        let environment = ProcessInfo.processInfo.environment
        guard environment["OAD_HOOK_PORT"] == nil,
              environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              NSClassFromString("XCTestCase") == nil,
              !isBeingTraced() else { return }
        guard !armed else { return }
        armed = true

        // A fresh run consumes the LAST run's verdict: only a clean termination from
        // THIS run writes the sentinel back, so a leftover "clean-exit" can never be
        // misread as this run's outcome.
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: sentinelURL)

        // A default-action SIGTERM kills the process without AppKit's shutdown path:
        // `willTerminateNotification` never fires, no sentinel is written, and the
        // watchdog would misread an intentional `kill` as a crash and resurrect the
        // old deck beside the new one. Ignoring the signal and routing it through a
        // dispatch source keeps shutdown on the same graceful path as Quit. SIGINT
        // gets the same treatment (Ctrl-C from a terminal). Kept in static storage so
        // both sources live for the process; a local `let` would be released and
        // cancelled when `arm()` returns.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigtermSource = term

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { NSApp.terminate(nil) }
        interrupt.resume()
        sigintSource = interrupt

        // The one write that means "this exit was on purpose", naming this process's
        // PID so only this instance's own watchdog can satisfy its check (see
        // `sentinelURL`). `try?`: a failed write degrades to one spurious relaunch,
        // never a crash of its own.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: sentinelURL)
        }

        // The watchdog itself. NOT killed when this process dies (an orphan
        // reparented to `launchd`) and one-shot: it renders a single verdict and
        // exits, and any deck it relaunches arms a fresh watchdog.
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = [
            "-c", watchdogScript, "watchdog",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
            sentinelURL.path,
            crashLogURL.path,
            "1",
            "/usr/bin/open",
        ]
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        watchdog.standardInput = FileHandle.nullDevice
        try? watchdog.run()
    }
}
