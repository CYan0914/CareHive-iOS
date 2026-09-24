// Your own account: who you are, when the phone stays quiet, and what this
// app is allowed to interrupt you for.
//
// Three decisions shape this screen, and each of them is a place the app could
// quietly lie:
//
//  * **The timezone is not a list of four hundred cities.** Nobody scrolls to
//    find "America/New_York" -- they set the phone up, the phone knows, and the
//    account still says whatever it said the day it was created. So the screen
//    offers the one timezone that is almost always the right answer, labelled
//    with what it currently reads, and shows the account's only when it differs.
//  * **Quiet hours are the reader's clock, not the recipient's.** Everything
//    else in this app renders the *recipient's* wall clock, because that is
//    where the medicine is. This is the one screen where the times are the
//    phone-holder's own, which is why it formats them itself rather than
//    through `WallClock`, and why the footer says so.
//  * **A reminder switch that cannot deliver is worse than no switch.** If the
//    server reports it cannot push, the section says that in a sentence. It
//    does not render a toggle that flips, persists, and does nothing --
//    that is the failure a reviewer finds, and the one a family would never
//    be able to diagnose.

import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    var me: Me?
    var devices: DeviceList?
    var notifications: NotificationList?
    var loading = false
    var busy = false
    var error: String?

    /// Held as text so that an empty field is a state the screen can show
    /// rather than a name that vanishes the moment somebody selects all.
    var draftName = ""
    /// Set once the account has actually been deleted, so the confirmation can
    /// give way to the server's own sentence about what remains.
    var deleted: DeletedAccount?
    var confirmingDelete = false

    private let api: any CareHiveAPI

    init(api: any CareHiveAPI) {
        self.api = api
    }

    var quietStart: Int { me?.user.quietStartMin ?? 22 * 60 }
    var quietEnd: Int { me?.user.quietEndMin ?? 7 * 60 }
    var timezone: String { me?.user.timezone ?? TimeZone.current.identifier }
    var isPro: Bool { me?.isPro ?? false }

    /// The phone's own timezone, offered only when it is not already the
    /// account's. Showing "Use this iPhone's timezone" on a phone that is
    /// already on it is a button that does nothing, which reads as broken.
    var offersDeviceTimezone: Bool {
        me != nil && timezone != TimeZone.current.identifier
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            // Sequential rather than concurrent: three reads on one screen is
            // not worth the complexity of a task group, and the account read
            // has to land first for the name field to be seeded from it.
            let account = try await api.me()
            me = account
            draftName = account.user.displayName ?? ""
            devices = try? await api.devices()
            notifications = try? await api.notifications()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    /// Saves only what changed. Sending the whole form would be the bug
    /// `MePatch` exists to prevent: the timezone field would carry a name the
    /// user never touched, and a stale one at that.
    func saveName() async {
        guard let me else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = me.user.displayName ?? ""
        guard trimmed != current else { return }
        await apply(MePatch(displayName: trimmed.isEmpty ? .null : .string(trimmed)))
    }

    func useDeviceTimezone() async {
        await apply(MePatch(timezone: TimeZone.current.identifier))
    }

    func setQuiet(start: Int, end: Int) async {
        guard start != quietStart || end != quietEnd else { return }
        await apply(MePatch(quietStartMin: start, quietEndMin: end))
    }

    private func apply(_ patch: MePatch) async {
        guard !patch.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let updated = try await api.updateMe(patch)
            // The response carries the user, so the screen updates from the
            // server's answer rather than from what was typed. A name the
            // server trimmed to nothing must not keep reading as typed.
            if let current = me {
                me = Me(user: updated.user, plan: current.plan,
                        limits: current.limits, recipients: current.recipients)
            }
            draftName = updated.user.displayName ?? ""
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func markRead(_ notification: Notification) async {
        // Optimistic: a read receipt is not worth a spinner, and if the call
        // fails the next load restores the truth.
        guard let list = notifications, !notification.isRead else { return }
        notifications = NotificationList(
            notifications: list.notifications.map {
                $0.id == notification.id ? notification.markedRead() : $0
            },
            count: list.count, unread: max(0, list.unread - 1))
        try? await api.markRead(notification.id)
    }

    func markAllRead() async {
        guard let list = notifications, list.unread > 0 else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await api.markAllRead()
            notifications = try? await api.notifications()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func deleteAccount() async {
        busy = true
        defer { busy = false }
        do {
            deleted = try await api.deleteAccount()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }
}

// MARK: - Screen

struct SettingsView: View {
    @State private var model: SettingsModel
    @State private var showPaywall = false
    /// Held as well as handed to the model, because the paywall is a second
    /// client on the same server and needs its own.
    private let api: any CareHiveAPI

    init(api: any CareHiveAPI) {
        _model = State(initialValue: SettingsModel(api: api))
        self.api = api
    }

    var body: some View {
        List {
            nameSection
            timezoneSection
            quietSection
            reminderSection
            notificationsSection
            planSection
            deleteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("You")
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $showPaywall) {
            PaywallView(api: api)
        }
        .alert("That didn't work", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        // `header:` beside `footer:` rather than the one-line `Section("Your
        // name")` form: `Section` has no `init(_:content:footer:)`, so a title
        // and a footer cannot be passed together. The header text is the same
        // either way -- what changes is which initialiser gets called.
        Section {
            HStack {
                TextField("Your name", text: $model.draftName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await model.saveName() } }
                if model.busy {
                    ProgressView()
                } else if isNameChanged {
                    Button("Save") { Task { await model.saveName() } }
                        .font(.body.weight(.semibold))
                }
            }
        } header: {
            Text("Your name")
        } footer: {
            Text("This is the name your family sees beside a dose you recorded. "
                 + "Nobody else can change it.")
        }
    }

    private var isNameChanged: Bool {
        guard let me = model.me else { return false }
        return model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            != (me.user.displayName ?? "")
    }

    private var timezoneSection: some View {
        Section {
            LabeledContent("Your account", value: model.timezone)
            if model.offersDeviceTimezone {
                Button {
                    Task { await model.useDeviceTimezone() }
                } label: {
                    Label("Use this iPhone's timezone", systemImage: "location")
                }
            }
        } header: {
            Text("Timezone")
        } footer: {
            // The distinction that keeps this screen from being read as a
            // setting for somebody else's day.
            Text("This is the clock your reminders are timed against. The doses "
                 + "you see are always shown in the timezone of the person the "
                 + "medicine is for.")
        }
    }

    private var quietSection: some View {
        Section {
            QuietHoursRow(
                title: "From",
                minutes: Binding(get: { model.quietStart },
                                 set: { start in
                                     Task { await model.setQuiet(start: start,
                                                                 end: model.quietEnd) }
                                 }))
            QuietHoursRow(
                title: "Until",
                minutes: Binding(get: { model.quietEnd },
                                 set: { end in
                                     Task { await model.setQuiet(start: model.quietStart,
                                                                 end: end) }
                                 }))
        } header: {
            Text("Quiet hours")
        } footer: {
            Text("Reminders are not sent during these hours, in your own "
                 + "timezone. Everything is still recorded; you will see it in "
                 + "the morning.")
        }
    }

    private var reminderSection: some View {
        Section {
            if let devices = model.devices {
                if devices.pushAvailable {
                    LabeledContent("This iPhone", value: thisDeviceLine(devices))
                } else {
                    // The honest case, and the one that must never be a switch.
                    Label("Reminders cannot be sent yet",
                          systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Devices", value: "\(devices.count)")
            } else if model.loading {
                ProgressView()
            } else {
                Text("Not available").foregroundStyle(.secondary)
            }
        } header: {
            Text("Reminders")
        } footer: {
            if let devices = model.devices, !devices.pushAvailable {
                Text("This CareHive server has no connection to Apple's "
                     + "notification service, so nothing will be delivered to "
                     + "this phone. The app does not pretend otherwise: what is "
                     + "recorded is still recorded, and still visible to "
                     + "everyone in the circle.")
            } else {
                Text("Reminders tell you when a dose has not been recorded. They "
                     + "never tell you to give one.")
            }
        }
    }

    /// "Registered" or "Version 1.0", whichever is true. A device that is here
    /// but whose version is not is not a device to claim anything about.
    private func thisDeviceLine(_ devices: DeviceList) -> String {
        guard let active = devices.devices.first(where: { $0.active }) else {
            return "Registered"
        }
        guard let version = active.appVersion, !version.isEmpty else {
            return "Registered"
        }
        return "Version \(version)"
    }

    private var notificationsSection: some View {
        Section {
            if let list = model.notifications, !list.notifications.isEmpty {
                ForEach(list.notifications) { note in
                    NotificationRow(note: note) {
                        Task { await model.markRead(note) }
                    }
                    .listRowBackground(DS.Palette.card)
                }
            } else if model.loading {
                ProgressView()
            } else {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("What you've been told")
                Spacer()
                if let list = model.notifications, list.unread > 0 {
                    Button("Mark all read") {
                        Task { await model.markAllRead() }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        } footer: {
            Text("A record of every reminder this account was sent, including "
                 + "ones your phone did not show. Tap one to mark it read.")
        }
    }

    private var planSection: some View {
        Section {
            Button {
                showPaywall = true
            } label: {
                HStack {
                    Label(model.isPro ? "CareHive Pro" : "CareHive Free",
                          systemImage: model.isPro ? "checkmark.seal" : "leaf")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            if let limits = model.me?.limits, let days = limits.historyDays {
                Text("Free keeps \(days) days of history. Everyone in the circle "
                     + "can always see and record doses, on any plan.")
            } else {
                Text("What is included, and what changes on Pro.")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            if let deleted = model.deleted {
                // The server's sentence, printed verbatim. It is the only
                // accurate description of what deletion does and does not
                // remove, and paraphrasing it here would be the app guessing.
                ExplanationCard(symbol: "checkmark.circle",
                                title: "Your account is deleted",
                                message: deleted.note ?? "")
            } else {
                Button("Delete my account", role: .destructive) {
                    model.confirmingDelete = true
                }
                .disabled(model.busy)
            }
        } footer: {
            if model.deleted == nil {
                Text("This removes your login and your access. It does not "
                     + "remove the doses you recorded -- those stay in your "
                     + "family's history with your name on them, because "
                     + "erasing them would change somebody else's record of "
                     + "what happened.")
            }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $model.confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete my account", role: .destructive) {
                Task { await model.deleteAccount() }
            }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("You will be signed out on every device, and you will not be "
                 + "able to sign back in to this circle. Doses you recorded "
                 + "stay in the history with your name on them.")
        }
    }
}

// MARK: - Pieces

/// A time, edited as a time.
///
/// The picker works in `Date` and the server stores minutes past midnight, so
/// the conversion happens here on a fixed reference day. That day is never
/// shown and never sent -- only the hour and minute are read back out -- which
/// is what stops a timezone or a DST change from moving somebody's quiet hours
/// by an hour.
private struct QuietHoursRow: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        DatePicker(title,
                   selection: Binding(
                       get: { Self.reference(hour: minutes / 60, minute: minutes % 60) },
                       set: { new in
                           let c = Calendar.current.dateComponents([.hour, .minute], from: new)
                           minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                       }),
                   displayedComponents: .hourAndMinute)
    }

    private static func reference(hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2001; c.month = 1; c.day = 1
        c.hour = hour; c.minute = minute
        // 2001-01-01 is the reference date every Apple platform agrees on, and
        // a day with no DST transition anywhere that matters.
        return Calendar.current.date(from: c) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}

private struct NotificationRow: View {
    let note: Notification
    let onRead: () -> Void

    var body: some View {
        Button(action: onRead) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(note.isRead ? .secondary : DS.Palette.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title ?? "CareHive")
                        .font(.subheadline.weight(note.isRead ? .regular : .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let body = note.body, !body.isEmpty {
                        Text(body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if !note.isRead {
                    Circle().fill(DS.Palette.accent).frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Whether the push was actually delivered, said out loud. "Sent" and
    /// "not sent" are different facts, and a family deciding whether to trust
    /// reminders needs the second one as much as the first.
    private var subtitle: String {
        var parts: [String] = []
        if let at = note.createdAt { parts.append(WallClock.time(at)) }
        if note.pushStatus == "sent" { parts.append("Sent to your phone") }
        else if note.pushStatus == "failed" { parts.append("Phone could not be reached") }
        else if note.pushStatus == nil { parts.append("Not sent to a phone") }
        if note.isRead { parts.append("Read") }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch note.kind {
        case "dose_missed": return "clock.badge.exclamationmark"
        case "dose_given": return "checkmark.circle"
        case "circle", "member_joined", "invite": return "person.2"
        case "supply": return "pills"
        default: return "bell"
        }
    }
}

private extension Notification {
    /// The same row with `readAt` set. A named helper rather than an inline
    /// copy so the field list cannot drift out of step with the struct.
    ///
    /// The value only ever has to be non-nil -- the screen shows that it was
    /// read, not when -- so it is stamped in the same shape the server uses
    /// rather than run through a date formatter that would imply this is a
    /// time anybody reads.
    func markedRead() -> Notification {
        func stamp() -> String {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                       from: Date())
            return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                          c.year ?? 2026, c.month ?? 1, c.day ?? 1,
                          c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        }
        return Notification(id: id, kind: kind, recipientId: recipientId,
                            title: title, body: body, silent: silent,
                            createdAt: createdAt, readAt: stamp(),
                            pushStatus: pushStatus)
    }
}
