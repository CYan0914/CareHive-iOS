// Tablets on walls.
//
// The screen exists to answer two questions and to make one thing impossible to
// misunderstand:
//
//  * "Did my code work?" -- the tablet is listed the moment it is registered,
//    before anyone has typed anything into it. A row with no last-seen date is
//    the honest answer to that question, and hiding unclaimed rows until they
//    pair would leave a family staring at an empty list wondering whether the
//    button they pressed did anything at all.
//  * "Is it still mine to switch off?" -- revoking is one tap and takes effect
//    on the next request the tablet makes.
//
// And the thing that must not be misunderstood: a wall tablet **reads**. It
// never records. People assume the opposite -- a screen in the kitchen showing
// today's doses looks exactly like something you could tick -- so the screen
// says which way round it is, in the footer, where somebody deciding whether to
// put one in a hallway will read it.

import SwiftUI

@MainActor
@Observable
final class DisplaysModel {
    var list: DisplayList?
    var loading = false
    var busy = false
    var error: String?

    /// The newly created tablet, holding the one-time code. Present only until
    /// the sheet is closed, and never re-fetchable -- see `DisplaysView`.
    var pairing: DisplayPairing?
    /// A reissued code for a tablet that was registered and never claimed.
    var reissued: PairingCode?
    var renaming: DisplayDevice?
    var confirmRevoke: DisplayDevice?

    private let api: any CareHiveAPI
    let recipientId: String

    init(api: any CareHiveAPI, recipientId: String) {
        self.api = api
        self.recipientId = recipientId
    }

