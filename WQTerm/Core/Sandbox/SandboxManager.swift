import Foundation

/// Quản lý sandbox escape (Module 1 — AUTO WORSE_QUERY).
///
/// Nhiệm vụ:
/// 1. Kiểm tra phiên bản iOS có nằm trong khoảng khai thác được không.
/// 2. Quét `/var/containers/Bundle/Application/` để lấy danh sách app đã cài
///    (tên, bundle ID, version, icon).
/// 3. Tạo symlink container của từng app vào `Documents/_sandbox/<bundle-id>/`
///    để Terminal và tab Files duyệt được như thư mục thường.
///
/// Mọi thao tác đọc đều **best-effort**: thiếu quyền thì ghi nhận lỗi và trả về
/// danh sách rỗng thay vì crash (yêu cầu Module 1).
final class SandboxManager: ObservableObject {
    static let shared = SandboxManager()

    /// Danh sách app đã cài (rỗng nếu chưa quét hoặc không đủ quyền).
    @Published private(set) var apps: [InstalledApp] = []
    /// Bundle ID → trạng thái mount.
    @Published private(set) var mountStates: [String: MountState] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var isMounting = false
    @Published private(set) var lastScanDate: Date?
    /// Lỗi gần nhất — hiển thị banner mềm trong UI, không chặn app.
    @Published private(set) var lastError: String?
    /// Tiến trình dạng text cho UI (đang quét / đang mount app nào).
    @Published private(set) var progressText: String?

    let fileManager = FileManager.default
    /// Các tác vụ nặng (quét, mount, dump) chạy ở đây — không chặn main thread.
    let workQueue = DispatchQueue(label: "com.wqterm.sandbox", qos: .userInitiated)

    private init() {}

