import Foundation

struct SavedReply: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var account: String
    var shortcut: String
    var title: String
    var body: String
    var createdAt = Date.now
    var updatedAt = Date.now
    var deletedAt: Date?

    static let maxBodyLength = 8000
    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            .lowercased().replacingOccurrences(of: "đ", with: "d")
    }
    static func normalizedShortcut(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") { value.removeFirst() }
        return folded(value)
    }
    static func suggestedShortcut(for title: String, reserved: Set<String> = []) -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let slug = folded(title).replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "mau" : String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var candidate = base
        var number = 2
        while reserved.contains(candidate) {
            let suffix = "-\(number)"
            candidate = String(base.prefix(40 - suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + suffix
            number += 1
        }
        return candidate
    }
    func validated() throws -> Self {
        var result = self
        result.shortcut = Self.normalizedShortcut(shortcut)
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, account.count <= 200 else { throw SavedReplyError.message("Chưa có tài khoản Zalo để lưu mẫu.") }
        guard result.shortcut.range(of: "^[a-z0-9][a-z0-9_-]{0,39}$", options: .regularExpression) != nil else {
            throw SavedReplyError.message("Lệnh dài 1–40 ký tự, bắt đầu bằng chữ/số; dùng chữ thường, số, - hoặc _. Ví dụ /dia-chi.")
        }
        guard !result.title.isEmpty, result.title.count <= 100 else { throw SavedReplyError.message("Nhập tên mẫu từ 1 đến 100 ký tự.") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= Self.maxBodyLength, !body.contains("\0") else {
            throw SavedReplyError.message("Nội dung cần từ 1 đến 8.000 ký tự văn bản.")
        }
        return result
    }
}

enum SavedReplyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

struct SavedReplyDatabase: Codable, Equatable {
    var version = 1
    var replies: [SavedReply] = []
}

/// A command at the caret, in UTF-16 coordinates used by NSTextView. URLs and paths with another slash do not match.
struct SavedReplyQuery: Equatable {
    var range: NSRange
    var text: String
    var token: String

    static func detect(in text: String, selection: NSRange, composing: Bool = false) -> Self? {
        let ns = text as NSString
        guard !composing, selection.length == 0, selection.location != NSNotFound,
              selection.location <= ns.length, Range(selection, in: text) != nil else { return nil }
        let prefix = ns.substring(to: selection.location)
        guard let pattern = try? NSRegularExpression(pattern: "(?:^|\\s)(/([\\p{L}\\p{M}\\p{N}_-]{0,40}))$"),
              let match = pattern.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
        var range = match.range(at: 1)
        let suffix = ns.substring(from: selection.location)
        let tail = try? NSRegularExpression(pattern: "^[\\p{L}\\p{M}\\p{N}_/-]*")
        let tailLength = tail?.firstMatch(in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length))?.range.length ?? 0
        range.length += tailLength
        let token = ns.substring(with: range)
        guard token.dropFirst().count <= 40, !token.dropFirst().contains("/") else { return nil }
        return Self(range: range, text: (prefix as NSString).substring(with: match.range(at: 2)), token: token)
    }
}
