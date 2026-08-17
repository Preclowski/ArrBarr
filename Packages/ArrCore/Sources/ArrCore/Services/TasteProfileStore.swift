import Foundation

/// The user's taste, distilled to a short paragraph — plus the switches that
/// govern where it may travel. Lock-guarded rather than an actor so the LLM
/// providers can read it synchronously while building a system prompt (same
/// reasoning as `MediaServerIndex`).
///
/// Transparency is the feature (2026-08-17 UX review): the paragraph is
/// always visible and regenerable in Settings, the user can append their own
/// line to it, and one toggle keeps it out of chat entirely. Hidden inference
/// is what this audience left the big platforms to escape.
public final class TasteProfileStore: @unchecked Sendable {

    public static let shared = TasteProfileStore()

    static let paragraphKey = "ArrBarr.tasteProfile.paragraph"
    static let updatedAtKey = "ArrBarr.tasteProfile.updatedAt"
    static let useInChatKey = "ArrBarr.tasteProfile.useInChat"
    static let userNoteKey = "ArrBarr.tasteProfile.userNote"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _paragraph: String?
    private var _updatedAt: Date?
    private var _useInChat: Bool
    private var _userNote: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _paragraph = defaults.string(forKey: Self.paragraphKey)
        _updatedAt = defaults.object(forKey: Self.updatedAtKey) as? Date
        // Default ON: the profile only exists after an explicit generate, so
        // the first surprise is impossible — there is nothing to inject yet.
        _useInChat = defaults.object(forKey: Self.useInChatKey) as? Bool ?? true
        _userNote = defaults.string(forKey: Self.userNoteKey) ?? ""
    }

    public var paragraph: String? {
        lock.lock(); defer { lock.unlock() }
        return _paragraph
    }

    public var updatedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _updatedAt
    }

    public var useInChat: Bool {
        lock.lock(); defer { lock.unlock() }
        return _useInChat
    }

    public var userNote: String {
        lock.lock(); defer { lock.unlock() }
        return _userNote
    }

    public func setParagraph(_ text: String?, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        _paragraph = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if _paragraph?.isEmpty == true { _paragraph = nil }
        _updatedAt = _paragraph == nil ? nil : date
        defaults.set(_paragraph, forKey: Self.paragraphKey)
        defaults.set(_updatedAt, forKey: Self.updatedAtKey)
    }

    public func setUseInChat(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        _useInChat = on
        defaults.set(on, forKey: Self.useInChatKey)
    }

    public func setUserNote(_ note: String) {
        lock.lock(); defer { lock.unlock() }
        _userNote = note
        defaults.set(note, forKey: Self.userNoteKey)
    }

    /// The block the system prompt carries — nil when disabled or empty, so
    /// an absent profile costs zero tokens. The user's own note rides along
    /// verbatim: "I hate musicals" typed by hand outranks anything inferred.
    public func promptBlock() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard _useInChat else { return nil }
        var parts: [String] = []
        if let paragraph = _paragraph { parts.append(paragraph) }
        let note = _userNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append("In the user's own words: \(note)") }
        guard !parts.isEmpty else { return nil }
        return """
        User taste profile (learned on this device from their quiz swipes and watch history; \
        let it inform recommendations, never recite it back unless asked):
        \(parts.joined(separator: "\n"))
        """
    }
}
