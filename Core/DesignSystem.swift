// Type, colour and spacing, in one place.
//
// Two constraints shape everything here, and neither is cosmetic:
//
//  * This is used one-handed, standing in a kitchen, sometimes by someone in
//    their seventies who is not the person who installed it. So: no control
//    smaller than 44pt, no label that relies on colour alone to mean something,
//    and every state also spelled out in words.
//  * The app is looked at in a hurry and often with dread. A missed dose and a
//    given dose must not differ only by a hue -- roughly one man in twelve has
//    a red/green confusion, and "did Mum get her pill" is not a question to
//    answer with a coin flip.

import SwiftUI

enum DS {

    // MARK: - Spacing

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// The floor for anything tappable. Apple's own minimum, and the number the
    /// layout is designed around rather than trimmed to afterwards.
    static let tapTarget: CGFloat = 44

    // MARK: - Colour

    enum Palette {
        static let pending = Color(.systemGray2)
        static let given = Color.green
        static let overdue = Color.orange
        static let missed = Color.red
        static let skipped = Color(.systemGray)

        static let card = Color(.secondarySystemGroupedBackground)
        static let screen = Color(.systemGroupedBackground)

        /// The one accent, used for the primary action on a screen and nothing
        /// else, so that "the thing to press" is never ambiguous.
        static let accent = Color.accentColor
    }

    // MARK: - Semantics

    /// Every dose state carries a word and a symbol as well as a colour, so the
    /// state survives both a colour-blind reader and a greyscale screenshot.
    struct StateStyle {
        let label: String
        let symbol: String
        let tint: Color
    }

    static func style(for status: DoseStatus, overdue: Bool) -> StateStyle {
        // Overdue is a *pending* dose whose time has passed. It is deliberately
        // not its own `DoseStatus` on the server: the dose is still pending --
        // nobody has recorded anything -- and calling it "missed" would be the
        // app making a claim about a person. It is late, and the family decides
        // what that means.
        if status == .pending && overdue {
            return StateStyle(label: "Overdue", symbol: "clock.badge.exclamationmark",
                              tint: Palette.overdue)
        }
        switch status {
        case .pending: return StateStyle(label: "Due", symbol: "circle", tint: Palette.pending)
        case .given: return StateStyle(label: "Given", symbol: "checkmark.circle.fill",
                                       tint: Palette.given)
        case .missed: return StateStyle(label: "Not given", symbol: "xmark.circle",
                                        tint: Palette.missed)
        case .skipped: return StateStyle(label: "Skipped", symbol: "arrow.uturn.forward.circle",
                                         tint: Palette.skipped)
        }
    }

    // MARK: - Formatting

    /// "1 tablet", "2 tablets". Never a bare number: a family reading "2" next
    /// to a medication name does not know if that is tablets, millilitres or
    /// milligrams, and this is the field where being wrong matters most.
    static func units(_ count: Double, _ label: String?) -> String {
        let unit = (label?.isEmpty == false ? label! : "dose")
        let rounded = count.rounded()
        if count == rounded && rounded == 1 { return "1 \(unit)" }
        if count == rounded { return "\(Int(rounded)) \(unit)s" }
        // Halves are real (a half tablet is a real prescription) so they are
        // shown as they are rather than rounded into a lie.
        return "\(count.formatted(.number.precision(.fractionLength(0...2)))) \(unit)s"
    }

    /// "10 mg" when there is a strength, nothing when there is not -- rather
    /// than a dash or the word "unknown", which read as an error.
    static func strength(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return value
    }

    /// "21:00" from 1260.
    ///
    /// Quiet hours are minutes past midnight on a clock that is the *reader's*
    /// own, not the recipient's -- which is why this lives here rather than
    /// beside `WallClock`, whose whole rule is that the only clock the app
    /// displays is somebody else's. The two must not be confused, so they are
    /// not in the same file.
    ///
    /// Wraps rather than clamps: 1440 and 0 are both midnight, and a range that
    /// ends at 08:00 the next morning is the ordinary case, not an error.
    static func clock(minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

// MARK: - Reusable pieces

/// A circular state badge. Sized from Dynamic Type so that a reader at the
/// largest accessibility size gets a proportionally bigger mark rather than a
/// fixed dot next to enormous text.
struct StateBadge: View {
    let style: DS.StateStyle

    var body: some View {
        Image(systemName: style.symbol)
            .font(.title2)
            .foregroundStyle(style.tint)
            .frame(width: DS.tapTarget, height: DS.tapTarget)
            .accessibilityHidden(true)   // the label beside it says the same thing
    }
}

/// The word that goes with the badge. Both are always present.
struct StatePill: View {
    let style: DS.StateStyle

    var body: some View {
        Text(style.label)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 3)
            .background(style.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(style.tint)
    }
}

/// The primary action on a screen. Full width, unmissable, and never the only
/// way to do something (there is always a text alternative) -- but when it is
/// on screen it is obvious which one it is.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = DS.Palette.accent
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(enabled ? tint : Color(.systemGray4), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.primary)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.systemGray4)))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// An explanation, in the app's voice, for the states that need one.
///
/// These sentences are the product's medical boundary written as copy. They
/// report what happened. They never advise about what to do next, never mention
/// a quantity of medicine as a thing to act on, and never imply the app is
/// watching. Every string here says "here is what was recorded", because that
/// is the only claim this app is entitled to make.
struct ExplanationCard: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
