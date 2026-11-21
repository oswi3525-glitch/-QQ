import Foundation
import Combine

/// Kết quả quét cache của một app.
struct CacheReport: Identifiable, Equatable {
    let bundleID: String
    let appName: String
    let cacheURL: URL
    let byteCount: UInt64
    let fileCount: Int

    var id: String { bundleID }
    var sizeLabel: String { BuiltinShell.sizeLabel(byteCount) }
}

/// Kết quả một lần dọn cache.
struct CacheCleanResult {
    let freedBytes: UInt64
    let cleanedApps: Int
    let backupURL: URL?
    let failures: [String]

    var freedLabel: String { BuiltinShell.sizeLabel(freedBytes) }
}

/// Dọn `Library/Caches` của các app đã mount (Module 2 — Cache Cleaner).
///
/// Nguyên tắc an toàn:
/// 1. Chỉ xoá **nội dung** bên trong `Library/Caches`, giữ lại thư mục.
/// 2. Luôn copy toàn bộ cache sang `Documents/.terminal/backups/cache-cleaner/`
///    trước khi xoá; backup lỗi thì bỏ qua app đó.
/// 3. Không đụng tới Documents/Library/Preferences hay bất kỳ thư mục nào khác.
final class CacheCleaner: ObservableObject {
    static let shared = CacheCleaner()

    @Published private(set) var reports: [CacheReport] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var progressText: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastResult: CacheCleanResult?

    /// Giới hạn backup mỗi app để tránh đầy bộ nhớ.
    private let maxBackupBytes: UInt64 = 2 * 1024 * 1024 * 1024

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.wqterm.cachecleaner", qos: .utility)

    private init() {}

    var totalBytes: UInt64 { reports.reduce(0) { $0 + $1.byteCount } }
    var totalLabel: String { BuiltinShell.sizeLabel(totalBytes) }

    /// Thư mục backup gốc.
    var backupRoot: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(".terminal/backups/cache-cleaner", isDirectory: true)
    }

    // MARK: - Scan

    /// Quét `Library/Caches` của tất cả app có data container.
    func scan(apps: [InstalledApp]) {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        lastError = nil
        progressText = "Đang quét Library/Caches…"
        let snapshot = apps

        queue.async { [weak self] in
            guard let self else { return }
            var found: [CacheReport] = []

            for app in snapshot {
                guard let dataContainer = app.dataContainerURL else { continue }
                let cache = dataContainer.appendingPathComponent("Library/Caches", isDirectory: true)
                SandboxAccess.grantRead(to: cache.path)
                guard self.fileManager.fileExists(atPath: cache.path) else { continue }

                let measurement = self.measure(cache)
                guard measurement.fileCount > 0 || measurement.bytes > 0 else { continue }
                found.append(CacheReport(bundleID: app.bundleID,
                                         appName: app.name,
                                         cacheURL: cache,
                                         byteCount: measurement.bytes,
                                         fileCount: measurement.fileCount))
            }

            found.sort { $0.byteCount > $1.byteCount }
            DispatchQueue.main.async {
                self.reports = found
                self.isScanning = false
                self.progressText = nil
            }
        }
    }

    // MARK: - Clean

    /// Dọn cache cho các bundle ID được chọn. Luôn backup trước khi xoá.
    func clean(apps: [InstalledApp],
               bundleIDs: Set<String>,
               completion: ((CacheCleanResult) -> Void)? = nil) {
        guard !isCleaning else { return }
        guard !bundleIDs.isEmpty else {
            lastError = "Chưa chọn app nào để dọn."
            return
        }

        isCleaning = true
        lastError = nil
        progressText = "Đang chuẩn bị backup cache…"
        let selected = apps.filter { bundleIDs.contains($0.bundleID) }

        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = Self.timestamp()
            let root = self.backupRoot.appendingPathComponent(timestamp, isDirectory: true)
            try? self.fileManager.createDirectory(at: root,
                                                   withIntermediateDirectories: true,
                                                   attributes: nil)

            var freed: UInt64 = 0
            var cleaned = 0
            var failures: [String] = []

            for app in selected {
                guard let dataContainer = app.dataContainerURL else {
                    failures.append("\(app.name): không tìm thấy data container")
                    continue
                }
                let cache = dataContainer.appendingPathComponent("Library/Caches", isDirectory: true)
                guard self.fileManager.fileExists(atPath: cache.path) else { continue }

                let measurement = self.measure(cache)
                guard measurement.bytes <= self.maxBackupBytes else {
                    failures.append("\(app.name): cache \(BuiltinShell.sizeLabel(measurement.bytes)) "
                                    + "vượt giới hạn backup \(BuiltinShell.sizeLabel(self.maxBackupBytes))")
                    continue
                }

                DispatchQueue.main.async {
                    self.progressText = "Backup cache \(app.name) (\(BuiltinShell.sizeLabel(measurement.bytes)))…"
                }

                let destination = root
                    .appendingPathComponent(FileSystem.safeFileName(app.bundleID), isDirectory: true)
                    .appendingPathComponent("Caches", isDirectory: true)
                do {
                    try FileSystem.copyTree(from: cache, to: destination)
                } catch {
                    failures.append("\(app.name): backup lỗi — \(error.localizedDescription)")
                    continue
                }

                DispatchQueue.main.async {
                    self.progressText = "Đang xoá cache \(app.name)…"
                }

                let removed = self.removeContents(of: cache)
                if removed.removedBytes > 0 || removed.removedFiles > 0 {
                    freed += removed.removedBytes
                    cleaned += 1
                    AuditLogger.shared.log(event: .fileDelete(path: cache.path))
                }
                if let error = removed.error {
                    failures.append("\(app.name): \(error)")
                }
            }

            let result = CacheCleanResult(freedBytes: freed,
                                          cleanedApps: cleaned,
                                          backupURL: cleaned > 0 ? root : nil,
                                          failures: failures)

            DispatchQueue.main.async {
                self.isCleaning = false
                self.progressText = nil
                self.lastResult = result
                if cleaned == 0, let first = failures.first {
                    self.lastError = first
                }
                completion?(result)
                self.scan(apps: apps)
            }
        }
    }

    // MARK: - Helpers

    private func measure(_ url: URL) -> (bytes: UInt64, fileCount: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url,
                                                      includingPropertiesForKeys: keys,
                                                      options: []) else {
            return (0, 0)
        }
        var bytes: UInt64 = 0
        var count = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            bytes += UInt64(values.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    private func removeContents(of directory: URL) -> (removedBytes: UInt64, removedFiles: Int, error: String?) {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil,
                                                            options: [])
        } catch {
            return (0, 0, error.localizedDescription)
        }

        var removedBytes: UInt64 = 0
        var removedFiles = 0
        var firstError: String?

        for child in children {
            let measurement = measure(child)
            do {
                try fileManager.removeItem(at: child)
                removedBytes += measurement.bytes
                removedFiles += max(measurement.fileCount, 1)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return (removedBytes, removedFiles, firstError)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
