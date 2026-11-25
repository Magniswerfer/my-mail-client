import MailEngine
import SwiftUI

/// A quiet line at the top of a conversation when its mail mentions a plan: "Add to Calendar:
/// Middag hos os · fre. 27. nov. 19.00". Add opens an editable event; Dismiss is remembered for
/// the message. Also ⌃⌘E and ⌘K. Meeting invitations have their own card (M4.6) instead.
struct DateSuggestionCard: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage
    let record: EventSuggestionRecord

    var body: some View {
        let suggestions = record.visible()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions) { suggestion in
                row(suggestion, isFirst: suggestion.id == suggestions.first?.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Calendar suggestions"))
    }

    @ViewBuilder private func row(_ suggestion: EventSuggestion, isFirst: Bool) -> some View {
        let added = model.isInCalendar(suggestion, message: message)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: added ? "calendar.badge.checkmark" : DateSuggestionFormat.symbol(suggestion.kind))
                .font(.title3)
                .foregroundStyle(added ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(suggestion, added: added))
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let written = DateSuggestionFormat.writtenTime(suggestion) {
                        Text(written)
                    }
                    if let place = suggestion.location, !place.isEmpty {
                        Label(place, systemImage: "mappin.and.ellipse").labelStyle(BulletLabelStyle())
                    }
                    if suggestion.source == .text {
                        Text("“\(suggestion.sourceText)”").italic()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if added {
                Text("In your calendar").font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    model.editEvent(suggestion, message: message)
                } label: {
                    Label("Add…", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .help(isFirst ? String(localized: "Add to Calendar (⌃⌘E)") : String(localized: "Add to Calendar"))
            }
            if isFirst, record.state != .added {
                Button {
                    model.dismissDateSuggestions(for: message)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel(Text("Dismiss"))
            }
        }
    }

    private func headline(_ s: EventSuggestion, added: Bool) -> AttributedString {
        var lead = AttributedString(added ? String(localized: "In Calendar: ") : String(localized: "Add to Calendar: "))
        lead.foregroundColor = .secondary
        var title = AttributedString(DateSuggestionFormat.title(s))
        title.font = .callout.weight(.semibold)
        let when = AttributedString(" · " + DateSuggestionFormat.when(s))
        return lead + title + when
    }
}

/// The suggestion card for a conversation, if any (scanning it first when it's older mail),
/// plus the editor sheet.
struct DateSuggestionSlot: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        let _ = model.revision
        if let found = model.dateSuggestions(inThread: threadID) {
            DateSuggestionCard(message: found.message, record: found.record)
        }
    }
}

extension View {
    /// Scans an opened conversation the background pass hasn't reached, and hosts the editor.
    func dateSuggestions(threadID: String, model: AppModel) -> some View {
        modifier(DateSuggestionHost(threadID: threadID, model: model))
    }
}

private struct DateSuggestionHost: ViewModifier {
    let threadID: String
    let model: AppModel
    @Bindable private var center = DateSuggestionCenter.shared

    func body(content: Content) -> some View {
        content
            .task(id: threadID) { await model.scanThreadIfNeeded(threadID) }
            .sheet(item: $center.editing) { draft in
                EventEditor(draft: draft).environment(model)
            }
    }
}

/// The editable event: what, when, where, notes. Saved in your default calendar.
struct EventEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft

    init(draft: EventDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text(DateSuggestionFormat.fallbackTitle(draft.kind)))
                    TextField("Location", text: $draft.location)
                }
                Section {
                    Toggle("All Day", isOn: $draft.isAllDay)
                    DatePicker("Starts", selection: $draft.start,
                               displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $draft.end, in: draft.start...,
                               displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    if let note = zoneNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                        .labelsHidden()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("New Event"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Calendar") {
                        model.saveEvent(draft)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.end < draft.start)
                }
            }
            .onChange(of: draft.start) { old, new in
                // Moving the start moves the end with it, keeping the length.
                draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
            }
        }
        .macFrame(width: 460, height: 440)
    }

    /// "Written as 14:00 in Paris": the times above are shown in your zone.
    private var zoneNote: String? {
        guard !draft.isAllDay, let id = draft.timeZoneID, let zone = TimeZone(identifier: id),
              zone.secondsFromGMT(for: draft.start) != TimeZone.current.secondsFromGMT(for: draft.start) else { return nil }
        let time = Date.FormatStyle(timeZone: zone).hour().minute()
        let place = id.contains("/") ? (id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id)
            : (zone.abbreviation(for: draft.start) ?? id)
        return String(localized: "Shown in your time zone. Written as \(draft.start.formatted(time)) in \(place).")
    }
}
