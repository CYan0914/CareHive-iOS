// The kitchen wall.
//
// A paired tablet shows one thing: today, in type big enough to read from
// across a room, to someone who did not install the app and may not have a
// phone. It is a different product surface with a different threat model, and
// both are visible in the shapes below.
//
//  * **It reads. It never writes.** The server refuses to record anything on a
//    display credential, and there is no button here that pretends otherwise.
//    A tablet on a wall is a shared object in a shared room; anything it could
//    change, a visitor could change.
//  * **The payload is an allow-list, not a filter.** Notes, reasons and the
//    overdue flag are absent on the server side, so they cannot be leaked by a
//    client that forgets to hide them. This file mirrors what arrives rather
//    than what a screen might like.
//  * **The tablet's clock is not trusted.** A wall iPad may have been asleep
//    for a week. The server sends its own instant and the recipient's wall clock
//    together, so the screen can work out its offset once and tick from there --
//    a large-type display showing the wrong time next to a dose's time is worse
//    than one showing no time at all.

import Foundation

struct WallRecipient: Decodable, Hashable {
    let id: String
    let name: String
    let callName: String
    let timezone: String
}

/// One dose, as the wall is allowed to see it.
///
/// No `is_overdue`, no `note`, no `dst_shifted`. Those are absent because the
/// server does not send them, and this type does not invent a local substitute
/// from the fields it does have -- computing "overdue" here would put a
/// judgement on a wall that the server deliberately kept out of the payload.
struct WallDose: Decodable, Identifiable, Hashable {
    let id: String
    /// The recipient's wall clock. Displayed literally.
    let timeLocal: String
    let slotLabel: String?
    let medicationName: String
    let medicationStrength: String?
    let unitsPerDose: Double
    let unitLabel: String?
    let status: DoseStatus
    let givenAtLocal: String?
    let givenByName: String?
}

struct WallPRN: Decodable, Identifiable, Hashable {
    let id: String
    let timeLocal: String?
    let medicationName: String?
    let units: Double
    let unitLabel: String?
    let givenByName: String?
}

struct WallCounts: Decodable, Hashable {
    let total: Int
    let given: Int
    let pending: Int

    /// "3 of 5 recorded". Words, not just a ring: this is read across a room.
    var sentence: String {
        if total == 0 { return "Nothing scheduled today" }
        return "\(given) of \(total) recorded today"
    }
}

struct WallToday: Decodable {
    let display: DisplayDevice
    let recipient: WallRecipient
    let date: String
    let isToday: Bool
    /// The server's own instant, UTC. Carried but never rendered or parsed:
    /// the screen shows the recipient's clock and nothing else, so the
    /// tablet's idea of the time cannot reach a person reading the wall.
    ///
    /// It is decoded rather than dropped so that the shape here stays a
    /// faithful copy of the payload -- a field silently missing from this
    /// struct is how a client and a server drift.
    let now: String
    /// The recipient's wall clock, "08:14". This is what a person reads.
    let nowLocal: String
    let doses: [WallDose]
    let prnToday: [WallPRN]
    let counts: WallCounts
    let beyondHorizon: Bool
    let canRecord: Bool
}

struct WallWhoAmI: Decodable {
    let display: DisplayDevice
    let recipient: WallRecipient
    let now: String
    let largeText: Bool
    let canRecord: Bool
}

/// What a tablet gets back the one time it redeems a code.
///
/// `token` is the whole point and the reason this response is never cached,
/// logged or re-fetched: only its digest is stored on the server, so if the
/// tablet loses it the family has to mint a new code.
struct WallPaired: Decodable {
    let token: String
    let display: DisplayDevice
    let recipient: WallRecipient
    let expiresAt: String?
}
