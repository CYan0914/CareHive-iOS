// Recording that a dose was given.
//
// The wording throughout this sheet is chosen carefully and should not be
// "improved" into something friendlier. The primary button says "Record as
// given", not "Give" and not "Give now", because this app records what a person
// did -- it does not instruct anyone to administer anything. That distinction is
// the product's medical boundary: CareHive never says how much to give, never
// says whether it is too soon, never checks anything against anything. It is a
// shared record, and it stays on that side of the line.

import SwiftUI

struct GiveDoseSheet: View {
    let dose: Dose
    /// Returns true when something was recorded, so the sheet can dismiss.
    let onGive: (String?) async -> Bool
    let onSkip: (String?) async -> Void
    let onClose: () -> Void

    @State private var note = ""
    @State private var busy = false
    @State private var showingSkip = false
    @State private var skipReason = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    header
                    if showingSkip { skipBox } else { noteBox }
                }
                .padding(DS.Space.m)
            }
            .background(DS.Palette.screen)
            .navigationTitle("Record dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose(); dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .interactiveDismissDisabled(busy)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(WallClock.time(dose.dueAtLocal))
                .font(.largeTitle.weight(.bold).monospacedDigit())
            HStack(spacing: DS.Space.s) {
                Text(dose.medicationName).font(.title3.weight(.semibold))
                if !DS.strength(dose.medicationStrength).isEmpty {
                    Text(DS.strength(dose.medicationStrength))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Text(DS.units(dose.unitsPerDose, dose.unitLabel))
                .font(.body)
                .foregroundStyle(.secondary)
            if dose.dstShifted {
                Text("The clocks changed on this date, so this is not the time that was originally set.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.m)
        .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var noteBox: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Add a note").font(.subheadline.weight(.medium))
            TextField("Optional — e.g. took it with breakfast", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .padding(DS.Space.s)
                .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var skipBox: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Why was it not given?").font(.subheadline.weight(.medium))
            TextField("Optional — e.g. asleep, refused", text: $skipReason, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .padding(DS.Space.s)
                .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 10))
            Text("This is recorded so the rest of the circle can see it was a decision, not a missed dose.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: DS.Space.s) {
            if showingSkip {
                Button {
                    Task {
                        busy = true
                        await onSkip(skipReason.isEmpty ? nil : skipReason)
                        busy = false
                        dismiss()
                    }
                } label: {
                    Text("Record as not given")
                }
                .buttonStyle(PrimaryButtonStyle(tint: DS.Palette.skipped, enabled: !busy))
                .disabled(busy)

                Button("Back") { showingSkip = false; skipReason = "" }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy)
            } else {
                Button {
                    Task {
                        busy = true
                        let ok = await onGive(note.isEmpty ? nil : note)
                        busy = false
                        if ok { dismiss() }
                    }
                } label: {
                    HStack(spacing: DS.Space.s) {
                        if busy { ProgressView().tint(.white) }
                        Text(busy ? "Recording…" : "Record as given")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !busy))
                .disabled(busy)
                .accessibilityHint("Saves that this dose was given, and shows it to everyone in the circle")

                Button("It was not given") { showingSkip = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy)
            }
        }
        .padding(DS.Space.m)
        .background(.bar)
    }
}

// MARK: - The race

/// Shown when the server says somebody else recorded this dose first.
///
/// This is a normal Tuesday in a family with two caregivers, not an error, and
/// the screen is written to feel that way. It leads with who and when, because
/// that is the actual answer to the question the person was asking -- they
/// wanted to know whether Mum had her pill, and now they know. The dose is
/// emphatically not offered again.
struct AlreadyGivenView: View {
    let given: AlreadyGiven
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Space.l) {
                Spacer(minLength: DS.Space.l)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DS.Palette.given)

                // The sentence this entire product exists to be able to say.
                Text(given.attribution)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let dose = given.dose {
                    VStack(spacing: DS.Space.xs) {
                        Text(dose.medicationName)
                            .font(.headline)
                        if !DS.strength(dose.medicationStrength).isEmpty {
                            Text(DS.strength(dose.medicationStrength))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(WallClock.time(dose.dueAtLocal)) · \(DS.units(dose.unitsPerDose, dose.unitLabel))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(DS.Space.m)
                    .frame(maxWidth: .infinity)
                    .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, DS.Space.m)
                }

                Text("Nothing more to do — it's already in the record.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.xl)

                Spacer()

                Button("Done", action: onDismiss)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(DS.Space.m)
            }
            .background(DS.Palette.screen)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
