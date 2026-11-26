#if os(iOS)
import MailEngine
import SwiftUI

/// iPhone: the Inbox's categories as one Liquid Glass bar at the bottom, in place of the tabs
/// above the list. Swipe it sideways to go to the next or previous category (the neighbours slide
/// in under your finger, like Safari's address bar), or tap its left or right side to step one;
/// hold it to pick from all of them. New Message
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
    @State private var isPickerShown = false
    /// Unread conversations per category (by tab id), recounted when the mail changes: not when
    /// you change category, so a label looks the same before and after it's the selected one.
    @State private var unread: [String: Int] = [:]

    var body: some View {
        let tabs = model.categoryTabs
        let index = model.currentCategoryTab.flatMap(tabs.firstIndex) ?? 0
        let items = tabs.map { tab in
            let (title, symbol, tint) = describe(tab)
            return CategoryBarItem(id: tab.id, title: title, symbol: symbol, tint: tint, unread: unread[tab.id] ?? 0)
        }
        CategoryPager(items: items, index: index,
                      select: { if tabs.indices.contains($0) { model.selection = tabs[$0].selection } },
                      doubleTap: {
                          // Back to where the Inbox starts.
                          UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                          model.goToInbox()
                      },
                      hold: {
                          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                          isPickerShown = true
                      })
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
            .accessibilityAction { isPickerShown = true }
            // Hold: every category in a glass popover rising from the bar.
            .popover(isPresented: $isPickerShown, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                CategoryPickerList(tabs: tabs, current: model.currentCategoryTab, unread: unread,
                                   describe: describe,
                                   pick: { tab in
                                       isPickerShown = false
                                       model.selection = tab.selection
                                   },
                                   newCategory: {
                                       isPickerShown = false
                                       model.editingAICategory = AICategoryEditing(category: AICategory(name: "", description: ""),
                                                                                   isNew: true)
                                   })
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: model.revision, initial: true) { recount() }
            .onChange(of: model.aiCategories.map(\.id)) { recount() }
    }

    /// Counts every category from the whole Inbox (`model.threads` only holds the one on screen).
    private func recount() {
        let inbox = (try? model.store.threads(mailbox: "INBOX", accountID: model.inboxAccountID, ownAddresses: model.ownAddresses)) ?? []
        var counts: [String: Int] = [:]
        for tab in model.categoryTabs { counts[tab.id] = model.unreadCount(for: tab, inbox: inbox) }
        if counts != unread { unread = counts }
    }

    private func describe(_ tab: CategoryTab) -> (title: String, symbol: String, tint: Color) {
        switch tab {
        case .all: (String(localized: "All"), "tray", .accentColor)
        case .builtIn(let c): (c.title, c.symbol, c.tint)
        case .ai(let id): (model.aiCategory(id: id)?.name ?? "", model.aiCategory(id: id)?.symbol ?? "sparkles", .indigo)
        }
    }
}

/// The popover from holding the bar: each category with its icon and colour, unread count and a
/// tick on the current one, then a way to describe a new one. Built-in categories, yours and
/// All are separate groups.
private struct CategoryPickerList: View {
    let tabs: [CategoryTab]
    let current: CategoryTab?
    let unread: [String: Int]
    let describe: (CategoryTab) -> (title: String, symbol: String, tint: Color)
    let pick: (CategoryTab) -> Void
    let newCategory: () -> Void

