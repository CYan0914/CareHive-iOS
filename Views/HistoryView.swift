// What happened, newest first -- and the one place in the app where a person
// writes something in their own words.
//
// The list is deliberately one list. A dose that was given, a dose that was
// skipped, a note somebody typed at midnight and a change to who is in the
// circle all belong in the same column of time, because the question a family
// actually asks is "what happened last week", not "show me the notes". The
// server already returns them interleaved and in order; this screen's job is to
// make each kind legible at a glance without splitting them apart.
//
// The one thing it must never do is round off. A plan-limited history says so,
// with the date it starts from, rather than quietly beginning at a date that
// looks like the beginning.

import SwiftUI

@MainActor
@Observable
final class HistoryModel {
    var page: LogPage?
    var entries: [LogEntry] = []
    var loading = false
    var loadingMore = false
    var error: String?

    /// Which kinds the family is looking at. Empty means all of them, which is
    /// the default and the useful answer most of the time.
    var kinds: Set<String> = []

    /// The note being written or edited, so the composer can be the same screen
    /// in both cases.
    var composing: ComposeTarget?
    /// True when the composer is fetching the full text of a note the list only
    /// had a truncated copy of.
    var opening = false

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
            let page = try await api.log(recipientId, from: nil, to: nil,
                                         kinds: kinds.isEmpty ? nil : Array(kinds),
                                         cursor: nil, limit: 50)
            self.page = page
            entries = page.entries
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func loadMore() async {
        guard let cursor = page?.nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = try await api.log(recipientId, from: nil, to: nil,
                                         kinds: kinds.isEmpty ? nil : Array(kinds),
                                         cursor: cursor, limit: 50)
            entries.append(contentsOf: next.entries)
            page = next
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func toggle(_ kind: String) async {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
        await load()
    }

    func save(_ target: ComposeTarget, body: String, mood: String?) async {
        do {
            switch target {
            case .new:
                _ = try await api.createEntry(recipientId, body: body,
                                              kind: "note", mood: mood)
            case .edit(let entry):
                _ = try await api.updateEntry(entry.id, body: body, mood: mood)
            }
            composing = nil
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    /// Opens a note from the list.
    ///
    /// The list only ever carries a truncated `body` -- that is what keeps a
    /// fifty-entry page small -- so opening one is a real fetch rather than a
    /// push. Editing the truncated copy and saving would silently shorten
    /// somebody's note, which is the one way this screen could destroy writing.
    func open(_ entry: LogEntry) async {
        guard entry.kind == "note", let id = entry.entryId else { return }
        opening = true
        defer { opening = false }
        do {
            composing = .edit(try await api.entry(id).entry)
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    func delete(_ entry: JournalEntry) async {
        do {
            try await api.deleteEntry(entry.id)
            composing = nil
            await load()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }
}

/// What the composer is doing. Two cases and not a boolean, because "editing
/// an entry" needs the entry and "writing a new one" must not be able to name
/// one -- a nil there would be a third state the UI has to invent a meaning for.
///
/// Deliberately not main-actor isolated: `Identifiable`'s `id` is a nonisolated
/// requirement, and a type that carries data needs no isolation of its own.
enum ComposeTarget: Identifiable {
    case new
    case edit(JournalEntry)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let e): return e.id
        }
    }
}

struct HistoryView: View {
    @State private var model: HistoryModel

    init(api: any CareHiveAPI, recipientId: String) {
        _model = State(initialValue: HistoryModel(api: api, recipientId: recipientId))
    }

    var body: some View {
        List {
            if let page = model.page, page.limitedByPlan, let from = page.historyFrom {
                Section {
                    // The honest version of a paywall: it does not imply the
                    // older record is missing, because it is not. It exists and
                    // is simply out of view.
                    ExplanationCard(
                        symbol: "clock.arrow.circlepath",
                        title: "Showing the last 30 days",
                        message: "Older entries are kept but not shown on the free "
                            + "plan. This view starts at \(WallClock.shortDate(from)).",
                        tint: DS.Palette.accent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.m,
                                                  bottom: 0, trailing: DS.Space.m))
                }
            }

            ForEach(model.entries) { entry in
                LogRow(entry: entry, onOpen: { open(entry) })
                    .listRowBackground(DS.Palette.card)
            }

            if model.page?.hasMore == true {
                Section {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.loadingMore {
                                ProgressView()
                            } else {
                                Text("Load earlier")
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(LogKind.all, id: \.self) { kind in
                        Button {
                            Task { await model.toggle(kind) }
                        } label: {
                            if model.kinds.contains(kind) {
                                Label(LogKind.label(kind), systemImage: "checkmark")
                            } else {
                                Text(LogKind.label(kind))
                            }
                        }
                    }
                    if !model.kinds.isEmpty {
                        Divider()
                        Button("Show everything") {
                            model.kinds = []
                            Task { await model.load() }
                        }
                    }
                } label: {
                    Image(systemName: model.kinds.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter the history")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.composing = .new
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Write a note")
            }
        }
        .overlay {
            if model.opening {
                // Opening a note is a fetch, because the list only carries the
                // first part of the text. Without this the screen looks frozen
                // for as long as that takes, on the one tap where the person is
                // waiting to read something.
                ProgressView()
                    .padding(DS.Space.l)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else if model.entries.isEmpty && !model.loading {
                EmptyStateView(
                    symbol: "clock",
                    title: model.kinds.isEmpty ? "Nothing recorded yet" : "Nothing of that kind",
                    message: model.kinds.isEmpty
                        ? "Doses, notes and changes to the circle all appear here."
                        : "Try showing everything.")
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $model.composing) { target in
            NoteComposer(
                target: target,
                onSave: { body, mood in
                    await model.save(target, body: body, mood: mood)
                },
                onDelete: {
                    if case .edit(let entry) = target { await model.delete(entry) }
                })
        }
        .alert("That didn't work", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    /// Opens a note for reading or editing. Doses are not editable -- there is
    /// a separate undo for that, with its own window and its own rules -- so
    /// tapping one of those does nothing, deliberately.
    private func open(_ entry: LogEntry) {
        Task { await model.open(entry) }
    }
}

/// The kinds the server emits, named once so the filter menu and the row
/// rendering cannot disagree about what exists.
enum LogKind {
    static let all = ["dose", "prn", "note", "supply", "circle"]

    static func label(_ kind: String) -> String {
        switch kind {
        case "dose": return "Scheduled doses"
        case "prn": return "As-needed doses"
        case "note": return "Notes"
        case "supply": return "Supply changes"
        case "circle": return "Circle changes"
        default: return kind
        }
    }
}

// MARK: - One row

private struct LogRow: View {
    let entry: LogEntry
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(spacing: 2) {
                Text(WallClock.time(entry.atLocal) )
                    .font(.subheadline.weight(.medium).monospacedDigit())
                Text(WallClock.dayMonth(entry.on))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 68, alignment: .leading)

            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(headline)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(entry.isVoided)

                if let body = entry.body, !body.isEmpty {
                    Text(body + (entry.bodyTruncated == true ? "…" : ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .italic()
                }
                if entry.isVoided {
                    Text("Undone")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DS.Palette.missed)
                }
            }

            Spacer(minLength: 0)

            if let count = entry.photoCount, count > 0 {
                Label("\(count)", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    /// The sentence. Written here rather than on the server because it is a
    /// composition of three fields and belongs with the layout that shows them
    /// -- but every fact in it comes from the server unchanged.
    private var headline: String {
        switch entry.kind {
        case "dose", "prn":
            let who = entry.actorName ?? "Someone"
            let med = entry.medication ?? "a medication"
            let amount = entry.units.map { DS.units($0, entry.unitLabel) } ?? ""
            switch entry.state {
            case "given":
                return amount.isEmpty ? "\(who) recorded \(med)"
                                      : "\(who) recorded \(med), \(amount)"
            case "skipped":
                return "\(who) skipped \(med)"
            case "missed":
                return "\(med) was not recorded"
            default:
                return "\(who) · \(med)"
            }
        case "note":
            return "\(entry.actorName ?? "Someone") wrote a note"
        case "supply":
            return "Supply changed"
        case "circle":
            return entry.note ?? "The circle changed"
        default:
            return entry.medication ?? entry.kind
        }
    }

    private var symbol: String {
        switch entry.kind {
        case "dose":
            switch entry.state {
            case "given": return "checkmark.circle.fill"
            case "skipped": return "arrow.uturn.forward.circle"
            case "missed": return "xmark.circle"
            default: return "circle"
            }
        case "prn": return "clock.arrow.circlepath"
        case "note": return (entry.photoCount ?? 0) > 0 ? "photo" : "text.bubble"
        case "supply": return "pills"
        case "circle": return "person.2"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case "dose":
            switch entry.state {
            case "given": return DS.Palette.given
            case "skipped": return DS.Palette.skipped
            case "missed": return DS.Palette.missed
            default: return DS.Palette.pending
            }
        case "circle": return DS.Palette.accent
        default: return .secondary
        }
    }
}

// MARK: - Writing

/// The composer. One screen for a new note and for editing an existing one,
/// because the fields are the same and the only difference is the title and
/// whether there is something to delete.
struct NoteComposer: View {
    let target: ComposeTarget
    let onSave: (String, String?) async -> Void
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var body_: String
    @State private var mood: String?
    @State private var saving = false
    @State private var confirmDelete = false

    init(target: ComposeTarget,
         onSave: @escaping (String, String?) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.target = target
        self.onSave = onSave
        self.onDelete = onDelete
        switch target {
        case .new:
            _body_ = State(initialValue: "")
        case .edit(let entry):
            _body_ = State(initialValue: entry.body)
            _mood = State(initialValue: entry.mood)
        }
    }

    /// A short list of words, not a mood scale. "Okay / Not great / Unwell" is
    /// a family's own vocabulary; a five-point Likert scale would be a clinical
    /// instrument this app has no business borrowing.
    private let moods = ["good", "okay", "not great", "unwell"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $body_)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Your note")
                } header: {
                    Text("What happened?")
                } footer: {
                    // The boundary, in the place where someone is most likely to
                    // cross it. This is a notebook, not a clinical record, and
                    // saying so here is what keeps it one.
                    Text("Write down what you noticed. CareHive does not give "
                         + "medical advice, so keep questions for the doctor.")
                    // An edited note is a fact about the note, and the person
                    // reading it is entitled to know they are not reading the
                    // first version. The list already flags it; this says when.
                    if let edited = editStamp {
                        Text(edited)
                    }
                }

                Section("How were they?") {
                    Picker("How were they?", selection: $mood) {
                        Text("Not saying").tag(String?.none)
                        ForEach(moods, id: \.self) { m in
                            Text(m.capitalized).tag(String?.some(m))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if let onDelete, isEditing {
                    Section {
                        Button("Delete this note", role: .destructive) {
                            confirmDelete = true
                        }
                    } footer: {
                        // Deletion here is a void, not a hole: the row stays in
                        // the history with its author's name on it. Saying so is
                        // not reassurance for its own sake -- a person deleting
                        // a note about a parent has usually just realised it was
                        // wrong, and needs to know whether the wrong thing is
                        // gone or merely struck through. It is struck through.
                        Text("The note is removed from the log but the record "
                             + "that it was written and deleted stays. Nothing "
                             + "else in the history changes.")
                    }
                    .confirmationDialog("Delete this note?", isPresented: $confirmDelete,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            saving = true
                            Task {
                                await onDelete()
                                saving = false
                            }
                        }
                        Button("Keep it", role: .cancel) {}
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit note" : "New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        let text = body_.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        saving = true
                        Task {
                            await onSave(text, mood)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || saving)
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    /// "Edited Sep 24" when it has been, nothing when it has not. Empty string
    /// rather than a placeholder, because an unedited note should say nothing
    /// about editing at all -- a permanent "not edited" label trains people to
    /// stop reading the line that matters.
    private var editStamp: String? {
        guard case .edit(let entry) = target, entry.edited else { return nil }
        guard let day = entry.editedAtLocal ?? entry.editedAt else {
            return "This note has been edited."
        }
        return "Edited \(WallClock.shortDate(String(day.prefix(10))))"
    }
}
