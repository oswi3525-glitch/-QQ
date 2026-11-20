import Foundation
import UIKit
import Combine

/// Kết quả một lần dump IPA.
struct DumpResult: Identifiable {
    let id = UUID()
    let app: InstalledApp
    let ipaURL: URL
    let byteCount: UInt64
    let duration: TimeInterval

    var sizeLabel: String { BuiltinShell.sizeLabel(byteCount) }
}

/// Dump `.app` của app khác thành `.ipa` (Module 2 — IPA Dumper).
///
/// Quy trình đúng chuẩn IPA:
/// 1. Copy bundle `.app` (giữ symlink) vào thư mục tạm `…/Payload/`.
/// 2. Nén `Payload/` thành ZIP → `.ipa`, cấu trúc bên trong đúng
///    `Payload/MyApp.app/Info.plist` mà SideStore/AltStore yêu cầu.
/// 3. Lưu vào `~/Documents/` rồi trả URL cho `UIActivityViewController`.
///
/// Toàn bộ chạy trên `SandboxManager.workQueue`; UI chỉ nhận callback trên main.
final class IPADumper: ObservableObject {
    static let shared = IPADumper()

    /// `true` khi có một lần dump đang chạy (UI disable nút).
    @Published private(set) var isDumping = false

    private init() {}

    /// Dump IPA cho `app`, gọi `progress` với nội dung tiếng Việt để UI hiển thị.
    ///
    /// - Note: Hàm **throw** nếu không copy/nén được; lỗi luôn có mô tả rõ ràng
    ///   để UI hiển thị trong alert thay vì im lặng.
    func dump(_ app: InstalledApp, progress: @escaping (String) -> Void) throws -> DumpResult {
        let started = Date()
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: app.bundleURL.path) else {
            throw IPADumperError.bundleMissing(app.bundleURL.path)
        }

        // 1. Dọn thư mục tạm của lần trước, tạo Payload mới.
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("WQTermDump-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workDirectory.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: payloadDirectory,
                                        withIntermediateDirectories: true, attributes: nil)
        defer { FileSystem.removeQuietly(workDirectory) }

        progress("Đang copy \(app.name).app…")
        SandboxAccess.grantRead(to: app.bundleURL.path)
        let stagedBundle = payloadDirectory.appendingPathComponent(
            app.bundleURL.lastPathComponent, isDirectory: true)
        try FileSystem.copyTree(from: app.bundleURL, to: stagedBundle)

        // 2. Nén Payload → .ipa
        progress("Đang nén IPA…")
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseName = FileSystem.safeFileName("\(app.name)-\(app.version)")
        let ipaURL = uniqueURL(in: documents, baseName: baseName, extension: "ipa")

        try ZipArchive.create(directory: payloadDirectory, at: ipaURL)

        let attributes = try? fileManager.attributesOfItem(atPath: ipaURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else { throw IPADumperError.emptyArchive(ipaURL.path) }

        AuditLogger.shared.log(event: .backupCreated(path: ipaURL.path))
        progress("Hoàn tất: \(BuiltinShell.sizeLabel(size))")

        return DumpResult(app: app, ipaURL: ipaURL, byteCount: size,
                          duration: Date().timeIntervalSince(started))
    }

    /// Dump bất đồng bộ trên `workQueue`, callback về main thread.
    func dumpInBackground(_ app: InstalledApp,
                          progress: @escaping (String) -> Void,
                          completion: @escaping (Result<DumpResult, Error>) -> Void) {
        guard !isDumping else { return }
        isDumping = true

        SandboxManager.shared.workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<DumpResult, Error>
            do {
                result = .success(try self.dump(app, progress: { message in
                    DispatchQueue.main.async { progress(message) }
                }))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.isDumping = false
                completion(result)
            }
        }
    }

    /// Trả về URL chưa tồn tại: `Tên.ipa`, `Tên-2.ipa`, `Tên-3.ipa`…
    func uniqueURL(in directory: URL, baseName: String, extension fileExtension: String) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }

    /// Trình chia sẻ hệ thống để người dùng lưu IPA ra Files app.
    @MainActor
    func shareController(for url: URL) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
}

enum IPADumperError: LocalizedError {
    case bundleMissing(String)
    case emptyArchive(String)

    var errorDescription: String? {
        switch self {
        case .bundleMissing(let path):
            return "Không tìm thấy bundle: \(path). App có thể đã bị xoá hoặc chưa mount."
        case .emptyArchive(let path):
            return "IPA tạo ra rỗng: \(path). Kiểm tra dung lượng và quyền ghi Documents."
        }
    }
}


