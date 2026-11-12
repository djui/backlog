import BackLogCore
import SwiftUI

/// Lays out views left to right, wrapping onto new lines — for tag bubbles and suggestion chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Tappable suggestions under a text field.
struct SuggestionChips: View {
    let values: [String]
    let pick: (String) -> Void

    var body: some View {
        if !values.isEmpty {
            FlowLayout {
                ForEach(values, id: \.self) { value in
                    Button(value) { pick(value) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                }
            }
        }
    }
}

/// A tag shown as a bubble.
struct TagBubble: View {
    let tag: String
    var remove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(tag)")
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.orange.opacity(0.18), in: Capsule())
        .foregroundStyle(Color.orange)
    }
}

/// Tags as bubbles with a field to add more (return adds) and previous tags to tap.
struct TagField: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        TagBubble(tag: tag) { tags.removeAll { $0 == tag } }
                    }
                }
            }
            TextField("Add tag", text: $draft)
                .onSubmit(commit)
                .onChange(of: draft) { _, new in
                    // A comma or space after a word also makes it a tag.
                    if new.hasSuffix(",") || (new.hasSuffix(" ") && !new.trimmingCharacters(in: .whitespaces).isEmpty) { commit() }
                }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                #endif
            SuggestionChips(values: Suggestions.rank(Recents.tags, typed: draft, excluding: tags)) { tag in
                tags.append(tag)
                draft = ""
            }
        }
    }

    private func commit() {
        let tag = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).replacingOccurrences(of: " ", with: "-")
        draft = ""
        guard !tag.isEmpty, !tags.contains(where: { $0.lowercased() == tag.lowercased() }) else { return }
        tags.append(tag)
    }
}
