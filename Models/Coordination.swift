// The shapes for the half of the app that is about the *circle* rather than
// about a single dose: who else can see this, what is left in the bottle, what
// happened last week, which kitchen tablet is trusted, and what the family is
// paying for.
//
// It is a separate file from `Wire.swift` for a reason that is not tidiness.
// `Wire.swift` describes one day, and every field in it is either a dose or a
// time. This file describes things that outlive a day -- an invitation, a
// supply count, a journal entry -- and the rules that govern them are different
// enough to be worth stating in their own place:
//
//  * A supply number is *what the family counted*, not what the app thinks.
//    The forecast is advisory text the server computed; the count is the truth
//    and the app may never adjust it on its own.
//  * A journal entry is writing by a named person, and an edit is a visible
//    fact about it (`edited`), not something to paper over.
//  * An invite code is shown once. The list never carries it again, which is
//    why `code` is optional here and `codeHint` is not.

import Foundation

// MARK: - Invites

/// A code that lets one more person into this circle.
///
/// `code` is present only on the response that created it. Every later read
/// carries `codeHint` (the last two characters) and nothing else, because the
/// server stores only a digest of the code -- so "show me the code again" is
/// not a thing this app can do, and the UI must be built so it never needs to.
struct Invite: Decodable, Identifiable, Hashable {
    let id: String
    let code: String?
    let codeHint: String
    let role: Role
    let label: String?
    let createdAt: String
    let expiresAt: String?
    let redeemedAt: String?
    let revokedAt: String?
    let createdByName: String?
    let redeemedByName: String?
    /// Still usable: not redeemed, not revoked, not expired. The server decides
    /// this rather than the app comparing `expiresAt` to the device clock --
    /// the device clock is not the server's, and a code that looks live here
    /// and is dead there is a person standing in a kitchen being told to try
    /// again by an app that was certain.
    let live: Bool

    var isRedeemed: Bool { redeemedAt != nil }
    var wasRevoked: Bool { revokedAt != nil }

    /// What happened to it, in one phrase, for a list that has to show past
    /// invites as well as live ones.
    var state: String {
        if let name = redeemedByName { return "Used by \(name)" }
        if isRedeemed { return "Used" }
        if wasRevoked { return "Cancelled" }
        return live ? "Waiting to be used" : "Expired"
    }
}

/// What the person *receiving* a code sees before they agree to join.
///
/// First names only, and no medication, no address, no count of anything. The
/// code was almost certainly sent over a messaging app; whoever is holding the
/// phone may not be the person it was meant for, and this response is readable
/// by anyone holding it.
struct InvitePreview: Decodable {
    let recipientFirstName: String
    let inviterFirstName: String
    let expiresAt: String?
    let alreadyRedeemed: Bool

    var sentence: String {
        "\(inviterFirstName) invited you to help care for \(recipientFirstName)."
    }
}

/// The response to redeeming. Carries the circle, so the joiner's app can open
/// straight onto it instead of making a second call that might fail.
struct Redeemed: Decodable {
    let joined: Bool
    let role: Role
    let recipient: Recipient
}

// MARK: - Circle membership

/// A membership change the owner can make. Handled as a value rather than a
/// bare string so an unknown role from a newer server fails to decode loudly
/// instead of being silently treated as the weakest one.
enum MemberChange: String, Decodable {
    case role, removed
}

struct MemberChangeResult: Decodable {
    let userId: String
    let role: Role?
    let changed: Bool?
    let removed: Bool?
    /// The server's own sentence about what just happened, shown verbatim. It
    /// says the one thing a person removing a sibling most needs to hear --
    /// that removing someone does not rewrite the record -- and that sentence
    /// belongs on the server, where the behaviour it describes lives.
    let note: String?
}

/// Handing the circle to someone else. The departing owner keeps editor, which
/// the app has to reflect immediately or the next screen shows buttons that
/// will 403.
struct TransferResult: Decodable {
    let ownerUserId: String
    let yourRole: Role
    let note: String?
}

// MARK: - Supply

