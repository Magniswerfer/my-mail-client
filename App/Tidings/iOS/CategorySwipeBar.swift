#if os(iOS)
import MailEngine
import SwiftUI

/// iPhone: the Inbox's categories as one Liquid Glass bar at the bottom, in place of the tabs
/// above the list. Swipe it sideways to go to the next or previous category (the neighbours slide
/// in under your finger, like Safari's address bar); tap it to pick from all of them. New Message
/// sits beside it in the same glass group.
struct PhoneBottomBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if model.isInInbox {
                    CategorySwipeBar()
                        .glassEffectID("categories", in: glass)
                } else {
                    Spacer(minLength: 0)
                }
                Button { model.composeNew() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title3.weight(.medium))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("compose", in: glass)
                .accessibilityLabel("New Message")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

struct CategorySwipeBar: View {
    @Environment(AppModel.self) private var model
    /// How far the finger has dragged the bar sideways.
    @State private var drag: CGFloat = 0
    @State private var isPickerShown = false

    /// A swipe past this share of a category's width changes category (or a quick flick).
    private let threshold: CGFloat = 0.3
    /// How much of the bar the current category takes; the rest shows its neighbours' ends.
    private let pageShare: CGFloat = 0.58

    var body: some View {
        let tabs = model.categoryTabs
        let index = model.currentCategoryTab.flatMap(tabs.firstIndex) ?? 0
        GeometryReader { proxy in
            let width = proxy.size.width
            // Each category is narrower than the bar, so the previous and next one peek in at the
            // edges (their inner ends showing) and you can see where a swipe goes.
            let page = width * pageShare
            let inset = (width - page) / 2
            HStack(spacing: 0) {
                ForEach([-2, -1, 0, 1, 2], id: \.self) { step in
                    self.page(tabs.indices.contains(index + step) ? tabs[index + step] : nil,
                              alignment: step < 0 ? .trailing : step > 0 ? .leading : .center)
                        .frame(width: page, height: proxy.size.height)
                        .opacity(step == 0 ? 1 : 0.45)
                }
            }
            .offset(x: inset - 2 * page + drag)
            .frame(width: width, alignment: .leading)
            .mask {
                // Fade the peeking neighbours out towards the bar's ends.
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        // Resist past the first and last category.
                        let dx = value.translation.width
                        let atEdge = (dx > 0 && index == 0) || (dx < 0 && index == tabs.count - 1)
                        drag = atEdge ? dx / 4 : dx
                    }
                    .onEnded { value in
                        let predicted = value.predictedEndTranslation.width
                        let step = (drag < -page * threshold || predicted < -page * 0.6) ? 1
                                 : (drag > page * threshold || predicted > page * 0.6) ? -1 : 0
                        guard step != 0, tabs.indices.contains(index + step) else {
                            withAnimation(.snappy) { drag = 0 }
                            return
                        }
                        // Slide the neighbour to the middle, then switch with the strip recentred.
                        withAnimation(.snappy(duration: 0.22)) { drag = -CGFloat(step) * page } completion: {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                model.selection = tabs[index + step].selection
                                drag = 0
                            }
                        }
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
            )
            .onTapGesture { isPickerShown = true }
        }
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.currentCategoryTab.map { describe($0).title } ?? "")
        .accessibilityValue(String(localized: "Category \(index + 1) of \(tabs.count)"))
        .accessibilityHint("Swipe left or right to change category, or double-tap to choose one.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.cycleCategory(1)
            case .decrement: model.cycleCategory(-1)
            @unknown default: break
            }
        }
        .confirmationDialog("Categories", isPresented: $isPickerShown, titleVisibility: .hidden) {
            ForEach(tabs) { tab in
                Button(describe(tab).title) { model.selection = tab.selection }
            }
        }
    }

    @ViewBuilder private func page(_ tab: CategoryTab?, alignment: Alignment) -> some View {
        if let tab {
            let (title, symbol, tint) = describe(tab)
            let inbox = model.threads
            let unread = model.unreadCount(for: tab, inbox: inbox)
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                if unread > 0, tab == model.currentCategoryTab {
                    Text("\(unread)").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            Color.clear
        }
    }

    private func describe(_ tab: CategoryTab) -> (title: String, symbol: String, tint: Color) {
        switch tab {
        case .all: (String(localized: "All"), "tray", .accentColor)
        case .builtIn(let c): (c.title, c.symbol, c.tint)
        case .ai(let id): (model.aiCategory(id: id)?.name ?? "", model.aiCategory(id: id)?.symbol ?? "sparkles", .indigo)
        }
    }
}
#endif
