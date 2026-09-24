// Tests for the two pieces of logic in this app that are pure functions and
// silent when wrong.
//
// They are here rather than in the API's suite because the API never sees them:
// the server sends a correct wall-clock string and the app is what either keeps
// it or quietly shifts it. A bug in either of these does not crash, does not
// fail a build, and does not show up on the developer's own phone -- it shows
// up as a dose given late by a relative in another timezone.

import XCTest
@testable import CareHive

final class WallClockTests: XCTestCase {

    // MARK: - The bug this file exists to prevent

    /// The whole point. If this test ever fails, the app is converting the
    /// recipient's wall clock into the viewer's timezone, and a daughter in
    /// Chicago is being shown her mother's 8am New York dose as 7am.
    ///
    /// Run in whatever timezone the test host happens to be, on purpose: the
    /// assertion must hold everywhere, which is exactly what a conversion would
    /// not do.
    func testLocalWallClockIsNeverShiftedByTheDeviceTimezone() {
        XCTAssertEqual(WallClock.time("2026-09-24 08:00"), WallClock.format(hour: 8, minute: 0))
        XCTAssertEqual(WallClock.time("2026-09-24 20:00"), WallClock.format(hour: 20, minute: 0))
        XCTAssertEqual(WallClock.hour("2026-09-24 23:45"), 23)
    }

    /// The trap that a `DateFormatter` implementation falls into: the same wall
    /// clock on two different dates must render identically. Under a timezone
    /// conversion, the two dates straddle a DST boundary and one of them moves.
    func testTheSameWallClockRendersTheSameAcrossADSTBoundary() {
        let before = WallClock.time("2026-11-01 01:30")   // US fall-back, ambiguous hour
        let after = WallClock.time("2026-03-08 01:30")    // US spring-forward, missing hour
        XCTAssertEqual(before, WallClock.format(hour: 1, minute: 30))
        XCTAssertEqual(after, WallClock.format(hour: 1, minute: 30))
    }

    // MARK: - Parsing

    func testParsesBothTheInstantAndTheLabelShapes() {
        // The API sends seconds on instants and not on local labels; both must
        // parse, and the label must win for display.
        XCTAssertEqual(WallClock.parts("2026-09-24 08:00")?.hour, 8)
        XCTAssertEqual(WallClock.parts("2026-09-24 08:00:00")?.minute, 0)
        XCTAssertEqual(WallClock.parts("2026-09-24 13:05:59")?.hour, 13)
    }

    func testRefusesGarbageRatherThanGuessing() {
        XCTAssertNil(WallClock.parts(""))
        XCTAssertNil(WallClock.parts(nil))
        XCTAssertNil(WallClock.parts("2026-09-24"))
        XCTAssertNil(WallClock.parts("not a time"))
        XCTAssertNil(WallClock.parts("2026-09-24 8"))       // no minutes
    }

    // MARK: - Dates

    func testDayPartsAndFormatting() {
        XCTAssertEqual(WallClock.dayParts("2026-09-24")?.year, 2026)
        XCTAssertEqual(WallClock.dayParts("2026-09-24")?.month, 9)
        XCTAssertEqual(WallClock.dayParts("2026-09-24")?.day, 24)
        XCTAssertNil(WallClock.dayParts("24/09/2026"))
        XCTAssertFalse(WallClock.shortDate("2026-09-24").isEmpty)
    }

    /// Day arithmetic must not be done on instants. A 24-hour period spanning a
    /// DST change is 23 or 25 hours, so an implementation that divides seconds
    /// by 86400 gives the wrong number of days twice a year.
    func testDaysBetweenCountsCalendarDaysNotElapsedHours() {
        // Spans the US spring-forward date.
        XCTAssertEqual(WallClock.daysBetween("2026-03-07", "2026-03-09"), 2)
        // Spans the US fall-back date.
        XCTAssertEqual(WallClock.daysBetween("2026-10-31", "2026-11-02"), 2)
        // Same day, both directions.
        XCTAssertEqual(WallClock.daysBetween("2026-09-24", "2026-09-24"), 0)
        XCTAssertEqual(WallClock.daysBetween("2026-09-24", "2026-09-25"), 1)
        XCTAssertEqual(WallClock.daysBetween("2026-09-25", "2026-09-24"), -1)
        XCTAssertNil(WallClock.daysBetween("nonsense", "2026-09-24"))
    }

    // MARK: - Sorting