    private var groups: [[CategoryTab]] {
        let builtIn = tabs.filter { if case .builtIn = $0 { true } else { false } }
        let yours = tabs.filter { if case .ai = $0 { true } else { false } }
        let all = tabs.filter { $0 == .all }
        return [builtIn, yours, all].filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { number, group in
                    if number > 0 { Divider().padding(.vertical, 6).padding(.horizontal, 12) }
                    ForEach(group) { tab in row(tab) }
                }
                Divider().padding(.vertical, 6).padding(.horizontal, 12)
                Button(action: newCategory) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").frame(width: 26)
                        Text("New AI Category…")
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
        }
        .frame(width: 270)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ tab: CategoryTab) -> some View {
        let (title, symbol, tint) = describe(tab)
        let count = unread[tab.id] ?? 0
        let isCurrent = tab == current
        return Button { pick(tab) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                Text(title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if count > 0 {
                    Text("\(count)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .opacity(isCurrent ? 1 : 0)
            }
            // No filled highlight (as in the system's own menus): the tick, the bolder name and
            // the coloured icon mark the current one. A fill fought the popover's rounded corners.
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// What one label on the strip shows. Nothing in it depends on which category is selected.
private struct CategoryBarItem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let unread: Int
}

/// Where the strip really is on screen right now (mid-animation too), so a finger that catches it
/// while it settles picks it up where it is.
@MainActor private final class PresentedOffset {
    var value: CGFloat = 0
}

/// The strip of labels with its drag, flick and snap. Reads nothing from the model, so a drag
/// only redraws this; the selection changes once, when the strip has landed.
private struct CategoryPager: View {
    let items: [CategoryBarItem]
    /// The selected category.
    let index: Int
    let select: (Int) -> Void
    let doubleTap: () -> Void
    let hold: () -> Void

    private struct DragStart {
        /// The strip's offset and the category in the middle when the finger took hold.
        var offset: CGFloat
        var index: Int
        /// The translation the gesture began with (its minimum distance), so the strip doesn't
        /// jump by that much when the drag is recognised.
        var origin: CGFloat
    }

    /// The strip's offset in points while you drag it or it settles. Nil at rest: then the
    /// selected category's centre.
    @State private var offset: CGFloat?
    @State private var drag: DragStart?
    /// Counts drags and landings, so a landing that was caught again doesn't select its category.
    @State private var landing = 0
    /// The category the strip is springing towards, until it lands: taps in quick succession
    /// step on from here, not from the one still selected.
    @State private var heading: Int?
    /// When the middle was last tapped, to tell a double tap there (no recogniser for it: that
    /// would hold back every single tap on the sides until it gave up).
    @State private var lastMiddleTap: Date?
    /// Each label's natural width, measured once (and again when its text changes).
    @State private var widths: [String: CGFloat] = [:]
    @State private var presented = PresentedOffset()
    @State private var feedback = UISelectionFeedbackGenerator()
    @GestureState private var isTouching = false

    // Layout
    /// The same gap between every two neighbouring labels, whatever their widths.
    private let gap: CGFloat = 26
    /// How much of a neighbour must still show beside the widest label.
    private let peek: CGFloat = 22

    // Feel
    /// Slower than this (pt/s) at release is a drag: it snaps to the nearest category. Faster
    /// goes on to the next one, so a light swipe is enough.
    private let flickSpeed: CGFloat = 200
    /// A flick only carries past the next category with speed above this (pt/s) …
    private let momentumFloor: CGFloat = 600
    /// … and then travels this many points per pt/s above it, so a quick flick runs through a
    /// few categories.
    private let momentumReach: CGFloat = 0.16
    /// One flick never passes more categories than this.
    private let maxFlickSteps = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let centres = centres()
            let rest = centres.indices.contains(index) ? centres[index] : 0
            CategoryStrip(items: items, centres: centres, offset: offset ?? rest, reach: width * 0.45,
                          maxLabelWidth: max(width - 2 * (gap + peek), 60), presented: presented,
                          measured: { id, w in if widths[id] != w { widths[id] = w } },
                          crossed: { if offset != nil { feedback.selectionChanged() } })
                // Picked from the list or with VoiceOver: glide there. (After a swipe the strip is
                // already there, so this moves nothing.)
                .animation(.snappy(duration: 0.35), value: index)
                .frame(width: width, height: proxy.size.height)
                .mask {
                    // The peeking neighbours fade out towards the bar's ends.
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                           .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .contentShape(.capsule)
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .updating($isTouching) { _, touching, _ in touching = true }
                        .onChanged { value in
                            let start: DragStart
                            if let drag {
                                start = drag
                            } else {
                                // Catching it mid-settle takes it from where it is on screen.
                                let from = offset == nil ? rest : presented.value
                                start = DragStart(offset: from, index: nearest(to: from, in: centres),
                                                  origin: value.translation.width)
                                drag = start
                                landing += 1
                                feedback.prepare()
                            }
                            let x = banded(start.offset - (value.translation.width - start.origin),
                                           in: centres, dimension: width / 2)
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { offset = x }
                        }
                        .onEnded { value in
                            guard let start = drag else { return }
                            drag = nil
                            land(from: start, velocity: -value.velocity.width, centres: centres)
                        }
                )
                // Tap a side: the category that way. Double tap the middle: back to Primary.
                // Hold (without moving): every category.
                .gesture(SpatialTapGesture().onEnded { tap in
                    tapped(at: tap.location.x, width: width, centres: centres)
                })
                .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 5, perform: hold)
                .onChange(of: isTouching) { _, touching in
                    // The system took the touch away (no end event): settle where it is.
                    if !touching, let start = drag {
                        drag = nil
                        land(from: start, velocity: 0, centres: centres)
                    }
                }
        }
    }

    /// Each label's centre along the strip: widths laid end to end with the same gap between.
    private func centres() -> [CGFloat] {
        var result: [CGFloat] = []
        var leading: CGFloat = 0
        for item in items {
            let w = widths[item.id] ?? 110
            result.append(leading + w / 2)
            leading += w + gap
        }
        return result
    }

    private func nearest(to x: CGFloat, in centres: [CGFloat]) -> Int {
        centres.indices.min { abs(centres[$0] - x) < abs(centres[$1] - x) } ?? 0
    }

    /// Past the first and last category the strip resists more the further you pull (the same
    /// curve as a scroll view's edge).
    private func banded(_ x: CGFloat, in centres: [CGFloat], dimension: CGFloat) -> CGFloat {
        guard let first = centres.first, let last = centres.last, dimension > 0 else { return x }
        func band(_ over: CGFloat) -> CGFloat { (1 - 1 / (over * 0.55 / dimension + 1)) * dimension }
        if x < first { return first - band(first - x) }
        if x > last { return last + band(x - last) }
        return x
    }

    /// Finger up: pick the category to land on and spring there, carrying the finger's speed.
    private func land(from start: DragStart, velocity: CGFloat, centres: [CGFloat]) {
        guard !centres.isEmpty else { offset = nil; return }
        let x = offset ?? start.offset
        // A released drag snaps to the nearest. Only speed above the floor glides further.
        let glide = max(abs(velocity) - momentumFloor, 0) * momentumReach * (velocity < 0 ? -1 : 1)
        var target = nearest(to: x + glide, in: centres)
        if abs(velocity) > flickSpeed {
            // A flick always goes on to the next category the way it was moving.
            if velocity > 0, let next = centres.firstIndex(where: { $0 > x + 1 }) { target = max(target, next) }
            if velocity < 0, let previous = centres.lastIndex(where: { $0 < x - 1 }) { target = min(target, previous) }
        }
        target = min(max(target, start.index - maxFlickSteps), start.index + maxFlickSteps)
        target = min(max(target, 0), centres.count - 1)
        settle(on: target, from: x, velocity: velocity, steps: abs(target - start.index), centres: centres)
    }

    /// A tap: on either side of the label in the middle it steps that way (again and again, as
    /// fast as you tap); twice in the middle goes back to Primary.
    private func tapped(at x: CGFloat, width: CGFloat, centres: [CGFloat]) {
        guard !centres.isEmpty, drag == nil else { return }
        let current = min(max(heading ?? index, 0), centres.count - 1)
        let label = min(widths[items[current].id] ?? 110, max(width - 2 * (gap + peek), 60))
        let side = max(label / 2 + 4, width * 0.2)
        let fromMiddle = x - width / 2
        if abs(fromMiddle) > side {
            lastMiddleTap = nil
            let target = min(max(current + (fromMiddle > 0 ? 1 : -1), 0), centres.count - 1)
            guard target != current else { return }
            feedback.prepare()
            settle(on: target, from: offset == nil ? centres[index] : presented.value, velocity: 0, steps: 1,
                   centres: centres)
        } else if let last = lastMiddleTap, Date.now.timeIntervalSince(last) < 0.35 {
            lastMiddleTap = nil
            doubleTap()
        } else {
            lastMiddleTap = .now
        }
    }

    /// Spring to a category, carrying the finger's speed, and select it once it has landed.
    private func settle(on target: Int, from x: CGFloat, velocity: CGFloat, steps: Int, centres: [CGFloat]) {
        landing += 1
        let id = landing
        let selected = index
        heading = target
        let distance = centres[target] - x
        // A little longer for a longer trip. No bounce: it must come to rest on the category.
        let duration = 0.36 + 0.05 * Double(min(steps, maxFlickSteps))
        let animation: Animation
        if abs(distance) > 0.5, velocity != 0 {
            // The spring starts at the finger's speed (as a share of the trip per second). Capped
            // where a no-bounce spring would visibly overshoot the category.
            let omega = 2 * Double.pi / duration
            let relative = min(max(Double(velocity / distance), -omega), 1.6 * omega)
            animation = .interpolatingSpring(duration: duration, bounce: 0, initialVelocity: relative)
        } else {
            // A tap (or nothing left to travel). Retargeting a spring keeps its speed, so quick
            // taps run on smoothly from one category to the next.
            animation = .spring(duration: duration, bounce: 0)
        }
        withAnimation(animation) {
            offset = centres[target]
        } completion: {
            // Landed (unless a finger or tap took it on): now select it, once. The strip is
            // already exactly where the selected category rests, so nothing on it moves.
            guard landing == id else { return }
            heading = nil
            offset = nil
            if target != selected { select(target) }
        }
    }
}

