// Notch Tray — GPL-3.0.
import Foundation

/// Unlike st_dev / FileAttributeKey.systemNumber, a volume UUID persists across boots.
/// Inode + birth time also distinguish replacements while surviving file renames.
struct ScreenshotIdentity: Equatable {
    let volumeUUID: String
    let inode: UInt64
    let created: Date

    var fileKey: String { "\(inode):\(created.timeIntervalSinceReferenceDate)" }
    var sourceID: String { "volume:\(volumeUUID.lowercased()):\(fileKey)" }

    static func legacyFileKey(_ sourceID: String) -> String? {
        let parts = sourceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, Int64(parts[0]) != nil,
              UInt64(parts[1]) != nil, let created = Double(parts[2]), created.isFinite else { return nil }
        return "\(parts[1]):\(parts[2])"
    }

    static func persistentFileKey(_ sourceID: String) -> String? {
        let parts = sourceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "volume", UUID(uuidString: String(parts[1])) != nil,
              UInt64(parts[2]) != nil, let created = Double(parts[3]), created.isFinite else { return nil }
        return "\(parts[2]):\(parts[3])"
    }
}
