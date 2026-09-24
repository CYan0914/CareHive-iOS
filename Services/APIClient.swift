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
    func updateMe(_ patch: [String: JSONValue]) async throws -> Me

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
    private var token: String?

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
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func setToken(_ token: String?) { self.token = token }

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

    func updateMe(_ patch: [String: JSONValue]) async throws -> Me {
        // The dictionary is already wire-shaped, so it goes through the raw
        // encoder. See the note on `rawEncoder`.
        let body = try rawEncoder.encode(JSONValue.object(patch))
        let data = try await request("PATCH", "/v1/me", body: body)
        return try decoder.decode(Me.self, from: data)
    }

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
}

struct EmptyBody: Codable {}
