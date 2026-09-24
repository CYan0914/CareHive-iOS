// The one place that talks to the server.
//
// `CareHiveAPI` is a protocol rather than a concrete class for one specific
// reason: the App Store screenshot pipeline has to render every screen with
// realistic data and no network at all. A CI runner has no backend, no tunnel
// and no session, and a screenshot job that needs one is a screenshot job that
// fails at 3am for reasons unrelated to the app. So the demo implementation is
// a peer of the real one, not a special case inside it.

import Foundation

// MARK: - The contract

protocol CareHiveAPI: Sendable {
    func me() async throws -> Me

    func circles() async throws -> [RecipientSummary]
    func circle(_ id: String) async throws -> Recipient
    func members(_ recipientId: String) async throws -> [Member]

    /// The medication list, named for the endpoint and returning everything it
    /// sends -- the list, the form options and the recipient's timezone all come
    /// from the same response, and splitting them would be two calls to build
    /// one screen.
    func medications(_ recipientId: String) async throws -> MedicationCatalog

    /// Both write paths send the whole form, not a diff. See `MedicationDraft`.
    func createMedication(_ recipientId: String,
                          _ draft: MedicationDraft) async throws -> Medication
    func updateMedication(_ medicationId: String,
                          _ draft: MedicationDraft) async throws -> Medication
    /// Stops a medication. Cancels what has not happened yet; keeps every dose
    /// that was recorded, because "what was she taking in March" is a question
    /// this app exists to answer.
    func archiveMedication(_ medicationId: String) async throws
    /// Removes one step of a taper. Its own call rather than part of the save,
    /// because it changes the amount on doses already on the family's screen.
    func deletePhase(_ phaseId: String) async throws

    func today(_ recipientId: String) async throws -> DayFeed
    func day(_ recipientId: String, on: String) async throws -> DayFeed
    func schedule(_ recipientId: String, days: Int) async throws -> [ScheduleDay]

    func give(doseId: String, clientRef: String, note: String?) async throws -> GiveOutcome
    func skip(doseId: String, reason: String?) async throws -> Dose
    func undo(doseId: String) async throws -> VoidResult
    func recordPRN(_ recipientId: String, medicationId: String, reason: String?,
                   clientRef: String) async throws -> PRNResult
    /// Undoes an as-needed dose. A PRN has no event to re-open the way a
    /// scheduled dose does -- the administration row *is* the record -- so this
    /// voids that row rather than flipping a status back.
    func undoPRN(_ administrationId: String) async throws

    // MARK: Who else is in this

    func updateMember(_ recipientId: String, userId: String,
                      role: Role) async throws -> MemberChangeResult
    func removeMember(_ recipientId: String, userId: String) async throws -> MemberChangeResult
    /// Hands the circle over. The caller stops being the owner, so whatever
    /// screen called this has to reload its role rather than assume it kept it.
    func transfer(_ recipientId: String, toUserId: String) async throws -> TransferResult

    /// Mints one invitation. The code comes back exactly once -- the server
    /// stores a digest -- so the caller has to hold it in memory long enough to
    /// show it, and the UI must never offer a way back to it.
    func createInvite(_ recipientId: String, role: Role,
                      label: String?) async throws -> InviteCreated
    func invites(_ recipientId: String) async throws -> InviteList
    func revokeInvite(_ inviteId: String) async throws
    /// What the person holding a code sees before they join. Reads no circle
    /// and needs no account; see `InvitePreview` for what it deliberately does
    /// not say.
    func previewInvite(code: String) async throws -> InvitePreview
    func redeemInvite(code: String) async throws -> Redeemed

    // MARK: What happened

    /// The circle's history, newest first.
    func log(_ recipientId: String, from: String?, to: String?, kinds: [String]?,
             cursor: String?, limit: Int) async throws -> LogPage
    func createEntry(_ recipientId: String, body: String, kind: String,
                     mood: String?) async throws -> JournalEntry
    func entry(_ entryId: String) async throws -> JournalEntryBody
    func updateEntry(_ entryId: String, body: String?, mood: String?) async throws -> JournalEntry
    func deleteEntry(_ entryId: String) async throws

    // MARK: What is left