    /// Doses sort on the UTC instant. Sorting the display strings would put
    /// "10:00" before "8:00" -- lexicographic order is not clock order, and the
    /// bug looks like an arbitrary list rather than like a bug.
    func testDosesSortByInstantNotByLabel() {
        let eight = "2026-09-24 12:00:00"     // 08:00 New York
        let ten = "2026-09-24 14:00:00"       // 10:00 New York
        XCTAssertTrue(WallClock.isEarlier(eight, ten))
        XCTAssertFalse(WallClock.isEarlier(ten, eight))
    }

    func testSortingHandlesMissingValuesWithoutTrapping() {
        XCTAssertTrue(WallClock.isEarlier("2026-09-24 12:00:00", nil))
        XCTAssertFalse(WallClock.isEarlier(nil, "2026-09-24 12:00:00"))
        XCTAssertFalse(WallClock.isEarlier(nil, nil))
    }
}

final class StateStyleTests: XCTestCase {

    /// Overdue is a pending dose whose time has passed -- not a `missed` one.
    /// The server never calls a dose missed, because nobody has decided that;
    /// the difference matters because "Missed" on a family's screen is an
    /// accusation about a person.
    func testOverdueIsAPendingDoseNotAMissedOne() {
        let style = DS.style(for: .pending, overdue: true)
        XCTAssertEqual(style.label, "Overdue")
        let plain = DS.style(for: .pending, overdue: false)
        XCTAssertEqual(plain.label, "Due")
    }

    /// Every state must carry a distinct word, so the screen still means
    /// something in greyscale and to a reader who cannot tell the colours apart.
    func testEveryStateHasItsOwnWord() {
        let labels = [
            DS.style(for: .pending, overdue: false).label,
            DS.style(for: .pending, overdue: true).label,
            DS.style(for: .given, overdue: false).label,
            DS.style(for: .missed, overdue: false).label,
            DS.style(for: .skipped, overdue: false).label,
        ]
        XCTAssertEqual(Set(labels).count, labels.count, "two states share a word: \(labels)")
    }
}

final class FormattingTests: XCTestCase {

    /// A bare number next to a medication name is the one field in this app
    /// where a misreading has consequences, so the unit is always spelled out.
    func testUnitCountsAreAlwaysSpelledOut() {
        XCTAssertEqual(DS.units(1, "tablet"), "1 tablet")
        XCTAssertEqual(DS.units(2, "tablet"), "2 tablets")
        XCTAssertEqual(DS.units(0.5, "tablet"), "0.5 tablets")
    }

    func testMissingUnitLabelFallsBackToSomethingReadable() {
        XCTAssertEqual(DS.units(1, nil), "1 dose")
        XCTAssertEqual(DS.units(2, ""), "2 doses")
    }

    /// No strength must render as nothing at all, not as a dash or "unknown" --
    /// both of which read as an error to someone checking a pill bottle.
    func testMissingStrengthRendersAsEmpty() {
        XCTAssertEqual(DS.strength(nil), "")
        XCTAssertEqual(DS.strength(""), "")
        XCTAssertEqual(DS.strength("10 mg"), "10 mg")
    }
}

final class ErrorCopyTests: XCTestCase {

    /// A family member must never be shown a status code or a machine word.
    func testErrorsBecomeSentencesWithoutCodes() {
        let cases: [APIError] = [
            .transport("connection reset"),
            .structured(code: "insufficient_role", payload: .null),
            .structured(code: "limit_reached", payload: .null),
            .message("Not Found"),
            .unreadable(status: 500, body: "<html>"),
        ]
        for error in cases {
            let text = TodayModel.message(for: error)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("409"), text)
            XCTAssertFalse(text.contains("500"), text)
            XCTAssertFalse(text.contains("nil"), text)
            XCTAssertFalse(text.contains("_"), text)
        }
    }

    /// The 409's whole purpose is to name the person who got there first, so the
    /// attribution must survive a server that sends nothing else.
    func testAttributionNamesThePersonWhenThereIsOne() {
        let given = AlreadyGiven(givenByName: "David Whitfield",
                                 givenAt: nil,
                                 givenAtLocal: "2026-09-24 12:06",
                                 administrationId: nil,
                                 dose: nil)
        XCTAssertEqual(given.attribution, "David Whitfield gave it at 12:06")
    }

    /// And must still be true when there is not. A blank or an empty sentence
    /// would leave the person who asked holding no answer at all.
    func testAttributionIsStillTrueWithNoName() {
        let given = AlreadyGiven(givenByName: nil, givenAt: nil, givenAtLocal: nil,
                                 administrationId: nil, dose: nil)
        XCTAssertEqual(given.attribution, "This dose was already recorded")
        XCTAssertFalse(given.attribution.contains("Optional"))
    }
}
