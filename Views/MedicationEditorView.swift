// Adding or editing a medication.
//
// Three things shape this screen and are worth stating before the code:
//
//  * **The save sends the whole form, every time.** The server's PATCH is
//    three-state per field: absent leaves it alone, `null` clears it, a value
//    sets it. A `Codable` struct of optionals encodes all three as absent, so a
//    family who deletes "with breakfast" would watch it come back on the next
//    load. `MedicationDraft.wireBody` builds the body explicitly instead.
//
//  * **Nothing here suggests an amount.** The quantities on this screen are the
//    ones already written on the box, retyped by the family. There is no drug
//    database, no default dose, no interaction check and no "usual" anything --
//    the field is empty and stays empty until someone fills it in.
//
//  * **Removing a time is not undoable, so it says what it did.** Cancelling
//    future doses at that time is a real change to what the app will remind
//    anyone about, and the confirmation names the time rather than asking a
//    generic "are you sure".

import SwiftUI

struct MedicationEditorView: View {
    let api: any CareHiveAPI
    let recipientId: String
    /// `nil` when adding.
    let editing: Medication?
    let formOptions: [String]
    /// Called after a successful save, so the list reloads. The screen has
    /// already been told what changed through `onSaved` rather than through its
    /// own state, because the server is the authority on the new schedule.
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: MedicationDraft
    @State private var saving = false
    @State private var error: String?
    @State private var showDetails = false
    @State private var showNewStep = false
    @State private var step: MedicationDraft.Phase

    init(api: any CareHiveAPI, recipientId: String, editing: Medication?,
         formOptions: [String] = [],
         onSaved: @escaping () async -> Void = {}) {
        self.api = api
        self.recipientId = recipientId
        self.editing = editing
        self.formOptions = formOptions
        self.onSaved = onSaved
        let draft = editing.map { MedicationDraft($0) } ?? MedicationDraft()
        _draft = State(initialValue: draft)
        // A new step starts today and runs until the family says otherwise,
        // because a taper step does have a start date and guessing one for them
        // would date the family's record from the server's clock.
        _step = State(initialValue: MedicationDraft.Phase(
            startsOn: WallClock.isoDay(Date()), endsOn: nil, unitsPerDose: 1, label: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                if !draft.isPrn { timesSection }
                if !draft.isPrn && editing != nil { stepsSection }
                usageSection
                detailsSection

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(DS.Palette.missed)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add medication" : "Edit medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!draft.isSaveable)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("Name", text: $draft.name)
                .textInputAutocapitalization(.words)
            TextField("Strength, like 10 mg", text: $draft.strength)
            Picker("Form", selection: $draft.form) {
                Text("Not set").tag("")
                ForEach(formOptions, id: \.self) { Text($0.capitalized).tag($0) }
            }
        } header: {
            Text("Medication")
        } footer: {
            Text("This is what appears on the day screen and in the record.")
        }
    }

