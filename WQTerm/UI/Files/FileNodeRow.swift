import SwiftUI

/// Một dòng file trong tab Files.
struct FileNodeRow: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.systemImage)
                .font(.title3)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    if node.isSymlink {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text(node.sizeLabel)
                    if !node.isDirectory {
                        Text("•")
                        Text(PreviewRouter.kind(for: node.url).displayName)
                    }
                    if node.modified.timeIntervalSince1970 > 0 {
                        Text("•")
                        Text(node.modified, format: .dateTime.day().month().hour().minute())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
