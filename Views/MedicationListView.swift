// What this person takes.
//
// The list answers one question before any row is read: what is she on, and at
// what times. So each row leads with the name and the times of day, and every
// other field -- prescriber, pharmacy, purpose -- is on the detail screen where
// somebody is looking for it deliberately.
//
// The first line of every row is the *schedule*, not the strength, and that is
// the opposite of what a medical app usually does. The family already knows
// Donepezil is 10mg; what they cannot remember is whether the second one is at
// noon or at six.

import SwiftUI

@MainActor
@Observable
final class MedicationListModel {
    var catalog: MedicationCatalog?
    var loading = false
    var loadError: String?
    /// Shown after a save or an archive, so a screen that changed under the
    /// family's hands says so rather than looking the same for no reason.
    var notice: String?

    private let api: any CareHiveAPI
    private let recipientId: String

    init(api: any CareHiveAPI, recipientId: String) {
        self.api = api
        self.recipientId = recipientId
    }

    func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            catalog = try await api.medications(recipientId)
        } catch {
            loadError = TodayModel.message(for: error)
        }
    }

    func archive(_ medication: Medication) async {
        do {
            try await api.archiveMedication(medication.id)
            // Not "deleted". The doses that were recorded are still there, and
            // a message that said "deleted" would make the family think the
            // history went with it.
            notice = "\(medication.name) stopped. Past doses are unchanged."
            await load()
        } catch {
            loadError = TodayModel.message(for: error)
        }
    }

}

// MARK: - Screen

struct MedicationListView: View {
    @State private var model: MedicationListModel
    @State private var editing: Medication?
    @State private var adding = false
    @State private var pendingArchive: Medication?

    private let api: any CareHiveAPI
    private let recipientId: String
    private let canEdit: Bool

    init(api: any CareHiveAPI, recipientId: String, canEdit: Bool) {
        self.api = api
        self.recipientId = recipientId
        self.canEdit = canEdit
        _model = State(initialValue: MedicationListModel(api: api, recipientId: recipientId))
    }

    var body: some View {
        List {
            if let notice = model.notice {
                Section {
                    // A quiet row rather than an alert. The list below it has
                    // already changed, and that is where the family will look.
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if let catalog = model.catalog {
                if catalog.medications.isEmpty {
                    Section {
                        EmptyStateView(
                            symbol: "pills",
                            title: "No medications yet",
                            message: canEdit
                                ? "Add one and its times, and the day screen will start showing it."
                                : "Someone who can edit this circle will add them.")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(catalog.medications) { med in
                            row(med)
                        }
                    } header: {
                        Text("\(catalog.medications.count) active")
                    } footer: {
                        if let tz = catalog.recipientTimezone {
                            // Naming the zone, once, at the bottom, because the
                            // times above are that zone's and a daughter in
                            // another one is the person most likely to need it.
                            Text("Times are shown in \(Self.zoneName(tz)).")
                        }
                    }
                }
            }

            if let error = model.loadError {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Medications")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add medication", systemImage: "plus")
                    }
                }
            }
        }
        .task { if model.catalog == nil { await model.load() } }
        .refreshable { await model.load() }
        .sheet(isPresented: $adding) {
            MedicationEditorView(api: api, recipientId: recipientId, editing: nil,
                                 formOptions: model.catalog?.formOptions ?? []) {
                await model.load()
            }
        }
        .sheet(item: $editing) { med in
            MedicationEditorView(api: api, recipientId: recipientId, editing: med,
                                 formOptions: model.catalog?.formOptions ?? []) {
                await model.load()
            }
        }
        .confirmationDialog(
            pendingArchive.map { "Stop \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingArchive != nil },
                                 set: { if !$0 { pendingArchive = nil } }),
            titleVisibility: .visible
        ) {
            if let med = pendingArchive {
                Button("Stop \(med.name)", role: .destructive) {
                    Task { await model.archive(med) }
                }
            }
            Button("Keep it", role: .cancel) { pendingArchive = nil }
        } message: {
            // The sentence that keeps someone from not stopping a medication
            // they should stop, and from thinking they are erasing the past.
            Text("CareHive will stop scheduling it from today. Every dose already recorded stays in the history.")
        }
    }

    @ViewBuilder
    private func row(_ med: Medication) -> some View {
        Group {
            if canEdit {
                // Tapping the row edits it; stopping it is behind a swipe, so
                // that the destructive act is never the one a hurried tap finds.
                Button { editing = med } label: { MedicationRow(med: med) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Stop", role: .destructive) { pendingArchive = med }
                    }
            } else {
                MedicationRow(med: med)
            }
        }
        .listRowBackground(DS.Palette.card)
    }

    /// "America/New_York" -> "New York". Falls back to the identifier itself,
    /// which is ugly but true, rather than to the device's zone, which would be
    /// a different fact stated with the same confidence.
    static func zoneName(_ identifier: String) -> String {
        guard let name = identifier.split(separator: "/").last else { return identifier }
        return name.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Row

struct MedicationRow: View {
    let med: Medication

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Text(med.name)
                    .font(.body.weight(.semibold))
                if !DS.strength(med.strength).isEmpty {
                    Text(DS.strength(med.strength))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if med.isPrn {
                    Text("AS NEEDED")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, 3)
                        .background(DS.Palette.skipped.opacity(0.18), in: Capsule())
                        .foregroundStyle(DS.Palette.skipped)
                }
            }

            // The times, spelled out. This is the line somebody reads to check
            // the pill bottle against the app.
            Text(scheduleLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let step = latestStep {
                // The step furthest along, with its dates and its amount. The
                // dates are printed rather than resolved into "current" because
                // deciding which step is running right now needs today's date in
                // the recipient's zone, which this screen does not have -- and a
                // guess would be a wrong amount stated confidently, which is the
                // worst thing this row could do. The family reads the dates off
                // it, which is what they would do with the box.
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.caption)
                    Text(step)
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var scheduleLine: String {
        if med.isPrn {
            guard let max = med.prnMaxPerDay else { return "Taken as needed" }
            // The family's own ceiling, stated as theirs.
            return "As needed · up to \(Int(max)) a day"
        }
        let times = med.slots.map { WallClock.clock($0.localTime) }
        guard !times.isEmpty else { return "No times set" }
        let daily = med.slots.allSatisfy { $0.daysOfWeek == nil && $0.intervalDays == nil }
        return daily ? "Every day at \(times.joined(separator: ", "))"
                     : times.joined(separator: ", ")
    }

    /// The last step, or a count when there is no amount to name.
    ///
    /// The server sends phases ordered by start date, so the last one is the
    /// one that runs to the end of the course. Its amount is the one in force at
    /// the far end of the taper, which is the number worth having on the list --
    /// the earlier steps are the family's own record and live on the detail
    /// screen.
    private var latestStep: String? {
        guard let last = med.phases.last else { return nil }
        let label = last.label ?? "Step \(med.phases.count)"
        guard let amount = last.unitsPerDose else { return "\(label) · \(last.range)" }
        return "\(label) · \(DS.units(amount, med.unitLabel)) · \(last.range)"
    }
}