    /// Whether it runs on a schedule or is taken as needed. The answer changes
    /// the rest of the screen, which is why it is a segmented control near the
    /// top rather than a switch buried in the details.
    private var usageSection: some View {
        Section {
            Picker("Taken", selection: $draft.isPrn) {
                Text("On a schedule").tag(false)
                Text("As needed").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.m,
                                      bottom: DS.Space.s, trailing: DS.Space.m))

            TextField("Counted in, like tablet or mL", text: $draft.unitLabel)
                .textInputAutocapitalization(.never)

            if draft.isPrn {
                Stepper(value: Binding(
                    get: { draft.prnMaxPerDay ?? 0 },
                    set: { draft.prnMaxPerDay = $0 == 0 ? nil : $0 }),
                    in: 0...24) {
                    Text(draft.prnMaxPerDay.map { "Up to \($0) a day" }
                         ?? "No daily limit set")
                }
                // Quarter-hour steps. A gap that is not a multiple of 15 --
                // only reachable by a value set through the API -- is rounded
                // for display and only written back if the family actually
                // moves the stepper, so opening the screen never rewrites it.
                Stepper(value: Binding(
                    get: { ((draft.prnMinIntervalMin ?? 0) + 7) / 15 },
                    set: { draft.prnMinIntervalMin = $0 == 0 ? nil : $0 * 15 }),
                    in: 0...96) {
                    Text(Self.gapLabel(draft.prnMinIntervalMin))
                }
            }
        } header: {
            Text("How it is taken")
        } footer: {
            if draft.isPrn {
                // The medical boundary, in the place a family would most expect
                // the app to have an opinion. It does not, and says so.
                Text("These are your own numbers. CareHive records them and shows them back — it does not check them, and it does not tell you what to give.")
            } else {
                Text("A scheduled medication needs at least one time of day.")
            }
        }
    }

    private var timesSection: some View {
        Section {
            ForEach($draft.slots) { $slot in
                NavigationLink {
                    SlotEditorView(slot: $slot)
                } label: {
                    SlotRow(slot: slot)
                }
            }
            .onDelete { offsets in
                draft.slots.remove(atOffsets: offsets)
            }

            Button {
                draft.slots.append(MedicationDraft.Slot(localTime: nextTimeOfDay))
            } label: {
                Label("Add a time", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Times of day")
        } footer: {
            Text("Removing a time stops it being scheduled from today. Doses already recorded are not affected.")
        }
    }

    /// A step is appended, never edited in place, and the footer says why.
    /// Changing the amount of a step that is already running would rewrite doses
    /// that are on the family's screen right now under a label they have already
    /// read.
    private var stepsSection: some View {
        Section {
            ForEach(editing?.phases ?? []) { phase in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.label ?? "Step")
                            .font(.body)
                        Text(phase.range)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let units = phase.unitsPerDose {
                        Text(DS.units(units, draft.unitLabel))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Remove", role: .destructive) {
                        Task {
                            do {
                                try await api.deletePhase(phase.id)
                                await onSaved()
                            } catch {
                                self.error = TodayModel.message(for: error)
                            }
                        }
                    }
                }
            }

            if showNewStep {
                DatePicker("Starts", selection: dayBinding($step.startsOn),
                           displayedComponents: .date)
                    .environment(\.timeZone, WallClock.gmt)
                Toggle("Has an end date", isOn: Binding(
                    get: { step.endsOn != nil },
                    set: { step.endsOn = $0 ? WallClock.isoDay(Date()) : nil }))
                if step.endsOn != nil {
                    DatePicker("Ends", selection: optionalDayBinding($step.endsOn),
                               displayedComponents: .date)
                        .environment(\.timeZone, WallClock.gmt)
                }
                Stepper(value: $step.unitsPerDose, in: 0.5...1000, step: 0.5) {
                    Text(DS.units(step.unitsPerDose, draft.unitLabel))
                }
                TextField("Step name, like Step 1", text: $step.label)
                Button("Add this step") {
                    draft.newPhase = step
                    showNewStep = false
                }
            } else {
                Button {
                    // Prefilled from the last step where there is one, because a
                    // taper's next step usually follows on from the previous.
                    if let last = editing?.phases.compactMap(\.endsOn).max() {
                        step.startsOn = nextDay(after: last)
                    }
                    showNewStep = true
                } label: {
                    Label("Add a step", systemImage: "plus.circle.fill")
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            if draft.newPhase != nil {
                Text("One new step will be added when you save. Steps already running are left alone.")
            } else {
                Text("A step changes the amount over a date range — a tapering course, or a week at a higher amount. The times above stay the same.")
            }
        }
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup("More details", isExpanded: $showDetails) {
                TextField("Instructions", text: $draft.instructions, axis: .vertical)
                    .lineLimit(1...4)
                TextField("What it is for", text: $draft.purpose)
                TextField("Prescriber", text: $draft.prescriber)
                    .textInputAutocapitalization(.words)
                TextField("Pharmacy", text: $draft.pharmacy)
                    .textInputAutocapitalization(.words)
                TextField("Prescription number", text: $draft.rxNumber)
                    .textInputAutocapitalization(.never)
            }
        } footer: {
            Text("Optional. Filled in here so the bottle and the app can be checked against each other.")
        }
    }

    // MARK: - Actions

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let editing {
                _ = try await api.updateMedication(editing.id, draft)
            } else {
                _ = try await api.createMedication(recipientId, draft)
            }
            await onSaved()
            dismiss()
        } catch {
            // Kept on screen rather than dismissing. A form that closes on a
            // failure loses everything typed into it, and the family's typing is
            // the only copy.
            self.error = TodayModel.message(for: error)
        }
    }

    /// The next slot time, an hour after the latest one, so a twice-daily
    /// medication does not need the picker dragged from 8am both times.
    private var nextTimeOfDay: String {
        let latest = draft.slots.compactMap { WallClock.clockParts($0.localTime) }
            .max { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        guard let latest else { return "08:00" }
        let hour = (latest.hour + 12) % 24
        return String(format: "%02d:%02d", hour, latest.minute)
    }

    /// "At least 4h apart" / "No minimum gap set".
    ///
    /// The gap is the family's own rule about how often this may be repeated,
    /// echoed back in the words they would use. It is not a safety interval, the
    /// app has not checked it against anything, and nothing on this screen says
    /// otherwise.
    private static func gapLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "No minimum gap set" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "At least \(rest)m apart" }
        if rest == 0 { return "At least \(hours)h apart" }
        return "At least \(hours)h \(rest)m apart"
    }

    private func nextDay(after isoDay: String) -> String {
        guard let date = WallClock.date(fromDay: isoDay) else { return WallClock.isoDay(Date()) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = WallClock.gmt
        return WallClock.isoDay(cal.date(byAdding: .day, value: 1, to: date) ?? date)
    }

    /// A `DatePicker` bound to a calendar-date *label*, with the picker's own
    /// zone pinned to GMT.
    ///
    /// Both halves are required. Without the GMT conversion the stored string
    /// shifts by the device's offset; without the environment zone the picker
    /// draws that shifted instant as a third date, and the family watches the
    /// day they picked change as they scroll. The editor is used by a daughter
    /// who may be in a different zone from her mother, which is exactly when
    /// this would be wrong and invisible.
    private func dayBinding(_ isoDay: Binding<String>) -> Binding<Date> {
        Binding(
            get: { WallClock.date(fromDay: isoDay.wrappedValue) ?? Date() },
            set: { isoDay.wrappedValue = WallClock.isoDay($0) })
    }

    /// The same, for the optional end date. Two names rather than two overloads
    /// because Swift cannot pick between them at a call site that passes
    /// `$step.endsOn` -- both are viable and the compiler will not guess.
    private func optionalDayBinding(_ isoDay: Binding<String?>) -> Binding<Date> {
        Binding(
            get: { WallClock.date(fromDay: isoDay.wrappedValue) ?? Date() },
            set: { isoDay.wrappedValue = WallClock.isoDay($0) })
    }
}

