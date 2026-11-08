import Foundation

enum MCPData {
    static func payload(_ result: Data) throws -> Any {
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw PluginError.message("MCP trả về JSON không hợp lệ.") }
        if object["isError"] as? Bool == true { throw PluginError.message("Công cụ MCP báo lỗi; kiểm tra tham số và quyền của nguồn.") }
        if let structured = object["structuredContent"] { try checkSuccess(structured); return structured }
        let text = (object["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw PluginError.message("Công cụ không trả dữ liệu JSON có cấu trúc. Có thể xem nội dung gốc trong phần Kết nối.")
        }
        try checkSuccess(value)
        return value
    }
    private static func checkSuccess(_ value: Any, depth: Int = 0) throws {
        guard depth < 5, let object = value as? [String: Any] else { return }
        if object["success"] as? Bool == false || object["isError"] as? Bool == true { throw PluginError.message("Nguồn báo thao tác thất bại; kiểm tra tham số và quyền trong Kết nối.") }
        for key in ["result", "data", "output"] { if let nested = object[key] { try checkSuccess(nested, depth: depth + 1) } }
    }
    static func unwrapped(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 5, let object = value as? [String: Any] else { return value }
        for key in ["result", "data", "output"] {
            if let nested = object[key], nested is [String: Any] || nested is [Any] { return unwrapped(nested, depth: depth + 1) }
        }
        return value
    }
}
