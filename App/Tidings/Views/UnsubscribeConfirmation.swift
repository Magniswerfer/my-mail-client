import MailEngine
import SwiftUI

/// "Unsubscribe from Shop?": always asked, saying what will happen.
struct UnsubscribeConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Only the window in front shows it (the Senders sheet when it's open).
    let isActive: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.unsubscribeCandidate.map { String(localized: "Unsubscribe from \($0.name)?") } ?? "",
            isPresented: Binding(get: { isActive && model.unsubscribeCandidate != nil },
                                 set: { if !$0 { model.unsubscribeCandidate = nil } }),
            titleVisibility: .visible,
            presenting: model.unsubscribeCandidate
        ) { request in
            Button("Unsubscribe") { model.confirmUnsubscribe(request, archiveInbox: false) }
                .keyboardShortcut(.defaultAction)
            if request.inboxCount > 0 {
                Button(request.inboxCount == 1 ? String(localized: "Unsubscribe and Mark 1 Done")
                                               : String(localized: "Unsubscribe and Mark \(request.inboxCount) Done")) {
                    model.confirmUnsubscribe(request, archiveInbox: true)
                }
            }
            Button("Cancel", role: .cancel) { model.unsubscribeCandidate = nil }
        } message: { request in
            Text(request.explanation)
        }
    }
}