// MARK: - Pieces

private struct SlotRow: View {
    let slot: MedicationDraft.Slot

    var body: some View {
        HStack {
            Text(WallClock.clock(slot.localTime))
                .font(.body.monospacedDigit())
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if !slot.label.isEmpty {
                    Text(slot.label)
                        .font(.subheadline)
                }
                if let days = slot.daysOfWeek {
                    Text(Self.days(days))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if slot.intervalDays != nil {
                    Text("Every \(slot.intervalDays!) days")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "Mon, Wed, Fri" / "Every day". Weekday symbols come from the reader's
    /// locale; the *days* are the ones the family chose.
    static func days(_ days: [Int]) -> String {
        let symbols = Calendar(identifier: .gregorian).shortWeekdaySymbols
        let names = days.compactMap { symbols.indices.contains($0) ? symbols[$0] : nil }
        return names.isEmpty ? "Every day" : names.joined(separator: ", ")
    }
}

/// One time of day, in full.
private struct SlotEditorView: View {
    @Binding var slot: MedicationDraft.Slot

    @State private var everyDay: Bool
    @State private var selected: Set<Int>

    init(slot: Binding<MedicationDraft.Slot>) {
        _slot = slot
        _everyDay = State(initialValue: slot.wrappedValue.daysOfWeek == nil)
        _selected = State(initialValue: Set(slot.wrappedValue.daysOfWeek ?? []))
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .environment(\.timeZone, WallClock.gmt)
            } header: {
                Text("Time of day")
            } footer: {
                // The sentence that stops this screen from being a medical
                // claim. It sets when the family is asked, nothing else.
                Text("This is when CareHive will ask about this dose. It is the family's schedule, not advice about when to give it.")
            }

            Section {
                TextField("Name this time, like Breakfast", text: $slot.label)
                Toggle("Every day", isOn: $everyDay)
                if !everyDay {
                    ForEach(1...7, id: \.self) { weekday in
                        Button {
                            if selected.contains(weekday) { selected.remove(weekday) }
                            else { selected.insert(weekday) }
                        } label: {
                            HStack {
                                Text(Self.name(weekday))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(weekday) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DS.Palette.accent)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Which days")
            }
        }
        .navigationTitle("Dose time")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: everyDay) { _, _ in sync() }
        .onChange(of: selected) { _, _ in sync() }
    }

    /// Writes the days back out in the one form the server means by "every day".
    ///
    /// Three states collapse to the same thing and it is deliberate: every day
    /// switched on, all seven picked, and nothing picked at all. The server
    /// stores NULL for each -- `models.parse_days_of_week` refuses to keep
    /// "0,1,2,3,4,5,6" and normalizes an empty list to None -- because a slot
    /// whose days are ambiguous would be a medication that silently stops
    /// reminding anyone. That last case is the one that matters: an empty list
    /// sent literally reads as "never", so it is sent as `nil`, which reads as
    /// "every day", which is what a family who picked no days means.
    private func sync() {
        if everyDay || selected.isEmpty || selected.count == 7 {
            slot.daysOfWeek = nil
            return
        }
        slot.daysOfWeek = selected.sorted()
    }

    /// A wheel picker over a bare HH:mm label, converted through GMT in both
    /// directions so the wheel shows the hour it was given.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let p = WallClock.clockParts(slot.localTime) ?? (8, 0)
                var c = DateComponents()
                c.year = 2000; c.month = 1; c.day = 1
                c.hour = p.hour; c.minute = p.minute
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = WallClock.gmt
                return cal.date(from: c) ?? Date()
            },
            set: { date in
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = WallClock.gmt
                let c = cal.dateComponents([.hour, .minute], from: date)
                slot.localTime = String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0)
            })
    }

    /// 1...7 is Monday-first, which is how the days are listed; the stored
    /// numbering is 0 = Sunday, as the server's is.
    private static func name(_ weekday: Int) -> String {
        let symbols = Calendar(identifier: .gregorian).weekdaySymbols
        let index = weekday % 7          // 7 -> 0 (Sunday)
        return symbols.indices.contains(index) ? symbols[index] : "\(weekday)"
    }
}