    /// Thư mục gốc chứa symlink tới container các app khác.
    var sandboxRoot: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("_sandbox", isDirectory: true)
    }

    // MARK: - Phiên bản iOS

    /// `true` nếu iOS hiện tại nằm trong khoảng worse_query còn hiệu lực.
    var isSupportedOS: Bool {
        switch IOSCompatibility.shared.status {
        case .fullSupport, .partialSupport: return true
        case .patched, .unknown: return false
        }
    }

    var compatibilitySummary: String {
        "iOS \(IOSCompatibility.shared.version.description) — "
            + IOSCompatibility.shared.status.displayName
    }

    // MARK: - Bootstrap (gọi khi app khởi động)

    /// Quét app + mount toàn bộ container. Chạy nền, không chặn UI.
    ///
    /// Bỏ qua nếu vừa quét trong 60 giây trước đó, tránh quét lặp khi chuyển tab.
    func bootstrap(force: Bool = false) {
        if !force, let last = lastScanDate,
           Date().timeIntervalSince(last) < 60, !apps.isEmpty {
            return
        }
        guard !isScanning, !isMounting else { return }

        DispatchQueue.main.async {
            self.isScanning = true
            self.lastError = nil
            self.progressText = "Đang quét ứng dụng đã cài…"
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            let found = self.scanInstalledAppsSynchronously()
            DispatchQueue.main.async {
                self.apps = found
                self.isScanning = false
                self.lastScanDate = Date()
                self.progressText = nil
                if found.isEmpty {
                    self.lastError = "Không đọc được /var/containers/Bundle/Application. "
                        + "Cần App Group entitlement và iOS còn khai thác được worse_query."
                }
                self.mountAllContainers()
            }
        }
    }

    // MARK: - Quét app đã cài

    /// Quét đồng bộ, chạy trên `workQueue`. Không bao giờ throw.
    func scanInstalledAppsSynchronously() -> [InstalledApp] {
        let bundleRoots = [
            "/var/containers/Bundle/Application",
            "/private/var/containers/Bundle/Application",
            "/var/mobile/Containers/Bundle/Application"
        ]

        var bundleDirectories: [URL] = []
        for path in bundleRoots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            SandboxAccess.grantRead(to: path)
            let children = (try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                                options: [])) ?? []
            bundleDirectories.append(contentsOf: children)
            if !bundleDirectories.isEmpty { break }
        }

        guard !bundleDirectories.isEmpty else { return [] }

        let dataContainers = dataContainersByBundleID()
        var result: [InstalledApp] = []

        for directory in bundleDirectories {
            SandboxAccess.grantRead(to: directory.path)
            let bundles = (try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [])) ?? []
            for bundle in bundles where bundle.pathExtension == "app" {
                SandboxAccess.grantRead(to: bundle.path)
                if let app = makeInstalledApp(bundleURL: bundle, dataContainers: dataContainers) {
                    result.append(app)
                }
            }
        }

        var seen = Set<String>()
        return result
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Đọc Info.plist của bundle và dựng `InstalledApp`.
    func makeInstalledApp(bundleURL: URL,
                          dataContainers: [String: URL] = [:]) -> InstalledApp? {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else {
            return nil
        }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent

        return InstalledApp(bundleID: bundleID,
                            name: name,
                            version: (info["CFBundleShortVersionString"] as? String) ?? "—",
                            build: (info["CFBundleVersion"] as? String) ?? "",
                            bundleURL: bundleURL,
                            dataContainerURL: dataContainers[bundleID],
                            iconURL: iconURL(in: bundleURL, info: info))
    }

    /// Map bundleID → data container, đọc metadata của mobile_container_manager.
    func dataContainersByBundleID() -> [String: URL] {
        let roots = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        var mapping: [String: URL] = [:]

        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            SandboxAccess.grantRead(to: root)
            let containers = (try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: root),
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [])) ?? []
            for container in containers {
                let metadata = container.appendingPathComponent(
                    ".com.apple.mobile_container_manager.metadata.plist")
                guard let data = try? Data(contentsOf: metadata),
                      let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                              options: [], format: nil),
                      let dictionary = plist as? [String: Any],
                      let identifier = dictionary["MCMMetadataIdentifier"] as? String else { continue }
                mapping[identifier] = container
            }
            if !mapping.isEmpty { break }
        }
        return mapping
    }

    /// Tìm file icon trong bundle theo các tên phổ biến.
    func iconURL(in bundleURL: URL, info: [String: Any]) -> URL? {
        var candidates: [String] = []

        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            if let files = primary["CFBundleIconFiles"] as? [String] {
                candidates.append(contentsOf: files.map { $0.contains("@") ? "\($0).png" : "\($0)@2x.png" })
            }
            if let name = primary["CFBundleIconName"] as? String {
                candidates.append("\(name)60x60@2x.png")
            }
        }
        candidates.append(contentsOf: [
            "AppIcon60x60@2x.png", "AppIcon60x60@3x.png",
            "AppIcon76x76@2x~ipad.png", "Icon@2x.png", "Icon.png",
            "AppIcon.png", "icon.png"
        ])

        for candidate in candidates {
            let url = bundleURL.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        // Fallback: PNG đầu tiên ở gốc bundle.
        let children = (try? fileManager.contentsOfDirectory(at: bundleURL,
                                                            includingPropertiesForKeys: nil,
                                                            options: [])) ?? []
        return children.first { $0.pathExtension.lowercased() == "png" }
    }

    // MARK: - Mount container

    /// Mount toàn bộ app tìm được vào `Documents/_sandbox/`.
    ///
    /// Chạy tuần tự từng app trên `workQueue` để tránh tạo hàng nghìn symlink
    /// cùng lúc; cập nhật `progressText` để UI hiển thị tiến trình.
    func mountAllContainers() {
        guard !isMounting else { return }
        guard !apps.isEmpty else { return }

        DispatchQueue.main.async {
            self.isMounting = true
            self.progressText = "Đang mount \(self.apps.count) container…"
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            self.prepareSandboxRoot()

            var states: [String: MountState] = [:]
            var failures = 0

            for (index, app) in self.apps.enumerated() {
                DispatchQueue.main.async {
                    self.progressText = "Mount \(index + 1)/\(self.apps.count): \(app.name)"
                }
                let state = self.mountContainer(for: app)
                states[app.bundleID] = state
                if case .failed = state { failures += 1 }
            }

            DispatchQueue.main.async {
                self.mountStates = states
                self.isMounting = false
                self.progressText = nil
                let mounted = states.values.filter { $0.isMounted }.count
                if mounted == 0 {
                    self.lastError = "Không mount được container nào (\(failures) lỗi). "
                        + "Kiểm tra App Group và phiên bản iOS."
                } else {
                    AuditLogger.shared.log(event: .sandboxMounted(bundleID: "…(\(mounted) apps)"))
                }
            }
        }
    }

    /// Mount một app thành thư mục thật trong `Documents/_sandbox/<bundle-id>/`:
    /// - `Bundle/` → symlink tới `.app` trong `/var/containers/Bundle/Application/`
    /// - `Data/`   → symlink tới data container trong `/var/mobile/Containers/Data/`
    ///
    /// Cấu trúc này **bắt buộc** phải là thư mục thật: bundle `.app` là read-only,
    /// nên không thể tạo symlink con bên trong nó.
    func mountContainer(for app: InstalledApp) -> MountState {
        prepareSandboxRoot()
        let container = sandboxRoot.appendingPathComponent(app.bundleID, isDirectory: true)

        do {
            // Cấp quyền đọc trước khi tạo symlink.
            SandboxAccess.grantRead(to: app.bundleURL.path)
            if let dataContainer = app.dataContainerURL {
                SandboxAccess.grantRead(to: dataContainer.path)
            }

            // Nếu đang là symlink cũ (phiên bản trước) → thay bằng thư mục thật.
            if let _ = try? fileManager.destinationOfSymbolicLink(atPath: container.path) {
                try? fileManager.removeItem(at: container)
            }
            if !fileManager.fileExists(atPath: container.path) {
                try fileManager.createDirectory(at: container,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
            }

            try link(app.bundleURL,
                     at: container.appendingPathComponent("Bundle", isDirectory: true))

            if let dataContainer = app.dataContainerURL {
                try link(dataContainer,
                         at: container.appendingPathComponent("Data", isDirectory: true))
            }

            return .mounted(container)
        } catch {
            let message = (error as NSError).localizedDescription
            AuditLogger.shared.log(event: .sandboxMountFailed(bundleID: app.bundleID,
                                                              error: message))
            return .failed(message)
        }
    }

    /// Tạo (hoặc thay) symlink tại `linkURL` trỏ tới `target`.
    private func link(_ target: URL, at linkURL: URL) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)) != nil
            || fileManager.fileExists(atPath: linkURL.path) {
            try? fileManager.removeItem(at: linkURL)
        }
        try fileManager.createSymbolicLink(atPath: linkURL.path,
                                           withDestinationPath: target.path)
    }

    /// Mount theo bundle ID (dùng cho nút "Mount lại" ở UI).
    @discardableResult
    func mountContainer(bundleID: String) -> MountState {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return .failed("Không tìm thấy app \(bundleID) trong danh sách đã quét.")
        }
        let state = mountContainer(for: app)
        DispatchQueue.main.async { self.mountStates[bundleID] = state }
        return state
    }

    /// Tạo `_sandbox` (và dọn symlink hỏng còn sót từ lần chạy trước).
    func prepareSandboxRoot() {
        try? fileManager.createDirectory(at: sandboxRoot, withIntermediateDirectories: true, attributes: nil)
        let children = (try? fileManager.contentsOfDirectory(at: sandboxRoot,
                                                            includingPropertiesForKeys: nil,
                                                            options: [])) ?? []
        for child in children {
            // Symlink trỏ tới đường dẫn không còn tồn tại (app bị xoá) → dọn.
            if !fileManager.fileExists(atPath: child.path) {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    /// Danh sách bundle ID đã mount thành công.
    var mountedBundleIDs: [String] {
        mountStates.compactMap { key, value in value.isMounted ? key : nil }.sorted()
    }

    /// Thư mục mount của một app (nil nếu chưa mount thành công).
    func mountedURL(for bundleID: String) -> URL? {
        if case .mounted(let url) = mountStates[bundleID] { return url }
        let candidate = sandboxRoot.appendingPathComponent(bundleID, isDirectory: true)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
