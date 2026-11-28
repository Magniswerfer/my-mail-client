import MailEngine
import SwiftUI

// MARK: - Auto Summarize

/// "✦ Anna needs the signed contract by Friday; Bo asked whether Tuesday works." Made on
/// device, only for conversations long enough to need it, and kept until a new message arrives.
struct SummaryLine: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    let messageCount: Int
    @State private var text: String?
    @State private var working = false

    var body: some View {
        Group {
            if let text {
                Label {
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.purple.opacity(0.07), in: .rect(cornerRadius: 10))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Summary: \(text)"))
                .help("Summarized on this device")
            } else if working {
                Label("Summarizing…", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            }
        }
        .task(id: "\(threadID)#\(messageCount)") {
            text = nil
            // A run cancelled mid-summary (a new message arrived) left this on.
            working = false
            guard let digest = model.summaryDigest(threadID: threadID) else { return }
            if let cached = model.cachedSummary(threadID: threadID, digest: digest) {
                text = cached
                return
            }
            guard model.assistant != nil else { return }
            working = true
            let made = await model.makeSummary(threadID: threadID, digest: digest)
            guard !Task.isCancelled else { return }
            working = false
            withAnimation(.snappy) { text = made }
        }
    }
}

// MARK: - Contact sidebar

/// Who you're talking to: history, how quickly they answer, their links, recent conversations
/// and colleagues. Built from your own mail; nothing is looked up online.
struct ContactPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        if let address = model.contactPanelAddress, let profile = model.contactProfile(address) {
            ContactProfileView(profile: profile)
        } else {
            ContentUnavailableView("No one selected", systemImage: "person.crop.circle",
                                   description: Text("Open a conversation to see who it's with."))
        }
    }
}