/// What is left in the bottle, as last counted by a person.
///
/// Every number here is an observation, not a prediction.
///
/// `unitsOnHand` is **already net of consumption**. The server subtracts the
/// doses recorded since the last count and sends the result; `consumedSinceCount`
/// is the amount it subtracted, carried along so the family can check the sum
/// rather than take it on faith. The app must not subtract a second time -- the
/// number in this field is the answer, not the input to one.
struct Supply: Decodable, Hashable {
    let medicationId: String
    let name: String
    let strength: String?
    let unitLabel: String?
    let isPrn: Bool
    /// Whether anyone is counting this one at all. False is the normal state
    /// for a PRN and not a gap to be filled in.
    let tracked: Bool
    /// What is left now, after the doses recorded since the count. See above:
    /// do not subtract from this.
    let unitsOnHand: Double?
    /// When the family last counted. UTC; never displayed.
    let countedAt: String?
    /// The recipient's wall clock, like every other time in this app.
    let countedAtLocal: String?
    /// How much of the count has been used up since it was taken. Displayed as
    /// a subtraction the family can verify, never applied again by the client.
    let consumedSinceCount: Double?
    /// The family's own "tell me when it gets down to this". Null means they
    /// never set one.
    let refillAt: Double?
    /// Their number compared against their own threshold. The server computes
    /// it; nothing in the UI may dress it as a warning.
    let belowRefillAt: Bool
    let lastRefillOn: String?
    let forecast: SupplyForecast

    /// The count as the family typed it, reconstructed for the sentence "20
    /// when Sarah counted, 6 used since". Named for the arithmetic it undoes so
    /// that nobody reads it as a second opinion about the current level.
    var countedValue: Double? {
        guard let unitsOnHand else { return nil }
        return unitsOnHand + (consumedSinceCount ?? 0)
    }
}

/// The server's guess at whether the supply will last, and -- this is the part
/// that matters -- whether it is entitled to guess at all.
///
/// `available: false` with a `reason` is the common case on the free plan and
/// the reason is shown to the family. An app that hides the reason turns a
/// deliberate plan limit into a bug report.
struct SupplyForecast: Decodable, Hashable {
    let available: Bool
    let reason: String?
    /// How many days of dose history the rate was worked out over.
    let basisDays: Int?
    /// How many units were recorded as given in that window.
    let consumedInBasis: Double?
    /// A rate, not an instruction. "about 2 a day" describes what happened.
    let perDay: Double?
    let daysLeft: Double?
    /// A recipient-local date.
    let runsOutOn: String?
    /// True when the projection is past the server's ten-year clamp, so the
    /// client says "more than ten years at this rate" instead of printing a
    /// date that would be silly to print.
    let beyondHorizon: Bool?
    /// Always true when present. Named so a view cannot accidentally present
    /// the projection as a measurement rather than an estimate.
    let estimated: Bool?

    var explanation: String? {
        switch reason {
        case "plan":
            // The free plan still gets the threshold the family set; what it
            // does not get is the rate. Saying that precisely is the difference
            // between an upsell and a bug report.
            return "Run-out dates use a rate worked out from the dose record, "
                + "and are part of CareHive Pro. The level you asked to be told "
                + "about still works."
        case "no_recent_use":
            return "Nothing has been recorded as given in the last "
                + "\(basisDays.map(String.init) ?? "few") days, so there is no "
                + "rate to work one out from."
        case "not_tracked":
            return "Nobody is counting this one yet."
        case "no_schedule":
            return "There is no schedule to work out a rate from."
        case "too_soon":
            return "Not enough days of counting yet to work out a rate."
        default:
            return nil
        }
    }

    /// The projection, in a sentence, when there is one. Every clause reports
    /// arithmetic the server did; none of it advises.
    var sentence: String? {
        guard available else { return nil }
        guard let perDay else { return nil }
        let rate = "about \(perDay.formatted(.number.precision(.fractionLength(0...2)))) a day"
        if beyondHorizon == true { return "Used at \(rate), more than ten years." }
        guard let runsOutOn else { return "Used at \(rate)." }
        return "Used at \(rate), this would last until "
            + "\(WallClock.shortDate(runsOutOn))."
    }
}

