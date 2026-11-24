import MailEngine
import SwiftUI

/// As-you-type results with refinement facets (SPEC §7). Newest first; facets arrive with the hits.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedHit: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if let facets = model.facets {
                FacetBar(facets: facets)
            }
            List(selection: $selectedHit) {
                Section {
                    ForEach(model.searchHits, id: \.id) { hit in
                        SearchHitRow(hit: hit)
                            .tag(hit.id)
                    }
                } header: {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.searchHits.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .onChange(of: selectedHit) { _, id in
            if let id { model.selectedThreadID = model.threadID(forMessage: id) }
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
