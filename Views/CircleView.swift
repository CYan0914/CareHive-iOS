// Who else can see this, and how to add someone.
//
// Two facts drive the whole screen, and both of them are about trust rather
// than about lists:
//
//  * An invite code is shown once. The server keeps a digest, so "show me that
//    code again" is not possible -- which means the sheet that displays it must
//    not offer a way back to it, and must say plainly that closing it loses the
//    code. A screen that looks like it can be reopened is a screen that lies.
//  * Removing someone does not remove what they recorded. A person taking a
//    sibling off the circle is usually angry and always frightened, and their
//    assumption is that it erases the history. The server sends that sentence
//    back and this screen prints it verbatim.

import SwiftUI

@MainActor
@Observable
final class CircleModel {
    var members: [Member] = []
    var invites: [Invite] = []
    var loading = false
    var error: String?
    var busy: String?

    /// The code that was just minted. Held here rather than fetched because
    /// there is nowhere to fetch it from: it exists in exactly one response.
    var freshInvite: InviteCreated?
    /// The result of a removal, kept so the sentence about the history can be
    /// shown after the sheet that caused it has closed.
    var lastNote: String?

    private let api: any CareHiveAPI
    let recipientId: String

    init(api: any CareHiveAPI, recipientId: String) {
        self.api = api
        self.recipientId = recipientId
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let m = api.members(recipientId)
            async let i = api.invites(recipientId)
            members = try await m
            invites = try await i.invites
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func invite(role: Role) async {
        busy = "invite"
        defer { busy = nil }
        do {
            freshInvite = try await api.createInvite(recipientId, role: role, label: nil)
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func change(_ member: Member, to role: Role) async {
        busy = member.id
        defer { busy = nil }
        do {
            _ = try await api.updateMember(recipientId, userId: member.userId, role: role)
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func remove(_ member: Member) async {
        busy = member.id
        defer { busy = nil }
        do {
            let result = try await api.removeMember(recipientId, userId: member.userId)
            lastNote = result.note
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func revoke(_ invite: Invite) async {
        busy = invite.id
        defer { busy = nil }
        do {
            try await api.revokeInvite(invite.id)
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func transfer(to member: Member) async {
        busy = member.id
        defer { busy = nil }
        do {
            let result = try await api.transfer(recipientId, toUserId: member.userId)
            lastNote = result.note
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }
}

struct CircleView: View {
    @State private var model: CircleModel
    @State private var showInvite = false
    @State private var confirmRemove: Member?

    init(api: any CareHiveAPI, recipientId: String) {
        _model = State(initialValue: CircleModel(api: api, recipientId: recipientId))
    }

    var body: some View {
        List {
            if let note = model.lastNote {
                Section {
                    ExplanationCard(symbol: "info.circle", title: "One thing to know",
                                    message: note)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.m,
                                                  bottom: 0, trailing: DS.Space.m))
                }
            }

            Section("In this circle") {
                ForEach(model.members) { member in
                    MemberRow(member: member,
                              busy: model.busy == member.id,
                              onRole: { role in Task { await model.change(member, to: role) } },
                              onTransfer: { Task { await model.transfer(to: member) } },
                              onRemove: { confirmRemove = member })
                        .listRowBackground(DS.Palette.card)
                }
            }

            Section {
                Button {
                    showInvite = true
                } label: {
                    Label("Invite someone", systemImage: "person.badge.plus")
                }
            } footer: {
                Text("Everyone in the circle sees the same record. There is no "
                     + "private copy.")
            }

            if !model.invites.isEmpty {
                Section("Invitations") {
                    ForEach(model.invites) { invite in
                        InviteRow(invite: invite,
                                  busy: model.busy == invite.id,
                                  onRevoke: { Task { await model.revoke(invite) } })
                            .listRowBackground(DS.Palette.card)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Circle")
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $showInvite) {
            InviteRoleSheet { role in
                showInvite = false
                Task { await model.invite(role: role) }
            }
        }
        .sheet(item: $model.freshInvite) { created in
            InviteCodeSheet(created: created) { model.freshInvite = nil }
        }
        .confirmationDialog(
            confirmRemove.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { confirmRemove != nil },
                                 set: { if !$0 { confirmRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove from circle", role: .destructive) {
                if let member = confirmRemove {
                    Task { await model.remove(member) }
                }
                confirmRemove = nil
            }
            Button("Keep them", role: .cancel) { confirmRemove = nil }
        } message: {
            // Said before the tap, not only after it: the reassurance is worth
            // more to someone about to press the button than to someone who has.
            Text("They will lose access immediately. Everything they recorded "
                 + "stays in the history with their name on it.")
        }
        .alert("That didn't work", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

/// Needed because `.sheet(item:)` requires an identity, and `InviteCreated` is
/// a plain response shape with no id of its own.
extension InviteCreated: Identifiable {
    var id: String { invite.id }
}

private struct MemberRow: View {
    let member: Member
    let busy: Bool
    let onRole: (Role) -> Void
    let onTransfer: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ZStack {
                Circle().fill(DS.Palette.accent.opacity(0.15))
                Text(initials)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Palette.accent)
            }
            .frame(width: DS.tapTarget, height: DS.tapTarget)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(member.name).font(.body.weight(.semibold))
                    if member.isYou {
                        Text("you")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(.systemGray5), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(member.role.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if busy {
                ProgressView()
            } else if !member.isYou {
                Menu {
                    // The ladder, in words a family uses. "Can record doses" is
                    // the real distinction in this product: it is the one that
                    // decides whether you were the person who gave it.
                    ForEach([Role.viewer, .member, .editor], id: \.self) { role in
                        Button {
                            onRole(role)
                        } label: {
                            if member.role == role {
                                Label(role.label, systemImage: "checkmark")
                            } else {
                                Text(role.label)
                            }
                        }
                    }
                    Divider()
                    Button("Make owner", action: onTransfer)
                    Divider()
                    Button("Remove from circle", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: DS.tapTarget, height: DS.tapTarget)
                }
                .accessibilityLabel("Options for \(member.name)")
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private var initials: String {
        member.name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }.joined()
    }
}

private struct InviteRow: View {
    let invite: Invite
    let busy: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: invite.live ? "envelope.open" : "envelope")
                .font(.title3)
                .foregroundStyle(invite.live ? DS.Palette.accent : .secondary)
                .frame(width: DS.tapTarget)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.codeHint)
                    .font(.body.monospaced())
                Text(invite.state)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Gives \(invite.role.label.lowercased())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if invite.live {
                if busy {
                    ProgressView()
                } else {
                    Button("Cancel", action: onRevoke)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}

// MARK: - Sheets

private struct InviteRoleSheet: View {
    let onPick: (Role) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Three choices, not four. Owner is not something you hand out from here
    /// -- it is one person, and moving it is a different act with a different
    /// warning, so it lives behind "Make owner" on the member row.
    private let choices: [Role] = [.viewer, .member, .editor]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choices, id: \.self) { role in
                        Button {
                            onPick(role)
                        } label: {
                            HStack(alignment: .top, spacing: DS.Space.m) {
                                Image(systemName: symbol(role))
                                    .font(.title3)
                                    .foregroundStyle(DS.Palette.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(role.label).font(.body.weight(.semibold))
                                    Text(detail(role))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("You can change this later, or remove them entirely.")
                }
            }
            .navigationTitle("What can they do?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func symbol(_ role: Role) -> String {
        switch role {
        case .viewer: return "eye"
        case .member: return "checkmark.circle"
        case .editor: return "pencil"
        case .owner: return "crown"
        }
    }

    private func detail(_ role: Role) -> String {
        switch role {
        case .viewer: return "Sees everything. Records nothing."
        case .member: return "Records doses and writes in the log."
        case .editor: return "Also adds and edits medications."
        case .owner: return "Also invites people and controls billing."
        }
    }
}

/// The one place a code is ever visible.
private struct InviteCodeSheet: View {
    let created: InviteCreated
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Space.l) {
                VStack(spacing: DS.Space.s) {
                    Text(created.invite.code ?? "")
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("Invitation code "
                                            + (created.invite.code ?? "").map(String.init)
                                                .joined(separator: " "))
                    Text("Expires in 10 minutes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.Space.l)

                ShareLink(item: created.shareText) {
                    Label("Send the message", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(PrimaryButtonStyle())

                // The warning is the design. There is no "show me again" button
                // and there cannot be one, so the sheet says so before the
                // close button is pressed rather than after.
                ExplanationCard(
                    symbol: "exclamationmark.triangle",
                    title: "Shown once",
                    message: created.note,
                    tint: DS.Palette.overdue)

                Spacer()

                Button("Done", action: onClose)
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(DS.Space.m)
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}
