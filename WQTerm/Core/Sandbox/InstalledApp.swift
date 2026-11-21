import Foundation

/// Một ứng dụng đã cài trên thiết bị, đọc từ `/var/containers/Bundle/Application/`.
struct InstalledApp: Identifiable, Hashable {
    /// Bundle ID (`CFBundleIdentifier` trong Info.plist).
    let bundleID: String
    /// Tên hiển thị (`CFBundleDisplayName` → `CFBundleName` → tên file `.app`).
    let name: String
    let version: String
    let build: String
    /// Đường dẫn tới bundle `.app`.
    let bundleURL: URL
    /// Data container (`/var/mobile/Containers/Data/Application/<UUID>`), nếu xác định được.
    let dataContainerURL: URL?
    /// Đường dẫn icon trong bundle (nếu tìm thấy).
    let iconURL: URL?
    /// Dung lượng data container (byte), tính một lần khi quét app.
    let dataSizeBytes: UInt64

    var id: String { bundleID }

    /// Nhãn version dùng trong danh sách.
    var versionLabel: String { build.isEmpty ? version : "\(version) (\(build))" }

    /// Kích thước bundle (byte), tính khi cần — có thể chậm với app lớn.
    var bundleSizeBytes: UInt64 {
        FileSystem.directorySize(bundleURL)
    }

    /// Nhãn dung lượng data container.
    var dataSizeLabel: String {
        dataContainerURL == nil ? "—" : BuiltinShell.sizeLabel(dataSizeBytes)
    }
}

/// Trạng thái mount container của một app.
enum MountState: Equatable {
    case notMounted
    case mounted(URL)
    case failed(String)

    var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }
}
