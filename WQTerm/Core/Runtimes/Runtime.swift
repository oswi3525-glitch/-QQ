import Foundation
import Combine

/// Runtime nhúng mà WQTerm hỗ trợ (PRD Module 4 & 5).
enum Runtime: String, CaseIterable, Identifiable {
    case node = "node"
    case python = "python3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .node: return "Node.js"
        case .python: return "Python 3.9"
        }
    }

    /// Thư mục đích trong `Documents/.terminal/RuntimeManager/`.
    var installedRelativePath: String {
        switch self {
        case .node: return "node-ios-arm64"
        case .python: return "python-ios"
        }
    }

    /// Thư mục nguồn trong app bundle.
    var bundledRelativePath: String {
        switch self {
        case .node: return "node-ios-arm64"
        case .python: return "python-runtime"
        }
    }

    /// Đường dẫn binary chính, tương đối so với `RuntimeManager/`.
    var binaryRelativePath: String {
        switch self {
        case .node: return "node-ios-arm64/bin/node"
        case .python: return "python-ios/Library/bin/python3"
        }
    }

    /// Tên binary hiển thị trong PATH.
    var executableName: String { rawValue }
}
