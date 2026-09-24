// The add/edit form's contents, and the one place a schedule is turned into a
// request body.
//
// This type exists because the request body has a rule the UI cannot express and
// the server cannot guess: PATCH is three-state on every field. Absent means
// "leave it alone", an explicit `null` means "clear it", and a value means "set
// it to this". A Swift struct of optionals encodes all three as absent, so a
// family who deletes the word "with breakfast" from the instructions field would
// send nothing at all and watch it come back on the next load. The editor
// therefore sends every editable field every time -- declaratively, as the full
// state of the form -- and `wireBody` below is where that decision is
// implemented rather than described.
//
// The single exception is `phase`, and it is worth being explicit about why:
// the server's PATCH only ever *adds* a phase. A taper is a sequence (4mg for a
// week, then 2mg, then 1mg) and phases have their own dates, so "replace the
// phases" has no meaning. An absent `phase` key means "nothing to add"; removing
// a step is its own call, because it changes the amount on doses that are
// already on the family's screen and deserves to be a deliberate act.

import Foundation

struct MedicationDraft: Equatable {

    var name = ""
    var strength = ""
    var form = ""
    /// What one dose is counted in -- "tablet", "mL", "puff". The list screen
    /// prints "1 tablet" and never a bare number, because a number next to a
    /// medication name does not say what it is counting.
    var unitLabel = "tablet"
    var instructions = ""
    var purpose = ""
    var prescriber = ""
    var pharmacy = ""
    var rxNumber = ""

    /// Taken as needed rather than on a schedule. A PRN medication has no times;
    /// its record is a list of what was actually given.
    var isPrn = false
    /// The ceiling and the gap are the FAMILY's numbers, stored and echoed back.
    /// The app never computes or recommends either, and the editor's copy says
    /// so -- "you set" rather than "recommended".
    var prnMaxPerDay: Int?
    var prnMinIntervalMin: Int?

    var slots: [Slot] = []
    /// A step to append, when the family added one on this visit.
    var newPhase: Phase?

    // MARK: - Rows the form edits

    struct Slot: Identifiable, Equatable {
        let id: UUID
        /// "08:00". A wall clock label, not a moment -- see `WallClock`.
        var localTime: String
        var label: String
        /// `nil` means every day.
        var daysOfWeek: [Int]?

        /// Carried through untouched, and this is not tidiness.
        ///
        /// The server replaces a medication's slots wholesale, so whatever the
        /// editor sends back is the entire schedule from then on. The editor has
        /// no control for an every-N-days cadence -- it is rare, and a stepper
        /// for it would sit on every medication's screen to serve almost none --
        /// but a slot that arrived with one must leave with it, or changing a
        /// strength would quietly turn "every other Monday" into "every Monday"
        /// and double someone's doses.
        var intervalDays: Int?
        var anchorOn: String?

        init(id: UUID = UUID(), localTime: String, label: String = "",
             daysOfWeek: [Int]? = nil, intervalDays: Int? = nil, anchorOn: String? = nil) {
            self.id = id
            self.localTime = localTime
            self.label = label
            self.daysOfWeek = daysOfWeek
            self.intervalDays = intervalDays
            self.anchorOn = anchorOn
        }
    }

    struct Phase: Equatable {
        /// "2026-09-25", the recipient's local date.
        var startsOn: String
        var endsOn: String?
        var unitsPerDose: Double
        var label = ""
    }

    // MARK: - Building one

    /// A blank form, with one time already on it.
    ///
    /// Starting with no times would mean the family's first act on a new
    /// medication is to add a row before they can save, and a scheduled
    /// medication with no times is exactly what the server refuses. 8am is a
    /// placeholder they will change, not a suggestion we are making -- it is the
    /// same reason the field is a picker and not a default they might miss.
    init() {
        slots = [Slot(localTime: "08:00")]
    }

    /// The form filled in from a medication the server already has.
    init(_ medication: Medication) {
        name = medication.name
        strength = medication.strength ?? ""
        form = medication.form ?? ""
        unitLabel = medication.unitLabel ?? "tablet"
        instructions = medication.instructions ?? ""
        purpose = medication.purpose ?? ""
        prescriber = medication.prescriber ?? ""
        pharmacy = medication.pharmacy ?? ""
        rxNumber = medication.rxNumber ?? ""
        isPrn = medication.isPrn
        prnMaxPerDay = medication.prnMaxPerDay.map { Int($0) }
        prnMinIntervalMin = medication.prnMinIntervalMin
        slots = medication.slots.map {
            Slot(localTime: $0.localTime, label: $0.label ?? "",
                 daysOfWeek: $0.daysOfWeek, intervalDays: $0.intervalDays,
                 anchorOn: $0.anchorOn)
        }
        // Existing phases are deliberately not loaded into `newPhase`. They are
        // shown on the editor as rows with their own dates, and this field only
        // ever carries a step being added on this visit.
    }

    /// Whether the server will accept this.
    ///
    /// Mirrors the two things it actually refuses -- no name, and a scheduled
    /// medication with no times -- so the Save button can be off rather than
    /// producing a 422. The server still checks; this is courtesy, not trust.
    var isSaveable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isPrn || !slots.isEmpty)
    }

    // MARK: - The body

    var wireBody: JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "strength": Self.text(strength),
            "form": Self.text(form),
            "unit_label": Self.text(unitLabel),
            "instructions": Self.text(instructions),
            "purpose": Self.text(purpose),
            "prescriber": Self.text(prescriber),
            "pharmacy": Self.text(pharmacy),
            "rx_number": Self.text(rxNumber),
            "is_prn": .bool(isPrn),
            // Cleared when the medication is not a PRN, rather than left behind.
            // A ceiling and a gap on a medication that is now taken on a
            // schedule are numbers nothing reads, and the next person to open
            // the edit screen would find a limit they never set.
            "prn_max_per_day": isPrn ? Self.number(prnMaxPerDay) : .null,
            "prn_min_interval_min": isPrn ? Self.number(prnMinIntervalMin) : .null,
            "slots": .array(isPrn ? [] : slots.map(Self.slotJSON)),
        ]
        if let newPhase { body["phase"] = Self.phaseJSON(newPhase) }
        return .object(body)
    }

    /// An empty field travels as `null`, which is what clears it. The create
    /// path reads absent and null identically, so one body shape serves both.
    private static func text(_ value: String) -> JSONValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .null : .string(trimmed)
    }

    private static func number(_ value: Int?) -> JSONValue {
        value.map { .number(Double($0)) } ?? .null
    }

    private static func slotJSON(_ slot: Slot) -> JSONValue {
        .object([
            "local_time": .string(slot.localTime),
            "label": text(slot.label),
            // `nil` days means every day, and the server's canonical form for
            // that is NULL rather than all seven -- see `MedSlot.weekdays`.
            "days_of_week": slot.daysOfWeek
                .map { .array($0.map { .number(Double($0)) }) } ?? .null,
            "interval_days": number(slot.intervalDays),
            "anchor_on": slot.anchorOn.map { .string($0) } ?? .null,
        ])
    }

    private static func phaseJSON(_ phase: Phase) -> JSONValue {
        .object([
            "starts_on": .string(phase.startsOn),
            "ends_on": phase.endsOn.map { .string($0) } ?? .null,
            "units_per_dose": .number(phase.unitsPerDose),
            "label": text(phase.label),
        ])
    }
}