    var displays: [DisplayDevice] { list?.displays ?? [] }
    var atLimit: Bool { !(list?.hasRoom ?? true) }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            list = try await api.displays(recipientId)
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func add(_ label: String?) async {
        busy = true
        defer { busy = false }
        do {
            pairing = try await api.createDisplay(recipientId, label: label)
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func reissue(_ display: DisplayDevice) async {
        busy = true
        defer { busy = false }
        do {
            reissued = try await api.reissuePairingCode(display.id)
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func rename(_ display: DisplayDevice, to label: String) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await api.renameDisplay(display.id, label: label)
            renaming = nil
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func revoke(_ display: DisplayDevice) async {
        busy = true
        defer { busy = false }
        do {
            try await api.revokeDisplay(display.id)
            confirmRevoke = nil
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }
}

struct DisplaysView: View {
    @State private var model: DisplaysModel
    @State private var namingNew = false
    @State private var newLabel = ""

    init(api: any CareHiveAPI, recipientId: String) {
        _model = State(initialValue: DisplaysModel(api: api, recipientId: recipientId))
    }

    var body: some View {
        List {
            Section {
                ForEach(model.displays) { display in
                    DisplayRow(
                        display: display,
                        busy: model.busy,
                        onReissue: { Task { await model.reissue(display) } },
                        onRename: { model.renaming = display },
                        onRevoke: { model.confirmRevoke = display })
                        .listRowBackground(DS.Palette.card)
                }
            } header: {
                if let list = model.list, let max = list.max {
                    Text("\(list.count) of \(max) on this plan")
                } else {
                    Text("Tablets")
                }
            } footer: {
                // The disclaimer people actually need. "Read only" is the fact a
                // family has to know before they put a screen on a wall.
                Text("A tablet only shows today. Nobody can record a dose from "
                     + "it, and it cannot see the notes or the history.")
            }

            Section {
                Button {
                    newLabel = ""
                    namingNew = true
                } label: {
                    Label("Add a tablet", systemImage: "plus")
                }
                .disabled(model.atLimit)
            } footer: {
                if model.atLimit {
                    Text("This plan includes one tablet. Remove one, or move to "
                         + "CareHive Pro for more.")
                } else {
                    Text("You will get a code to type into the tablet. It lasts "
                         + "fifteen minutes.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tablets")
        .task { await model.load() }
        .refreshable { await model.load() }
        .overlay {
            if model.displays.isEmpty && !model.loading {
                EmptyStateView(
                    symbol: "ipad",
                    title: "No tablets yet",
                    message: "A tablet on a kitchen wall can show today's doses "
                        + "in large type, without anyone having to open the app.")
            }
        }
        .sheet(isPresented: $namingNew) {
            NameSheet(title: "Name this tablet",
                      placeholder: "Kitchen iPad",
                      initial: newLabel) { label in
                namingNew = false
                Task { await model.add(label.isEmpty ? nil : label) }
            }
        }
        .sheet(item: $model.pairing) { pairing in
            PairingCodeSheet(
                title: "Type this into the tablet",
                code: pairing.pairingCode,
                minutes: pairing.expiresInMinutes,
                footnote: "Open CareHive on the tablet, choose \"Set up this "
                    + "tablet\", and type this in. It works once.",
                onClose: { model.pairing = nil })
        }
        .sheet(item: $model.reissued) { code in
            PairingCodeSheet(
                title: "A new code",
                code: code.pairingCode,
                minutes: code.expiresInMinutes,
                footnote: "The old code has stopped working. This one works "
                    + "once, for the next fifteen minutes.",
                onClose: { model.reissued = nil })
        }
        .sheet(item: $model.renaming) { display in
            NameSheet(title: "Rename this tablet",
                      placeholder: "Kitchen iPad",
                      initial: display.label ?? "") { label in
                Task { await model.rename(display, to: label) }
            }
        }
        .confirmationDialog(
            model.confirmRevoke.map { "Switch off \($0.name)?" } ?? "",
            isPresented: Binding(get: { model.confirmRevoke != nil },
                                 set: { if !$0 { model.confirmRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch it off", role: .destructive) {
                if let display = model.confirmRevoke {
                    Task { await model.revoke(display) }
                }
            }
            Button("Leave it on", role: .cancel) { model.confirmRevoke = nil }
        } message: {
            Text("It stops showing anything within a few minutes. You can set "
                 + "it up again with a new code.")
        }
        .alert("That didn't work", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

// MARK: - Pieces

private struct DisplayRow: View {
    let display: DisplayDevice
    let busy: Bool
    let onReissue: () -> Void
    let onRename: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: display.isRevoked ? "ipad.slash" : "ipad")
                .font(.title3)
                .foregroundStyle(display.isRevoked ? .secondary : DS.Palette.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(display.name).font(.body.weight(.semibold))
                Text(display.state)
                    .font(.subheadline)
                    .foregroundStyle(display.paired ? .secondary : DS.Palette.overdue)
            }

            Spacer(minLength: 0)

            if busy {
                ProgressView()
            } else {
                Menu {
                    // Offered only for a tablet that has never been claimed.
                    // Once it is paired, the pairing code is gone from the
                    // server and there is nothing to reissue -- the only way
                    // back is to switch it off and add it again, so offering
                    // a button that would 409 is not an option here.
                    if !display.paired && !display.isRevoked {
                        Button("Get a new code", action: onReissue)
                    }
                    Button("Rename", action: onRename)
                    if !display.isRevoked {
                        Divider()
                        Button("Switch off", role: .destructive, action: onRevoke)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: DS.tapTarget, height: DS.tapTarget)
                }
                .accessibilityLabel("Options for \(display.name)")
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}

/// A name for a tablet. Asked for before the code is minted rather than after,
/// because "Kitchen iPad" appearing in the list is what tells a family their
/// code landed -- an unnamed row called "A paired tablet" tells them nothing.
private struct NameSheet: View {
    let title: String
    let placeholder: String
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.words)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
            .onAppear { if text.isEmpty { text = initial } }
        }
    }
}

/// The code, once.
///
/// Same rule as an invitation, and for the same reason: the server keeps a
/// digest. There is no way to see this again, so the sheet must not look like
/// there could be -- no "show me later", and a line that says the code dies
/// when the sheet closes rather than after somebody has closed it.
private struct PairingCodeSheet: View {
    let title: String
    let code: String
    let minutes: Int
    let footnote: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Space.l) {
                Text(code)
                    // Spaced for reading aloud across a room, which is how a
                    // code gets from a phone to a tablet in practice.
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .kerning(4)
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))

                Text("Good for \(minutes) minutes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ExplanationCard(symbol: "key", title: title, message: footnote)

                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(DS.Space.m)
            .navigationTitle("Pairing code")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

/// Needed for `.sheet(item:)` on the two one-shot responses, which carry a
/// display id but no identity of their own.
extension DisplayPairing: Identifiable {
    var id: String { display.id }
}

extension PairingCode: Identifiable {
    var id: String { displayId }
}
