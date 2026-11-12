import BackLogCore
import SwiftUI

/// Who shared an item and your note and tags: what you entered yourself, set apart from the page's
/// own description.
struct SharedByCard: View {
    let item: Item

    var body: some View {
        let tags = Tags.parse(item.note)
        let note = Tags.strip(item.note)
        if !item.sharedBy.isEmpty || !note.isEmpty || !tags.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Text(String(item.sharedBy.first ?? "✎").uppercased())
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    if !item.sharedBy.isEmpty {
                        Text("From ").foregroundStyle(.secondary) + Text(item.sharedBy).bold()
                            + Text(" · " + item.addedAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    }
                    if !note.isEmpty {
                        Text("“\(note)”").font(.body).textSelection(.enabled)
                    }
                    if !tags.isEmpty {
                        FlowLayout { ForEach(tags, id: \.self) { TagBubble(tag: $0) } }
                    }
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
