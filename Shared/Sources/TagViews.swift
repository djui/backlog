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
        #if os(macOS)
        TokenTagField(tags: $tags)
        #else
        stacked
        #endif
    }

    private var stacked: some View {
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

#if os(macOS)
/// Mac: the chosen tags sit inside the field as bubbles, like recipients in Mail. Earlier tags
/// drop down below the field only while it has focus, instead of always taking a row of their
/// own. Up and down move through them, return picks one, escape closes the list, and delete in
/// an empty field removes the last tag.
struct TokenTagField: View {
    @Binding var tags: [String]
    @State private var draft = ""
    @State private var highlighted: Int?
    @State private var listClosed = false
    @FocusState private var focused: Bool
    @State private var fieldHeight: CGFloat = 0
    /// Watches for backspace in an empty field, which the text field itself swallows.
    @State private var backspaceMonitor: Any?

    private var suggestions: [String] {
        guard focused, !listClosed else { return [] }
        return Suggestions.rank(Recents.tags, typed: draft, excluding: tags, limit: 6)
    }

    var body: some View {
        let shown = suggestions
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                TagBubble(tag: tag) { tags.removeAll { $0 == tag } }
            }
            TextField(tags.isEmpty ? "Add tag" : "Add another", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(minWidth: 120)
                .padding(.vertical, 3)
                .accessibilityLabel("Add tag")
                .onSubmit {
                    if let highlighted, shown.indices.contains(highlighted) { add(shown[highlighted]) } else { commit() }
                    focused = true
                }
                .onChange(of: draft) { _, new in
                    listClosed = false
                    // Typing narrows the list, so the best match is ready for return.
                    highlighted = new.isEmpty ? nil : 0
                    // A comma or space after a word also makes it a tag.
                    if new.hasSuffix(",") || (new.hasSuffix(" ") && !new.trimmingCharacters(in: .whitespaces).isEmpty) { commit() }
                }
                .onKeyPress(.downArrow) { move(1, in: shown) }
                .onKeyPress(.upArrow) { move(-1, in: shown) }
                .onKeyPress(.escape) {
                    guard !shown.isEmpty else { return .ignored }
                    listClosed = true
                    return .handled
                }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
        }
        // A click anywhere in the box, not just on the text, starts typing.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
        .overlay(alignment: .topLeading) {
            if !shown.isEmpty {
                SuggestionList(values: shown, highlighted: highlighted) { add($0); focused = true }
                    .offset(y: fieldHeight + 4)
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { highlighted = nil }
            watchBackspace(isFocused)
        }
        .onDisappear { watchBackspace(false) }
        // Lifts the list above whatever comes below the field.
        .zIndex(1)
    }

    private func watchBackspace(_ on: Bool) {
        if let backspaceMonitor { NSEvent.removeMonitor(backspaceMonitor) }
        backspaceMonitor = nil
        guard on else { return }
        backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 51 is the backspace key; with modifiers it means something else (⌘⌫ and so on).
            guard event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  draft.isEmpty, !tags.isEmpty else { return event }
            tags.removeLast()
            return nil
        }
    }

    private func move(_ step: Int, in shown: [String]) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        listClosed = false
        let next = (highlighted ?? (step > 0 ? -1 : shown.count)) + step
        highlighted = min(max(next, 0), shown.count - 1)
        return .handled
    }

    private func add(_ tag: String) {
        if !tags.contains(where: { $0.lowercased() == tag.lowercased() }) { tags.append(tag) }
        draft = ""
        highlighted = nil
    }

    private func commit() {
        let tag = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).replacingOccurrences(of: " ", with: "-")
        draft = ""
        guard !tag.isEmpty else { return }
        add(tag)
    }
}

/// The drop-down under the Mac tag field: earlier tags, the highlighted one filled with the accent.
private struct SuggestionList: View {
    let values: [String]
    let highlighted: Int?
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                Button { pick(value) } label: {
                    Text("#\(value)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(index == highlighted ? Color.white : Color.primary)
                        .background(index == highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add tag \(value)")
            }
        }
        .padding(4)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)) }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
#endif
