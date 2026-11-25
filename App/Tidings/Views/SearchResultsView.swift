import MailEngine
import SwiftUI

/// As-you-type results with refinement facets (SPEC §7). Newest first; facets arrive with the hits.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScopeBar()
            if let facets = model.facets {
                FacetBar(facets: facets)
            }
            ScrollViewReader { proxy in
            List(selection: $model.selectedHitID) {
                if let contact = model.searchContact {
                    ContactCard(contact: contact)
                        .selectionDisabled()
                }
                Section {
                    ForEach(model.searchHits, id: \.id) { hit in
                        SearchHitRow(hit: hit)
                            .id(hit.id)
                            .tag(hit.id)
                    }
                } header: {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.relatedHits.isEmpty {
                    Section {
                        ForEach(model.relatedHits, id: \.id) { hit in
                            SearchHitRow(hit: hit)
                                .id(hit.id)
                                .tag(hit.id)
                        }
                    } header: {
                        Label("Related", systemImage: "sparkle.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Close in meaning, found with on-device embeddings")
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.searchHits.isEmpty && model.relatedHits.isEmpty && model.searchContact == nil {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
            .onChange(of: model.selectedHitID) { _, id in
                guard let id else { return }
                let ids = model.searchHits.map(\.id) + model.relatedHits.map(\.id)
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

/// "In Reklamer · Search Everywhere": what a scoped search covers, and the key that widens it.
struct ScopeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.searchScope != nil || model.searchEverywhere {
            HStack(spacing: 8) {
                Image(systemName: model.searchEverywhere ? "globe" : "scope").foregroundStyle(.secondary)
                Text(model.searchEverywhere ? String(localized: "Searching all mail")
                                            : String(localized: "Searching in \(model.currentMailboxTitle)"))
                    .lineLimit(1)
                Spacer()
                Button(model.searchEverywhere ? String(localized: "Only \(model.currentMailboxTitle)")
                                              : String(localized: "Search Everywhere")) {
                    model.toggleSearchEverywhere()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("⌥⌘F")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

/// The person a search seems to mean: their mail in one click, or who they are.
struct ContactCard: View {
    @Environment(AppModel.self) private var model
    let contact: ContactHit

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.name ?? contact.address, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name ?? contact.address).font(.headline)
                Text(contact.address).font(.caption).foregroundStyle(.secondary)
                Text(contact.messageCount == 1 ? String(localized: "1 message from them")
                                               : String(localized: "\(contact.messageCount) messages from them"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("All Their Mail") { model.searchAll(from: contact) }
                .buttonStyle(.glass)
            Button {
                model.contactAddress = contact.address
                model.isContactPanelShown = true
            } label: {
                Label("Contact Info", systemImage: "person.crop.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .help("Who this is (⌃⌘I)")
        }
        .padding(.vertical, 6)
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
