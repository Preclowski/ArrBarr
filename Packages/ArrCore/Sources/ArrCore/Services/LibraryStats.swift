import Foundation

/// Lock-guarded snapshot of the library's SIZE, fed by `LibraryIndex` on
/// every fetch. Exists so the system prompt can carry "3021 movies, 214
/// series" synchronously at request time — the size decides the agent's
/// whole discovery strategy (a big collection owns the canon, so guessing
/// obvious titles wastes a full round of lookups plus an LLM turn), and an
/// actor hop has no place inside prompt assembly.
public final class LibraryStats: @unchecked Sendable {

    public static let shared = LibraryStats()

    private let lock = NSLock()
    private var _movieCount: Int?
    private var _seriesCount: Int?

    public init() {}

    public var movieCount: Int? {
        lock.lock(); defer { lock.unlock() }
        return _movieCount
    }

    public var seriesCount: Int? {
        lock.lock(); defer { lock.unlock() }
        return _seriesCount
    }

    func setMovieCount(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        _movieCount = count
    }

    func setSeriesCount(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        _seriesCount = count
    }

    /// The system-prompt block. Nil until a library has been fetched at
    /// least once this session — an absent line costs nothing, and lying
    /// with zeros would push the model toward exactly the wrong strategy.
    public func promptBlock() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard _movieCount != nil || _seriesCount != nil else { return nil }
        var parts: [String] = []
        if let m = _movieCount { parts.append("\(m) movies") }
        if let s = _seriesCount { parts.append("\(s) series") }
        var out = "The user's library holds \(parts.joined(separator: " and "))."
        let total = (_movieCount ?? 0) + (_seriesCount ?? 0)
        if total >= 500 {
            out += " A collection this size owns virtually every canonical or popular title: for \"something new\" asks NEVER open with the canon — go straight to deep cuts, send large batches (40-60 picks to discover_in_quiz, exclude_owned to suggest_titles), and expect even those to be partly owned."
        }
        return out
    }
}
