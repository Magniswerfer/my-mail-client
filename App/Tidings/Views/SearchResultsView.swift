import MailEngine
import SwiftUI

/// As-you-type results with refinement facets (SPEC §7). Newest first; facets arrive with the hits.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let facets = model.facets {
                FacetBar(facets: facets)
            }
            ScrollViewReader { proxy in
            List(selection: $model.selectedHitID) {
                Section {
                    ForEach(model.searchHits, id: \.id) { hit in
                        SearchHitRow(hit: hit)
                            .id(hit.id)
                            .tag(hit.id)
                    }
                } header: {
                    HStack {
                        Text(summary)
                        Spacer()
                        Button("Save as Smart Folder…", systemImage: "folder.badge.plus") { model.isSavingSearch = true }
                            .buttonStyle(.borderless)
                            .help("Keep this search in the sidebar (⌘S)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !model.relatedMessages.isEmpty {
                    Section {
                        ForEach(model.relatedMessages, id: \.id) { message in
                            RelatedRow(message: message)
                                .tag(message.id ?? 0)
                        }
                    } header: {
                        Label("Related", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Mail that means the same, in other words (on-device)")
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.searchHits.isEmpty && model.relatedMessages.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
            .onChange(of: model.selectedHitID) { _, id in
                guard let id else { return }
                let ids = model.searchHits.map(\.id)
                var target = id
                if model.lastMoveDirection != 0, let i = ids.firstIndex(of: id), ids.indices.contains(i + model.lastMoveDirection) {
                    target = ids[i + model.lastMoveDirection]
                }
                model.lastMoveDirection = 0
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(target) }
            }
            }
        }
    }

    private var summary: String {
        let count = model.facets?.total ?? model.searchHits.count
        return String(localized: "\(count) results · \(String(format: "%.1f", model.searchMilliseconds)) ms")
    }
}

struct FacetBar: View {
    @Environment(AppModel.self) private var model
    let facets: SearchFacets

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(facets.categories, id: \.value) { facet in
                        if let category = MailCategory(rawValue: facet.value) {
                            chip(category.title, count: facet.count, symbol: category.symbol, tint: category.tint) {
                                model.addSearchFilter("category:\(category.rawValue)")
                            }
                        }
                    }
                    if facets.withAttachments > 0 {
                        chip(String(localized: "Attachments"), count: facets.withAttachments, symbol: "paperclip", tint: .secondary) {
                            model.addSearchFilter("has:attachment")
                        }
                    }
                    ForEach(facets.senders.prefix(4), id: \.value) { facet in
                        chip(facet.value, count: facet.count, symbol: "person", tint: .secondary) {
                            let token = facet.value.contains(" ") ? "from:\"\(facet.value)\"" : "from:\(facet.value)"
                            model.addSearchFilter(token)
                        }
                    }
                    ForEach(facets.years.prefix(4), id: \.value) { facet in
                        chip(facet.value, count: facet.count, symbol: "calendar", tint: .secondary) {
                            model.addSearchFilter("after:\(facet.value)-01-01 before:\((Int(facet.value) ?? 0) + 1)-01-01")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func chip(_ title: String, count: Int, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).lineLimit(1)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: hit.fromName ?? hit.fromAddress, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hit.fromName ?? hit.fromAddress).font(.headline.weight(.regular)).lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: hit.category.symbol).font(.caption).foregroundStyle(hit.category.tint)
                        .accessibilityLabel(hit.category.title)
                    Text(MailDate.short(hit.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(hit.subject).font(.subheadline).lineLimit(1)
                Text(hit.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A semantic match: no snippet to highlight, so sender, subject and preview.
struct RelatedRow: View {
    let message: StoredMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(message.senderDisplay).font(.headline).lineLimit(1)
                Spacer()
                Text(MailDate.short(message.date)).font(.caption).foregroundStyle(.secondary)
            }
            Text(message.subject).font(.subheadline).lineLimit(1)
            Text(message.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// ⌘S: name the current search and keep it in the sidebar.
struct SaveSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Smart Folder").font(.headline)
            Text(model.searchText).font(.callout.monospaced()).foregroundStyle(.secondary)
            TextField("Name", text: $name).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .macFrame(width: 380)
        .onAppear { name = model.searchText.split(separator: " ").filter { !$0.contains(":") }.joined(separator: " ").capitalized }
    }

    private func save() {
        model.saveCurrentSearch(named: name)
        dismiss()
    }
}
