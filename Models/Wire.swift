// The API's shapes, mirrored. Nothing here makes a decision; it only names what
// the server sends so that a field rename is a compile error rather than a
// silently-empty label.
//
// One rule runs through the whole file and is worth stating once:
//
//     The recipient's local clock is the only clock the UI ever shows.
//
// The server sends three parallel representations of every time -- `due_at` (a
// UTC instant), `due_at_local` (the wall clock in the recipient's timezone) and
// `due_on` (their local date). The app displays the local ones *literally* and
// never converts. A daughter in Chicago looking at her mother in New York must
// see "8:00 AM" because that is what is written on the pill bottle, not 7:00 AM
// because that is what her own phone thinks. Every `*Local` field below is
// therefore a `String` and not a `Date`: a `Date` is an instant and would invite
// exactly the conversion that must not happen.

import Foundation

// MARK: - Envelopes

/// Every error the API returns is `{"detail": ...}`, where `detail` is either a
/// string or a structured object. Modelling that as a type rather than string
/// matching is what lets the 409 path render the winner's name.
enum APIError: Error, Equatable {
    /// `{"detail": "Not Found"}`
    case message(String)
    /// `{"detail": {"error": "already_given", ...}}`
    case structured(code: String, payload: JSONValue)
    /// A refusal we could not parse, kept verbatim so it can be logged rather
    /// than swallowed.
    case unreadable(status: Int, body: String)
    case transport(String)

    /// The machine-readable code, when there is one.
    var code: String? {
        switch self {
        case .structured(let code, _): return code
        case .message: return nil
        case .unreadable(let status, _): return "http_\(status)"
        case .transport: return "offline"
        }
    }
}

/// A minimal JSON tree, for the parts of a payload the app reads by key without
/// wanting to model the whole thing. Declared here so `APIError` can hold one.
indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

/// The API wraps single objects in a named key: `{"recipient": {...}}`. These
/// are one line each and are spelled out rather than made generic, because the
/// wrapper name differs per endpoint and a generic version would need the key
/// passed as a string -- which turns a typo into a runtime decode failure
/// instead of a compile error.

// MARK: - Account

struct Me: Decodable {
    let user: User
    let plan: String
    let limits: Limits
    let recipients: [RecipientSummary]

    var isPro: Bool { plan != "free" }
}

struct User: Decodable {
    let id: String
    let displayName: String?
    let timezone: String
    let quietStartMin: Int?
    let quietEndMin: Int?
}

struct Limits: Decodable {
    let maxOwnedRecipients: Int
    let maxMedications: Int
    let historyDays: Int?
    let photosPerMonth: Int?
    let maxDisplayDevices: Int?
    let supplyForecast: String?
    let logSearch: Bool?

    var historyIsUnlimited: Bool { historyDays == nil }
}

// MARK: - Circles

struct Recipient: Decodable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let preferredName: String?
    let timezone: String
    let dateOfBirth: String?
    let color: String?
    let photoKey: String?
    let notes: String?
    let role: Role
    let isOwner: Bool
    /// What the family calls them. The server picks the fallback, so the app
    /// never has to decide between two names in two places.
    let callName: String
}

struct RecipientSummary: Decodable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let preferredName: String?
    let timezone: String
    let color: String?
    let photoKey: String?
    let role: Role
    let isOwner: Bool
    let medicationCount: Int?

    /// `callName` is absent from this shape, so mirror the server's rule here.
    var callName: String { preferredName ?? displayName }
}

enum Role: String, Decodable, CaseIterable {
    case viewer, member, editor, owner

    /// Whether this role may record that something happened. Mirrors the
    /// server's ladder; the server is still the authority and refuses anything
    /// this gets wrong, so a mistake here shows a button that 403s rather than
    /// letting something through.
    var canRecordDoses: Bool {
        switch self {
        case .viewer: return false
        case .member, .editor, .owner: return true
        }
    }

    var canEditSchedule: Bool {
        switch self {
        case .viewer, .member: return false
        case .editor, .owner: return true
        }
    }

    var label: String {
        switch self {
        case .viewer: return "Can view"
        case .member: return "Can record doses"
        case .editor: return "Can edit medications"
        case .owner: return "Owner"
        }
    }
}

struct Member: Decodable, Identifiable {
    let userId: String
    let membershipId: String
    let role: Role
    let displayName: String?
    let isOwner: Bool
    let joinedAt: String?
    let invitedByName: String?
    let isYou: Bool

    var id: String { membershipId }
    var name: String { displayName ?? "Someone" }
}

// MARK: - The day