struct ContactProfileView: View {
    @Environment(AppModel.self) private var model
    let profile: ContactProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                facts
                if !profile.signature.links.isEmpty || !profile.signature.phones.isEmpty { reach }
                if !profile.recent.isEmpty { recent }
                if !profile.colleagues.isEmpty { colleagues }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(profile.name ?? profile.address)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Avatar(name: profile.name ?? profile.address, address: profile.address, size: 56)
            Text(profile.name ?? profile.address).font(.title3.weight(.semibold)).textSelection(.enabled)
            if profile.name != nil {
                Text(profile.address).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if profile.isOrganisation, let site = URL(string: "https://\(profile.domain)"), !profile.domain.isEmpty {
                Link(destination: site) {
                    Label(profile.domain, systemImage: "building.2")
                }
                .font(.caption)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.composeNew(to: [MailAddress(name: profile.name, address: profile.address)]) } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            Button {
                model.searchText = "from:\(profile.address)"
                if Platform.isPhone { model.isContactPanelShown = false }
            } label: {
                Label("All Mail", systemImage: "magnifyingglass")
            }
            Button { Platform.copy(profile.address) } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("envelope", String(localized: "\(profile.received) from them · \(profile.sent) from you"))
            if let first = profile.firstContact {
                fact("calendar", String(localized: "Since \(first.formatted(.dateTime.month(.wide).year()))"))
            }
            if let last = profile.lastContact {
                fact("clock", String(localized: "Last mail \(last.formatted(.relative(presentation: .named)))"))
            }
            if let hours = profile.typicalReplyHours {
                fact("arrowshape.turn.up.left", Self.replyTime(hours))
            }
        }
        .font(.callout)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(.secondary)
    }

    static func replyTime(_ hours: Double) -> String {
        if hours < 1 { return String(localized: "Usually answers within the hour") }
        if hours < 24 { return String(localized: "Usually answers within \(Int(hours.rounded(.up))) hours") }
        return String(localized: "Usually answers within \(Int((hours / 24).rounded(.up))) days")
    }

    private var reach: some View {
        section(String(localized: "From their signature")) {
            ForEach(profile.signature.links, id: \.url) { link in
                if let url = URL(string: link.url) {
                    Link(destination: url) { Label(link.label, systemImage: Self.symbol(link.kind)) }
                }
            }
            ForEach(profile.signature.phones, id: \.self) { phone in
                if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                    Link(destination: url) { Label(phone, systemImage: "phone") }
                }
            }
        }
    }

    static func symbol(_ kind: SignatureInfo.LinkKind) -> String {
        switch kind {
        case .linkedIn: "person.text.rectangle"
        case .x, .mastodon, .bluesky: "bubble.left"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .website: "globe"
        }
    }

    private var recent: some View {
        section(String(localized: "Recent conversations")) {
            ForEach(profile.recent) { conversation in
                Button {
                    model.selectedThreadID = conversation.threadID
                    if Platform.isPhone { model.isContactPanelShown = false }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.subject).lineLimit(1)
                        Text(MailDate.short(conversation.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var colleagues: some View {
        section(String(localized: "Also at \(profile.domain)")) {
            ForEach(profile.colleagues, id: \.address) { person in
                Button { model.contactAddress = person.address } label: {
                    HStack(spacing: 8) {
                        Avatar(name: person.name ?? person.address, address: person.address, size: 22)
                        Text(person.name ?? person.address).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

// MARK: - Share Availability

/// Picks free times from your calendar and inserts them as text ("Tuesday 2 December: 9:15–10:00").
struct AvailabilityPicker: View {
    @Environment(\.dismiss) private var dismiss
    let insert: (String) -> Void
    @State private var slots: [Availability.Slot] = []
    @State private var chosen: Set<Availability.Slot> = []
    @State private var minutes = 30
    @State private var state = LoadState.loading

    enum LoadState { case loading, denied, ready }

    private static let lookAhead: TimeInterval = 14 * 86_400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share availability").font(.headline)
            Picker("Shortest slot", selection: $minutes) {
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
            }
            .pickerStyle(.segmented)
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .denied:
                Label(Platform.calendarSettingsHint, systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            case .ready where slots.isEmpty:
                Text("No free time in your working hours over the next week.").foregroundStyle(.secondary)
            case .ready:
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(slots, id: \.self) { slot in
                            Toggle(isOn: Binding(get: { chosen.contains(slot) },
                                                 set: { if $0 { chosen.insert(slot) } else { chosen.remove(slot) } })) {
                                Text(Self.describe(slot))
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Text("Working hours and time zone come from Settings and this device.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Insert") {
                    insert(Self.text(for: slots.filter(chosen.contains)))
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .macFrame(width: 440)
        .task(id: minutes) { await load() }
    }

    private func load() async {
        let calendar = CalendarBridge.shared
        guard await calendar.requestAccess() else { state = .denied; return }
        let now = Date()
        var options = Availability.Options()
        options.minimumMinutes = minutes
        options.dayStartHour = AssistSettings.workdayStart
        options.dayEndHour = AssistSettings.workdayEnd
        let busy = calendar.busyIntervals(from: now, to: now.addingTimeInterval(Self.lookAhead))
        slots = Availability.freeSlots(busy: busy, from: now, options: options)
        chosen = Set(slots)
        state = .ready
    }

    static func describe(_ slot: Availability.Slot) -> String {
        let day = slot.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let time = Date.FormatStyle.dateTime.hour().minute()
        return "\(day): \(slot.start.formatted(time))–\(slot.end.formatted(time))"
    }

    /// One line per day, in this device's time zone.
    static func text(for slots: [Availability.Slot]) -> String {
        let zone = TimeZone.current.localizedName(for: .shortGeneric, locale: .current) ?? TimeZone.current.identifier
        var lines = [String(localized: "Here are some times that work for me (\(zone)):")]
        let time = Date.FormatStyle.dateTime.hour().minute()
        let byDay = Dictionary(grouping: slots) { Calendar.current.startOfDay(for: $0.start) }
        for day in byDay.keys.sorted() {
            let ranges = byDay[day]!.sorted { $0.start < $1.start }
                .map { "\($0.start.formatted(time))–\($0.end.formatted(time))" }.joined(separator: ", ")
            lines.append("• \(day.formatted(.dateTime.weekday(.wide).day().month(.wide))): \(ranges)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Settings

struct AssistantSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AssistSettings.summariesKey) private var summaries = true
    @AppStorage(AssistSettings.autoDraftsKey) private var autoDrafts = true
    @AppStorage(AssistSettings.followUpDaysKey) private var followUpDays = 3
    @AppStorage(AssistSettings.workdayStartKey) private var workdayStart = 9
    @AppStorage(AssistSettings.workdayEndKey) private var workdayEnd = 17
    @AppStorage(AssistSettings.sendAndDoneKey) private var sendAndDone = true
    @AppStorage(AssistSettings.replyDraftsKey) private var replyDrafts = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Apple Intelligence") {
                    Text(model.assistant != nil ? LocalizedStringKey("Available") : LocalizedStringKey("Not available on this device"))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Everything here runs on this device. Without Apple Intelligence, summaries are off and follow-ups use a short template.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Mark the conversation done when I send a reply", isOn: $sendAndDone)
            } header: {
                Text("Sending")
            } footer: {
                Text("⌘↩ sends and marks done; ⌥⌘↩ sends and keeps it in the Inbox. Undo brings both back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Summaries") {
                Toggle("Summarize long conversations", isOn: $summaries)
            }
            Section {
                Toggle("Draft follow-ups when nobody replies", isOn: $autoDrafts)
                Toggle("Draft replies to mail that asks you something", isOn: $replyDrafts)
                    .disabled(model.assistant == nil)
                Stepper("After \(followUpDays) days", value: $followUpDays, in: 2...14)
                    .disabled(!autoDrafts)
            } header: {
                Text("Auto Drafts")
            } footer: {
                Text("Drafts wait in the Outbox for you to review. Tidings never sends them by itself, and drops them when a reply arrives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Share availability") {
                Picker("Working day starts", selection: $workdayStart) {
                    ForEach(6..<13) { Text("\($0):00").tag($0) }
                }
                Picker("Working day ends", selection: $workdayEnd) {
                    ForEach(14..<22) { Text("\($0):00").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
