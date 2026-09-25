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
    /// The demo circle's one recipient. Named here rather than repeated at each
    /// call site, because the screens the capture job launches directly have to
    /// agree with the ones the demo server answers for -- and a screenshot job
    /// that fails because two string literals drifted is a failure that looks
    /// like a crash.
    static let recipient = "rc_demo_margaret"
    private let recipientId = DemoAPI.recipient

    /// The medication list, mutable because the demo is also how the UI is
    /// worked on with no backend: adding a medication has to put it on the
    /// screen, and stopping one has to take it off.
    ///
    /// It does not, however, feed the day screen. The doses below are a
    /// hand-written fixture -- one of each state, which is the whole point of
    /// them -- and generating them from this list would replace a day that shows
    /// every case with a day that shows whatever the arithmetic produced. A
    /// medication added in the demo therefore appears on this list and not on
    /// Today, which is a demo limitation and not a claim about the product.
    private var meds: [Medication] = DemoAPI.seedMedications()

    /// The demo day is anchored to the real date so that screenshots taken any
    /// week still say "Today" against a plausible date. `let`, not `lazy var`:
    /// an actor's mutable state should be state the demo actually changes.
    private let clock = Date()

    /// The signed-in user's own settings, as `PATCH /me` can change them.
    ///
    /// Mutable because the settings screen is one of the screens the capture job
    /// photographs *after* an edit as well as before one, and a demo that
    /// answered every write with the value it started with would photograph a
    /// screen that ignores its user.
    private var displayName: String? = "Sarah Whitfield"
    private var timezone = "America/New_York"
    private var quietStart = 22 * 60
    private var quietEnd = 7 * 60

    /// One formatter for quiet hours, in `DS` next to the other formatting, so
    /// that the demo and the settings screen cannot disagree about what 1260
    /// reads as. The server has its own copy of this and the two must match.
    static func hhmm(_ minutes: Int) -> String { DS.clock(minutes: minutes) }

    // MARK: - Fixtures

    /// "2026-09-24", offset by whole days. Computed in GMT so that the day
    /// arithmetic cannot be perturbed by a DST change -- the result is a
    /// calendar label, not an instant.
    ///
    /// The fixtures that a taper is dated from need this at property-
    /// initialization time, which is before the instance exists, so the
    /// arithmetic is static and the instance form is a thin wrapper.
    static func day(_ offset: Int, from moment: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let d = cal.date(byAdding: .day, value: offset, to: moment) ?? moment
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    private func isoDay(_ offset: Int = 0) -> String { DemoAPI.day(offset, from: clock) }

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
        Me(user: User(id: "us_demo_you", displayName: displayName,
                      timezone: timezone,
                      quietStartMin: quietStart, quietEndMin: quietEnd),
           plan: "pro",
           limits: Limits(maxOwnedRecipients: 5, maxMedications: 100,
                          historyDays: nil, photosPerMonth: 50,
                          maxDisplayDevices: 3,
                          // "calendar", not "full": the server's two values are
                          // `threshold` and `calendar`, and a demo that invents
                          // a third would let a client branch on a string the
                          // real server never sends.
                          supplyForecast: "calendar",
                          logSearch: true),
           recipients: [summary()])
    }

    func updateMe(_ patch: MePatch) async throws -> MeUpdate {
        // The demo applies the change, so a settings screen can be photographed
        // after a change rather than only before one. The three-state rule is
        // honoured: an absent key is not touched, an explicit null clears.
        if case .string(let name)? = patch.displayName { displayName = name }
        if case .null? = patch.displayName { displayName = nil }
        if let tz = patch.timezone { timezone = tz }
        if let start = patch.quietStartMin { quietStart = start }
        if let end = patch.quietEndMin { quietEnd = end }
        var changed = 0
        if patch.displayName != nil { changed += 1 }
        if patch.timezone != nil { changed += 1 }
        if patch.quietStartMin != nil { changed += 1 }
        if patch.quietEndMin != nil { changed += 1 }
        return MeUpdate(
            user: User(id: "us_demo_you", displayName: displayName,
                       timezone: timezone, quietStartMin: quietStart,
                       quietEndMin: quietEnd),
            changed: changed,
            quietHours: "\(Self.hhmm(quietStart))-\(Self.hhmm(quietEnd))")
    }

    private func summary() -> RecipientSummary {
        RecipientSummary(id: recipientId, displayName: "Margaret Whitfield",
                         preferredName: "Mum", timezone: "America/New_York",
                         color: "amber", photoKey: nil, role: .owner,
                         isOwner: true, medicationCount: meds.count)
    }

    // MARK: - Circles

    func circles() async throws -> [RecipientSummary] { [summary()] }

    func circle(_ id: String) async throws -> Recipient {
        Recipient(id: recipientId, displayName: "Margaret Whitfield",
                  preferredName: "Mum", timezone: "America/New_York",
                  dateOfBirth: "1943-04-02", color: "amber", photoKey: nil,
                  notes: nil, role: .owner, isOwner: true, callName: "Mum")
    }

    func members(_ recipientId: String) async throws -> [Member] { memberList }

    // MARK: - Medications

    /// The fixture list. Four medications, chosen so that every shape the list
    /// screen has to draw appears at least once: a plain daily medication, one
    /// with two times a day, a taper with three steps, and a PRN with a ceiling.
    private static func seedMedications() -> [Medication] {
        let rid = DemoAPI.recipient
        func slot(_ n: Int, _ time: String, _ label: String?, days: [Int]? = nil) -> MedSlot {
            MedSlot(id: "sl_demo_\(n)", localTime: time, label: label,
                    daysOfWeek: days, intervalDays: nil, anchorOn: nil)
        }
        return [
            Medication(id: "md_demo_donepezil", recipientId: rid,
                       name: "Donepezil", strength: "10 mg", form: "tablet",
                       unitLabel: "tablet", instructions: "With breakfast",
                       purpose: nil, prescriber: "Dr. Alvarez", pharmacy: nil,
                       rxNumber: nil, isPrn: false, prnMaxPerDay: nil,
                       prnMinIntervalMin: nil, color: nil, active: true,
                       slots: [slot(1, "08:00", "Breakfast")], phases: [],
                       summary: "Donepezil 10 mg — 08:00"),
            Medication(id: "md_demo_metformin", recipientId: rid,
                       name: "Metformin", strength: "500 mg", form: "tablet",
                       unitLabel: "tablet", instructions: "With food",
                       purpose: "Blood sugar", prescriber: "Dr. Alvarez",
                       pharmacy: nil, rxNumber: nil, isPrn: false,
                       prnMaxPerDay: nil, prnMinIntervalMin: nil, color: nil,
                       active: true,
                       slots: [slot(2, "09:00", "Breakfast"), slot(3, "12:00", "Lunch")],
                       phases: [], summary: "Metformin 500 mg — 09:00, 12:00"),
            // The taper, because it is the case a schedule editor exists for:
            // three amounts over three weeks is three rows here rather than
            // twenty-one scheduled doses.
            Medication(id: "md_demo_prednisone", recipientId: rid,
                       name: "Prednisone", strength: "5 mg", form: "tablet",
                       unitLabel: "tablet",
                       instructions: "Take with food. Do not stop early.",
                       purpose: "Chest infection", prescriber: "Dr. Alvarez",
                       pharmacy: nil, rxNumber: nil, isPrn: false,
                       prnMaxPerDay: nil, prnMinIntervalMin: nil, color: nil,
                       active: true,
                       slots: [slot(4, "08:00", "Breakfast"), slot(5, "20:00", "Evening")],
                       phases: [
                        MedPhase(id: "ph_demo_1", startsOn: DemoAPI.day(-6),
                                 endsOn: DemoAPI.day(7), unitsPerDose: 4, label: "Step 1"),
                        MedPhase(id: "ph_demo_2", startsOn: DemoAPI.day(8),
                                 endsOn: DemoAPI.day(14), unitsPerDose: 2, label: "Step 2"),
                        MedPhase(id: "ph_demo_3", startsOn: DemoAPI.day(15),
                                 endsOn: nil, unitsPerDose: 1, label: "Step 3"),
                       ],
                       summary: "Prednisone 5 mg — 08:00, 20:00"),
            Medication(id: "md_demo_tylenol", recipientId: rid,
                       name: "Tylenol", strength: "500 mg", form: "tablet",
                       unitLabel: "tablet", instructions: nil, purpose: "Pain",
                       prescriber: nil, pharmacy: nil, rxNumber: nil,
                       isPrn: true, prnMaxPerDay: 4, prnMinIntervalMin: 240,
                       color: nil, active: true, slots: [], phases: [],
                       summary: "Tylenol 500 mg — as needed"),
        ]
    }

    func medications(_ recipientId: String) async throws -> MedicationCatalog {
        MedicationCatalog(medications: meds, formOptions: DemoAPI.formOptions,
                          recipientTimezone: "America/New_York")
    }

    func createMedication(_ recipientId: String,
                          _ draft: MedicationDraft) async throws -> Medication {
        let med = DemoAPI.build(id: "md_demo_\(meds.count + 1)", recipientId: recipientId,
                                draft: draft,
                                phases: draft.newPhase.map { [DemoAPI.wirePhase($0, index: 1)] } ?? [])
        meds.append(med)
        return med
    }

    func updateMedication(_ medicationId: String,
                          _ draft: MedicationDraft) async throws -> Medication {
        guard let i = meds.firstIndex(where: { $0.id == medicationId }) else {
            throw APIError.message("Not Found")
        }
        // Existing phases survive an edit; `newPhase` is appended, mirroring the
        // server, where PATCH can add a step but never replace the sequence.
        var phases = meds[i].phases
        if let step = draft.newPhase {
            phases.append(DemoAPI.wirePhase(step, index: phases.count + 1))
        }
        let med = DemoAPI.build(id: medicationId, recipientId: meds[i].recipientId,
                                draft: draft, phases: phases)
        meds[i] = med
        return med
    }

    func archiveMedication(_ medicationId: String) async throws {
        meds.removeAll { $0.id == medicationId }
    }

    func deletePhase(_ phaseId: String) async throws {
        for i in meds.indices {
            let remaining = meds[i].phases.filter { $0.id != phaseId }
            guard remaining.count != meds[i].phases.count else { continue }
            let m = meds[i]
            meds[i] = Medication(
                id: m.id, recipientId: m.recipientId, name: m.name, strength: m.strength,
                form: m.form, unitLabel: m.unitLabel, instructions: m.instructions,
                purpose: m.purpose, prescriber: m.prescriber, pharmacy: m.pharmacy,
                rxNumber: m.rxNumber, isPrn: m.isPrn, prnMaxPerDay: m.prnMaxPerDay,
                prnMinIntervalMin: m.prnMinIntervalMin, color: m.color, active: m.active,
                slots: m.slots, phases: remaining, summary: m.summary)
            return
        }
        throw APIError.message("Not Found")
    }

    /// The demo's dose forms. The real list comes from the server so the app
    /// cannot drift from it; this is the one copy, and it is only ever used by
    /// the demo server, which has no other server to ask.
    private static let formOptions = [
        "tablet", "capsule", "liquid", "drops", "injection", "patch", "inhaler",
        "cream", "spray", "suppository", "powder", "other",
    ]

    /// A draft turned into a medication, the way the server would.
    ///
    /// Slots are given fresh ids on every save because the server gives them
    /// fresh ids on every save -- PATCH deactivates the old rows and inserts new
    /// ones. Mirroring that keeps the demo from being quietly kinder than the
    /// thing it stands in for.
    /// One step of a taper, in the shape the server would have sent it back.
    ///
    /// `MedicationDraft.Phase` is what the form collects; `MedPhase` is what
    /// arrives on the wire. They are separate types on purpose and not a
    /// duplication to be collapsed: the draft carries no id, because the id
    /// belongs to whoever stores the row, and it holds an empty label where the
    /// wire model holds nil, because a text field is always a string.
    ///
    /// The real client bridges them by encoding `MedicationDraft.phaseJSON`.
    /// The demo has no JSON in the middle, so it has to bridge them in Swift --
    /// and skipping the bridge is not a near-miss, it is a type error: a step
    /// the family adds on a new medication is a `Phase` sitting in an array
    /// declared `[MedPhase]`. That is exactly what happened in
    /// `createMedication`, which passed `draft.newPhase` straight through while
    /// `updateMedication` converted. Hence one function rather than the same
    /// six lines written twice, once correctly.
    ///
    /// The id keeps the `ph_demo_new_` prefix the editor's delete uses to find
    /// a step it may remove before saving; `index` is what makes it unique
    /// within one medication.
    private static func wirePhase(_ phase: MedicationDraft.Phase,
                                  index: Int) -> MedPhase {
        MedPhase(id: "ph_demo_new_\(index)",
                 startsOn: phase.startsOn, endsOn: phase.endsOn,
                 unitsPerDose: phase.unitsPerDose,
                 label: phase.label.isEmpty ? nil : phase.label)
    }

    private static func build(id: String, recipientId: String,
                              draft: MedicationDraft,
                              phases: [MedPhase]) -> Medication {
        let slots = draft.isPrn ? [] : draft.slots.map { s in
            MedSlot(id: "sl_demo_\(UUID().uuidString.prefix(8).lowercased())",
                    localTime: s.localTime,
                    label: s.label.isEmpty ? nil : s.label,
                    daysOfWeek: s.daysOfWeek, intervalDays: s.intervalDays,
                    anchorOn: s.anchorOn)
        }
        return Medication(
            id: id, recipientId: recipientId, name: draft.name,
            strength: blank(draft.strength), form: blank(draft.form),
            unitLabel: blank(draft.unitLabel) ?? "tablet",
            instructions: blank(draft.instructions), purpose: blank(draft.purpose),
            prescriber: blank(draft.prescriber), pharmacy: blank(draft.pharmacy),
            rxNumber: blank(draft.rxNumber), isPrn: draft.isPrn,
            prnMaxPerDay: draft.isPrn ? draft.prnMaxPerDay.map { Double($0) } : nil,
            prnMinIntervalMin: draft.isPrn ? draft.prnMinIntervalMin : nil,
            color: nil, active: true, slots: slots, phases: phases,
            summary: nil)
    }

    private static func blank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
                              activeMedications: meds.count,
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
                                          activeMedications: meds.count, prnToday: 0),
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

    func undoPRN(_ administrationId: String) async throws {
        prnToday.removeAll { $0.id == administrationId }
    }

    // MARK: - Who else is in this

    /// Members are stored rather than returned from a constant, because the
    /// circle screen is the one place the demo has to be able to *show* a
    /// change: promoting David and seeing the word "Editor" appear next to his
    /// name is the entire experience of the feature.
    private var memberList: [Member] = DemoAPI.seedMembers()

    private static func seedMembers() -> [Member] {
        [
            Member(userId: "us_demo_you", membershipId: "mb_demo_1", role: .owner,
                   displayName: "Sarah Whitfield", isOwner: true,
                   joinedAt: DemoAPI.day(-210), invitedByName: nil, isYou: true),
            Member(userId: "us_demo_david", membershipId: "mb_demo_2", role: .editor,
                   displayName: "David Whitfield", isOwner: false,
                   joinedAt: DemoAPI.day(-208), invitedByName: "Sarah Whitfield",
                   isYou: false),
            Member(userId: "us_demo_priya", membershipId: "mb_demo_3", role: .member,
                   displayName: "Priya Raman", isOwner: false,
                   joinedAt: DemoAPI.day(-35), invitedByName: "David Whitfield",
                   isYou: false),
        ]
    }

    func updateMember(_ recipientId: String, userId: String,
                      role: Role) async throws -> MemberChangeResult {
        guard let i = memberList.firstIndex(where: { $0.userId == userId }) else {
            throw APIError.structured(code: "member_not_found",
                                      payload: .object(["error": .string("member_not_found")]))
        }
        let old = memberList[i]
        memberList[i] = Member(userId: old.userId, membershipId: old.membershipId,
                               role: role, displayName: old.displayName,
                               isOwner: old.isOwner, joinedAt: old.joinedAt,
                               invitedByName: old.invitedByName, isYou: old.isYou)
        return MemberChangeResult(userId: userId, role: role, changed: true, removed: false,
                                  note: nil)
    }

    func removeMember(_ recipientId: String, userId: String) async throws -> MemberChangeResult {
        guard let i = memberList.firstIndex(where: { $0.userId == userId }) else {
            throw APIError.structured(code: "member_not_found",
                                      payload: .object(["error": .string("member_not_found")]))
        }
        // The owner leaving a circle with other people in it is refused by the
        // server for a reason worth reproducing here: handing the demo a
        // success the real server would refuse teaches the wrong lesson about
        // what the button does.
        if memberList[i].isOwner && memberList.count > 1 {
            throw APIError.structured(
                code: "ownership_transfer_required",
                payload: .object([
                    "error": .string("ownership_transfer_required"),
                    "other_members": .number(Double(memberList.count - 1)),
                ]))
        }
        memberList.remove(at: i)
        return MemberChangeResult(
            userId: userId, role: nil, changed: false, removed: true,
            note: "Their recorded doses stay in the history with their name on them. "
                + "Removing someone does not rewrite what happened.")
    }

    func transfer(_ recipientId: String, toUserId: String) async throws -> TransferResult {
        guard memberList.contains(where: { $0.userId == toUserId }) else {
            throw APIError.structured(code: "member_not_found",
                                      payload: .object(["error": .string("member_not_found")]))
        }
        for j in memberList.indices {
            let old = memberList[j]
            let role: Role = old.userId == toUserId ? .owner : (old.isYou ? .editor : old.role)
            memberList[j] = Member(userId: old.userId, membershipId: old.membershipId,
                                   role: role, displayName: old.displayName,
                                   isOwner: old.userId == toUserId,
                                   joinedAt: old.joinedAt,
                                   invitedByName: old.invitedByName, isYou: old.isYou)
        }
        return TransferResult(
            ownerUserId: toUserId, yourRole: .editor,
            note: "You are now an editor and can still record doses and edit schedules. "
                + "Only invites and deletion moved.")
    }

    // MARK: - Invites

    /// Only the live ones. A redeemed invite's code is gone from the server and
    /// cannot be reproduced here either, which is the honest state of a demo
    /// that never had a second phone in it.
    private var inviteList: [Invite] = []

    func createInvite(_ recipientId: String, role: Role,
                      label: String?) async throws -> InviteCreated {
        let code = DemoAPI.code()
        let invite = Invite(id: "iv_demo_\(inviteList.count + 1)", code: code,
                            codeHint: "••••-\(code.suffix(2))", role: role, label: label,
                            createdAt: "\(isoDay()) \(currentHHMM):00",
                            expiresAt: nil, redeemedAt: nil, revokedAt: nil,
                            createdByName: you, redeemedByName: nil, live: true)
        inviteList.append(invite)
        return InviteCreated(
            invite: invite,
            shareText: "Join me in caring for Margaret Whitfield on CareHive. "
                + "Your code is \(code) — it expires in 10 minutes.",
            note: "This code is shown once. Anyone who has it can join the circle, "
                + "so send it to one person.")
    }

    /// The same shape the server mints: four characters, a dash, four more. The
    /// alphabet avoids I, O, 0 and 1 -- a rule about people reading a code off
    /// one phone and typing it into another, which is the only way this code
    /// ever travels.
    private static func code() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func block(_ n: Int) -> String {
            String((0..<n).map { _ in alphabet.randomElement() ?? "A" })
        }
        return "\(block(4))-\(block(4))"
    }

    func invites(_ recipientId: String) async throws -> InviteList {
        // The list never carries a code again -- the server stores a digest --
        // so the demo strips it here too. A demo that showed the code forever
        // would make the UI look like it could re-display one.
        let redacted = inviteList.map {
            Invite(id: $0.id, code: nil, codeHint: $0.codeHint, role: $0.role,
                   label: $0.label, createdAt: $0.createdAt, expiresAt: $0.expiresAt,
                   redeemedAt: $0.redeemedAt, revokedAt: $0.revokedAt,
                   createdByName: $0.createdByName, redeemedByName: $0.redeemedByName,
                   live: $0.live)
        }
        return InviteList(count: redacted.count,
                          liveCount: redacted.filter(\.live).count,
                          invites: redacted)
    }

    func revokeInvite(_ inviteId: String) async throws {
        guard let i = inviteList.firstIndex(where: { $0.id == inviteId }) else {
            throw APIError.message("Not Found")
        }
        let old = inviteList[i]
        inviteList[i] = Invite(id: old.id, code: nil, codeHint: old.codeHint, role: old.role,
                               label: old.label, createdAt: old.createdAt,
                               expiresAt: old.expiresAt, redeemedAt: old.redeemedAt,
                               revokedAt: "\(isoDay()) \(currentHHMM):00",
                               createdByName: old.createdByName,
                               redeemedByName: old.redeemedByName, live: false)
    }

    /// The demo preview answers for any code, because there is no server to
    /// check one against and the screen it drives is reached by a deep link
    /// that a screenshot job has to be able to open.
    func previewInvite(code: String) async throws -> InvitePreview {
        InvitePreview(recipientFirstName: "Margaret", inviterFirstName: "Sarah",
                      expiresAt: nil, alreadyRedeemed: false)
    }

    func redeemInvite(code: String) async throws -> Redeemed {
        guard let i = inviteList.firstIndex(where: { $0.live }) else {
            throw APIError.structured(
                code: "invalid_code",
                payload: .object(["error": .string("invalid_code"),
                                  "message": .string("That code was not recognised.")]))
        }
        let inv = inviteList[i]
        inviteList[i] = Invite(id: inv.id, code: nil, codeHint: inv.codeHint, role: inv.role,
                               label: inv.label, createdAt: inv.createdAt,
                               expiresAt: inv.expiresAt,
                               redeemedAt: "\(isoDay()) \(currentHHMM):00",
                               revokedAt: nil, createdByName: inv.createdByName,
                               redeemedByName: "Dev User", live: false)
        return Redeemed(joined: true, role: inv.role, recipient: try await circle(recipientId))
    }

    // MARK: - What happened

    /// A week of a real household. Every kind of row the log can draw appears
    /// at least once, because the screen's whole job is to make them
    /// distinguishable at a glance -- and a fixture of six identical "given"
    /// rows would not show that it does.
    private lazy var journal: [JournalEntry] = DemoAPI.seedJournal()

    private static func seedJournal() -> [JournalEntry] {
        let rid = DemoAPI.recipient
        func photo(_ n: Int) -> JournalPhoto {
            JournalPhoto(id: "jp_demo_\(n)", url: nil, width: 1200, height: 1600,
                         createdAt: DemoAPI.day(-2) + " 10:00:00")
        }
        return [
            JournalEntry(id: "jr_demo_1", kind: "note", recipientId: rid,
                         authorName: "David Whitfield", authorId: "us_demo_david",
                         entryOn: DemoAPI.day(-2),
                         body: "She seemed a bit unsteady after lunch but perked up "
                             + "by four. No change to the pills.",
                         mood: "okay", createdAt: DemoAPI.day(-2) + " 16:20:00",
                         createdAtLocal: DemoAPI.day(-2) + " 12:20", edited: false,
                         editedAt: nil, editedAtLocal: nil, voidedAt: nil,
                         photos: [photo(1)]),
            JournalEntry(id: "jr_demo_2", kind: "note", recipientId: rid,
                         authorName: "Priya Raman", authorId: "us_demo_priya",
                         entryOn: DemoAPI.day(-4),
                         body: "Nurse said to keep the water by her chair, she is not "
                             + "drinking enough in the afternoon.",
                         mood: nil, createdAt: DemoAPI.day(-4) + " 18:05:00",
                         createdAtLocal: DemoAPI.day(-4) + " 14:05", edited: false,
                         editedAt: nil, editedAtLocal: nil, voidedAt: nil, photos: []),
            JournalEntry(id: "jr_demo_3", kind: "note", recipientId: rid,
                         authorName: "Sarah Whitfield", authorId: "us_demo_you",
                         entryOn: DemoAPI.day(-6),
                         body: "Pharmacy had the Prednisone ready. New box is in the "
                             + "kitchen drawer, not the bathroom cabinet.",
                         mood: nil, createdAt: DemoAPI.day(-6) + " 09:40:00",
                         createdAtLocal: DemoAPI.day(-6) + " 05:40",
                         // Edited, and marked as edited. A note that changed is a
                         // different thing from one that did not and the family
                         // is entitled to know which they are reading.
                         edited: true, editedAt: DemoAPI.day(-6) + " 09:52:00",
                         editedAtLocal: DemoAPI.day(-6) + " 05:52", voidedAt: nil,
                         photos: []),
        ]
    }

    func log(_ recipientId: String, from: String?, to: String?, kinds: [String]?,
             cursor: String?, limit: Int) async throws -> LogPage {
        var rows: [LogEntry] = []
        // Today's doses, as the log would record them: given ones with a name
        // and a time, the skipped one with its reason.
        for d in doses {
            switch d.status {
            case .given:
                rows.append(LogEntry(
                    kind: "dose", id: "lg_\(d.id)", at: d.givenAt, atLocal: d.givenAtLocal,
                    on: d.dueOn, state: "given", actorName: d.givenByName,
                    medication: d.medicationName, units: d.unitsPerDose,
                    unitLabel: d.unitLabel, slotLabel: d.slotLabel, note: d.note,
                    via: "app", voidedAt: nil, doseId: d.id, dstShifted: false,
                    mood: nil, entryId: nil, photoCount: nil, body: nil,
                    bodyTruncated: nil))
            case .skipped:
                rows.append(LogEntry(
                    kind: "dose", id: "lg_\(d.id)", at: nil, atLocal: nil, on: d.dueOn,
                    state: "skipped", actorName: "David Whitfield",
                    medication: d.medicationName, units: d.unitsPerDose,
                    unitLabel: d.unitLabel, slotLabel: d.slotLabel, note: d.note,
                    via: "app", voidedAt: nil, doseId: d.id, dstShifted: false,
                    mood: nil, entryId: nil, photoCount: nil, body: nil,
                    bodyTruncated: nil))
            case .pending, .missed:
                break
            }
        }
        for p in prnToday {
            rows.append(LogEntry(
                kind: "prn", id: "lg_\(p.id)", at: p.givenAt, atLocal: p.givenAtLocal,
                on: p.givenOn, state: "given", actorName: p.givenByName,
                medication: p.medicationName, units: p.units, unitLabel: "tablet",
                slotLabel: nil, note: p.reason ?? p.note, via: "app", voidedAt: nil,
                doseId: nil, dstShifted: false, mood: nil, entryId: nil,
                photoCount: nil, body: nil, bodyTruncated: nil))
        }
        // A dose recorded on the printed kitchen card rather than in the app.
        // It is the row that shows why `via` exists at all.
        rows.append(LogEntry(
            kind: "dose", id: "lg_card", at: nil, atLocal: "\(DemoAPI.day(-1)) 20:05",
            on: DemoAPI.day(-1), state: "given", actorName: "Margaret Whitfield",
            medication: "Atorvastatin", units: 1, unitLabel: "tablet",
            slotLabel: "Evening", note: nil, via: "card", voidedAt: nil,
            doseId: nil, dstShifted: false, mood: nil, entryId: nil, photoCount: nil,
            body: nil, bodyTruncated: nil))
        // A membership change, in the same list. It goes here because the
        // question "who could see this in March" is answered by the same screen
        // as "what happened in March".
        rows.append(LogEntry(
            kind: "circle", id: "lg_priya", at: DemoAPI.day(-35) + " 11:00:00",
            atLocal: DemoAPI.day(-35) + " 07:00", on: DemoAPI.day(-35), state: nil,
            actorName: "David Whitfield", medication: nil, units: nil,
            unitLabel: nil, slotLabel: nil,
            note: "Priya Raman joined the circle", via: nil, voidedAt: nil,
            doseId: nil, dstShifted: false, mood: nil, entryId: nil, photoCount: nil,
            body: nil, bodyTruncated: nil))
        for j in journal {
            rows.append(LogEntry(
                kind: "note", id: "lg_\(j.id)", at: j.createdAt, atLocal: j.createdAtLocal,
                on: j.entryOn, state: nil, actorName: j.authorName, medication: nil,
                units: nil, unitLabel: nil, slotLabel: nil, note: nil, via: "app",
                voidedAt: nil, doseId: nil, dstShifted: false, mood: j.mood,
                entryId: j.id, photoCount: j.photos.count,
                body: String(j.body.prefix(140)),
                bodyTruncated: j.body.count > 140))
        }
        rows.sort { ($0.at ?? "") > ($1.at ?? "") }
        if let kinds, !kinds.isEmpty {
            rows = rows.filter { kinds.contains($0.kind) }
        }
        let page = Array(rows.prefix(limit))
        return LogPage(
            recipientId: recipientId, timezone: "America/New_York", entries: page,
            count: page.count, nextCursor: rows.count > limit ? "demo-more" : nil,
            hasMore: rows.count > limit,
            range: LogRange(from: DemoAPI.day(-30), to: DemoAPI.day(0)),
            historyFrom: DemoAPI.day(-30), limitedByPlan: false, searchAvailable: true,
            yourRole: .owner, canWrite: true)
    }

    func createEntry(_ recipientId: String, body: String, kind: String,
                     mood: String?) async throws -> JournalEntry {
        let entry = JournalEntry(
            id: "jr_demo_\(journal.count + 1)", kind: kind, recipientId: recipientId,
            authorName: you, authorId: "us_demo_you", entryOn: isoDay(), body: body,
            mood: mood, createdAt: "\(isoDay()) \(currentHHMM):00",
            createdAtLocal: "\(isoDay()) \(currentHHMM)", edited: false,
            editedAt: nil, editedAtLocal: nil, voidedAt: nil, photos: [])
        journal.insert(entry, at: 0)
        return entry
    }

    func entry(_ entryId: String) async throws -> JournalEntryBody {
        guard let e = journal.first(where: { $0.id == entryId }) else {
            throw APIError.message("Not Found")
        }
        return JournalEntryBody(entry: e, yourRole: .owner, canWrite: true)
    }

    func updateEntry(_ entryId: String, body: String?,
                     mood: String?) async throws -> JournalEntry {
        guard let i = journal.firstIndex(where: { $0.id == entryId }) else {
            throw APIError.message("Not Found")
        }
        let old = journal[i]
        let edited = JournalEntry(
            id: old.id, kind: old.kind, recipientId: old.recipientId,
            authorName: old.authorName, authorId: old.authorId, entryOn: old.entryOn,
            body: body ?? old.body, mood: mood ?? old.mood, createdAt: old.createdAt,
            createdAtLocal: old.createdAtLocal, edited: true,
            editedAt: "\(isoDay()) \(currentHHMM):00",
            editedAtLocal: "\(isoDay()) \(currentHHMM)", voidedAt: old.voidedAt,
            photos: old.photos)
        journal[i] = edited
        return edited
    }

    func deleteEntry(_ entryId: String) async throws {
        journal.removeAll { $0.id == entryId }
    }

    // MARK: - What is left

    /// Counts, not forecasts. Donepezil is below the family's own threshold and
    /// that is the state worth putting on a screenshot; Prednisone is tracked
    /// and fine; Tylenol is a PRN nobody counts.
    private lazy var supplies: [Supply] = DemoAPI.seedSupply()

    private static func seedSupply() -> [Supply] {
        // The projection the server would have computed: a rate over the last
        // thirty days of doses, applied to what is left. Built here rather than
        // faked as a fixed date so that the demo's arithmetic still agrees with
        // its own counts when the calendar moves.
        func forecast(perDay: Double, onHand: Double, basis: Int = 30,
                      consumed: Double) -> SupplyForecast {
            let daysLeft = perDay > 0 ? onHand / perDay : 0
            let beyond = daysLeft > 3650
            return SupplyForecast(
                available: true, reason: nil, basisDays: basis,
                consumedInBasis: consumed, perDay: perDay,
                daysLeft: (daysLeft * 10).rounded() / 10,
                runsOutOn: beyond ? nil : DemoAPI.day(Int(daysLeft)),
                beyondHorizon: beyond ? true : nil, estimated: true)
        }
        return [
            Supply(medicationId: "md_demo_donepezil", name: "Donepezil", strength: "10 mg",
                   unitLabel: "tablet", isPrn: false, tracked: true, unitsOnHand: 6,
                   countedAt: DemoAPI.day(-3) + " 09:00:00",
                   countedAtLocal: DemoAPI.day(-3) + " 05:00", consumedSinceCount: 3,
                   refillAt: 14, belowRefillAt: true, lastRefillOn: DemoAPI.day(-30),
                   forecast: forecast(perDay: 1, onHand: 6, consumed: 30)),
            Supply(medicationId: "md_demo_metformin", name: "Metformin", strength: "500 mg",
                   unitLabel: "tablet", isPrn: false, tracked: true, unitsOnHand: 58,
                   countedAt: DemoAPI.day(-3) + " 09:00:00",
                   countedAtLocal: DemoAPI.day(-3) + " 05:00", consumedSinceCount: 6,
                   refillAt: 20, belowRefillAt: false, lastRefillOn: DemoAPI.day(-12),
                   forecast: forecast(perDay: 2, onHand: 58, consumed: 60)),
            Supply(medicationId: "md_demo_prednisone", name: "Prednisone", strength: "5 mg",
                   unitLabel: "tablet", isPrn: false, tracked: true, unitsOnHand: 34,
                   countedAt: DemoAPI.day(-1) + " 20:30:00",
                   countedAtLocal: DemoAPI.day(-1) + " 16:30", consumedSinceCount: 2,
                   refillAt: 10, belowRefillAt: false, lastRefillOn: DemoAPI.day(-1),
                   forecast: forecast(perDay: 1, onHand: 34, consumed: 30)),
            // The PRN. `tracked: false` is its normal state and the reason is
            // spelled out rather than left as a blank cell.
            Supply(medicationId: "md_demo_tylenol", name: "Tylenol", strength: "500 mg",
                   unitLabel: "tablet", isPrn: true, tracked: false, unitsOnHand: nil,
                   countedAt: nil, countedAtLocal: nil, consumedSinceCount: nil,
                   refillAt: nil, belowRefillAt: false, lastRefillOn: nil,
                   forecast: SupplyForecast(available: false, reason: "not_tracked",
                                            basisDays: nil, consumedInBasis: nil,
                                            perDay: nil, daysLeft: nil, runsOutOn: nil,
                                            beyondHorizon: nil, estimated: nil)),
        ]
    }

    func supply(_ recipientId: String) async throws -> SupplyList {
        SupplyList(recipientId: recipientId, timezone: "America/New_York",
                   items: supplies,
                   counts: SupplyCounts(medications: supplies.count,
                                        tracked: supplies.filter(\.tracked).count,
                                        belowThreshold: supplies.filter(\.belowRefillAt).count),
                   forecastAvailable: true, yourRole: .owner, canWrite: true)
    }

    func supplyHistory(_ medicationId: String) async throws -> SupplyHistory {
        guard let s = supplies.first(where: { $0.medicationId == medicationId }) else {
            throw APIError.message("Not Found")
        }
        var events: [SupplyEvent] = [
            SupplyEvent(id: "sp_demo_1", kind: "count", delta: s.unitsOnHand ?? 0,
                        unitsAfter: s.unitsOnHand ?? 0, note: nil, byName: you,
                        at: s.countedAt),
        ]
        if let refillOn = s.lastRefillOn {
            events.append(SupplyEvent(id: "sp_demo_2", kind: "refill", delta: 30,
                                      unitsAfter: (s.unitsOnHand ?? 0) + 30,
                                      note: nil, byName: "David Whitfield",
                                      at: refillOn + " 17:10:00"))
        }
        return SupplyHistory(medicationId: medicationId, unitLabel: s.unitLabel,
                             supply: s, events: events, count: events.count)
    }

    func setSupply(_ medicationId: String, unitsOnHand: Double,
                   refillAt: Double?) async throws -> Supply {
        guard let i = supplies.firstIndex(where: { $0.medicationId == medicationId }) else {
            throw APIError.message("Not Found")
        }
        let old = supplies[i]
        let updated = Supply(medicationId: old.medicationId, name: old.name,
                             strength: old.strength, unitLabel: old.unitLabel,
                             isPrn: old.isPrn, tracked: true, unitsOnHand: unitsOnHand,
                             countedAt: "\(isoDay()) \(currentHHMM):00",
                             countedAtLocal: "\(isoDay()) \(currentHHMM)",
                             consumedSinceCount: 0,
                             refillAt: refillAt ?? old.refillAt,
                             belowRefillAt: refillAt.map { unitsOnHand <= $0 }
                                 ?? old.belowRefillAt,
                             lastRefillOn: old.lastRefillOn,
                             forecast: DemoAPI.refit(old.forecast, onHand: unitsOnHand))
        supplies[i] = updated
        return updated
    }

    /// The same rate, applied to a new count. A recount does not change how fast
    /// something is being used, so the rate carries over and only the date
    /// moves -- which is also why the demo re-derives it rather than leaving the
    /// old run-out date sitting next to a brand-new number. Two fields that
    /// disagree about the same bottle is the kind of inconsistency a screenshot
    /// would preserve forever.
    private static func refit(_ forecast: SupplyForecast, onHand: Double) -> SupplyForecast {
        guard forecast.available, let perDay = forecast.perDay, perDay > 0 else {
            return forecast
        }
        let daysLeft = onHand / perDay
        let beyond = daysLeft > 3650
        return SupplyForecast(available: true, reason: nil,
                              basisDays: forecast.basisDays,
                              consumedInBasis: forecast.consumedInBasis,
                              perDay: perDay,
                              daysLeft: (daysLeft * 10).rounded() / 10,
                              runsOutOn: beyond ? nil : DemoAPI.day(Int(daysLeft)),
                              beyondHorizon: beyond ? true : nil, estimated: true)
    }

    func refill(_ medicationId: String, units: Double, note: String?) async throws -> Supply {
        guard let s = supplies.first(where: { $0.medicationId == medicationId }) else {
            throw APIError.message("Not Found")
        }
        return try await setSupply(medicationId, unitsOnHand: (s.unitsOnHand ?? 0) + units,
                                   refillAt: s.refillAt)
    }

    func untrackSupply(_ medicationId: String) async throws {
        guard let i = supplies.firstIndex(where: { $0.medicationId == medicationId }) else {
            throw APIError.message("Not Found")
        }
        let old = supplies[i]
        supplies[i] = Supply(medicationId: old.medicationId, name: old.name,
                             strength: old.strength, unitLabel: old.unitLabel,
                             isPrn: old.isPrn, tracked: false, unitsOnHand: nil,
                             countedAt: nil, countedAtLocal: nil,
                             consumedSinceCount: nil, refillAt: nil,
                             belowRefillAt: false, lastRefillOn: old.lastRefillOn,
                             forecast: SupplyForecast(available: false,
                                                      reason: "not_tracked",
                                                      basisDays: nil, consumedInBasis: nil,
                                                      perDay: nil, daysLeft: nil,
                                                      runsOutOn: nil, beyondHorizon: nil,
                                                      estimated: nil))
    }

    // MARK: - The wall tablet

    /// One paired tablet and one that was registered and never claimed -- which
    /// is the state that makes the reissue button worth having, so the demo
    /// shows it rather than only showing the happy one.
    private var displayList: [DisplayDevice] = [
        DisplayDevice(id: "dp_demo_1", recipientId: DemoAPI.recipient,
                      label: "Kitchen iPad", paired: true,
                      pairedAt: DemoAPI.day(-40) + " 08:12:00",
                      lastSeenAt: "\(DemoAPI.day(0)) 07:58:00", revokedAt: nil,
                      tokenExpiresAt: DemoAPI.day(325) + " 08:12:00",
                      createdAt: DemoAPI.day(-40) + " 08:10:00"),
        DisplayDevice(id: "dp_demo_2", recipientId: DemoAPI.recipient,
                      label: "Hallway tablet", paired: false, pairedAt: nil,
                      lastSeenAt: nil, revokedAt: nil, tokenExpiresAt: nil,
                      createdAt: DemoAPI.day(-2) + " 19:22:00"),
    ]

    func displays(_ recipientId: String) async throws -> DisplayList {
        let live = displayList.filter { $0.revokedAt == nil }
        return DisplayList(displays: live, count: live.count, max: 3)
    }

    func createDisplay(_ recipientId: String, label: String?) async throws -> DisplayPairing {
        let d = DisplayDevice(id: "dp_demo_\(displayList.count + 1)", recipientId: recipientId,
                              label: label, paired: false, pairedAt: nil, lastSeenAt: nil,
                              revokedAt: nil, tokenExpiresAt: nil, createdAt: isoDay())
        displayList.append(d)
        return DisplayPairing(display: d, pairingCode: DemoAPI.code(),
                              expiresInMinutes: 15)
    }

    func reissuePairingCode(_ displayId: String) async throws -> PairingCode {
        guard let d = displayList.first(where: { $0.id == displayId }) else {
            throw APIError.message("Not Found")
        }
        if d.paired {
            throw APIError.structured(
                code: "already_paired",
                payload: .object([
                    "error": .string("already_paired"),
                    "message": .string("That display is already set up. Remove it "
                                       + "first to pair a different tablet."),
                ]))
        }
        return PairingCode(displayId: displayId, pairingCode: DemoAPI.code(),
                           expiresInMinutes: 15)
    }

    func renameDisplay(_ displayId: String, label: String) async throws -> DisplayDevice {
        guard let i = displayList.firstIndex(where: { $0.id == displayId }) else {
            throw APIError.message("Not Found")
        }
        let old = displayList[i]
        displayList[i] = DisplayDevice(id: old.id, recipientId: old.recipientId, label: label,
                                       paired: old.paired, pairedAt: old.pairedAt,
                                       lastSeenAt: old.lastSeenAt, revokedAt: old.revokedAt,
                                       tokenExpiresAt: old.tokenExpiresAt,
                                       createdAt: old.createdAt)
        return displayList[i]
    }

    func revokeDisplay(_ displayId: String) async throws {
        guard let i = displayList.firstIndex(where: { $0.id == displayId }) else {
            throw APIError.message("Not Found")
        }
        let old = displayList[i]
        displayList[i] = DisplayDevice(id: old.id, recipientId: old.recipientId,
                                       label: old.label, paired: false, pairedAt: nil,
                                       lastSeenAt: old.lastSeenAt,
                                       revokedAt: "\(isoDay()) \(currentHHMM):00",
                                       tokenExpiresAt: nil, createdAt: old.createdAt)
    }

    // MARK: - Reminders and the plan

    func registerDevice(token: String, platform: String, environment: String,
                        appVersion: String?) async throws -> Device {
        Device(id: "dv_demo_1", environment: environment, appVersion: appVersion,
               createdAt: "\(isoDay()) \(currentHHMM):00",
               lastSeenAt: "\(isoDay()) \(currentHHMM):00", disabledAt: nil,
               disabledReason: nil, active: true)
    }

    /// `pushAvailable: false`, and the settings screen says so out loud. The
    /// demo has no push service behind it, and a switch that flips but delivers
    /// nothing is the one kind of demo dishonesty that would end up in a
    /// submitted screenshot.
    func devices() async throws -> DeviceList {
        DeviceList(devices: [Device(id: "dv_demo_1", environment: "sandbox",
                                    appVersion: "1.0", createdAt: DemoAPI.day(-9),
                                    lastSeenAt: "\(isoDay()) \(currentHHMM):00",
                                    disabledAt: nil, disabledReason: nil, active: true)],
                   count: 1, pushAvailable: false)
    }

    private var notificationList: [Notification] = [
        Notification(id: "nt_demo_1", kind: "dose_missed", recipientId: DemoAPI.recipient,
                     title: "12:00 Metformin not recorded",
                     body: "Nobody has recorded the lunchtime Metformin yet.",
                     silent: false, createdAt: "\(DemoAPI.day(0)) 12:30:00", readAt: nil,
                     pushStatus: "sent"),
        Notification(id: "nt_demo_2", kind: "circle", recipientId: DemoAPI.recipient,
                     title: "David joined the circle", body: nil, silent: true,
                     createdAt: DemoAPI.day(-208) + " 09:00:00",
                     readAt: DemoAPI.day(-208) + " 09:01:00", pushStatus: nil),
    ]

    func notifications() async throws -> NotificationList {
        let live = notificationList.filter { $0.readAt == nil }
        return NotificationList(notifications: live, count: live.count, unread: live.count)
    }

    func markRead(_ notificationId: String) async throws {
        guard let i = notificationList.firstIndex(where: { $0.id == notificationId }) else {
            throw APIError.message("Not Found")
        }
        let old = notificationList[i]
        notificationList[i] = Notification(id: old.id, kind: old.kind,
                                           recipientId: old.recipientId, title: old.title,
                                           body: old.body, silent: old.silent,
                                           createdAt: old.createdAt,
                                           readAt: "\(isoDay()) \(currentHHMM):00",
                                           pushStatus: old.pushStatus)
    }

    func markAllRead() async throws -> Int {
        let n = notificationList.filter { $0.readAt == nil }.count
        for i in notificationList.indices {
            let old = notificationList[i]
            if old.readAt == nil {
                notificationList[i] = Notification(id: old.id, kind: old.kind,
                                                   recipientId: old.recipientId,
                                                   title: old.title, body: old.body,
                                                   silent: old.silent,
                                                   createdAt: old.createdAt,
                                                   readAt: "\(isoDay()) \(currentHHMM):00",
                                                   pushStatus: old.pushStatus)
            }
        }
        return n
    }

    /// Agrees with `me()`, which reports Pro. Two endpoints disagreeing about
    /// what the family has paid for is the one inconsistency a demo must not
    /// have: whichever screen read the other one would be showing a state the
    /// app cannot actually be in, and the screenshot job would photograph it.
    func products() async throws -> ProductsResponse {
        ProductsResponse(
            products: [ProductOffer(id: "com.cyan0914.carehive.pro.monthly", plan: "pro"),
                       ProductOffer(id: "com.cyan0914.carehive.pro.yearly", plan: "pro")],
            current: Entitlement(plan: "pro", isActive: true,
                                 expiresAt: DemoAPI.day(240),
                                 productId: "com.cyan0914.carehive.pro.yearly"))
    }

    func verifyPurchase(signedTransaction: String) async throws -> Entitlement {
        Entitlement(plan: "pro", isActive: true, expiresAt: DemoAPI.day(365),
                    productId: "com.cyan0914.carehive.pro.yearly")
    }

    // MARK: - Who you are

    /// The demo always signs in as Sarah. The real path through Sign in with
    /// Apple cannot be exercised on a runner with no Apple ID, and refusing to
    /// answer at all would make the sign-in screen the one screen the capture
    /// job cannot photograph -- which is the screen a reviewer sees first.
    func signInWithApple(identityToken: String, nonce: String,
                         authorizationCode: String?, fullName: String?,
                         timezone: String) async throws -> SignedIn {
        if let fullName, !fullName.isEmpty { displayName = fullName }
        if !timezone.isEmpty { self.timezone = timezone }
        return SignedIn(sessionToken: "demo-session-token",
                        expiresAt: DemoAPI.day(30),
                        created: true,
                        user: User(id: "us_demo_you", displayName: displayName,
                                   timezone: self.timezone,
                                   quietStartMin: quietStart, quietEndMin: quietEnd))
    }

    func deleteAccount() async throws -> DeletedAccount {
        DeletedAccount(
            deleted: true, appleTokenRevoked: true, circlesDeleted: 0,
            note: "Doses you recorded remain in your family's history with your "
                + "name on them. Your login and your access are gone.")
    }
}