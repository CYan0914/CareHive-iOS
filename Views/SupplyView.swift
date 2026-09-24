// What is left in the bottle, as counted by a person.
//
// This screen sits closest to the medical line of anything in the app, so the
// line is drawn here in the copy rather than left to whoever writes the next
// label:
//
//  * The number on screen is what somebody counted, minus what the record says
//    has been given since. Both halves are shown, so the subtraction can be
//    checked. The app never states a level it did not receive.
//  * "Below the level you set" is the family's own number compared against the
//    family's own threshold. It is not a clinical judgement and it must never
//    read like one -- no "low", no "running out", no colour-only alarm.
//  * The run-out date is arithmetic the server did over the dose record, and it
//    is labelled as arithmetic. It is not a prediction about a person, and the
//    word "should" does not appear next to it.

import SwiftUI

@MainActor
@Observable
final class SupplyModel {
    var list: SupplyList?
    var history: [String: SupplyHistory] = [:]
    var loading = false
    var busy = false
    var error: String?
    /// Whose detail sheet is open, by medication id rather than by value: after
    /// a recount the numbers change, and a sheet holding a stale copy would show
    /// the old ones next to a fresh confirmation.
    var focus: SupplyFocus?

    private let api: any CareHiveAPI
    let recipientId: String

    init(api: any CareHiveAPI, recipientId: String) {
        self.api = api
        self.recipientId = recipientId
    }

    var items: [Supply] { list?.items ?? [] }

    /// Tracked first and below-threshold at the very top: the whole point of
    /// setting a threshold is that the thing you asked about is the thing you
    /// see first.
    var belowThreshold: [Supply] { items.filter { $0.tracked && $0.belowRefillAt } }
    var rest: [Supply] {
        items.filter { $0.tracked && !$0.belowRefillAt }
            .sorted { $0.name < $1.name }
    }
    var untracked: [Supply] { items.filter { !$0.tracked } }

