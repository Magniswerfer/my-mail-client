import MailEngine
import SwiftUI

extension Highlight {
    var symbol: String {
        switch kind {
        case .code: "key.fill"
        case .package: "shippingbox.fill"
        case .flight: "airplane"
        case .receipt: "receipt"
        case .reservation: "fork.knife"
        case .bill: "doc.text.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .code: .indigo
        case .package: .brown
        case .flight: .blue
        case .receipt: .teal
        case .reservation: .orange
        case .bill: .red
        }
    }

    var kindTitle: String {
        switch kind {
        case .code: String(localized: "Code")
        case .package: String(localized: "Parcel")
        case .flight: String(localized: "Flight")
        case .receipt: String(localized: "Receipt")
        case .reservation: String(localized: "Reservation")
        case .bill: String(localized: "Bill")
        }
    }

    /// One line for the stream row: "Code 482913", "Parcel · PostNord", "SK 1234 · 3 Dec".
    var chipText: String {
        switch kind {
        case .code: "\(kindTitle) \(value ?? "")"
        case .flight, .reservation:
            [title, date.map { $0.formatted(.dateTime.day().month(.abbreviated)) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .package: [kindTitle, title].filter { !$0.isEmpty }.joined(separator: " · ")
        case .receipt, .bill: value ?? kindTitle
        }
    }
}

/// The highlights of a conversation's newest message, at the top of the reader.
struct HighlightCards: View {
    @Environment(AppModel.self) private var model
    let highlights: [Highlight]
    let message: StoredMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(highlights.enumerated()), id: \.offset) { _, h in
                HighlightCard(highlight: h, message: message)
            }
        }
    }
}

struct HighlightCard: View {
    @Environment(AppModel.self) private var model
    let highlight: Highlight
    let message: StoredMessage

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: highlight.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(highlight.tint.gradient, in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.kindTitle.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(headline).font(.headline).textSelection(.enabled)
                if let sub = subline { Text(sub).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(highlight.tint.opacity(0.07), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch highlight.kind {
        case .code: highlight.value ?? ""
        case .package: highlight.value ?? highlight.title
        case .receipt, .bill: highlight.value ?? highlight.title
        default: highlight.title
        }
    }

    private var subline: String? {
        let when = highlight.date.map { $0.formatted(date: .abbreviated, time: highlight.kind == .bill ? .omitted : .shortened) }
        switch highlight.kind {
        case .code: return highlight.title.isEmpty ? nil : highlight.title
        case .package: return [highlight.title, when.map { String(localized: "Expected \($0)") }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .flight: return [when, highlight.value.map { String(localized: "Booking \($0)") }].compactMap { $0 }.joined(separator: " · ")
        case .reservation: return [when, highlight.location, highlight.detail.map { String(localized: "\($0) people") }].compactMap { $0 }.joined(separator: " · ")
        case .receipt: return [highlight.title, highlight.detail.map { String(localized: "Order \($0)") }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .bill: return [highlight.title, when.map { String(localized: "Due \($0)") }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch highlight.kind {
            case .code:
                Button("Copy") { model.copyCode(highlight.value, from: message) }
                    .buttonStyle(.glassProminent)
            case .package:
                link(String(localized: "Track"))
            case .flight, .reservation:
                if highlight.date != nil {
                    Button("Add to Calendar", systemImage: "calendar.badge.plus") { model.addToCalendar(highlight) }
                        .labelStyle(.iconOnly).buttonStyle(.glass)
                }
                link(highlight.kind == .flight ? String(localized: "Check In") : String(localized: "Manage"))
            case .bill:
                if let due = highlight.date {
                    Button("Remind Me", systemImage: "checklist") { model.remindToPay(highlight, due: due, message: message) }
                        .labelStyle(.iconOnly).buttonStyle(.glass)
                }
                link(String(localized: "Pay"))
            case .receipt:
                link(String(localized: "View Order"))
            }
        }
    }

    @ViewBuilder private func link(_ title: String) -> some View {
        if let url = highlight.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
            Link(title, destination: url).buttonStyle(.glass)
        }
    }
}

/// The small chip in a stream row.
struct HighlightChip: View {
    @Environment(AppModel.self) private var model
    let highlight: Highlight
    let message: StoredMessage

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: highlight.symbol)
            Text(highlight.chipText).lineLimit(1)
            if highlight.kind == .code {
                Button { model.copyCode(highlight.value, from: message) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the code")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(highlight.tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(highlight.tint.opacity(0.1), in: .capsule)
    }
}

extension AppModel {
    func copyCode(_ code: String?, from message: StoredMessage) {
        guard let code else { return }
        Platform.copy(code)
        show(Toast(message: String(localized: "Copied \(code) from \(message.senderDisplay)"), symbol: "key.fill"))
    }

    /// ⌃⌥C anywhere on the Mac (and ⌘K): the newest login code from the last 20 minutes.
    func copyLatestCode() {
        if let found = try? store.latestLoginCode() {
            copyCode(found.code, from: found.message)
            #if os(macOS)
            NSSound(named: "Pop")?.play()
            #endif
        } else {
            show(Toast(message: String(localized: "No login code in the last 20 minutes"), symbol: "key"))
        }
    }

    func addToCalendar(_ highlight: Highlight) {
        guard let start = highlight.date else { return }
        Task {
            guard await CalendarBridge.shared.requestAccess() else {
                show(Toast(message: Platform.calendarSettingsHint, symbol: "calendar.badge.exclamationmark"))
                return
            }
            do {
                try CalendarBridge.shared.addEvent(title: highlight.title, start: start,
                                                   end: highlight.endDate ?? start.addingTimeInterval(3_600),
                                                   location: highlight.location, url: highlight.url.flatMap(URL.init(string:)))
                show(Toast(message: String(localized: "Added to your calendar"), symbol: "calendar.badge.plus"))
            } catch {
                lastError = String(localized: "Couldn't add it to your calendar: \(error.localizedDescription)")
            }
        }
    }

    func remindToPay(_ highlight: Highlight, due: Date, message: StoredMessage) {
        Task {
            do {
                let title = String(localized: "Pay \(highlight.title.isEmpty ? message.senderDisplay : highlight.title)")
                try await CalendarBridge.shared.addReminder(title: title, notes: highlight.value, url: link(for: message),
                                                            due: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due))
                show(Toast(message: String(localized: "Added to Reminders"), symbol: "checklist"))
            } catch {
                show(Toast(message: Platform.remindersSettingsHint, symbol: "checklist"))
            }
        }
    }
}