    func supply(_ recipientId: String) async throws -> SupplyList
    func supplyHistory(_ medicationId: String) async throws -> SupplyHistory
    /// A recount. `unitsOnHand` is what the family counted, not what the app
    /// predicted; nothing here ever adjusts it.
    func setSupply(_ medicationId: String, unitsOnHand: Double,
                   refillAt: Double?) async throws -> Supply
    func refill(_ medicationId: String, units: Double, note: String?) async throws -> Supply
    /// Stops counting this one. The history stays; only the tracking stops.
    func untrackSupply(_ medicationId: String) async throws

    // MARK: The wall tablet

    func displays(_ recipientId: String) async throws -> DisplayList
    func createDisplay(_ recipientId: String, label: String?) async throws -> DisplayPairing
    /// A fresh code for a display that was registered but never claimed --
    /// because the fifteen-minute code expired while nobody was looking.
    func reissuePairingCode(_ displayId: String) async throws -> PairingCode
    func renameDisplay(_ displayId: String, label: String) async throws -> DisplayDevice
    /// Takes the tablet out of the circle. Its next request fails immediately;
    /// the row stays so the family can still see when it was last used.
    func revokeDisplay(_ displayId: String) async throws

    // MARK: Reminders and the plan

    func registerDevice(token: String, platform: String, environment: String,
                        appVersion: String?) async throws -> Device
    func devices() async throws -> DeviceList
    func notifications() async throws -> NotificationList
    func markRead(_ notificationId: String) async throws
    func markAllRead() async throws -> Int

    func products() async throws -> ProductsResponse
    /// Sends a StoreKit transaction to the server, which verifies the signature
    /// against Apple's root and returns the entitlement it now believes. The
    /// app never decides on its own that a purchase succeeded.
    func verifyPurchase(signedTransaction: String) async throws -> Entitlement

    // MARK: Who you are

    /// The one call that works without a session, because it is the call that
    /// produces one.
    ///
    /// `fullName` is forwarded because Apple sends it exactly once, at first
    /// sign-in, and a client that drops it leaves the user with no name and no
    /// way to supply one except by typing it.
    func signInWithApple(identityToken: String, nonce: String,
                         authorizationCode: String?, fullName: String?,
                         timezone: String) async throws -> SignedIn
    func updateMe(_ patch: MePatch) async throws -> MeUpdate
    /// Guideline 5.1.1(v). What survives is described by the server's own note,
    /// which the confirming screen prints before this is called.
    func deleteAccount() async throws -> DeletedAccount
}

/// The session token and who it belongs to.
///
/// The token is written to the Keychain by the caller rather than by the
/// client, so that a screen which fails halfway cannot end up with a token it
/// never stored -- and so that the one place a credential lands is visible in
/// the sign-in flow rather than buried in a transport layer.
struct SignedIn: Decodable {
    let sessionToken: String
    let expiresAt: String?
    /// True the first time this Apple ID is seen. Worth knowing: it is the only
    /// moment a name can be captured from Apple.
    let created: Bool
    let user: User
}

/// A partial update to the account, with the server's three-state rule modelled
/// rather than flattened.
///
/// `nil` means "I did not mention this". `JSONValue.null` means "clear it".
/// Collapsing those into one -- which an `Optional` field does by default --
/// means a settings screen that changes the timezone also silently wipes a name
/// the user never touched. The type exists to make that mistake unrepresentable.
struct MePatch {
    var displayName: JSONValue?
    var timezone: String?
    var quietStartMin: Int?
    var quietEndMin: Int?

    var isEmpty: Bool {
        displayName == nil && timezone == nil
            && quietStartMin == nil && quietEndMin == nil
    }

    var wireBody: JSONValue {
        var out: [String: JSONValue] = [:]
        if let displayName { out["display_name"] = displayName }
        if let timezone { out["timezone"] = .string(timezone) }
        if let quietStartMin { out["quiet_start_min"] = .number(Double(quietStartMin)) }
        if let quietEndMin { out["quiet_end_min"] = .number(Double(quietEndMin)) }
        return .object(out)
    }
}

struct MeUpdate: Decodable {
    let user: User
    let changed: Int
    /// "21:00-08:00", formatted by the server so the client is not the one
    /// deciding how a wrapped range reads.
    let quietHours: String?
}

