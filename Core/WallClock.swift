// Reading the API's time strings without ever converting a timezone.
//
// This file exists because the obvious implementation is wrong in a way that
// looks right. The naive version of "show the dose time" is
//
//     let f = DateFormatter()
//     f.dateFormat = "yyyy-MM-dd HH:mm"
//     f.date(from: dose.dueAtLocal)          // parsed as *device local*
//     f.string(from: thatDate)               // formatted back out
//
// which happens to round-trip on the phone that created it and silently shifts
// by the offset difference on every other phone. A daughter in Chicago sees her
// mother's 8:00 AM New York dose as 7:00 AM, decides it is not due yet, and the
// dose is late. The bug is invisible in development, where the developer's
// phone and the test recipient share a timezone.
//
// So the rule here is absolute: a `*_local` string from the API is a *label*,
// not an instant. We split it into numbers and format those numbers, and no
// `TimeZone` is ever consulted. Round-tripping is not the goal; not converting
// is.
//
// The one place an instant matters -- sorting doses within a day -- uses
// `due_at`, which is UTC and therefore comparable, and never `due_at_local`.

import Foundation

enum WallClock {

    // MARK: - Parsing

    /// "2026-09-24 08:00" or "2026-09-24 08:00:00" -> components, read literally.
    ///
    /// Parsed by hand rather than with `DateFormatter` so that no calendar,
    /// locale or timezone can get involved. There is nothing to configure and
    /// therefore nothing to get wrong.
    static func parts(_ value: String?) -> (date: String, hour: Int, minute: Int)? {
        guard let value, value.count >= 16 else { return nil }
        let datePart = String(value.prefix(10))
        let timePart = value.dropFirst(11)
        let hm = timePart.split(separator: ":")
        guard hm.count >= 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return nil }
        // A trailing "Z" or "+00:00" would mean this is an instant, not a label.
        // Refuse it loudly rather than quietly shifting it: seeing this in a
        // crash log beats seeing a wrong time on a family's screen.
        assert(!value.hasSuffix("Z"), "\(value) is an instant; use the *Local field")
        return (datePart, h, m)
    }

    // MARK: - Display

    /// The time of day, in the device's *formatting* preference only.
    ///
    /// "08:00" -> "8:00 AM" for a US locale, "08:00" for a 24-hour locale. The
    /// hour and minute are the ones that were written; only their presentation
    /// follows the reader's habits.
    static func time(_ value: String?) -> String {
        guard let p = parts(value) else { return "" }
        return format(hour: p.hour, minute: p.minute)
    }

    static func format(hour: Int, minute: Int) -> String {
        // Built in GMT purely so that the formatter below cannot shift it. The
        // resulting `Date` is meaningless as a moment in time and is never used
        // as one -- it exists to hand two integers to the locale's clock style.
        var c = DateComponents()
        c.year = 2000; c.month = 1; c.day = 1
        c.hour = hour; c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: c) ?? Date(timeIntervalSince1970: 0)
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)!
        f.locale = .current
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// The hour alone, for grouping a day into "Morning / Afternoon / Evening".
    static func hour(_ value: String?) -> Int? { parts(value)?.hour }

    /// "2026-09-24" -> "Wednesday, September 24" without a timezone in sight.
    static func longDate(_ isoDay: String?) -> String {
        guard let d = dayParts(isoDay) else { return "" }
        var c = DateComponents()
        c.year = d.year; c.month = d.month; c.day = d.day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: c) else { return "" }
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)!
        f.locale = .current
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// "2026-09-24" -> "Wed, Sep 24".
    static func shortDate(_ isoDay: String?) -> String {
        guard let d = dayParts(isoDay) else { return "" }
        var c = DateComponents()
        c.year = d.year; c.month = d.month; c.day = d.day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: c) else { return "" }
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)!
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: date)
    }

    static func dayParts(_ isoDay: String?) -> (year: Int, month: Int, day: Int)? {
        guard let isoDay, isoDay.count >= 10 else { return nil }
        let bits = isoDay.prefix(10).split(separator: "-")
        guard bits.count == 3,
              let y = Int(bits[0]), let m = Int(bits[1]), let d = Int(bits[2])
        else { return nil }
        return (y, m, d)
    }

    /// Whole days between two ISO local dates, using a GMT calendar so that a
    /// DST change cannot make a 24-hour period count as zero or two days. Only
    /// ever compares two *local* dates, so this is a difference between two
    /// calendar labels and not between two instants.
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = dayParts(from), let b = dayParts(to) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var ca = DateComponents(); ca.year = a.year; ca.month = a.month; ca.day = a.day
        var cb = DateComponents(); cb.year = b.year; cb.month = b.month; cb.day = b.day
        guard let da = cal.date(from: ca), let db = cal.date(from: cb) else { return nil }
        return cal.dateComponents([.day], from: da, to: db).day
    }

    // MARK: - Sorting

    /// Orders doses within one day. Sorts on the UTC instant, which is the only
    /// field here that is unconditionally comparable across medications -- two
    /// doses at the same local time are the same local time, but comparing the
    /// labels as strings would put "10:00" before "8:00".
    static func isEarlier(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a != nil }
        return a < b
    }
}