/// One recipient-local day, as the day endpoint returns it.
///
/// `isToday` comes from the server rather than being recomputed against the
/// device's calendar on purpose: "today" for this screen means today where the
/// recipient is, and the server is the one that knows.
struct DayFeed: Decodable {
    let date: String
    let isToday: Bool
    let recipient: DayRecipient
    let doses: [Dose]
    let prnToday: [PRNEntry]
    let counts: DayCounts
    let beyondHorizon: Bool
    let horizonEnd: String?
    let yourRole: Role
    let canRecord: Bool
}

struct DayRecipient: Decodable, Hashable {
    let id: String
    let name: String
    let callName: String
    let timezone: String
}

struct DayCounts: Decodable {
    let total: Int
    let pending: Int
    let given: Int
    let missed: Int
    let skipped: Int?
    let overdue: Int?
    let activeMedications: Int?
    let prnToday: Int?
}

/// A single dose: one medication, at one time, on one day.
struct Dose: Decodable, Identifiable, Hashable {
    let id: String
    let recipientId: String
    let medicationId: String
    let phaseId: String?
    let medicationName: String
    let medicationStrength: String?
    /// UTC instant. Never displayed.
    let dueAt: String
    /// The recipient's wall clock. This is what the family reads.
    let dueAtLocal: String
    /// The recipient's local date.
    let dueOn: String
    let slotLabel: String?
    let unitsPerDose: Double
    let unitLabel: String?
    let status: DoseStatus
    let administrationCount: Int
    /// True when the wall-clock time the family asked for does not exist on
    /// this date -- the spring-forward gap. The dose is real and still happens;
    /// this flag exists so the UI can say the time moved rather than showing a
    /// time nobody scheduled.
    let dstShifted: Bool
    let givenAt: String?
    let givenAtLocal: String?
    let givenByName: String?
    let note: String?
    let isOverdue: Bool?
    let administrations: [Administration]?
}

enum DoseStatus: String, Decodable {
    case pending, given, missed, skipped

    var isActionable: Bool { self == .pending }
}

struct Administration: Decodable, Identifiable, Hashable {
    let id: String
    let givenAt: String?
    let givenAtLocal: String?
    let givenByName: String?
    let units: Double
    let via: String?
    let note: String?
    let voidedAt: String?
}

// MARK: - PRN

/// An as-needed dose that was actually given. There is no event to claim; this
/// row *is* the record, which is why it has its own type.
struct PRNEntry: Decodable, Identifiable, Hashable {
    let id: String
    let recipientId: String?
    let medicationId: String
    let medicationName: String?
    let givenAt: String?
    let givenAtLocal: String?
    let givenOn: String?
    let units: Double
    let reason: String?
    let note: String?
    /// Whether this took the family past the ceiling *they set themselves*.
    /// The server computes it; the UI's only job is to not editorialize.
    let overMax: Bool?
    let givenByName: String?
    let voidedAt: String?
}

/// The response to recording a PRN dose.
///
/// `yourDailyCeiling` and `youMinInterval` are the family's own numbers echoed
/// back. They are labelled "your" here because that is the entire medical
/// boundary of this product: the app repeats what the family decided and never
/// computes, compares, or advises. Nothing in the PRN UI may render these as a
/// warning.
struct PRNResult: Decodable {
    let duplicate: Bool
    let administration: PRNEntry
    let todayCount: Int
    let yourDailyCeiling: Double?
    let minutesSinceLast: Int?
    let youMinInterval: Int?
}

// MARK: - Medications

struct Medication: Decodable, Identifiable, Hashable {
    let id: String
    let recipientId: String
    let name: String
    let strength: String?
    let form: String?
    let unitLabel: String?
    let instructions: String?
    let purpose: String?
    let prescriber: String?
    let pharmacy: String?
    let rxNumber: String?
    let isPrn: Bool
    let prnMaxPerDay: Double?
    let prnMinIntervalMin: Int?
    let color: String?
    let active: Bool
    let slots: [MedSlot]
    let phases: [MedPhase]
    let summary: String?
}

/// One time of day a medication is taken.
///
/// Decoded by hand for one field. `days_of_week` is a single field with two wire
/// shapes: the server accepts a list of numbers or names (`[1,3,5]`, `["mon"]`)
/// and normalizes both to a comma-separated string, which is what it stores and
/// therefore what it sends back. A client that modelled only the array would
/// decode cleanly against its own fixtures and then fail on the first real
/// response that had any days set -- and the medications most likely to carry
/// days are the ones the family most needs the list to show. So the field is
/// read as a JSON tree and normalized once, here, and no view ever sees the
/// string form.
struct MedSlot: Decodable, Identifiable, Hashable {
    let id: String
    /// A wall clock label -- "08:00" -- with no date and no zone. See the note
    /// at the top of this file: it is displayed literally and never converted.
    let localTime: String
    let label: String?
    /// The days this time is taken on. 0 = Sunday, matching the server.
    /// `nil` means every day, which is also what the server stores for it.
    let daysOfWeek: [Int]?
    let intervalDays: Int?
    let anchorOn: String?
    let active: Bool

