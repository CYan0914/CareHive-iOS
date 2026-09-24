// Today's doses for one person.
//
// This is the screen the whole app exists to serve: someone standing in a
// kitchen holding a pill, needing to know whether it has already been given.
// Everything about the layout follows from that -- the answer is the first
// thing on the screen, it is stated in words, and recording a dose is one tap
// from here.

import SwiftUI

@MainActor
@Observable
final class TodayModel {
    var feed: DayFeed?
    var loading = false
    var loadError: String?

    /// The dose currently being recorded, so the row can show progress and the
    /// rest of the list can stay interactive.
    var inFlight: String?

    /// Set when the server says somebody else recorded the dose first. Drives
    /// the sheet that names them.
    var alreadyGiven: AlreadyGiven?

    /// `client_ref` per dose, minted when a give is *started* and reused on
    /// every retry of that same attempt.
    ///
    /// This is the whole idempotency contract. If the request times out on a
    /// bad connection and the family taps again, the server must recognise the
    /// second request as the same act and replay the original success rather
    /// than recording a second dose -- or refusing the retry as a race it lost
    /// to itself. Minting a new ref per *tap* would break both.
    private var refs: [String: String] = [:]

    private let api: any CareHiveAPI

    init(api: any CareHiveAPI) { self.api = api }

