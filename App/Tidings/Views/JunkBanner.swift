import MailEngine
import SwiftUI

/// The junk filter's word in the reader (SPEC §8): in Junk, why it's there and Not Junk; in the
/// Inbox, a warning when the filter thinks it's likely junk but isn't sure enough to move it.
struct JunkBanner: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    let messages: [StoredMessage]

    enum Kind { case inJunk(movedByFilter: Bool), likely }

    static func kind(for messages: [StoredMessage], model: AppModel) -> Kind? {
        guard let latest = messages.last else { return nil }
        if model.isInJunk(latest) {
            return .inJunk(movedByFilter: messages.contains { ($0.junkScore ?? 0) >= JunkFilter.junkThreshold })
        }
        if latest.mailbox == "INBOX", messages.contains(where: { ($0.junkScore ?? 0) >= JunkFilter.warningThreshold && $0.mailbox == "INBOX" }) {
            return .likely
        }
        return nil
    }

    var body: some View {
        if let kind = Self.kind(for: messages, model: model),
           let thread = model.threads.first(where: { $0.threadID == threadID }) {
            VStack(alignment: .leading, spacing: 8) {
                switch kind {
                case .inJunk(let moved):
                    Label("This message is in Junk", systemImage: "xmark.bin.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text(moved ? "Tidings moved it here: it looks like mail you've marked as junk."
                               : "If it isn't junk, move it back and Tidings learns from that.")
                        .font(Platform.isPhone ? .subheadline : .callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Not Junk", systemImage: "tray.and.arrow.down") { model.notJunk([thread]) }
                        .buttonStyle(.glassProminent).tint(.orange)
                        .lineLimit(1).fixedSize()
                case .likely:
                    Label("This looks like junk", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text("It resembles mail you've marked as junk.")
                        .font(Platform.isPhone ? .subheadline : .callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Move to Junk", systemImage: "xmark.bin") { model.perform(.junk, on: [thread]) }
                            .buttonStyle(.glassProminent).tint(.orange)
                            .lineLimit(1).fixedSize()
                        Button("It's Fine") { model.markNotJunk(thread) }
                            .buttonStyle(.glass)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .padding(Platform.isPhone ? 16 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: Platform.isPhone ? 20 : 14))
            .overlay(RoundedRectangle(cornerRadius: Platform.isPhone ? 20 : 14)
                .strokeBorder(Color.orange.opacity(Platform.isPhone ? 0.25 : 0.4)))
        }
    }
}