/// One change to the count: a recount or a refill. Both are events with a
/// person's name on them, which is why this is a list and not a single number.
struct SupplyEvent: Decodable, Identifiable, Hashable {
    let id: String
    /// "count" or "refill". Kept as a string rather than an enum because a new
    /// kind from a newer server should still render its row, not blank the
    /// whole history.
    let kind: String
    let delta: Double
    let unitsAfter: Double
    let note: String?
    let byName: String?
    let at: String?

    var isRefill: Bool { kind == "refill" }
}

struct SupplyHistory: Decodable {
    let medicationId: String
    let unitLabel: String?
    let supply: Supply
    let events: [SupplyEvent]
    let count: Int
}

struct SupplyList: Decodable {
    let recipientId: String
    let timezone: String
    let items: [Supply]
    let counts: SupplyCounts
    let forecastAvailable: Bool
    let yourRole: Role
    let canWrite: Bool
}

struct SupplyCounts: Decodable {
    let medications: Int
    let tracked: Int
    let belowThreshold: Int
}

// MARK: - The log

/// One line of the circle's history. Deliberately flat.
///
/// A dose, a skip, a note and a membership change all arrive in this one shape
/// with most fields null, because the screen that shows them is one list in
/// time order. Modelling them as four separate types would mean four decode
/// paths and a sort that has to compare four kinds of thing; here the list is
/// already in order from the server and each row reads the fields it has.
struct LogEntry: Decodable, Identifiable, Hashable {
    /// "dose", "note", "circle", "prn", "supply". A string, not an enum, so an
    /// unrecognised kind still renders instead of failing the whole page.
    let kind: String
    let id: String
    /// UTC. Never displayed; ordering only.
    let at: String?
    /// The recipient's wall clock. This is what goes on screen.
    let atLocal: String?
    /// The recipient's local date.
    let on: String?
    /// For a dose: given / skipped / missed.
    let state: String?
    let actorName: String?
    let medication: String?
    let units: Double?
    let unitLabel: String?
    let slotLabel: String?
    let note: String?
    /// "app" or "card" -- whether this was recorded in the app or on the
    /// printed daily card, which a family member can tick and photograph. Worth
    /// showing: it is the difference between "she told me she took it" and
    /// "someone wrote it down in the kitchen".
    let via: String?
    let voidedAt: String?
    let doseId: String?
    let dstShifted: Bool?
    let mood: String?
    /// Set for note entries; the id of the journal row, for opening it.
    let entryId: String?
    let photoCount: Int?
    /// The note's text, already truncated by the server for the list. The full
    /// text lives behind `entryId`.
    let body: String?
    let bodyTruncated: Bool?

    var isVoided: Bool { voidedAt != nil }
}

/// A page of the log. `nextCursor` is opaque on purpose -- the app passes it
/// back without interpreting it, so the server can change what a cursor means
/// without a client release.
struct LogPage: Decodable {
    let recipientId: String
    let timezone: String
    let entries: [LogEntry]
    let count: Int
    let nextCursor: String?
    let hasMore: Bool
    let range: LogRange
    /// The oldest date this plan can see. Anything before it exists but is not
    /// returned, and the screen says so with this date rather than pretending
    /// the record starts here.
    let historyFrom: String?
    let limitedByPlan: Bool
    let searchAvailable: Bool
    let yourRole: Role
    let canWrite: Bool
}

struct LogRange: Decodable {
    let from: String
    let to: String
}

/// A journal note: something a person wrote down that is not a dose.
struct JournalEntry: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let recipientId: String
    let authorName: String?
    let authorId: String?
    /// The recipient's local date, which is the date the note belongs to.
    let entryOn: String
    let body: String
    let mood: String?
    let createdAt: String
    let createdAtLocal: String?
    /// True once edited. Shown on the row, because a note that changed after
    /// the fact is a different thing from one that did not, and the family is
    /// entitled to know which they are reading.
    let edited: Bool
    let editedAt: String?
    let editedAtLocal: String?
    let voidedAt: String?
    let photos: [JournalPhoto]
}

struct JournalPhoto: Decodable, Identifiable, Hashable {
    let id: String
    let url: String?
    let width: Int?
    let height: Int?
    let createdAt: String?
}

struct JournalEntryBody: Decodable {
    let entry: JournalEntry
    let yourRole: Role
    let canWrite: Bool
}

