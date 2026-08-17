import Foundation

/// The user's STANDING media preferences — their own words, nothing inferred.
///
/// This deliberately is not a "taste profile" (2026-08-17 design revision):
/// taste is mostly mood — tech dramas one night, love sagas the next — and a
/// generated one-off definition pretends the first is the second. What IS
/// stable are the user's standing constraints ("no musicals, subtitles fine,
/// nothing over 3 hours"), so that is all this stores and all the chat sees.
/// Mood arrives with each ask; per-session personalization comes from the
/// swipe log's anchors, which react to tonight's swipes rather than defining
/// the user in advance.
///
/// Lock-guarded rather than an actor so the LLM providers can read it
/// synchronously while building a system prompt (same reasoning as
/// `MediaServerIndex`).
public final class TasteProfileStore: @unchecked Sendable {

    public static let shared = TasteProfileStore()

    static let useInChatKey = "ArrBarr.tasteProfile.useInChat"
    static let userNoteKey = "ArrBarr.tasteProfile.userNote"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _useInChat: Bool
    private var _userNote: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _useInChat = defaults.object(forKey: Self.useInChatKey) as? Bool ?? true
        _userNote = defaults.string(forKey: Self.userNoteKey) ?? ""
    }

    public var useInChat: Bool {
        lock.lock(); defer { lock.unlock() }
        return _useInChat
    }

    public var userNote: String {
        lock.lock(); defer { lock.unlock() }
        return _userNote
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
    /// an absent note costs zero tokens.
    public func promptBlock() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard _useInChat else { return nil }
        let note = _userNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        return """
        The user's standing media preferences, in their own words (these are stable \
        constraints — tonight's mood still comes from the conversation itself): \(note)
        """
    }
}
