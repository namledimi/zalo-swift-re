import Foundation

enum MCPConnectionPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case generic, wordpress, woocommerce, facebookAds, facebookPages
    var id: String { rawValue }
    var title: String {
        switch self {
        case .generic: "MCP tùy chỉnh"
        case .wordpress: "WordPress"
        case .woocommerce: "WooCommerce"
        case .facebookAds: "Facebook · Meta Ads"
        case .facebookPages: "Facebook · Page / Messenger"
        }
    }
    var isWordPress: Bool { self == .wordpress || self == .woocommerce }
    var help: String {
        switch self {
        case .generic: "Kết nối server MCP local hoặc HTTP do bạn chọn."
        case .wordpress: "Website cần bật MCP Adapter và abilities cần dùng. Nhập username WordPress và Application Password; giữ quyền theo tài khoản website."
        case .woocommerce: "Dùng MCP Adapter trên website WooCommerce và Application Password WordPress. Consumer Key/Secret của REST API không dùng cho endpoint MCP Adapter này. Khả năng phụ thuộc phiên bản và abilities website công khai."
        case .facebookAds: "Nguồn công cụ quảng cáo Meta. OAuth cần Client ID và redirect URI được Meta chấp nhận. Kết nối này không phải hộp thư Fanpage/Messenger."
        case .facebookPages: "Nhập URL server MCP cung cấp Page, bình luận hoặc Messenger của bạn. Không có endpoint Inbox chung được giả định; quyền và chức năng do server đó cung cấp."
        }
    }
    var defaultURL: String { self == .facebookAds ? "https://mcp.facebook.com/ads" : "" }
    var defaultAuthentication: MCPAuthenticationMode { isWordPress ? .basic : (self == .generic ? .none : .oauth) }

    static func wordpressEndpoint(site: String) throws -> String {
        let text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        try MCPServerConfiguration(url: text).validate()
        guard var c = URLComponents(string: text), c.query == nil else { throw PluginError.message("Nhập URL website không có query; có thể giữ thư mục con của WordPress.") }
        let path = c.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.percentEncodedPath = (path.isEmpty ? "" : "/" + path) + "/wp-json/mcp/mcp-adapter-default-server"
        guard let result = c.string else { throw PluginError.message("Không tạo được endpoint WordPress.") }
        return result
    }
}

struct MCPAbilityDescriptor: Identifiable, Equatable, Sendable {
    var name: String
    var label: String
    var description: String
    var inputSchema: Data
    var readOnly: Bool
    var id: String { name }
}

enum MCPToolAccess {
    static let discoverAbilities = "mcp-adapter-discover-abilities"
    static let abilityInfo = "mcp-adapter-get-ability-info"
    static let executeAbility = "mcp-adapter-execute-ability"
    static func isReadOnly(_ tool: MCPToolDescriptor) -> Bool {
        if tool.name == executeAbility { return false }
        let hints = tool.annotations.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if hints["destructiveHint"] as? Bool == true { return false }
        if [discoverAbilities, abilityInfo, "search_products", "get_product", "list_product_categories", "search_posts", "get_post", "list_post_categories", "search_orders", "get_order", "get_order_status_counts"].contains(tool.name) { return true }
        return hints["readOnlyHint"] as? Bool == true && hints["destructiveHint"] as? Bool != true
    }
    static func validateAbilityCall(tool: String, arguments: [String: Any], allowed: Set<String>?) throws {
        guard tool == executeAbility else { return }
        guard let name = arguments["ability_name"] as? String, allowed?.contains(name) == true else {
            throw PluginError.message("WordPress ability chưa được cấp quyền riêng trong Plugin của Olaz.")
        }
    }
}