struct DeletedAccount: Decodable {
    let deleted: Bool
    let appleTokenRevoked: Bool?
    let circlesDeleted: Int?
    /// The server's own sentence about what was kept, printed verbatim.
    let note: String?
}

/// A newly minted invite. The code is here and nowhere else, ever again.
struct InviteCreated: Decodable {
    let invite: Invite
    /// The message to send, written by the server so that the wording lives
    /// next to the expiry rule it describes.
    let shareText: String
    let note: String
}

struct InviteList: Decodable {
    let count: Int
    let liveCount: Int
    let invites: [Invite]
}

struct PairingCode: Decodable {
    let displayId: String
    let pairingCode: String
    let expiresInMinutes: Int
}

// MARK: - Outcomes

/// What happened when somebody tapped "Given".
///
/// The 409 is modelled as a case of this rather than as a thrown error, and
/// that is the important decision in this file. The server deliberately returns
/// the same dose object in the 409 body as it would in a 200, so that the
/// screen which says "Sarah gave it at 8:03" is one code path and not two.
/// Making the caller `catch` in order to render the single most likely outcome
/// -- two siblings, one dose -- would throw that design away and put the race
/// handling in every call site instead of one.
enum GiveOutcome {
    /// 200. The dose is now recorded as given by this user.
    case recorded(dose: Dose?)
    /// 200 with `duplicate: true`. This device already sent this exact request;
    /// the original result is being replayed. Not an error, and not a second
    /// dose -- a retry.
    case alreadyRecordedByYou(dose: Dose?)
    /// 409. Someone else got there first, and the body names them.
    case someoneElseGotThere(AlreadyGiven)
}

struct VoidResult: Decodable {
    let voided: Bool
    let dose: Dose?
    let remainingAdministrations: Int?
    let voidedAdministration: Administration?
}

struct ScheduleDay: Decodable, Identifiable {
    let date: String
    let isToday: Bool
    let counts: DayCounts
    let doses: [Dose]

    var id: String { date }
}

// MARK: - Response wrappers
//
// Spelled out per endpoint rather than made generic. A generic envelope would
// need the wrapper key passed as a string, which turns a typo into a runtime
// decode failure instead of a compile error.

private struct CirclesBody: Decodable { let recipients: [RecipientSummary] }
private struct CircleBody: Decodable { let recipient: Recipient }
private struct MembersBody: Decodable { let members: [Member] }
private struct MedBody: Decodable { let medication: Medication }
private struct ScheduleBody: Decodable { let days: [ScheduleDay] }
private struct GiveBody: Decodable {
    let duplicate: Bool?
    let dose: Dose?
    let administration: Administration?
}
private struct SkipBodyResponse: Decodable { let dose: Dose }

// MARK: - Live client

