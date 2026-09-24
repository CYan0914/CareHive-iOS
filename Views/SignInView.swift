// The first screen, and the one a reviewer sees before any other.
//
// Sign in with Apple is the only way in, which is a product decision rather
// than a technical one: this app holds a record of what medication somebody's
// parent takes, and the alternative -- an email and a password -- would mean
// holding a credential for it, sending password-reset mail, and answering for a
// breach. Apple's identifier is enough to know who is who and nothing else.
//
// Two things this screen has to do that a normal sign-in does not:
//
//  * **Ask for the name at the right moment.** Apple sends the person's name
//    exactly once, on the very first authorisation, and never again. A flow
//    that drops it leaves a family with a member listed as "Someone" and no
//    way to fix it except by typing it. So the name is forwarded from the one
//    credential that will ever carry it, and the request is not treated as
//    complete until it lands.
//  * **Say what signing in does before it does it.** The button is Apple's and
//    cannot be restyled, so the sentence explaining the circle, the reminders
//    and the medical boundary goes above it, where it is read rather than
//    skipped.

import AuthenticationServices
import CommonCrypto
import SwiftUI

@MainActor
@Observable
final class SignInModel {
    var busy = false
    var error: String?

    /// What the server sent back, once there is a session. Held rather than
    /// written straight to the Keychain so the screen that owns the flow is
    /// the one place a credential lands -- see `SignedIn`.
    var signedIn: SignedIn?

    private let api: any CareHiveAPI
    /// The nonce, kept between `prepareRequest` and the callback because Apple
    /// signs *this* value and the server recomputes the hash to check it. A
    /// nonce regenerated in between is a nonce that never matches.
    private var nonce: String?

    init(api: any CareHiveAPI) {
        self.api = api
    }

    /// Called by SwiftUI before the sheet is shown.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let fresh = SignInModel.makeNonce()
        nonce = fresh
        request.requestedScopes = [.fullName]
        request.nonce = SignInModel.sha256(fresh)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            // A cancellation is not a failure and must not be reported as one.
            if let authError = error as? ASAuthorizationError,
               authError.code == .canceled {
                return
            }
            self.error = "Sign in with Apple didn't finish. Please try again."
        case .success(let authorization):
            await exchange(authorization)
        }
    }

    private func exchange(_ authorization: ASAuthorization) async {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              let nonce else {
            error = "Sign in with Apple didn't return a usable credential."
            return
        }
        busy = true
        defer { busy = false }
        do {
            signedIn = try await api.signInWithApple(
                identityToken: identityToken,
                nonce: nonce,
                authorizationCode: credential.authorizationCode.flatMap {
                    String(data: $0, encoding: .utf8)
                },
                // Nil on every sign-in after the first. Passing an empty string
                // instead would be a name of "" rather than no name, and the
                // server would store it.
                fullName: credential.fullName?.formatted(),
                timezone: TimeZone.current.identifier)
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    // MARK: Nonce

    /// A fresh random string per attempt. Reusing one across attempts is the
    /// replay the nonce exists to prevent.
    static func makeNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else {
            // A nonce that could not be generated randomly is not a nonce.
            // Falling back to something predictable would silently remove the
            // protection, so this fails loudly instead -- and it cannot happen
            // on a device with a working keychain.
            fatalError("SecRandomCopyBytes failed with status \(status)")
        }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func sha256(_ input: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(input.utf8)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Screen

struct SignInView: View {
    @State private var model: SignInModel
    let onSignedIn: (SignedIn) -> Void

    init(api: any CareHiveAPI, onSignedIn: @escaping (SignedIn) -> Void) {
        _model = State(initialValue: SignInModel(api: api))
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                headerGap
                title
                whatItIs
                bullets
                signInButton
                if let error = model.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.missed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrivacyNote()
            }
            .padding(DS.Space.l)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(DS.Palette.screen)
        .onChange(of: model.signedIn?.sessionToken) {
            if let signedIn = model.signedIn { onSignedIn(signedIn) }
        }
    }

    /// Pushes the content below the fold line on a small phone, so the screen
    /// reads as a page rather than as a wall of text starting at the notch.
    private var headerGap: some View { Color.clear.frame(height: DS.Space.xl) }

    private var title: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 44))
                .foregroundStyle(DS.Palette.accent)
            Text("CareHive")
                .font(.largeTitle.weight(.bold))
            Text("One place for a family to see what has already been done.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whatItIs: some View {
        Text("When several people look after the same person, the question is "
             + "never \"what is on the list\" -- it is \"did Mum have her "
             + "morning tablets, or did I imagine it\". CareHive answers that "
             + "question for everyone at once.")
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bullets: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Bullet(symbol: "checkmark.circle",
                   title: "Everyone sees the same day",
                   text: "Every brother, sister, neighbour and carer you add "
                       + "sees the same list, updated as it happens.")
            Bullet(symbol: "person.badge.plus",
                   title: "Adding people is free",
                   text: "Nobody in the circle is charged for joining, on any "
                       + "plan. Paying never changes who is allowed to help.")
            Bullet(symbol: "eye.slash",
                   title: "It records. It does not advise.",
                   text: "CareHive never suggests a dose, never calculates one, "
                       + "and never tells you what to do. It shows what was "
                       + "written down, and who wrote it.")
        }
    }

    private var signInButton: some View {
        VStack(spacing: DS.Space.s) {
            SignInWithAppleButton(.signIn) { request in
                // SwiftUI calls this on the main thread, so asserting that is
                // a statement of fact rather than a hope -- and it is the only
                // way to reach a main-actor method from a closure the button
                // declares as nonisolated. The nonce has to be set here and
                // nowhere later: the callback arrives already signed.
                MainActor.assumeIsolated { model.prepare(request) }
            } onCompletion: { result in
                Task { await model.complete(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .disabled(model.busy)
            .opacity(model.busy ? 0.6 : 1)

            if model.busy {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Pieces

private struct Bullet: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The privacy sentence, stated as a fact about the data rather than as a
/// reassurance. "We take privacy seriously" is a sentence every app has, which
/// is why it means nothing; what this app actually does is more useful.
struct PrivacyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("What CareHive holds")
                .font(.footnote.weight(.semibold))
            Text("Your name and an identifier from Apple, your medication "
                 + "schedules, and what was recorded. Not your contacts, not "
                 + "your location, and nothing about anyone's health beyond "
                 + "what your family types in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.Space.s)
    }
}
