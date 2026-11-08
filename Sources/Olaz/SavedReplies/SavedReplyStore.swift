import Foundation
import Observation

@MainActor @Observable final class SavedReplyStore {
    private(set) var database = SavedReplyDatabase()
    private(set) var storageError: String?
    @ObservationIgnored private let url: URL?
    static let maxActivePerAccount = 300
    static let maxFileBytes = 8_000_000
    static var defaultURL: URL { ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("SavedReplies/replies.json") }

    init(url: URL? = SavedReplyStore.defaultURL) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maxFileBytes else { throw SavedReplyError.message("Tệp quá lớn.") }
            let decoded = try JSONDecoder().decode(SavedReplyDatabase.self, from: Data(contentsOf: url))
            guard decoded.version == 1, Set(decoded.replies.map(\.id)).count == decoded.replies.count else { throw SavedReplyError.message("Định dạng không hỗ trợ.") }
            var active = Set<String>()
            for reply in decoded.replies {
                guard try reply.validated().shortcut == reply.shortcut else { throw SavedReplyError.message("Lệnh không hợp lệ.") }
                if reply.deletedAt == nil, !active.insert(reply.account + ":" + reply.shortcut).inserted { throw SavedReplyError.message("Lệnh bị trùng.") }
            }
            database = decoded
        } catch { storageError = "Không đọc được tin nhắn mẫu. Dữ liệu cũ được giữ nguyên; chưa cho phép ghi đè." }
    }

    func replies(account: String, deleted: Bool = false) -> [SavedReply] {
        database.replies.filter { $0.account == account && ($0.deletedAt != nil) == deleted }.sorted {
            $0.shortcut.localizedStandardCompare($1.shortcut) == .orderedAscending
        }
    }
    func matches(account: String, query: String, slash: Bool = false) -> [SavedReply] {
        let key = SavedReply.folded(query.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        return replies(account: account).filter {
            key.isEmpty || $0.shortcut.hasPrefix(key) || SavedReply.folded($0.title).contains(key)
                || (!slash && (SavedReply.folded($0.body).contains(key) || $0.shortcut.contains(key)))
        }.sorted {
            let left = $0.shortcut == key ? 0 : ($0.shortcut.hasPrefix(key) ? 1 : 2)
            let right = $1.shortcut == key ? 0 : ($1.shortcut.hasPrefix(key) ? 1 : 2)
            return left == right ? $0.shortcut.localizedStandardCompare($1.shortcut) == .orderedAscending : left < right
        }
    }
    func save(_ input: SavedReply) throws {
        var reply = try input.validated()
        guard !database.replies.contains(where: { $0.id == reply.id && $0.account != reply.account }) else { throw SavedReplyError.message("Mẫu thuộc tài khoản khác.") }
        guard !database.replies.contains(where: { $0.id != reply.id && $0.account == reply.account && $0.shortcut == reply.shortcut && $0.deletedAt == nil }) else {
            throw SavedReplyError.message("Lệnh /\(reply.shortcut) đã có trong tài khoản này. Chọn lệnh khác hoặc sửa mẫu đang có.")
        }
        if reply.deletedAt == nil, !replies(account: reply.account).contains(where: { $0.id == reply.id }), replies(account: reply.account).count >= Self.maxActivePerAccount {
            throw SavedReplyError.message("Mỗi tài khoản lưu tối đa 300 mẫu đang dùng.")
        }
        reply.updatedAt = .now
        var next = database
        if let index = next.replies.firstIndex(where: { $0.id == reply.id }) { next.replies[index] = reply }
        else { next.replies.append(reply) }
        try persist(next)
    }
    func remove(_ id: UUID, account: String) throws {
        guard var reply = database.replies.first(where: { $0.id == id && $0.account == account && $0.deletedAt == nil }) else { return }
        reply.deletedAt = .now; try save(reply)
    }
    func restore(_ id: UUID, account: String) throws {
        guard var reply = database.replies.first(where: { $0.id == id && $0.account == account && $0.deletedAt != nil }) else { return }
        reply.deletedAt = nil; try save(reply)
    }
    private func persist(_ next: SavedReplyDatabase) throws {
        guard storageError == nil else { throw SavedReplyError.message(storageError!) }
        if let url {
            let fm = FileManager.default
            let data = try JSONEncoder().encode(next)
            guard data.count <= Self.maxFileBytes else { throw SavedReplyError.message("Dữ liệu tin nhắn mẫu vượt quá 8 MB.") }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
            guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw SavedReplyError.message("Không tạo được tệp tin nhắn mẫu.") }
            defer { try? fm.removeItem(at: temp) }
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: url) }
        }
        database = next
    }
}
