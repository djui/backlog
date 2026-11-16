import BackLogCore
import SwiftUI

extension Color {
    /// Orange for text: #A34A00 in light mode (about 5:1 on white and on the tag fill), system
    /// orange in dark mode. System orange itself is only about 2.2:1 on white.
    static let tagInk: Color = {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemOrange : NSColor(srgbRed: 0.64, green: 0.29, blue: 0, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.64, green: 0.29, blue: 0, alpha: 1)
        })
        #endif
    }()

    /// The fill behind tag text.
    static let tagFill = Color.orange.opacity(0.18)
}

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
        if let remove {
            // The whole bubble removes the tag: the × alone is far too small to tap.
            Button(action: remove) {
                bubble(removable: true)
                    #if os(iOS)
                    .frame(minHeight: 44)
                    #endif
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        } else {
            bubble(removable: false)
        }
    }

    private func bubble(removable: Bool) -> some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
            if removable { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.tagFill, in: Capsule())
        .foregroundStyle(Color.tagInk)
    }
}

/// A field to add tags (return, comma or space adds), then the chosen tags as bubbles, then
/// previous tags to tap. The field stays put at the top so it doesn't jump as tags are picked.
struct TagField: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            if !tags.isEmpty {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        TagBubble(tag: tag) { tags.removeAll { $0 == tag } }
                    }
                }
            }
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
