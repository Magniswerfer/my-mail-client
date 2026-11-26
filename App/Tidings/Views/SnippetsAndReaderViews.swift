import MailEngine
import SwiftUI

// MARK: - Snippets

struct SnippetsSettings: View {
    @State private var snippets = SnippetStore.all

    var body: some View {
        Form {
            Section {
                ForEach($snippets) { $snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(";").foregroundStyle(.secondary)
                            TextField("keyword", text: $snippet.keyword)
                                .onChange(of: snippet.keyword) { save() }
                            Spacer()
                            Button(role: .destructive) {
                                snippets.removeAll { $0.id == snippet.id }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                        TextField("Text", text: $snippet.text, axis: .vertical)
                            .lineLimit(2...6)
                            .onChange(of: snippet.text) { save() }
                    }
                }
                Button("New Snippet", systemImage: "plus") {
                    snippets.append(Snippet(keyword: "", text: ""))
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Type ;keyword and a space in a message to insert the text. {first} and {name} are the first recipient, {me} is you, {date} is today.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        SnippetStore.all = snippets.map {
            var s = $0
            s.keyword = s.keyword.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";")).lowercased()
            return s
        }
    }
}

// MARK: - Reader mode

/// Read Later's reader mode: the message as clean text, sized for reading.
struct ReaderModeText: View {
    let text: String

    var body: some View {
        // The message's own words: quoted history and signature cut, wrapped lines joined.
        VStack(alignment: .leading, spacing: 14) {
            Text("\(ReadingText.minutes(text)) min read")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(ReadingText.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(.title3, design: .serif))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
