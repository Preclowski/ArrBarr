import Foundation

public enum MCPToolWhitelist {
    public static func isDestructive(_ toolName: String) -> Bool {
        toolName.contains("_add_") || toolName.hasPrefix("add_") || toolName.contains("_delete_")
    }
}