    func ref(for doseId: String) -> String {
        if let existing = refs[doseId] { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        refs[doseId] = fresh
        return fresh
    }

    /// Called when the give sheet closes without giving, so the next attempt is
    /// a new act with a new ref.
    func forgetRef(for doseId: String) { refs[doseId] = nil }

    func load(recipientId: String) async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            feed = try await api.today(recipientId)
        } catch {
            loadError = Self.message(for: error)
        }
    }

    /// Returns the outcome so the caller can drive the sheet. The 409 comes back
    /// as a value rather than an error, and is stored for rendering.
    func give(doseId: String, note: String?) async -> GiveOutcome? {
        inFlight = doseId
        defer { inFlight = nil }
        do {
            let outcome = try await api.give(doseId: doseId, clientRef: ref(for: doseId),
                                             note: note)
            switch outcome {
            case .someoneElseGotThere(let given):
                alreadyGiven = given
                // The dose is no longer ours to give, so the ref is spent.
                forgetRef(for: doseId)
            case .recorded, .alreadyRecordedByYou:
                forgetRef(for: doseId)
            }
            // The feed is reloaded rather than patched locally in every case,
            // including the race: after a race the *other* person's name and
            // time are what belong on the row, and only the server knows them.
            if let rid = feed?.recipient.id { await load(recipientId: rid) }
            return outcome
        } catch {
            loadError = Self.message(for: error)
            return nil
        }
    }

    func skip(doseId: String, reason: String?) async {
        inFlight = doseId
        defer { inFlight = nil }
        do {
            _ = try await api.skip(doseId: doseId, reason: reason)
            if let rid = feed?.recipient.id { await load(recipientId: rid) }
        } catch {
            loadError = Self.message(for: error)
        }
    }

    func undo(doseId: String) async {
        inFlight = doseId
        defer { inFlight = nil }
        do {
            _ = try await api.undo(doseId: doseId)
            if let rid = feed?.recipient.id { await load(recipientId: rid) }
        } catch {
            loadError = Self.message(for: error)
        }
    }

    /// Turns an error into one sentence a family member can act on. Deliberately
    /// free of codes and jargon: nobody in this app's audience should ever be
    /// shown the word "409".
    ///
    /// `nonisolated` because it reads no state and is called from tests and from
    /// background contexts.
    nonisolated static func message(for error: Error) -> String {
        switch error {
        case APIError.transport:
            return "Can't reach CareHive. Check your connection and try again."
        case APIError.structured(let code, _):
            switch code {
            case "insufficient_role":
                return "Your role in this circle doesn't allow recording doses."
            case "void_window_closed":
                return "This was recorded too long ago to undo here. Ask the circle owner."
            case "limit_reached":
                return "This circle has reached its plan's limit."
            default:
                return "That didn't work. Please try again."
            }
        case APIError.message(let text):
            return text
        default:
            return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Screen

/// A named band of the day. A struct rather than a labelled tuple because
/// `ForEach` needs an identifier and Swift key paths cannot address tuple
/// elements -- `\.name` on a tuple is a compile error, not a style choice.
private struct DoseGroup: Identifiable {
    let name: String
    let doses: [Dose]
    var id: String { name }
}

struct TodayView: View {
    @State private var model: TodayModel
    @State private var sheetDose: Dose?
    @State private var showAlreadyGiven = false
    @Environment(\.openURL) private var openURL

    /// When set, the sheet for the nth dose of the day opens by itself once the
    /// feed arrives. Used only by the screenshot job's `record` screen, which
    /// needs the sheet on screen without driving a tap. `nil` in normal use.
    private let openDoseIndex: Int?

    /// The server is handed to the model rather than kept here too: two
    /// references to the same client is two places for them to drift apart.
    init(api: any CareHiveAPI, openDoseIndex: Int? = nil) {
        self.openDoseIndex = openDoseIndex
        _model = State(initialValue: TodayModel(api: api))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Palette.screen.ignoresSafeArea()
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .task { await loadIfNeeded() }
            .refreshable { await loadIfNeeded(force: true) }
            .sheet(item: $sheetDose) { dose in
                GiveDoseSheet(
                    dose: dose,
                    onGive: { note in
                        let outcome = await model.give(doseId: dose.id, note: note)
                        if case .someoneElseGotThere = outcome { showAlreadyGiven = true }
                        return outcome != nil
                    },
                    onSkip: { reason in
                        await model.skip(doseId: dose.id, reason: reason)
                    },
                    onClose: { model.forgetRef(for: dose.id) })
            }
            .sheet(isPresented: $showAlreadyGiven) {
                if let given = model.alreadyGiven {
                    AlreadyGivenView(given: given) { showAlreadyGiven = false }
                }
            }
        }
    }

    private var title: String {
        guard let feed = model.feed else { return "Today" }
        return "\(feed.recipient.callName)'s day"
    }

    private func loadIfNeeded(force: Bool = false) async {
        if !force, model.feed != nil { return }
        // Demo ships a fixed recipient so the screenshot job never has to have
        // created a circle first.
        let id = model.feed?.recipient.id ?? "rc_demo_margaret"
        await model.load(recipientId: id)
        openRequestedDose()
    }

    /// Opens the sheet the capture job asked for, once, after the first load.
    /// Guarded by `sheetDose == nil` so a pull-to-refresh cannot reopen a sheet
    /// the user deliberately closed.
    private func openRequestedDose() {
        guard sheetDose == nil, let index = openDoseIndex,
              let doses = model.feed?.doses, doses.indices.contains(index)
        else { return }
        sheetDose = doses[index]
    }

    @ViewBuilder
    private var content: some View {
        if model.feed == nil && model.loading {
            ProgressView("Loading today's doses")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let feed = model.feed {
            List {
                Section { SummaryHeader(feed: feed) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.m,
                                              bottom: DS.Space.s, trailing: DS.Space.m))

                if feed.beyondHorizon {
                    // An empty day that is empty because it is past what the app
                    // has planned is a different fact from a day with nothing
                    // scheduled, and saying "nothing here" for both would be a
                    // lie the family cannot see through.
                    Section {
                        ExplanationCard(
                            symbol: "calendar.badge.clock",
                            title: "Not scheduled this far ahead",
                            message: "CareHive plans doses up to \(WallClock.shortDate(feed.horizonEnd)). Nothing has been missed.")
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.m,
                                                      bottom: 0, trailing: DS.Space.m))
                    }
                } else {
                    ForEach(groups(feed.doses)) { group in
                        Section(group.name) {
                            ForEach(group.doses) { dose in
                                DoseRow(
                                    dose: dose,
                                    busy: model.inFlight == dose.id,
                                    canRecord: feed.canRecord,
                                    onTap: { sheetDose = dose },
                                    onUndo: { Task { await model.undo(doseId: dose.id) } },
                                    onGive: { sheetDose = dose })
                                .listRowBackground(DS.Palette.card)
                            }
                        }
                    }

                    if !feed.prnToday.isEmpty {
                        Section("As-needed today") {
                            ForEach(feed.prnToday) { entry in
                                PRNRow(entry: entry)
                                    .listRowBackground(DS.Palette.card)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else if let error = model.loadError {
            EmptyStateView(symbol: "wifi.exclamationmark", title: "Can't load today",
                           message: error) {
                Task { await loadIfNeeded(force: true) }
            }
        }
    }

    /// Morning / afternoon / evening, so the day reads as a shape rather than a
    /// wall of rows. The boundaries are the recipient's own clock, from the
    /// wall-clock hour, and are presentation only -- no dose is ever filtered by
    /// them, so getting a boundary wrong moves a row between headings and
    /// nothing else.
    private func groups(_ doses: [Dose]) -> [DoseGroup] {
        var morning: [Dose] = [], afternoon: [Dose] = [], evening: [Dose] = []
        for dose in doses.sorted(by: { WallClock.isEarlier($0.dueAt, $1.dueAt) }) {
            switch WallClock.hour(dose.dueAtLocal) ?? 0 {
            case ..<12: morning.append(dose)
            case 12..<17: afternoon.append(dose)
            default: evening.append(dose)
            }
        }
        return [DoseGroup(name: "Morning", doses: morning),
                DoseGroup(name: "Afternoon", doses: afternoon),
                DoseGroup(name: "Evening", doses: evening)]
            .filter { !$0.doses.isEmpty }
    }
}

// MARK: - Pieces

private struct SummaryHeader: View {
    let feed: DayFeed

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(feed.isToday ? "Today" : WallClock.longDate(feed.date))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            // One sentence, and it is the answer to the question the app exists
            // for. Counts, not a verdict -- "3 of 5 given" is a fact, "on track"
            // would be a judgement the app has no business making.
            Text(sentence)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.m) {
                MiniCount(value: feed.counts.given, label: "Given", tint: DS.Palette.given)
                MiniCount(value: feed.counts.pending, label: "Still due",
                          tint: DS.Palette.pending)
                if let overdue = feed.counts.overdue, overdue > 0 {
                    MiniCount(value: overdue, label: "Overdue", tint: DS.Palette.overdue)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, DS.Space.xs)
        }
        .padding(.horizontal, DS.Space.xs)
    }

    private var sentence: String {
        let total = feed.counts.total
        if total == 0 { return "Nothing scheduled today" }
        let given = feed.counts.given
        if given == total { return "All \(total) doses recorded today" }
        if given == 0 { return "\(total) doses to record today" }
        return "\(given) of \(total) doses recorded"
    }
}

private struct MiniCount: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DoseRow: View {
    let dose: Dose
    var busy: Bool = false
    var canRecord: Bool = true
    var onTap: () -> Void = {}
    var onUndo: () -> Void = {}
    var onGive: () -> Void = {}

    private var style: DS.StateStyle {
        DS.style(for: dose.status, overdue: dose.isOverdue == true)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WallClock.time(dose.dueAtLocal))
                    .font(.headline.monospacedDigit())
                if dose.dstShifted {
                    // The wall clock the family asked for does not exist on this
                    // date. Say so, rather than showing a time nobody chose.
                    Text("clock change")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.s) {
                    Text(dose.medicationName)
                        .font(.body.weight(.semibold))
                    if !DS.strength(dose.medicationStrength).isEmpty {
                        Text(DS.strength(dose.medicationStrength))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(DS.units(dose.unitsPerDose, dose.unitLabel))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                StatePill(style: style)

                // Who recorded it, in words. This line is the product: it is the
                // difference between "someone gave it" and "Sarah gave it".
                if dose.status == .given, let by = dose.givenByName {
                    Text("\(by) · \(WallClock.time(dose.givenAtLocal))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let note = dose.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .padding(.vertical, DS.Space.s)
        .contentShape(Rectangle())
        .onTapGesture { if canRecord { onTap() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var trailing: some View {
        if busy {
            ProgressView().frame(width: DS.tapTarget, height: DS.tapTarget)
        } else if dose.status == .given {
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body)
                    .frame(width: DS.tapTarget, height: DS.tapTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Undo recording \(dose.medicationName)")
        } else if canRecord {
            // "Record", not "Give". The app writes down what a person did; it
            // does not tell anyone to administer anything, and the button text
            // is where that distinction is either kept or lost.
            Button(action: onGive) {
                Text("Record")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: DS.tapTarget)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Record \(dose.medicationName) as given")
        } else {
            StateBadge(style: style)
        }
    }

    private var accessibilityText: String {
        var parts = [WallClock.time(dose.dueAtLocal), dose.medicationName]
        if !DS.strength(dose.medicationStrength).isEmpty {
            parts.append(DS.strength(dose.medicationStrength))
        }
        parts.append(DS.units(dose.unitsPerDose, dose.unitLabel))
        parts.append(style.label)
        if dose.status == .given, let by = dose.givenByName {
            parts.append("recorded by \(by)")
        }
        return parts.joined(separator: ", ")
    }
}

struct PRNRow: View {
    let entry: PRNEntry

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(DS.Palette.skipped)
                .frame(width: 72)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(entry.medicationName ?? "Medication")
                    .font(.body.weight(.semibold))
                Text("\(DS.units(entry.units, "dose")) · as needed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let reason = entry.reason, !reason.isEmpty {
                    Text("For \(reason)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if entry.overMax == true {
                    // Past the ceiling the family set. Stated as a fact about
                    // their own number. No warning, no advice, no colour that
                    // reads as an alarm -- the app does not know whether this
                    // was right, and must not pretend to.
                    Text("This is one more than the \(Int(entry.units))-a-day limit you set")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.xs)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
