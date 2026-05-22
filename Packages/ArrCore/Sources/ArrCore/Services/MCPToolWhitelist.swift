import Foundation

public enum MCPToolWhitelist {
    public static let v1Allowed: Set<String> = [
        "sonarr_search",
        "radarr_search",
        "sonarr_get_series",
        "radarr_get_movies",
        "sonarr_get_calendar",
        "radarr_get_calendar",
        "sonarr_add_series",
        "radarr_add_movie",
    ]

    public static func isDestructive(_ toolName: String) -> Bool {
        toolName.contains("_add_") || toolName.hasPrefix("add_") || toolName.contains("_delete_")
    }

    public static func filter(_ tools: [MCPTool]) -> [MCPTool] {
        tools.filter { v1Allowed.contains($0.name) }
    }
}