actor LiveAPI: CareHiveAPI {
    private let baseURL: URL
    private let session: URLSession
    /// Set when a caller wants a token other than the stored one -- a test, or a
    /// screen working on behalf of a credential that is not this device's.
    private var explicitToken: String?

    /// JSON dates stay strings. The server sends `"2026-09-24 12:00:00"`, which
    /// is neither RFC 3339 nor ISO 8601, so `.iso8601` would fail and
    /// `.deferredToDate` would misread it as a number. Leaving the policy off
    /// means every date field arrives as the exact string the server sent,
    /// which is what `WallClock` wants anyway.
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// For typed request bodies, where `clientRef` must become `client_ref`.
    private let typedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// For bodies built as dictionaries at the call site, where the keys are
    /// *already* the wire names. Using the snake_case strategy here would be a
    /// silent trap: it would look like it worked, because `display_name` and
    /// `timezone` are unchanged by the transform, right up until someone adds a
    /// key the transform does rewrite.
    private let rawEncoder = JSONEncoder()

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.explicitToken = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// The stored session token, unless one was supplied at construction.
    ///
    /// Read per request rather than captured once, because the client is built
    /// before anyone has signed in -- the sign-in screen needs an API to call,
    /// and it is that call which produces the token. Caching it at construction
    /// would mean the very first request after signing in went out unauthenticated.
    private var token: String? { explicitToken ?? SessionStore.shared.token }

    func setToken(_ token: String?) { self.explicitToken = token }

    // MARK: Transport

    /// `body` is already-encoded JSON, or nil for no body. Callers encode so
    /// that which encoder is used is visible at the call site.
    private func request(_ method: String, _ path: String,
                         query: [URLQueryItem] = [],
                         body: Data? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else {
            throw APIError.transport("bad path: \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.decodeError(status: http.statusCode, data: data)
            }
            return data
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request("GET", path, query: query)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let data = try await request("POST", path, body: typedEncoder.encode(body))
        return try decoder.decode(T.self, from: data)
    }

    /// Turns `{"detail": ...}` into an `APIError` without guessing. A structured
    /// detail is kept as a JSON tree so the 409 path can pull named fields out
    /// of it, and anything unparseable is preserved verbatim rather than being
    /// flattened into a generic failure -- an unreadable refusal is exactly the
    /// one worth having in a bug report.
    static func decodeError(status: Int, data: Data) -> APIError {
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let detail = root["detail"] else {
            return .unreadable(status: status, body: text)
        }
        switch detail {
        case .string(let s):
            return .message(s)
        case .object(let o) where o["error"] != nil:
            return .structured(code: o["error"]?.stringValue ?? "http_\(status)",
                               payload: detail)
        default:
            return .unreadable(status: status, body: text)
        }
    }

    // MARK: Account

    func me() async throws -> Me { try await get("/v1/me") }

    // MARK: Circles

    func circles() async throws -> [RecipientSummary] {
        let body: CirclesBody = try await get("/v1/recipients")
        return body.recipients
    }

    func circle(_ id: String) async throws -> Recipient {
        let body: CircleBody = try await get("/v1/recipients/\(id)")
        return body.recipient
    }

    func members(_ recipientId: String) async throws -> [Member] {
        let body: MembersBody = try await get("/v1/recipients/\(recipientId)/members")
        return body.members
    }

    func medications(_ recipientId: String) async throws -> MedicationCatalog {
        try await get("/v1/recipients/\(recipientId)/medications")
    }

    func createMedication(_ recipientId: String,
                          _ draft: MedicationDraft) async throws -> Medication {
        let body = try rawEncoder.encode(draft.wireBody)
        let data = try await request("POST", "/v1/recipients/\(recipientId)/medications",
                                     body: body)
        return try decoder.decode(MedBody.self, from: data).medication
    }

    func updateMedication(_ medicationId: String,
                          _ draft: MedicationDraft) async throws -> Medication {
        let body = try rawEncoder.encode(draft.wireBody)
        let data = try await request("PATCH", "/v1/medications/\(medicationId)", body: body)
        return try decoder.decode(MedBody.self, from: data).medication
    }

    func archiveMedication(_ medicationId: String) async throws {
        // The response names the medication and counts the doses it cancelled,
        // which the caller does not need: the list is reloaded afterwards, and
        // the count is a number to reconcile against the screen rather than to
        // show. Discarded deliberately.
        _ = try await request("DELETE", "/v1/medications/\(medicationId)")
    }

    func deletePhase(_ phaseId: String) async throws {
        _ = try await request("DELETE", "/v1/phases/\(phaseId)")
    }

    func schedule(_ recipientId: String, days: Int) async throws -> [ScheduleDay] {
        let body: ScheduleBody = try await get(
            "/v1/recipients/\(recipientId)/schedule",
            query: [URLQueryItem(name: "days", value: String(days))])
        return body.days
    }

    // MARK: The day

    func today(_ recipientId: String) async throws -> DayFeed {
        try await get("/v1/recipients/\(recipientId)/day")
    }

    func day(_ recipientId: String, on: String) async throws -> DayFeed {
        try await get("/v1/recipients/\(recipientId)/day",
                      query: [URLQueryItem(name: "on", value: on)])
    }

    // MARK: Recording

    private struct GiveBodyRequest: Encodable {
        let clientRef: String
        let note: String?
    }

    func give(doseId: String, clientRef: String, note: String?) async throws -> GiveOutcome {
        do {
            let body: GiveBody = try await post(
                "/v1/doses/\(doseId)/give",
                body: GiveBodyRequest(clientRef: clientRef, note: note))
            return body.duplicate == true ? .alreadyRecordedByYou(dose: body.dose)
                                          : .recorded(dose: body.dose)
        } catch APIError.structured(let code, let payload) where code == "already_given" {
            return .someoneElseGotThere(try Self.decodeGiven(payload))
        }
    }

    /// The 409 payload carries the dose under the same key a 200 uses, which is
    /// what makes one render path possible. Re-encoded through JSON so there is
    /// exactly one definition of `AlreadyGiven` rather than a second, hand-rolled
    /// parser that can drift from it.
    private static func decodeGiven(_ payload: JSONValue) throws -> AlreadyGiven {
        let data = try JSONEncoder().encode(payload)
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(AlreadyGiven.self, from: data)
    }

    private struct SkipBodyRequest: Encodable { let reason: String? }

    func skip(doseId: String, reason: String?) async throws -> Dose {
        let body: SkipBodyResponse = try await post("/v1/doses/\(doseId)/skip",
                                                    body: SkipBodyRequest(reason: reason))
        return body.dose
    }

    func undo(doseId: String) async throws -> VoidResult {
        try await post("/v1/doses/\(doseId)/void", body: EmptyBody())
    }

    private struct PRNBodyRequest: Encodable {
        let medicationId: String
        let reason: String?
        let clientRef: String
    }

    func recordPRN(_ recipientId: String, medicationId: String, reason: String?,
                   clientRef: String) async throws -> PRNResult {
        try await post("/v1/recipients/\(recipientId)/prn",
                       body: PRNBodyRequest(medicationId: medicationId, reason: reason,
                                            clientRef: clientRef))
    }

    func undoPRN(_ administrationId: String) async throws {
        _ = try await request("DELETE", "/v1/prn/\(administrationId)")
    }

    // MARK: Who else is in this

    private struct RoleBody: Encodable { let role: Role }
    private struct UserBody: Encodable { let userId: String }

    func updateMember(_ recipientId: String, userId: String,
                      role: Role) async throws -> MemberChangeResult {
        try await patch("/v1/recipients/\(recipientId)/members/\(userId)",
                        body: RoleBody(role: role))
    }

    func removeMember(_ recipientId: String,
                      userId: String) async throws -> MemberChangeResult {
        let data = try await request("DELETE",
                                     "/v1/recipients/\(recipientId)/members/\(userId)")
        return try decoder.decode(MemberChangeResult.self, from: data)
    }

    func transfer(_ recipientId: String, toUserId: String) async throws -> TransferResult {
        try await post("/v1/recipients/\(recipientId)/transfer",
                       body: UserBody(userId: toUserId))
    }

    private struct InviteBody: Encodable {
        let role: Role
        let label: String?
    }

    func createInvite(_ recipientId: String, role: Role,
                      label: String?) async throws -> InviteCreated {
        try await post("/v1/recipients/\(recipientId)/invites",
                       body: InviteBody(role: role, label: label))
    }

    func invites(_ recipientId: String) async throws -> InviteList {
        try await get("/v1/recipients/\(recipientId)/invites")
    }

    func revokeInvite(_ inviteId: String) async throws {
        _ = try await request("DELETE", "/v1/invites/\(inviteId)")
    }

    /// Anonymous by design: the person holding the code usually has no account
    /// yet, which is the whole point of the code. The request goes out with
    /// whatever token happens to be stored and the server ignores it -- what
    /// authorises this read is the code itself.
    func previewInvite(code: String) async throws -> InvitePreview {
        try await get("/v1/invites/preview", query: [URLQueryItem(name: "code", value: code)])
    }

    private struct CodeBody: Encodable { let code: String }

    func redeemInvite(code: String) async throws -> Redeemed {
        try await post("/v1/invites/redeem", body: CodeBody(code: code))
    }

    // MARK: What happened

    func log(_ recipientId: String, from: String?, to: String?, kinds: [String]?,
             cursor: String?, limit: Int) async throws -> LogPage {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        // `from` is the alias the server publishes, but `from` is also a Swift
        // keyword and a URL query name that reads ambiguously next to a date.
        // The wire name is kept here so the two ends cannot disagree.
        if let from { query.append(URLQueryItem(name: "from", value: from)) }
        if let to { query.append(URLQueryItem(name: "to", value: to)) }
        if let kinds, !kinds.isEmpty {
            query.append(URLQueryItem(name: "kinds", value: kinds.joined(separator: ",")))
        }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get("/v1/recipients/\(recipientId)/log", query: query)
    }

    private struct EntryBody: Encodable {
        let body: String
        let kind: String
        let mood: String?
    }

    private struct EntryEnvelope: Decodable { let entry: JournalEntry }

    func createEntry(_ recipientId: String, body: String, kind: String,
                     mood: String?) async throws -> JournalEntry {
        let env: EntryEnvelope = try await post("/v1/recipients/\(recipientId)/journal",
                                                body: EntryBody(body: body, kind: kind,
                                                                mood: mood))
        return env.entry
    }

    func entry(_ entryId: String) async throws -> JournalEntryBody {
        try await get("/v1/journal/\(entryId)")
    }

    /// Both fields optional, and only the ones present are sent. Sending
    /// `body: null` would mean "clear the note", which is a different act from
    /// "change the mood" -- so the dictionary is built key by key rather than
    /// with two optionals that encode as nulls.
    func updateEntry(_ entryId: String, body: String?,
                     mood: String?) async throws -> JournalEntry {
        var patch: [String: JSONValue] = [:]
        if let body { patch["body"] = .string(body) }
        if let mood { patch["mood"] = .string(mood) }
        let raw = try rawEncoder.encode(JSONValue.object(patch))
        let data = try await request("PATCH", "/v1/journal/\(entryId)", body: raw)
        return try decoder.decode(EntryEnvelope.self, from: data).entry
    }

    func deleteEntry(_ entryId: String) async throws {
        _ = try await request("DELETE", "/v1/journal/\(entryId)")
    }

    // MARK: What is left

    func supply(_ recipientId: String) async throws -> SupplyList {
        try await get("/v1/recipients/\(recipientId)/supply")
    }

    func supplyHistory(_ medicationId: String) async throws -> SupplyHistory {
        try await get("/v1/medications/\(medicationId)/supply/history")
    }

    private struct SupplyBody: Encodable {
        let unitsOnHand: Double
        let refillAt: Double?
    }

    private struct SupplyEnvelope: Decodable { let supply: Supply }

    /// `refillAt` is the threshold to *store*, so passing nil clears it. The
    /// server distinguishes the two -- it only touches the column when the key
    /// is present, and an explicit null is how you say "no threshold" -- and
    /// this signature collapses that into one meaning so a caller cannot send
    /// a null by accident and silently drop a number the family set.
    func setSupply(_ medicationId: String, unitsOnHand: Double,
                   refillAt: Double?) async throws -> Supply {
        let body = try rawEncoder.encode(JSONValue.object([
            "units_on_hand": .number(unitsOnHand),
            "refill_at": refillAt.map { JSONValue.number($0) } ?? .null,
        ]))
        let data = try await request("PUT", "/v1/medications/\(medicationId)/supply",
                                     body: body)
        return try decoder.decode(SupplyEnvelope.self, from: data).supply
    }

    private struct RefillBody: Encodable {
        let units: Double
        let note: String?
    }

    func refill(_ medicationId: String, units: Double, note: String?) async throws -> Supply {
        let env: SupplyEnvelope = try await post("/v1/medications/\(medicationId)/supply/refill",
                                                 body: RefillBody(units: units, note: note))
        return env.supply
    }

    func untrackSupply(_ medicationId: String) async throws {
        _ = try await request("DELETE", "/v1/medications/\(medicationId)/supply")
    }

    // MARK: The wall tablet

    func displays(_ recipientId: String) async throws -> DisplayList {
        try await get("/v1/recipients/\(recipientId)/display")
    }

    private struct DisplayBody: Encodable { let label: String? }

    func createDisplay(_ recipientId: String, label: String?) async throws -> DisplayPairing {
        try await post("/v1/recipients/\(recipientId)/display", body: DisplayBody(label: label))
    }

    func reissuePairingCode(_ displayId: String) async throws -> PairingCode {
        try await post("/v1/display/\(displayId)/pairing-code", body: EmptyBody())
    }

    private struct LabelBody: Encodable { let label: String }
    private struct DisplayEnvelope: Decodable { let display: DisplayDevice }

    func renameDisplay(_ displayId: String, label: String) async throws -> DisplayDevice {
        let env: DisplayEnvelope = try await patch("/v1/display/\(displayId)",
                                                   body: LabelBody(label: label))
        return env.display
    }

    func revokeDisplay(_ displayId: String) async throws {
        _ = try await request("DELETE", "/v1/display/\(displayId)")
    }

    // MARK: Reminders and the plan

    private struct DeviceBody: Encodable {
        let token: String
        let platform: String
        let environment: String
        let appVersion: String?
    }

    private struct DeviceEnvelope: Decodable { let device: Device }

    func registerDevice(token: String, platform: String, environment: String,
                        appVersion: String?) async throws -> Device {
        let env: DeviceEnvelope = try await post("/v1/devices",
                                                 body: DeviceBody(token: token,
                                                                  platform: platform,
                                                                  environment: environment,
                                                                  appVersion: appVersion))
        return env.device
    }

    func devices() async throws -> DeviceList { try await get("/v1/devices") }

    func notifications() async throws -> NotificationList { try await get("/v1/notifications") }

    func markRead(_ notificationId: String) async throws {
        let _: MarkedResult = try await post("/v1/notifications/\(notificationId)/read",
                                             body: EmptyBody())
    }

    func markAllRead() async throws -> Int {
        let r: MarkedResult = try await post("/v1/notifications/read-all", body: EmptyBody())
        return r.marked
    }

    func products() async throws -> ProductsResponse { try await get("/v1/purchases/products") }

    private struct VerifyBody: Encodable { let signedTransaction: String }
    private struct EntitlementEnvelope: Decodable { let entitlement: Entitlement? }

    /// The raw StoreKit transaction, unmodified. The server parses the JWS and
    /// walks the certificate chain to Apple's root; anything this client did to
    /// the blob first -- unwrapping it, re-encoding it, trimming whitespace out
    /// of the payload -- would break that verification, and a client that
    /// "helpfully" repaired a payload would be a client that could be made to
    /// vouch for a forged one.
    func verifyPurchase(signedTransaction: String) async throws -> Entitlement {
        let env: EntitlementEnvelope = try await post(
            "/v1/purchases/verify", body: VerifyBody(signedTransaction: signedTransaction))
        guard let entitlement = env.entitlement else {
            throw APIError.message("The purchase was verified but no plan came back.")
        }
        return entitlement
    }

    // MARK: Who you are

    private struct AppleSignInBody: Encodable {
        let identityToken: String
        let nonce: String
        let authorizationCode: String?
        let fullName: String?
        let timezone: String
    }

    func signInWithApple(identityToken: String, nonce: String,
                         authorizationCode: String?, fullName: String?,
                         timezone: String) async throws -> SignedIn {
        // Sent with whatever token happens to be stored, which on a first run is
        // none. The server ignores the header on this route: what authorises it
        // is Apple's signature, verified against Apple's keys.
        try await post("/v1/auth/apple",
                       body: AppleSignInBody(identityToken: identityToken,
                                             nonce: nonce,
                                             authorizationCode: authorizationCode,
                                             fullName: fullName,
                                             timezone: timezone))
    }

    func updateMe(_ patch: MePatch) async throws -> MeUpdate {
        let raw = try rawEncoder.encode(patch.wireBody)
        let data = try await request("PATCH", "/v1/me", body: raw)
        return try decoder.decode(MeUpdate.self, from: data)
    }

    func deleteAccount() async throws -> DeletedAccount {
        let data = try await request("DELETE", "/v1/me")
        return try decoder.decode(DeletedAccount.self, from: data)
    }

    // MARK: Transport, part two

    /// Added alongside the read paths above rather than at the top of the file,
    /// because PATCH was the one verb the first pass did not need and the
    /// transport section is easier to read as a set than as a list.
    private func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let data = try await request("PATCH", path, body: typedEncoder.encode(body))
        return try decoder.decode(T.self, from: data)
    }
}

struct EmptyBody: Codable {}
