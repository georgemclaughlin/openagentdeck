//
//  Timestamp.swift · DeckCore/Ingest
//
//  ISO-8601 to whole milliseconds, by arithmetic.
//
//  Foundation's parsers all produce a `Date`, which the no-clock-in-the-core
//  rule forbids in this module: a `Date` can be compared against the host
//  clock, and the injected-clock rule exists to make that impossible.
//
//  The civil-date conversion below is Howard Hinnant's `days_from_civil`, which
//  is exact for the whole proleptic Gregorian range and is pure integer
//  arithmetic. Recorded timestamps are all `Z`, which is why no zone offset is
//  parsed: a decoder that silently accepted `+02:00` and ignored it would be
//  worse than one that refuses.
//

public enum Timestamp {

    /// `2026-07-25T06:51:37.207Z` -> 1784...  milliseconds since the epoch.
    ///
    /// Returns nil rather than throwing, and rather than guessing. A
    /// timestamp this parser does not understand is an event the deck cannot
    /// place on its timeline.
    public static func epochMillis(iso: String) -> Int64? {
        let s = Array(iso.utf8)
        // YYYY-MM-DDTHH:MM:SS  is 19 bytes; the fraction and the Z follow.
        guard s.count >= 20, s[4] == UInt8(ascii: "-"), s[7] == UInt8(ascii: "-"),
              s[10] == UInt8(ascii: "T"), s[13] == UInt8(ascii: ":"),
              s[16] == UInt8(ascii: ":"), s.last == UInt8(ascii: "Z")
        else { return nil }

        func num(_ from: Int, _ count: Int) -> Int64? {
            var acc: Int64 = 0
            for i in from ..< (from + count) {
                let c = s[i]
                guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
                acc = acc * 10 + Int64(c - UInt8(ascii: "0"))
            }
            return acc
        }

        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2)
        else { return nil }
        guard (1...12).contains(mo), (1...31).contains(d),
              h < 24, mi < 60, sec < 61 else { return nil }

        // Fraction: `.` then 1-9 digits, truncated to milliseconds. Truncated
        // rather than rounded, so that ordering by this value never disagrees
        // with ordering by the source string.
        var millis: Int64 = 0
        if s.count > 20, s[19] == UInt8(ascii: ".") {
            var digits = 0
            var i = 20
            while i < s.count - 1, s[i] >= UInt8(ascii: "0"), s[i] <= UInt8(ascii: "9") {
                if digits < 3 { millis = millis * 10 + Int64(s[i] - UInt8(ascii: "0")) }
                digits += 1; i += 1
            }
            guard digits > 0, i == s.count - 1 else { return nil }
            while digits < 3 { millis *= 10; digits += 1 }
        } else if s.count != 20 {
            return nil
        }

        return (daysFromCivil(y: y, m: mo, d: d) * 86_400 + h * 3600 + mi * 60 + sec) * 1000 + millis
    }

    /// Days since 1970-01-01 from a civil date. Exact; no calendar object, no
    /// locale, no clock.
    static func daysFromCivil(y: Int64, m: Int64, d: Int64) -> Int64 {
        let y = y - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                    // [0, 399]
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1   // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy            // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}
