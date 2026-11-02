//
//  Statusline.swift · DeckCore/Ingest
//
//  One line of the statusline relay's stream.
//
//  `context_window.used_percentage` arrives **null** on the first lines of the
//  recorded feed. Showing `0%` there would show a number nobody sent: "0% of
//  the context used" and "not heard yet" must look different.
//
//  The payload carries no emission timestamp (the only temporal values are
//  `rate_limits.*.resets_at`, which are future deadlines). Staleness can only
//  be measured from deck receipt, so arrival-stamping belongs to this layer.
//

/// One rate-limit window as the statusline reports it (fixture LV19):
/// `rate_limits.five_hour` and `.seven_day`, each carrying `used_percentage`
/// and a `resets_at` epoch deadline. The epoch becomes an `Instant` AT INGEST:
/// time enters the core exactly at the decoder, as `HookIngest` does for `ts`.
public struct RateWindow: Equatable, Codable, Sendable {
    /// The wire's own key: "five_hour", "seven_day", and whatever a future
    /// CLI adds (unknown windows ride along rather than erroring).
    public let window: String
    public let usedPercentage: Int
    public let resetsAt: Instant

    /// The wire's key, short enough to sit on a mast beside another one.
    ///
    /// Windows are labelled individually: one number for two windows (say 3 %
    /// and 81 %) is a wrong number.
    ///
    /// Unknown keys keep their own name rather than being dropped or renamed.
    public var shortName: String {
        switch window {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        default:          return window
        }
    }
    public init(window: String, usedPercentage: Int, resetsAt: Instant) {
        self.window = window; self.usedPercentage = usedPercentage; self.resetsAt = resetsAt
    }
}

public struct StatuslinePayload: Equatable, Sendable {
    public let session: SessionID
    public let contextPercent: Fed<Int>
    public let costUSD: Fed<Double>
    public let model: String?
    public let version: String?
    /// Account-scoped, not per-session: every session's statusline reports
    /// the same account's windows. Empty when the payload carried none.
    public let rateLimits: [RateWindow]

    public init(session: SessionID, contextPercent: Fed<Int>, costUSD: Fed<Double>,
                model: String?, version: String?, rateLimits: [RateWindow] = []) {
        self.session = session; self.contextPercent = contextPercent
        self.costUSD = costUSD; self.model = model; self.version = version
        self.rateLimits = rateLimits
    }
}

public enum StatuslineIngest {

    /// Total apart from the one thing that cannot be absorbed: no session id
    /// means no lane to attach the value to, and inventing one would break
    /// the no-synthesised-lane rule.
    ///
    /// `epochBase` is the same millisecond origin `HookIngest` uses — needed
    /// here because `resets_at` is an epoch deadline and the core speaks only
    /// `Instant`. Callers with no interest in rate limits may pass 0 and
    /// ignore the windows; the recorded feeds' other fields are unaffected.
    public static func payload(from row: JSONValue, epochBase: Int64 = 0) -> StatuslinePayload? {
        guard let session = row["session_id"]?.stringValue, !session.isEmpty
        else { return nil }
        let window = row["context_window"] ?? .object([:])
        let cost = row["cost"] ?? .object([:])
        // A window contributes only when BOTH halves arrived: a percentage
        // with no deadline cannot self-expire, and a deadline with no
        // percentage says nothing. Never fabricate the missing half.
        var limits: [RateWindow] = []
        if let rl = row["rate_limits"], case .object(let windows) = rl {
            for (key, value) in windows.sorted(by: { $0.key < $1.key }) {
                guard let used = value["used_percentage"]?.intValue,
                      let resets = value["resets_at"]?.intValue else { continue }
                limits.append(RateWindow(
                    window: key,
                    usedPercentage: used,
                    resetsAt: Instant(sinceStart: Millis(Int64(resets) * 1000 - epochBase))))
            }
        }
        return StatuslinePayload(session: SessionID(session),
                                 contextPercent: window.fedInt("used_percentage"),
                                 costUSD: cost.fedDouble("total_cost_usd"),
                                 model: row["model"]?["display_name"]?.stringValue,
                                 version: row["version"]?.stringValue,
                                 rateLimits: limits)
    }
}
