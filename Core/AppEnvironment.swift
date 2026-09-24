// Which server the app is talking to, and which screen it should open on.
//
// Both are decided by launch arguments, which is what makes the App Store
// screenshot job possible: `simctl launch` can hand the app a screen name and a
// stubbed server, so a CI runner with no backend renders every screen
// deterministically. The same mechanism is what a developer uses to work on the
// UI on a train.

import Foundation

enum AppEnvironment {

    /// `-CareHiveDemo <screen>` -- run against `DemoAPI` and open on `screen`.
    ///
    /// The bare form `-CareHiveDemo` (or `-CareHiveDemo 1`) turns the demo on
    /// and leaves the default screen. Naming the screen is what the capture
    /// script does, one launch per screenshot.
    static var demoScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-CareHiveDemo") else { return nil }
        let next = args.indices.contains(i + 1) ? args[i + 1] : nil
        // A following token that starts with "-" is the next flag, not a screen.
        if let next, !next.hasPrefix("-") { return next }
        return "today"
    }

    static var isDemo: Bool { demoScreen != nil }

    /// Where the API lives.
    ///
    /// Debug builds point at the local dev server so that a build someone runs
    /// from Xcode cannot accidentally write a real family's dose record. That
    /// safety has to stop at the archive: a release build sent to Apple with a
    /// loopback address in it is an app whose sign-in screen fails for every
    /// reviewer, which is a rejection rather than a bug report. So the split is
    /// on the build configuration rather than left as a line to remember.
    ///
    /// The production host is the one `helpers/deploy_ssh.py` provisions. If
    /// the API is ever deployed somewhere else, this string and that constant
    /// have to move together -- which is why there is exactly one of each.
    static var baseURL: URL {
        if let override = ProcessInfo.processInfo.environment["CAREHIVE_API"],
           let url = URL(string: override) {
            return url
        }
        #if DEBUG
        return URL(string: "http://127.0.0.1:8823")!
        #else
        return URL(string: "https://carehive.taomindapp.com")!
        #endif
    }

    /// The server for this launch. Demo never touches the network -- not even a
    /// health check -- because the screenshot job runs where there is nothing to
    /// check.
    static func makeAPI() -> any CareHiveAPI {
        if isDemo { return DemoAPI() }
        return LiveAPI(baseURL: baseURL, token: SessionStore.shared.token)
    }
}

/// The bearer token, in the Keychain.
///
/// Not `UserDefaults`: this token is the only thing standing between a stranger
/// and a record of what medication an elderly person takes, which is among the
/// more sensitive things a phone can hold. `UserDefaults` is a plist in the app
/// container -- readable from a backup and from a jailbroken device.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than `WhenUnlocked` because the
/// reminder notification can be delivered while the phone is locked, and the
/// snooze action on it needs to read this. It still does not survive a restore
/// to a different device, which is what `ThisDeviceOnly` buys.
final class SessionStore {
    static let shared = SessionStore()

    private let service = "com.cyan0914.carehive"
    private let account = "session-token"
    private var cached: String??

    var token: String? {
        get {
            if let cached { return cached }
            let value = read()
            cached = value
            return value
        }
        set {
            cached = newValue
            if let newValue { write(newValue) } else { delete() }
        }
    }

    private func read() -> String? {
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

    private func write(_ value: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