    private enum Keys: String, CodingKey {
        case id, label, active
        case localTime, daysOfWeek, intervalDays, anchorOn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        localTime = try c.decode(String.self, forKey: .localTime)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        intervalDays = try c.decodeIfPresent(Int.self, forKey: .intervalDays)
        anchorOn = try c.decodeIfPresent(String.self, forKey: .anchorOn)
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? true
        daysOfWeek = Self.weekdays(try c.decodeIfPresent(JSONValue.self, forKey: .daysOfWeek))
    }

    /// The memberwise initializer the decoder above would otherwise have
    /// suppressed. The demo server and the tests build slots directly.
    init(id: String, localTime: String, label: String?, daysOfWeek: [Int]?,
         intervalDays: Int?, anchorOn: String?, active: Bool = true) {
        self.id = id
        self.localTime = localTime
        self.label = label
        self.daysOfWeek = daysOfWeek
        self.intervalDays = intervalDays
        self.anchorOn = anchorOn
        self.active = active
    }

    /// "1,3,5" / [1,3,5] / ["mon"] -> [1,3,5]. Anything that is not a day, or
    /// nothing at all, means every day.
    ///
    /// All seven collapsing to `nil` mirrors `models.parse_days_of_week`, which
    /// refuses to store "0,1,2,3,4,5,6" for the same reason: so that one state
    /// -- every day -- has one representation. Without this the editor would
    /// show "every day" two different ways depending on how the row was
    /// created, and the next save would send a schedule the family never chose.
    static func weekdays(_ raw: JSONValue?) -> [Int]? {
        let days: [Int]
        switch raw {
        case .array(let items):
            days = items.compactMap {
                $0.doubleValue.map { Int($0) } ?? $0.stringValue.flatMap(weekday(named:))
            }
        case .string(let text):
            days = text.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
        default:
            return nil
        }
        let valid = Set(days.filter { (0...6).contains($0) })
        if valid.isEmpty || valid.count == 7 { return nil }
        return valid.sorted()
    }

    /// The three-letter names the server also accepts, for the array form.
    private static func weekday(named name: String) -> Int? {
        let key = String(name.trimmingCharacters(in: .whitespaces).lowercased().prefix(3))
        return ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: key)
    }
}

/// A window during which a medication is taken at a different amount -- a
/// tapering steroid course, a week of double dose. `unitsPerDose` overrides the
/// medication's own for doses that fall inside `[startsOn, endsOn]`.
struct MedPhase: Decodable, Identifiable, Hashable {
    let id: String
    let startsOn: String
    let endsOn: String?
    let unitsPerDose: Double?
    let label: String?
    /// A step that never ends is a step that is still going.
    var isOpenEnded: Bool { endsOn == nil }

    /// "Sep 25 – Oct 2" / "from Sep 25". Both ends are recipient-local dates and
    /// are printed as written; `WallClock.shortDate` handles that.
    var range: String {
        let start = WallClock.shortDate(startsOn)
        guard let endsOn else { return "from \(start)" }
        return "\(start) – \(WallClock.shortDate(endsOn))"
    }
}

/// Everything the medication list endpoint sends, not just the list.
///
/// The form's picker of dose forms comes from the server for the same reason
/// nothing else here is hardcoded: a copy of that list in the app is a copy that
/// drifts, and a form the server does not recognise is a medication whose
/// `form` field quietly stops matching anything. `recipientTimezone` travels
/// with the list because the times on this screen are the recipient's, and a
/// daughter three zones away is the person most likely to need to be told that.
struct MedicationCatalog: Decodable {
    let medications: [Medication]
    let formOptions: [String]
    let recipientTimezone: String?
}

// MARK: - The race

/// The body of a 409: somebody else recorded this dose first.
///
/// Rendered as a success-shaped payload on purpose. The screen's job is to show
/// "Sarah gave it at 8:03", and handing it the same `Dose` object a 200 would
/// have carried means that screen is one code path instead of two.
struct AlreadyGiven: Decodable {
    let givenByName: String?
    let givenAt: String?
    let givenAtLocal: String?
    let administrationId: String?
    let dose: Dose?

    /// What to put on screen, with a fallback that is still true when the
    /// server sends no name.
    var attribution: String {
        let who = givenByName?.trimmingCharacters(in: .whitespaces) ?? ""
        let when = givenAtLocal.map(WallClock.time) ?? ""
        switch (who.isEmpty, when.isEmpty) {
        case (false, false): return "\(who) gave it at \(when)"
        case (false, true): return "\(who) gave it"
        case (true, false): return "Gave it at \(when)"
        case (true, true): return "This dose was already recorded"
        }
    }
}
