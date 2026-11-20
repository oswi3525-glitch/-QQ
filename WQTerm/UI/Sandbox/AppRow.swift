import SwiftUI
import UIKit

/// Hàng hiển thị một app đã cài: icon, tên, bundle ID, version, trạng thái mount
/// và nút "Dump IPA" (Module 2).
struct AppRow: View {
    let app: InstalledApp
    let state: MountState
    let isDumping: Bool
    let onDump: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(app.versionLabel)
                    Text("•")
                    stateBadge
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isDumping {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: onDump) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.body)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Dump IPA cho \(app.name)")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        if let iconURL = app.iconURL, let image = UIImage(contentsOfFile: iconURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .overlay {
                    Image(systemName: "app.dashed")
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .mounted:
            Label("đã mount", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("lỗi mount", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notMounted:
            Label("chưa mount", systemImage: "circle.dashed")
        }
    }
}
