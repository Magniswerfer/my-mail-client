import EventKit
import MailEngine
import SwiftUI

/// The invitation at the top of a conversation: what, when, where, who, your answer, and how it
/// sits in your calendar. Accept / Maybe / Decline are also ⌃⌘Y / ⌃⌘M / ⌃⌘N, in ⌘K and the Message menu.
struct InviteCard: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage
    let invite: CalendarInvite
    @State private var showGuests = false

    var body: some View {
        let _ = model.revision
        let calendar = CalendarBridge.shared
        let inCalendar = calendar.existingEvent(for: invite)
        let conflicts = calendar.conflicts(for: invite)
        let mine = model.myResponse(to: invite, accountID: message.accountID)
        let isOrganizer = invite.isOrganized(by: model.ownAddresses)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                DateTile(invite: invite)
                VStack(alignment: .leading, spacing: 4) {
                    statusLine(mine: mine, isOrganizer: isOrganizer)
                    eventDetails
                }
                Spacer(minLength: 0)
                if let link = invite.conferenceURL.flatMap(URL.init(string:)), !invite.isCancelled {
                    Link(destination: link) {
                        Label(InviteFormat.joinTitle(link), systemImage: "video.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .help(link.absoluteString)
                }
            }

            if !conflicts.isEmpty {
                Label(InviteFormat.conflicts(conflicts), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            actions(mine: mine, isOrganizer: isOrganizer, inCalendar: inCalendar)
        }
        .padding(14)
        .background(.tint.opacity(0.06), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.tint.opacity(0.18)))
        .tint(invite.isCancelled ? .red : .accentColor)
        .task(id: "\(invite.uid)#\(invite.sequence)#\(invite.isCancelled)") { model.syncCalendarCopy(invite) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Invitation: \(invite.summary)"))
    }

    @ViewBuilder private func statusLine(mine: CalendarInvite.ParticipationStatus?, isOrganizer: Bool) -> some View {
        let (text, symbol, tint): (String, String, Color) = {
            if invite.isCancelled { return (String(localized: "Cancelled"), "calendar.badge.minus", .red) }
            switch invite.method {
            case .counter: return (String(localized: "New time proposed"), "calendar.badge.clock", .orange)
            case .publish, .add: return (String(localized: "Event"), "calendar", .secondary)
            default: break
            }
            if isOrganizer { return (String(localized: "You're the organizer"), "person.crop.circle.badge.checkmark", .secondary) }
            let updated = invite.sequence > 0
            switch mine {
            case .accepted?: return (String(localized: "You're going"), "checkmark.circle.fill", .green)
            case .tentative?: return (String(localized: "You might go"), "questionmark.circle.fill", .orange)
            case .declined?: return (String(localized: "You declined"), "xmark.circle.fill", .secondary)
            default: return (updated ? String(localized: "Updated invitation") : String(localized: "Invitation"), "envelope.badge", .accentColor)
            }
        }()
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
    }

    /// What, when (also in the organizer's zone), how often, where and who.
    @ViewBuilder private var eventDetails: some View {
        Text(invite.summary.isEmpty ? String(localized: "Untitled event") : invite.summary)
            .font(.headline)
            .strikethrough(invite.isCancelled)
            .textSelection(.enabled)
        Text(InviteFormat.when(invite)).font(.subheadline)
        if let other = InviteFormat.organizerTime(invite) {
            Text(other).font(.caption).foregroundStyle(.secondary)
        }
        if let repeats = InviteFormat.repeats(invite.recurrenceRule) {
            Label(repeats, systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
        }
        if let location = invite.location, location != invite.conferenceURL {
            Label(location, systemImage: "mappin.and.ellipse")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
        people
    }

    @ViewBuilder private var people: some View {
        let guests = invite.guests
        if let organizer = invite.organizer {
            Button {
                showGuests.toggle()
            } label: {
                Label {
                    Text(guests.count > 1
                         ? String(localized: "\(organizer.display) · \(guests.count) guests")
                         : organizer.display)
                } icon: { Image(systemName: "person.2") }
                .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show guests")
            .popover(isPresented: $showGuests, arrowEdge: .bottom) {
                GuestList(organizer: organizer, guests: guests)
            }
        }
    }

    @ViewBuilder private func actions(mine: CalendarInvite.ParticipationStatus?, isOrganizer: Bool, inCalendar: EKEvent?) -> some View {
        HStack(spacing: 8) {
            if invite.isCancelled {
                if inCalendar != nil, CalendarBridge.shared.isLinked(invite) {
                    Button("Remove from Calendar", systemImage: "calendar.badge.minus") { model.removeFromCalendar(invite) }
                }
            } else if invite.method == .request, !isOrganizer, invite.organizer != nil {
                // Icons only when a narrow reading pane would truncate the words ("Acc…").
                ViewThatFits(in: .horizontal) {
                    answerButtons(mine: mine, compact: false)
                    answerButtons(mine: mine, compact: true)
                }
            }
            Spacer()
            if !invite.isCancelled {
                if inCalendar != nil {
                    Label("In your calendar", systemImage: "calendar.badge.checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                } else if invite.method != .request || mine == .accepted || mine == .tentative || isOrganizer {
                    Button("Add to Calendar", systemImage: "calendar.badge.plus") { model.addToCalendar(invite) }
                }
            }
        }
        .controlSize(.regular)
        .buttonStyle(.glass)
    }

    @ViewBuilder private func answerButtons(mine: CalendarInvite.ParticipationStatus?, compact: Bool) -> some View {
        let buttons = HStack(spacing: 8) {
            answerButton(.accepted, title: String(localized: "Accept"), symbol: "checkmark", mine: mine)
            answerButton(.tentative, title: String(localized: "Maybe"), symbol: "questionmark", mine: mine)
            answerButton(.declined, title: String(localized: "Decline"), symbol: "xmark", mine: mine)
        }
        .fixedSize()
        if compact { buttons.labelStyle(.iconOnly) } else { buttons.labelStyle(.titleAndIcon) }
    }

    private func answerButton(_ status: CalendarInvite.ParticipationStatus, title: String, symbol: String,
                              mine: CalendarInvite.ParticipationStatus?) -> some View {
        let chosen = mine == status
        let chosenTint: Color? = !chosen ? nil : status == .declined ? .secondary : status == .tentative ? .orange : .green
        return Button {
            guard !chosen else { return }
            model.respond(status, to: invite, message: message)
        } label: {
            Label(title, systemImage: chosen ? "\(symbol).circle.fill" : symbol)
        }
        .tint(chosenTint)
        .help(title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .help(chosen ? String(localized: "Your answer") : title)
    }
}

/// "DEC / 1 / Tue": the calendar-page glyph.
private struct DateTile: View {
    let invite: CalendarInvite

    var body: some View {
        let zone = invite.isAllDay ? TimeZone(identifier: "UTC")! : .current
        VStack(spacing: 0) {
            Text(invite.start.formatted(InviteFormat.style(zone).month(.abbreviated)).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(invite.isCancelled ? Color.red : Color.accentColor)
            Text(invite.start.formatted(InviteFormat.style(zone).day()))
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(invite.start.formatted(InviteFormat.style(zone).weekday(.abbreviated)))
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 3)
        }
        .frame(width: 52)
        .background(.background, in: .rect(cornerRadius: 9))
        .clipShape(.rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
        .accessibilityHidden(true)
    }
}

private struct GuestList: View {
    let organizer: CalendarInvite.Person
    let guests: [CalendarInvite.Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(organizer, note: String(localized: "Organizer"))
            Divider()
            ForEach(guests, id: \.address) { guest in
                row(guest, note: guest.isOptional ? String(localized: "Optional") : nil)
            }
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 360)
    }

    private func row(_ person: CalendarInvite.Person, note: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: InviteFormat.symbol(person.status))
                .foregroundStyle(InviteFormat.tint(person.status))
                .accessibilityLabel(InviteFormat.statusText(person.status))
            VStack(alignment: .leading, spacing: 0) {
                Text(person.display)
                if person.name != nil { Text(person.address).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .textSelection(.enabled)
    }
}

/// "Anna accepted": an attendee's answer, shown on its message instead of the boilerplate body.
struct InviteReplyLine: View {
    let invite: CalendarInvite

    var body: some View {
        if let who = invite.replyFrom {
            Label(InviteFormat.replyText(who), systemImage: InviteFormat.symbol(who.status))
                .foregroundStyle(InviteFormat.tint(who.status))
                .font(.callout)
        }
    }
}

enum InviteFormat {
    /// A date format in a given zone (all-day dates are stored as UTC midnight).
    static func style(_ zone: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(timeZone: zone)
    }

    /// "Tuesday 1 December · 14:00–15:00", "Thursday 24 December · All day",
    /// "24–27 December · All day". Times in this Mac's zone; all-day dates as written.
    static func when(_ invite: CalendarInvite) -> String {
        if invite.isAllDay {
            let utc = TimeZone(identifier: "UTC")!
            let day = style(utc).weekday(.wide).day().month(.wide)
            let lastDay = invite.end.map { $0.addingTimeInterval(-1) } ?? invite.start
            var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
            if cal.isDate(invite.start, inSameDayAs: lastDay) {
                return String(localized: "\(invite.start.formatted(day)) · All day")
            }
            let short = style(utc).day().month(.wide)
            return String(localized: "\(invite.start.formatted(short)) – \(lastDay.formatted(short)) · All day")
        }
        let day = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        let time = Date.FormatStyle.dateTime.hour().minute()
        guard let end = invite.end else { return "\(invite.start.formatted(day)) · \(invite.start.formatted(time))" }
        if Calendar.current.isDate(invite.start, inSameDayAs: end.addingTimeInterval(-1)) {
            return "\(invite.start.formatted(day)) · \(invite.start.formatted(time))–\(end.formatted(time))"
        }
        return "\(invite.start.formatted(day)) \(invite.start.formatted(time)) – \(end.formatted(day)) \(end.formatted(time))"
    }

    /// "15:00–16:00 in London" when the organizer's zone differs from yours.
    static func organizerTime(_ invite: CalendarInvite) -> String? {
        guard !invite.isAllDay, let id = invite.timeZoneID, let zone = TimeZone(identifier: id), id != "UTC",
              zone.secondsFromGMT(for: invite.start) != TimeZone.current.secondsFromGMT(for: invite.start) else { return nil }
        let time = style(zone).hour().minute()
        let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
        let range = invite.end.map { "\(invite.start.formatted(time))–\($0.formatted(time))" } ?? invite.start.formatted(time)
        return String(localized: "\(range) in \(city)")
    }

    static func repeats(_ rule: String?) -> String? {
        guard let rule else { return nil }
        let parts = rule.uppercased().split(separator: ";")
        func value(_ key: String) -> Substring? {
            parts.first { $0.hasPrefix(key + "=") }?.dropFirst(key.count + 1)
        }
        let freq = value("FREQ").map(String.init) ?? ""
        let interval = value("INTERVAL").flatMap { Int($0) } ?? 1
        switch (freq, interval) {
        case ("DAILY", 1): return String(localized: "Every day")
        case ("WEEKLY", 1): return String(localized: "Every week")
        case ("WEEKLY", 2): return String(localized: "Every other week")
        case ("MONTHLY", 1): return String(localized: "Every month")
        case ("YEARLY", 1): return String(localized: "Every year")
        default: return String(localized: "Repeats")
        }
    }

    static func joinTitle(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("teams.") { return String(localized: "Join Teams") }
        if host.contains("zoom") { return String(localized: "Join Zoom") }
        if host.contains("meet.google") { return String(localized: "Join Meet") }
        if host.contains("webex") { return String(localized: "Join Webex") }
        if host.contains("facetime") { return String(localized: "Join FaceTime") }
        return String(localized: "Join")
    }

    static func conflicts(_ events: [EKEvent]) -> String {
        let time = Date.FormatStyle.dateTime.hour().minute()
        let first = events[0]
        if events.count == 1 {
            return String(localized: "Overlaps \(first.title ?? "") at \(first.startDate.formatted(time))")
        }
        return String(localized: "Overlaps \(first.title ?? "") and \(events.count - 1) more")
    }

    static func symbol(_ status: CalendarInvite.ParticipationStatus) -> String {
        switch status {
        case .accepted: "checkmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .delegated: "arrow.forward.circle"
        case .needsAction: "circle.dotted"
        }
    }

    static func tint(_ status: CalendarInvite.ParticipationStatus) -> Color {
        switch status {
        case .accepted: .green
        case .tentative: .orange
        case .declined: .red
        default: .secondary
        }
    }

    static func statusText(_ status: CalendarInvite.ParticipationStatus) -> String {
        switch status {
        case .accepted: String(localized: "Going")
        case .tentative: String(localized: "Maybe")
        case .declined: String(localized: "Not going")
        case .delegated: String(localized: "Delegated")
        case .needsAction: String(localized: "No answer yet")
        }
    }

    static func replyText(_ person: CalendarInvite.Person) -> String {
        switch person.status {
        case .accepted: String(localized: "\(person.display) accepted")
        case .tentative: String(localized: "\(person.display) might attend")
        case .declined: String(localized: "\(person.display) declined")
        case .delegated: String(localized: "\(person.display) delegated the invitation")
        case .needsAction: String(localized: "\(person.display) hasn't answered")
        }
    }
}
