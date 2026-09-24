// The wall tablet's own client, kept apart from `CareHiveAPI` on purpose.
//
// The server keeps two disjoint credential spaces: a session token is looked up
// in `sessions` and a display credential in `display_devices`, and neither
// lookup can succeed on the other's value. Mirroring that separation in the
// client means a tablet cannot reach the family's write endpoints even if a
// screen is added carelessly later -- there is no method on this protocol that
// writes anything, and no token in this store that would authorise one.
//
// The tablet's credential outlives every session. It is the only credential in
// this app that is not a person's, which is exactly why it is stored under its
// own Keychain account rather than beside the session token.

import Foundation

/// What the wall can do. Two reads and no writes, which is the entire surface.
protocol KitchenWallAPI: Sendable {
    func whoAmI() async throws -> WallWhoAmI
    func today() async throws -> WallToday
}

/// Raised when the tablet's credential is not accepted.
///
/// Its own case, rather than whatever `APIError` the 401 would otherwise
/// become, because the server answers the same way for every reason a
/// credential can stop working -- revoked from a phone, expired, or never
/// valid at all -- and the screen has to say something true about all three
/// rather than guess which one it was.
enum WallError: Error {
    /// No credential stored at all -- this tablet has never been set up, or
    /// somebody chose "Set up again".
    case unpaired
    /// A credential existed and was refused.
    case switchedOff
}

/// Redeeming a pairing code, which has to happen before there is any credential
/// at all -- so it is a free function on a type with no state rather than a
/// method on a client that would need one.
enum WallPairing {
    /// The only anonymous write this app makes. The code itself is the
    /// authorisation; that is the point of it, and the server rate-limits this
    /// endpoint far harder than anything else because of it.
    static func redeem(code: String, baseURL: URL) async throws -> WallPaired {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/v1/display/pair"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = []
        guard let url = comps?.url else { throw APIError.transport("bad path") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Normalised here as well as on the server, because a person reading a
        // code off a tablet screen and typing it into a phone is the single most
        // likely place for a stray space or a lower-case letter to creep in.
        req.httpBody = try JSONEncoder().encode(
            ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .uppercased()])

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveAPI.decodeError(status: http.statusCode, data: data)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WallPaired.self, from: data)
    }
}

actor LiveWallAPI: KitchenWallAPI {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        // Longer than the phone's, and deliberately so. A wall tablet that has
        // been asleep may be on a slow or flaky connection, and the failure mode
        // we care about is not "slow" -- it is showing a stale day. A timeout
        // that fires early and leaves yesterday's doses on the wall is worse
        // than one that waits.
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.transport("bad path: \(path)")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                // The 401 becomes a wall-specific error here, at the single
                // point both reads pass through. The server answers 401 for
                // every reason a display credential can stop working --
                // revoked from a phone, expired, or never valid -- and the
                // screen has to say something true about all three rather than
                // guess which one it was.
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw WallError.switchedOff
                }
                throw LiveAPI.decodeError(status: http.statusCode, data: data)
            }
            return try decoder.decode(T.self, from: data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    func whoAmI() async throws -> WallWhoAmI { try await get("/v1/display/whoami") }
    func today() async throws -> WallToday { try await get("/v1/display/today") }
}

// MARK: - The tablet's credential

/// The display token, in the Keychain under its own account.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, like the session token
/// and for a stronger version of the same reason: a wall tablet is on a charger
/// in a hallway, it is never signed out deliberately, and this credential can
/// read a person's medication list for as long as it lives. It must not travel
/// in a backup to somebody else's device.
enum DisplayTokenStore {
    private static let service = "com.cyan0914.carehive"
    private static let account = "display-token"

    static var token: String? {
        get { read() }
        set {
            delete()
            guard let newValue else { return }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(newValue.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