/// The labels, drawn for one offset. Animatable, so while the strip springs every frame is laid
/// out from the in-between offset: each label fades by where it really is, and the tick comes as
/// each category passes the middle. Only offsets and opacities change from frame to frame.
private struct CategoryStrip: View, @preconcurrency Animatable {
    let items: [CategoryBarItem]
    let centres: [CGFloat]
    var offset: CGFloat
    /// The distance from the middle at which a label is fully dimmed.
    let reach: CGFloat
    let maxLabelWidth: CGFloat
    let presented: PresentedOffset
    let measured: (String, CGFloat) -> Void
    let crossed: () -> Void

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    var body: some View {
        let _ = (presented.value = offset)
        let under = centres.indices.min { abs(centres[$0] - offset) < abs(centres[$1] - offset) } ?? 0
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let distance = (centres.indices.contains(i) ? centres[i] : 0) - offset
                CategoryBarLabel(item: item)
                    .equatable()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured(item.id, $0) }
                    .frame(maxWidth: maxLabelWidth)
                    .opacity(1 - min(abs(distance) / max(reach, 1), 1) * 0.55)
                    .offset(x: distance)
            }
        }
        .onChange(of: under) { crossed() }
    }
}

private struct CategoryBarLabel: View, Equatable {
    let item: CategoryBarItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol).foregroundStyle(item.tint)
            Text(item.title).font(.body.weight(.semibold)).lineLimit(1)
            if item.unread > 0 {
                Text("\(item.unread)").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
