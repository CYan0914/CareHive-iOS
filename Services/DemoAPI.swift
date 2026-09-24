// A stubbed server, for screenshots and for working on the UI without a backend.
//
// This is a full peer of `LiveAPI`, selected at launch, and that is deliberate.
// The App Store screenshot pipeline renders every screen on a CI runner that has
// no backend, no tunnel and no session; if the demo path were a special case
// threaded through the real client, that job would depend on a network it does
// not have. Instead the app is *given* a different server.
//
// The data below is written to show the product's whole point on one screen.
// The reason this app exists is that a family cannot tell whether Mum already
// had her 8am pill. So the fixture day is a real day: some doses given, one by
// someone else, one overdue, one still to come, and a PRN logged with a reason.
// A screenshot of an empty list would be honest and useless.

import Foundation

actor DemoAPI: CareHiveAPI {
    /// The names are the fixture family, and they are consistent everywhere so
    /// that a screenshot of the circle screen and one of the day screen show
    /// the same people. "You" is Sarah.
    private let you = "Sarah Whitfield"
    private let recipientId = "rc_demo_margaret"

    /// The demo day is anchored to the real date so that screenshots taken any
    /// week still say "Today" against a plausible date. `let`, not `lazy var`:
    /// an actor's mutable state should be state the demo actually changes.
    private let clock = Date()

    // MARK: - Fixtures

    /// "2026-09-24", offset by whole days. Computed in GMT so that the day
    /// arithmetic cannot be perturbed by a DST change -- the result is a
    /// calendar label, not an instant.
    private func isoDay(_ offset: Int = 0) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let d = cal.date(byAdding: .day, value: offset, to: clock) ?? clock
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    private func dose(_ n: Int, _ hhmm: String, _ med: String, _ strength: String?,
                      _ units: Double, _ unit: String, status: DoseStatus,
                      givenBy: String? = nil, givenAt: String? = nil,
                      note: String? = nil, overdue: Bool = false,
                      dstShifted: Bool = false) -> Dose {
        let day = isoDay()
        let dueLocal = "\(day) \(hhmm)"
        return Dose(
            id: "de_demo_\(n)",
            recipientId: recipientId,
            medicationId: "md_demo_\(med.lowercased())",
            phaseId: nil,
            medicationName: med,
            medicationStrength: strength,
            dueAt: "\(day) \(hhmm):00",
            dueAtLocal: dueLocal,
            dueOn: day,
            slotLabel: hhmm,
            unitsPerDose: units,
            unitLabel: unit,
            status: status,
            administrationCount: status == .given ? 1 : 0,
            dstShifted: dstShifted,
            givenAt: givenAt.map { "\(day) \($0):00" },
            givenAtLocal: givenAt.map { "\(day) \($0)" },
            givenByName: givenBy,
            note: note,
            isOverdue: overdue,
            administrations: nil)
    }

    private lazy var doses: [Dose] = [
        // Given, by someone else -- the sentence this entire product exists to
        // be able to say.
        dose(1, "08:00", "Donepezil", "10 mg", 1, "tablet",
             status: .given, givenBy: "David Whitfield", givenAt: "08:12"),
        dose(2, "09:00", "Metformin", "500 mg", 1, "tablet",
             status: .given, givenBy: you, givenAt: "09:04"),
        // Overdue. The state the family most needs to see, and the reason the
        // list is ordered by time rather than by status.
        dose(3, "12:00", "Metformin", "500 mg", 1, "tablet",
             status: .pending, overdue: true),
        dose(4, "14:00", "Lisinopril", "10 mg", 1, "tablet", status: .pending),
        dose(5, "20:00", "Atorvastatin", "20 mg", 1, "tablet", status: .pending),
    ]

    private lazy var prnToday: [PRNEntry] = [
        PRNEntry(id: "pa_demo_1", recipientId: recipientId,
                 medicationId: "md_demo_tylenol", medicationName: "Tylenol",
                 givenAt: "\(isoDay()) 09:30:00", givenAtLocal: "\(isoDay()) 09:30",
                 givenOn: isoDay(), units: 1, reason: "headache",
                 note: nil, overMax: false, givenByName: you, voidedAt: nil),
    ]

    // MARK: - Account

    func me() async throws -> Me {
        Me(user: User(id: "us_demo_you", displayName: you,
                      timezone: "America/New_York",
                      quietStartMin: 22 * 60, quietEndMin: 7 * 60),
           plan: "pro",
           limits: Limits(maxOwnedRecipients: 5, maxMedications: 100,
                          historyDays: nil, photosPerMonth: 50,
                          maxDisplayDevices: 3, supplyForecast: "full",
                          logSearch: true),
           recipients: [summary()])
    }

    func updateMe(_ patch: [String: JSONValue]) async throws -> Me { try await me() }

    private func summary() -> RecipientSummary {
        RecipientSummary(id: recipientId, displayName: "Margaret Whitfield",
                         preferredName: "Mum", timezone: "America/New_York",
                         color: "amber", photoKey: nil, role: .owner,
                         isOwner: true, medicationCount: 5)
    }

    // MARK: - Circles

    func circles() async throws -> [RecipientSummary] { [summary()] }

    func circle(_ id: String) async throws -> Recipient {
        Recipient(id: recipientId, displayName: "Margaret Whitfield",
                  preferredName: "Mum", timezone: "America/New_York",
                  dateOfBirth: "1943-04-02", color: "amber", photoKey: nil,
                  notes: nil, role: .owner, isOwner: true, callName: "Mum")
    }

    func members(_ recipientId: String) async throws -> [Member] {
        [
            Member(userId: "us_demo_you", membershipId: "mb_demo_1", role: .owner,
                   displayName: you, isOwner: true, joinedAt: nil,
                   invitedByName: nil, isYou: true),
            Member(userId: "us_demo_david", membershipId: "mb_demo_2", role: .editor,
                   displayName: "David Whitfield", isOwner: false, joinedAt: nil,
                   invitedByName: you, isYou: false),
            Member(userId: "us_demo_priya", membershipId: "mb_demo_3", role: .member,
                   displayName: "Priya Raman", isOwner: false, joinedAt: nil,
                   invitedByName: you, isYou: false),
        ]
    }

    func medications(_ recipientId: String) async throws -> [Medication] {
        [
            Medication(id: "md_demo_donepezil", recipientId: recipientId,
                       name: "Donepezil", strength: "10 mg", form: "tablet",
                       unitLabel: "tablet", instructions: "With breakfast",
                       purpose: nil, prescriber: nil, pharmacy: nil, rxNumber: nil,
                       isPrn: false, prnMaxPerDay: nil, prnMinIntervalMin: nil,
                       color: nil, active: true,
                       slots: [MedSlot(id: "sl_demo_1", localTime: "08:00",
                                       label: "Breakfast", daysOfWeek: nil,
                                       intervalDays: nil, anchorOn: nil, active: true)],
                       phases: [], summary: "Donepezil 10 mg — 08:00"),
            Medication(id: "md_demo_metformin", recipientId: recipientId,
                       name: "Metformin", strength: "500 mg", form: "tablet",
                       unitLabel: "tablet", instructions: "With food",
                       purpose: nil, prescriber: nil, pharmacy: nil, rxNumber: nil,
                       isPrn: false, prnMaxPerDay: nil, prnMinIntervalMin: nil,
                       color: nil, active: true,
                       slots: [
                        MedSlot(id: "sl_demo_2", localTime: "09:00", label: "Breakfast",
                                daysOfWeek: nil, intervalDays: nil, anchorOn: nil, active: true),
                        MedSlot(id: "sl_demo_3", localTime: "12:00", label: "Lunch",
                                daysOfWeek: nil, intervalDays: nil, anchorOn: nil, active: true),
                       ],
                       phases: [], summary: "Metformin 500 mg — 09:00, 12:00"),
            Medication(id: "md_demo_tylenol", recipientId: recipientId,
                       name: "Tylenol", strength: "500 mg", form: "tablet",
                       unitLabel: "tablet", instructions: nil, purpose: "Pain",
                       prescriber: nil, pharmacy: nil, rxNumber: nil,
                       isPrn: true, prnMaxPerDay: 4, prnMinIntervalMin: 240,
                       color: nil, active: true, slots: [], phases: [],
                       summary: "Tylenol 500 mg — as needed"),
        ]
    }

    // MARK: - The day

    func today(_ recipientId: String) async throws -> DayFeed { feed(on: nil) }

    func day(_ recipientId: String, on: String) async throws -> DayFeed { feed(on: on) }

    private func feed(on: String?) -> DayFeed {
        let day = on ?? isoDay()
        let isToday = day == isoDay()
        let shown = isToday ? doses : doses.map { d in
            // A future day is entirely pending and nobody has touched it, which
            // is what the schedule screen actually looks like.
            dose(Int(d.id.suffix(1)) ?? 0, d.slotLabel ?? "08:00", d.medicationName,
                 d.medicationStrength, d.unitsPerDose, d.unitLabel ?? "tablet",
                 status: .pending)
        }
        let given = shown.filter { $0.status == .given }.count
        return DayFeed(
            date: day,
            isToday: isToday,
            recipient: DayRecipient(id: recipientId, name: "Margaret Whitfield",
                                    callName: "Mum", timezone: "America/New_York"),
            doses: shown,
            prnToday: isToday ? prnToday : [],
            counts: DayCounts(total: shown.count,
                              pending: shown.count - given,
                              given: given,
                              missed: 0,
                              skipped: 0,
                              overdue: shown.filter { $0.isOverdue == true }.count,
                              activeMedications: 3,
                              prnToday: isToday ? prnToday.count : 0),
            beyondHorizon: false,
            horizonEnd: isoDay(21),
            yourRole: .owner,
            canRecord: true)
    }

    func schedule(_ recipientId: String, days: Int) async throws -> [ScheduleDay] {
        (0..<min(days, 7)).map { offset in
            ScheduleDay(date: isoDay(offset), isToday: offset == 0,
                        counts: DayCounts(total: doses.count - (offset == 0 ? 2 : 0),
                                          pending: 3, given: offset == 0 ? 2 : 0,
                                          missed: 0, skipped: 0, overdue: 0,
                                          activeMedications: 3, prnToday: 0),
                        doses: offset == 0 ? doses : [])
        }
    }

    // MARK: - Recording

    /// Records locally and returns the same shape the server would.
    ///
    /// One dose is wired to answer with the race instead: `de_demo_3` is the
    /// overdue lunchtime dose, and asking for it returns "someone else got
    /// there" naming David. That is not a stub shortcut -- it is the only way to
    /// screenshot the screen that a two-sibling household sees several times a
    /// week, without needing two phones and a real race.
    func give(doseId: String, clientRef: String, note: String?) async throws -> GiveOutcome {
        if doseId == "de_demo_3" {
            let already = AlreadyGiven(
                givenByName: "David Whitfield",
                givenAt: "\(isoDay()) 12:06:00",
                givenAtLocal: "\(isoDay()) 12:06",
                administrationId: "ad_demo_race",
                dose: dose(3, "12:00", "Metformin", "500 mg", 1, "tablet",
                           status: .given, givenBy: "David Whitfield",
                           givenAt: "12:06"))
            return .someoneElseGotThere(already)
        }
        guard let i = doses.firstIndex(where: { $0.id == doseId }) else {
            throw APIError.message("Not Found")
        }
        let old = doses[i]
        let now = WallClock.time("\(isoDay()) \(currentHHMM)")
        doses[i] = dose(Int(old.id.suffix(1)) ?? 0, old.slotLabel ?? "08:00",
                        old.medicationName, old.medicationStrength,
                        old.unitsPerDose, old.unitLabel ?? "tablet",
                        status: .given, givenBy: you, givenAt: now,
                        note: note)
        return .recorded(dose: doses[i])
    }

    private var currentHHMM: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.hour, .minute], from: clock)
        return String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
    }

    func skip(doseId: String, reason: String?) async throws -> Dose {
        guard let i = doses.firstIndex(where: { $0.id == doseId }) else {
            throw APIError.message("Not Found")
        }
        let old = doses[i]
        doses[i] = dose(Int(old.id.suffix(1)) ?? 0, old.slotLabel ?? "08:00",
                        old.medicationName, old.medicationStrength,
                        old.unitsPerDose, old.unitLabel ?? "tablet",
                        status: .skipped, note: reason)
        return doses[i]
    }

    func undo(doseId: String) async throws -> VoidResult {
        guard let i = doses.firstIndex(where: { $0.id == doseId }) else {
            throw APIError.message("Not Found")
        }
        let old = doses[i]
        doses[i] = dose(Int(old.id.suffix(1)) ?? 0, old.slotLabel ?? "08:00",
                        old.medicationName, old.medicationStrength,
                        old.unitsPerDose, old.unitLabel ?? "tablet",
                        status: .pending)
        return VoidResult(voided: true, dose: doses[i], remainingAdministrations: 0,
                          voidedAdministration: nil)
    }

    func recordPRN(_ recipientId: String, medicationId: String, reason: String?,
                   clientRef: String) async throws -> PRNResult {
        PRNResult(duplicate: false,
                  administration: PRNEntry(
                    id: "pa_demo_new", recipientId: recipientId,
                    medicationId: medicationId, medicationName: "Tylenol",
                    givenAt: "\(isoDay()) \(currentHHMM):00",
                    givenAtLocal: "\(isoDay()) \(currentHHMM)",
                    givenOn: isoDay(), units: 1, reason: reason, note: nil,
                    overMax: false, givenByName: you, voidedAt: nil),
                  todayCount: prnToday.count + 1,
                  yourDailyCeiling: 4,
                  minutesSinceLast: 95,
                  youMinInterval: 240)
    }
}