// MARK: - Trusted walls

/// A tablet on a kitchen wall that shows today's card.
///
/// The token is not here and never will be: it exists in exactly one response,
/// the pairing call, and only its digest is stored. Everything else the app
/// needs about a display is in this shape.
struct DisplayDevice: Decodable, Identifiable, Hashable {
    let id: String
    let recipientId: String
    let label: String?
    let paired: Bool
    let pairedAt: String?
    let lastSeenAt: String?
    let revokedAt: String?
    let tokenExpiresAt: String?
    let createdAt: String

    var isRevoked: Bool { revokedAt != nil }

    /// "Kitchen iPad" when it was named, and a neutral description when it was
    /// not -- never an id, which tells a family nothing.
    var name: String { label?.isEmpty == false ? label! : "A paired tablet" }

    var state: String {
        if isRevoked { return "Removed" }
        guard paired else { return "Waiting to be set up" }
        guard let lastSeenAt else { return "Set up, not seen yet" }
        return "Last seen \(WallClock.shortDate(String(lastSeenAt.prefix(10))))"
    }
}

/// A freshly created display, with the one-time code the family types into the
/// tablet. `pairingCode` is present only here.
struct DisplayPairing: Decodable {
    let display: DisplayDevice
    let pairingCode: String
    let expiresInMinutes: Int
}

struct DisplayList: Decodable {
    let displays: [DisplayDevice]
    let count: Int
    /// How many this plan allows. The screen says "1 of 1" rather than hiding
    /// the limit until it is hit.
    let max: Int?

    var hasRoom: Bool { max.map { count < $0 } ?? true }
}

// The tablet's own view of the same is in `Wall.swift`, alongside the rest of
// what the wall is allowed to see -- the pairing response lives there because
// the credential it carries is the wall's, not the family's.

// MARK: - Devices and reminders

struct Device: Decodable, Identifiable, Hashable {
    let id: String
    let environment: String
    let appVersion: String?
    let createdAt: String
    let lastSeenAt: String?
    let disabledAt: String?
    let disabledReason: String?
    let active: Bool
}

struct DeviceList: Decodable {
    let devices: [Device]
    let count: Int
    /// Whether this server can actually deliver a push. False on a dev
    /// deployment with no keys configured, and the settings screen says so
    /// instead of offering a switch that does nothing.
    let pushAvailable: Bool
}

struct Notification: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let recipientId: String?
    let title: String?
    let body: String?
    let silent: Bool
    let createdAt: String?
    let readAt: String?
    let pushStatus: String?

    var isRead: Bool { readAt != nil }
}

struct NotificationList: Decodable {
    let notifications: [Notification]
    let count: Int
    let unread: Int
}

struct MarkedResult: Decodable {
    let marked: Int
}

// MARK: - Purchases

struct ProductOffer: Decodable, Identifiable, Hashable {
    /// The StoreKit product id. The same string exists in App Store Connect and
    /// in the server's plan map, and all three have to agree.
    let id: String
    let plan: String
}

/// The current entitlement, straight from the server.
///
/// The app does *not* decide what the family has paid for by reading StoreKit
/// locally. A receipt that StoreKit says is valid can be a receipt that belongs
/// to another account, or one that has been refunded since; the server is the
/// one that verified the signature and holds the high-water mark, so this
/// response is the authority and the paywall reads from it.
struct Entitlement: Decodable {
    let plan: String
    let isActive: Bool
    let expiresAt: String?
    let productId: String?

    var isPro: Bool { isActive && plan != "free" }
}

struct ProductsResponse: Decodable {
    let products: [ProductOffer]
    let current: Entitlement
}

/// What the server sends back after verifying a StoreKit transaction.
struct VerifiedPurchase: Decodable {
    let plan: String?
    let isActive: Bool?
    let expiresAt: String?
    let message: String?
}

// MARK: - Shared result shapes

/// The response to anything that only has to say "that happened".
struct RemovedResult: Decodable {
    let removed: Bool?
    let voided: Bool?
    let tracking: Bool?
    let entryId: String?
    let prnId: String?
    let medicationId: String?
    let recipientTimezone: String?
}

struct AddedResult: Decodable {
    let added: Double
}
