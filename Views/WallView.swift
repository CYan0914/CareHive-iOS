// The tablet on the kitchen wall.
//
// This is the same binary as the phone app, launched into a different mode,
// and the reason is worth stating: a separate iPad app would be a second thing
// to install, a second thing to update, and a second thing to get wrong. What
// makes the modes different is not the UI framework, it is the credential --
// `KitchenWallAPI` has no method that writes, and the token in
// `DisplayTokenStore` cannot authorise one.
//
// Three things drive the whole screen:
//
//  * **Type big enough to read standing up, from the doorway.** The whole point
//    is that somebody walks past and knows, without stopping, putting glasses
//    on, or finding a phone. Everything here is sized for that and nothing is
//    sized for density.
//  * **It never says "overdue".** That judgement is not in the payload, and
//    this screen does not manufacture it. A wall that says "overdue" is a wall
//    that scolds, in a room where the person being scolded may be sitting.
//  * **Nobody can record from here.** There is no checkbox, no button and no
//    row that looks tappable, because the honest answer to "can I tick it from
//    here" is no, and a screen that looks like it might is the one design
//    failure that would actually cause a double dose: somebody taps, nothing
//    happens, and they walk to the pill organiser to be sure.

import SwiftUI

@MainActor
@Observable
final class WallModel {
    enum Phase {
        case starting
        case needsPairing
        case showing(WallToday)
        case failed(String)
    }

    var phase: Phase = .starting
    var code = ""
    var pairing = false
    var pairError: String?
    /// Advanced by the ticker. Only used to decide when to re-fetch, never
    /// rendered -- the clock on screen comes from the server's `now_local`.
    private var lastFetch = Date.distantPast

    private let baseURL: URL
    private var api: (any KitchenWallAPI)?

    init(baseURL: URL, demo: Bool = false) {
        self.baseURL = baseURL
        if demo {
            api = DemoWallAPI()
        } else if let token = DisplayTokenStore.token {
            api = LiveWallAPI(baseURL: baseURL, token: token)
        }
    }

    func start() async {
        guard let api else {
            phase = .needsPairing
            return
        }
        do {
            // `whoAmI` first, and not for its own sake: it is the cheapest way
            // to find out that this tablet has been switched off from the
            // family's phone, which is a state the screen has to show rather
            // than sit on a blank day forever.
            _ = try await api.whoAmI()
            await refresh()
        } catch {
            phase = .failed(WallModel.sentence(for: error))
        }
    }

    func refresh() async {
        guard let api else { return }
        do {
            let today = try await api.today()
            phase = .showing(today)
            lastFetch = Date()
        } catch {
            // Keep whatever is on screen if there is something on screen. A
            // wall that clears itself because one request failed is worse than
            // one showing the morning for a few minutes longer -- and the
            // timestamp at the bottom says which it is.
            if case .showing = phase { return }
            phase = .failed(WallModel.sentence(for: error))
        }
    }

    /// Called on a timer. `stale` is computed from the request clock rather
    /// than the tablet's, so a device that has been asleep does not believe it
    /// fetched a second ago.
    func tick() async {
        switch phase {
        case .showing:
            if Date().timeIntervalSince(lastFetch) > 120 { await refresh() }
        case .failed, .starting:
            await start()
        case .needsPairing:
            break
        }
    }

    func pair() async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pairing = true
        pairError = nil
        defer { pairing = false }
        do {
            let paired = try await WallPairing.redeem(code: trimmed, baseURL: baseURL)
            DisplayTokenStore.token = paired.token
            api = LiveWallAPI(baseURL: baseURL, token: paired.token)
            code = ""
            await start()
        } catch {
            pairError = WallModel.sentence(for: error)
        }
    }

    func unpair() {
        DisplayTokenStore.token = nil
        api = nil
        phase = .needsPairing
        code = ""
        pairError = nil
    }

    /// What a person standing at the tablet needs to be told. Not the app's
    /// usual error copy: there is nobody here to retry a network call, and the
    /// only useful instruction is about the tablet itself.
    static func sentence(for error: Error) -> String {
        switch error {
        // `LiveWallAPI` translates the server's 401 into this before it gets
        // here, so it is the case that actually fires when a tablet has been
        // switched off from somebody's phone.
        case WallError.switchedOff:
            return "This tablet was switched off from the CareHive app."
        case WallError.unpaired:
            return "This tablet is not set up yet."
        case APIError.transport:
            return "No connection. Showing the last day it could get."
        default:
            return "This tablet is not set up yet."
        }
    }
}

// MARK: - Screen

struct WallRootView: View {
    @State private var model: WallModel

    init(baseURL: URL = AppEnvironment.baseURL, demo: Bool = AppEnvironment.isDemo) {
        _model = State(initialValue: WallModel(baseURL: baseURL, demo: demo))
    }

