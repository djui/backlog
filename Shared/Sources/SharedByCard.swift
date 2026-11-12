import BackLogCore
import SwiftUI

/// Who shared an item and your note and tags: what you entered yourself, set apart from the page's
/// own description.
struct SharedByCard: View {
    let item: Item

    var body: some View {
        let note = Tags.strip(item.note)
        if !item.sharedBy.isEmpty || !note.isEmpty {
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
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// An item's tags as bubbles you can add to and remove from, saved as you go.
struct ItemTagsEditor: View {
    @Bindable var item: Item
    @Environment(\.modelContext) private var context

    var body: some View {
        TagField(tags: Binding(
            get: { item.tags },
            set: { new in
                let added = new.filter { !item.hasTag($0) }
                item.tags = new
                Recents.remember(tags: added)
                item.rebuildSearchText()
                try? context.save()
            }
        ))
    }
}
