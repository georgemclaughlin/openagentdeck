//
//  RelativeAge.swift · DeckCore/Model
//
//  How long ago something happened, in words, for a surface where the
//  ANSWER matters more than the precision.
//
//  Written for the transcript well's recap row, but general: "is this fact
//  stale" is asked about several mirrored facts.
//
//  **Pure and clockless: both `Instant`s come from the caller** (this module
//  may not read wall time), so every threshold is testable by naming two
//  instants.
//
//  **Coarse on purpose.** The only question an age answers is "is this still
//  roughly true?", which "2h ago" answers as well as "2h 14m 3s ago" in far
//  less width. Rounding is TRUNCATION, not nearest: 119 minutes reads "1h
//  ago", so the label never overstates how stale something is.
//

public enum RelativeAge {

    static let minute: Int64 = 60_000
    static let hour: Int64 = 60 * minute
    static let day: Int64 = 24 * hour

    /// `at` in the past, `now` the present — "just now", "5m ago", "2h
    /// ago", "3d ago".
    ///
    /// **A future `at` reads "just now"** rather than a negative age or a
    /// crash. `at` is resolved from a transcript row's wall-clock `timestamp`
    /// against the runtime's epoch base, two clocks' readings of the same
    /// moment, so a few milliseconds of skew is ordinary and "just now" is
    /// the true answer.
    public static func label(of at: Instant, now: Instant) -> String {
        let elapsed = now.sinceStart.raw - at.sinceStart.raw
        guard elapsed >= minute else { return "just now" }
        if elapsed < hour { return "\(elapsed / minute)m ago" }
        if elapsed < day { return "\(elapsed / hour)h ago" }
        return "\(elapsed / day)d ago"
    }
}