    var body: some View {
        ZStack {
            DS.Palette.screen.ignoresSafeArea()
            content
        }
        .task { await model.start() }
        // A wall tablet has nobody to pull to refresh, so it refreshes itself.
        // A minute is often enough for a screen whose smallest unit is a dose
        // time, and cheap enough to leave running for a year.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await model.tick()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting:
            ProgressView().controlSize(.large)
        case .needsPairing:
            WallPairingView(model: model)
        case .showing(let today):
            WallTodayView(today: today)
        case .failed(let message):
            WallFailedView(model: model, message: message)
        }
    }
}

// MARK: - Today

private struct WallTodayView: View {
    let today: WallToday

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            header
            if today.beyondHorizon {
                Text("This tablet is showing a day it no longer has a schedule for.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            doses
            if !today.prnToday.isEmpty { prn }
            Spacer(minLength: 0)
            footer
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(today.recipient.callName)
                    .font(.system(size: 44, weight: .semibold))
                Text(WallClock.longDate(today.date))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                // The recipient's wall clock, straight from the server. Never
                // the tablet's own, which may have been asleep for a week.
                //
                // `now_local` arrives as a bare "08:05" rather than the full
                // timestamps the doses carry, so it goes through `clock` and
                // not `time` -- and through one of them it must go, or the
                // wall would print 24-hour time beside 12-hour dose times.
                Text(WallClock.clock(today.nowLocal))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(today.counts.sentence)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var doses: some View {
        VStack(spacing: DS.Space.s) {
            if today.doses.isEmpty {
                Text("Nothing scheduled for today.")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DS.Space.l)
            } else {
                ForEach(today.doses) { dose in
                    WallDoseRow(dose: dose)
                }
            }
        }
    }

    private var prn: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Taken when needed")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(today.prnToday) { entry in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    Text(entry.medicationName ?? "As needed")
                        .font(.title2)
                    Text(DS.units(entry.units, entry.unitLabel))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let at = entry.timeLocal.map({ WallClock.time($0) }) {
                        Text(at).font(.title3).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        // The one sentence that has to be on the wall itself. Somebody will
        // try to tap it; a visitor will ask; and the answer is on the screen
        // before they ask.
        Text("To record a dose, use the CareHive app on your phone.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

private struct WallDoseRow: View {
    let dose: WallDose

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 0) {
                Text(WallClock.time(dose.timeLocal))
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
                if let slot = dose.slotLabel {
                    Text(slot).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(dose.medicationName)
                    .font(.system(size: 30, weight: .semibold))
                HStack(spacing: DS.Space.s) {
                    if let strength = dose.medicationStrength, !strength.isEmpty {
                        Text(strength).font(.title3).foregroundStyle(.secondary)
                    }
                    Text(DS.units(dose.unitsPerDose, dose.unitLabel))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                // The word, in large type, in the state's colour as well. Both,
                // always -- a wall read from across a room by somebody who may
                // be colour-blind is the exact case `DS.style` exists for.
                StatePill(style: style)
                if let at = dose.givenAtLocal.map({ WallClock.time($0) }) {
                    Text(at).font(.title3).foregroundStyle(.secondary)
                }
                if let by = dose.givenByName {
                    Text(by).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(DS.Space.m)
        .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    /// `overdue: false`, always, and deliberately not computed here. See the
    /// note at the top of the file: the server keeps the judgement out of the
    /// payload, and a tablet that reconstructed it would put a scolding on
    /// somebody's kitchen wall.
    private var style: DS.StateStyle { DS.style(for: dose.status, overdue: false) }
}

// MARK: - Not set up yet

private struct WallPairingView: View {
    let model: WallModel

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "ipad")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Set up this tablet")
                .font(.largeTitle.weight(.semibold))
            Text("Open CareHive on your phone, go to Tablets, and add a "
                 + "tablet. It will give you a code to type here.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            TextField("Code", text: Binding(
                get: { model.code },
                set: { model.code = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 40, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                .frame(maxWidth: 420, minHeight: 72)
                .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 14))
                .onSubmit { Task { await model.pair() } }

            Button {
                Task { await model.pair() }
            } label: {
                if model.pairing {
                    ProgressView().tint(.white)
                } else {
                    Text("Set up")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !model.pairing))
            .frame(maxWidth: 420)

            if let error = model.pairError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(DS.Palette.missed)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Text("A code lasts fifteen minutes and works once.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(DS.Space.xl)
    }
}

private struct WallFailedView: View {
    let model: WallModel
    let message: String

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundStyle(DS.Palette.overdue)
            Text(message)
                .font(.title2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("This tablet keeps trying on its own. If it does not come "
                 + "back, set it up again from the CareHive app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Set up again") { model.unpair() }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: 320)
        }
        .padding(DS.Space.xl)
    }
}
