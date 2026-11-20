import SwiftUI

/// Một dòng trong danh sách file.
struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(item.sizeLabel)
                    Text("•")
                    Text(item.modified, format: .dateTime.day().month().hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        if item.isDirectory { return "folder.fill" }
        return PreviewRouter.kind(for: item.url).systemImage
    }
}