    func item(_ medicationId: String) -> Supply? {
        items.first { $0.medicationId == medicationId }
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            list = try await api.supply(recipientId)
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func open(_ supply: Supply) async {
        focus = SupplyFocus(id: supply.medicationId)
        await loadHistory(supply.medicationId)
    }

    func loadHistory(_ medicationId: String) async {
        do {
            history[medicationId] = try await api.supplyHistory(medicationId)
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    /// A recount. `units` is what the person counted with their own eyes; the
    /// only number this screen ever sends upward.
    func count(_ medicationId: String, units: Double, threshold: Double?) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await api.setSupply(medicationId, unitsOnHand: units,
                                        refillAt: threshold)
            await load()
            await loadHistory(medicationId)
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func addRefill(_ medicationId: String, units: Double, note: String?) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await api.refill(medicationId, units: units, note: note)
            await load()
            await loadHistory(medicationId)
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func stopCounting(_ medicationId: String) async {
        busy = true
        defer { busy = false }
        do {
            try await api.untrackSupply(medicationId)
            focus = nil
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

}

struct SupplyFocus: Identifiable, Hashable {
    let id: String
}

/// `Supply` carries `medicationId` and no `id` of its own, because on the wire
/// it is a value inside a list rather than a resource. `Identifiable` is what
/// `ForEach` wants, and the medication it describes is exactly the identity a
/// list needs.
extension Supply: Identifiable {
    var id: String { medicationId }
}

struct SupplyView: View {
    @State private var model: SupplyModel

    init(api: any CareHiveAPI, recipientId: String) {
        _model = State(initialValue: SupplyModel(api: api, recipientId: recipientId))
    }

    var body: some View {
        List {
            if let list = model.list, !list.forecastAvailable {
                Section {
                    // Said once at the top rather than repeated per row. The
                    // free plan still does the threshold the family asked for,
                    // and saying so is what keeps this from reading as a wall.
                    ExplanationCard(
                        symbol: "calendar",
                        title: "Counts, and the level you set",
                        message: "You can record a count and set the level you "
                            + "want to be told about. Run-out dates use a rate "
                            + "worked out from the dose record, and are part of "
                            + "CareHive Pro.",
                        tint: DS.Palette.accent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.m,
                                                  bottom: 0, trailing: DS.Space.m))
                }
            }

            if !model.belowThreshold.isEmpty {
                Section {
                    ForEach(model.belowThreshold) { supply in
                        SupplyRow(supply: supply) { Task { await model.open(supply) } }
                            .listRowBackground(DS.Palette.card)
                    }
                } header: {
                    // The family's threshold, in the family's terms. Not "low",
                    // not "running out" -- both of those are the app having an
                    // opinion about a bottle it has never seen.
                    Text("At or below the level you set")
                } footer: {
                    Text("These are your own numbers: what someone counted, and "
                         + "the level you asked to be told about.")
                }
            }

            if !model.rest.isEmpty {
                Section(model.belowThreshold.isEmpty ? "Being counted" : "Above your level") {
                    ForEach(model.rest) { supply in
                        SupplyRow(supply: supply) { Task { await model.open(supply) } }
                            .listRowBackground(DS.Palette.card)
                    }
                }
            }

            if !model.untracked.isEmpty {
                Section {
                    ForEach(model.untracked) { supply in
                        SupplyRow(supply: supply) { Task { await model.open(supply) } }
                            .listRowBackground(DS.Palette.card)
                    }
                } header: {
                    Text("Not being counted")
                } footer: {
                    Text("Nothing is counted for these, so nothing is shown. "
                         + "That is the normal state for something taken only "
                         + "when it is needed.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Supply")
        .task { await model.load() }
        .refreshable { await model.load() }
        .overlay {
            if model.items.isEmpty && !model.loading {
                EmptyStateView(
                    symbol: "pills",
                    title: "Nothing to count yet",
                    message: "Add a medication and you can start counting what "
                        + "is left in the bottle.")
            }
        }
        .sheet(item: $model.focus) { focus in
            SupplyDetailSheet(model: model, medicationId: focus.id)
        }
        .alert("That didn't work", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

// MARK: - One row

private struct SupplyRow: View {
    let supply: Supply
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: supply.tracked ? "pills.fill" : "pills")
                    .font(.title3)
                    .foregroundStyle(supply.belowRefillAt ? DS.Palette.overdue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(supply.name).font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(amountLine)
                        .font(.subheadline)
                        .foregroundStyle(supply.belowRefillAt ? DS.Palette.overdue : .secondary)
                    if let detail = detailLine {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, DS.Space.xs)
        }
        .buttonStyle(.plain)
    }

    /// The state in words, always -- including the reassuring case, because a
    /// row that says nothing when things are fine teaches people to read the
    /// absence of a sentence as bad news. Whether it is below the family's level
    /// is carried by the section it sits under and by `detailLine`, both in
    /// words, so the colour is never the only thing saying it.
    private var amountLine: String {
        guard supply.tracked, let left = supply.unitsOnHand else { return "Not counted" }
        return "\(DS.units(left, supply.unitLabel)) left"
    }

    /// The subtraction, spelled out so it can be checked rather than trusted.
    private var detailLine: String? {
        guard supply.tracked, let counted = supply.countedValue else { return nil }
        let used = supply.consumedSinceCount ?? 0
        let when = WallClock.shortDate(supply.countedAtLocal.map { String($0.prefix(10)) })
        if used <= 0 {
            return "Counted \(DS.units(counted, supply.unitLabel)) \(when). "
                + "Nothing recorded since."
        }
        return "Counted \(DS.units(counted, supply.unitLabel)) \(when); "
            + "\(DS.units(used, supply.unitLabel)) recorded since."
    }
}

// MARK: - One medication, in full

private struct SupplyDetailSheet: View {
    let model: SupplyModel
    let medicationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var countText = ""
    @State private var thresholdText = ""
    @State private var refillText = ""
    @State private var refillNote = ""
    @State private var confirmStop = false

    private var supply: Supply? { model.item(medicationId) }
    private var history: SupplyHistory? { model.history[medicationId] }
    private var unitName: String { supply?.unitLabel ?? "unit" }

    var body: some View {
        NavigationStack {
            Form {
                if let supply {
                    whatIsLeft(supply)
                    recordCount(supply)
                    addRefill(supply)
                    events
                    stopCounting(supply)
                } else {
                    Text("That medication is no longer in the circle.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(supply?.name ?? "Supply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let supply, countText.isEmpty {
                    countText = Self.number(supply.countedValue ?? supply.unitsOnHand ?? 0)
                    thresholdText = supply.refillAt.map(Self.number) ?? ""
                }
            }
        }
        .confirmationDialog("Stop counting this one?", isPresented: $confirmStop,
                            titleVisibility: .visible) {
            Button("Stop counting", role: .destructive) {
                Task { await model.stopCounting(medicationId) }
            }
            Button("Keep counting", role: .cancel) {}
        } message: {
            Text("The counts you have made stay in the history. Only the "
                 + "counting stops.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func whatIsLeft(_ supply: Supply) -> some View {
        Section {
            if let left = supply.unitsOnHand {
                LabeledContent("Left now") {
                    Text(DS.units(left, supply.unitLabel)).monospacedDigit()
                }
            }
            if let counted = supply.countedValue, let used = supply.consumedSinceCount {
                LabeledContent("Counted") {
                    Text(DS.units(counted, supply.unitLabel)).monospacedDigit()
                }
                LabeledContent("Recorded since") {
                    Text(DS.units(used, supply.unitLabel)).monospacedDigit()
                }
            }
            LabeledContent("You asked to be told at") {
                if let refillAt = supply.refillAt {
                    Text(DS.units(refillAt, supply.unitLabel)).monospacedDigit()
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            if let at = supply.countedAtLocal {
                LabeledContent("Last counted") {
                    Text(WallClock.shortDate(String(at.prefix(10))))
                }
            }
        } header: {
            Text("What is left")
        } footer: {
            Text("Left now is what was counted, less what the record says has "
                 + "been given since. Both numbers are above so you can check "
                 + "the subtraction.")
        }

        if supply.forecast.available, let sentence = supply.forecast.sentence {
            Section {
                Text(sentence)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("At this rate")
            } footer: {
                Text("Worked out from the doses recorded over the last "
                     + "\(supply.forecast.basisDays ?? 30) days. It is an "
                     + "estimate from your own record, not a prediction.")
            }
        } else if let why = supply.forecast.explanation {
            Section("At this rate") {
                Text(why)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func recordCount(_ supply: Supply) -> some View {
        Section {
            LabeledContent("\(unitName.capitalized) in the bottle") {
                TextField("0", text: $countText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
            LabeledContent("Tell me at") {
                TextField("Not set", text: $thresholdText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
            Button {
                guard let units = Double(countText.trimmingCharacters(in: .whitespaces)) else {
                    return
                }
                let threshold = Double(thresholdText.trimmingCharacters(in: .whitespaces))
                Task { await model.count(medicationId, units: units, threshold: threshold) }
            } label: {
                if model.busy { ProgressView() } else { Text("Save the count") }
            }
            .disabled(Double(countText.trimmingCharacters(in: .whitespaces)) == nil || model.busy)
        } header: {
            Text("Count it")
        } footer: {
            Text("Type what you counted. Set a level if you want to see this "
                 + "one at the top of the list when it gets there.")
        }
    }

    @ViewBuilder
    private func addRefill(_ supply: Supply) -> some View {
        Section {
            LabeledContent("Added") {
                TextField("0", text: $refillText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
            TextField("Note (optional)", text: $refillNote)
            Button {
                guard let units = Double(refillText.trimmingCharacters(in: .whitespaces)) else {
                    return
                }
                let note = refillNote.trimmingCharacters(in: .whitespaces)
                Task {
                    await model.addRefill(medicationId, units: units,
                                          note: note.isEmpty ? nil : note)
                    refillText = ""
                    refillNote = ""
                }
            } label: {
                Text("Add a refill")
            }
            .disabled(Double(refillText.trimmingCharacters(in: .whitespaces)) == nil || model.busy)
        } header: {
            Text("Picked up more")
        } footer: {
            Text("A refill is recorded on its own so the history shows the "
                 + "difference between what you collected and what you counted.")
        }
    }

    @ViewBuilder
    private var events: some View {
        Section("History") {
            if let events = history?.events, !events.isEmpty {
                ForEach(events) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: event.isRefill ? "plus.circle" : "number.circle")
                            .foregroundStyle(event.isRefill ? DS.Palette.given : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.isRefill
                                 ? "Refill of \(DS.units(event.delta, history?.unitLabel))"
                                 : "Counted \(DS.units(event.unitsAfter, history?.unitLabel))")
                                .font(.subheadline)
                            Text(subtitle(event))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("No counts recorded yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stopCounting(_ supply: Supply) -> some View {
        if supply.tracked {
            Section {
                Button("Stop counting this one", role: .destructive) {
                    confirmStop = true
                }
            } footer: {
                Text("Useful when something is finished or no longer being "
                     + "counted. It can be started again by counting it.")
            }
        }
    }

    private func subtitle(_ event: SupplyEvent) -> String {
        var parts: [String] = []
        if let name = event.byName { parts.append(name) }
        if let at = event.at { parts.append(WallClock.shortDate(String(at.prefix(10)))) }
        if let note = event.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    /// `6` not `6.0`, `6.5` not `6.50`. A count is a number somebody typed, and
    /// echoing it back with a decimal tail they did not type reads as the app
    /// having changed it.
    static func number(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(value)
    }
}
