import MediaKit

/// One arr's history narrowed to a detail's subject, by the arr's own filters. Episode and artist rows
/// are checked here too: the demo's recordings answer unfiltered.
nonisolated enum HistoryScope: Hashable, Sendable {
    /// A movie, series or album: the arr's own id filter.
    case record(Int)
    case episode(seriesId: Int, episodeId: Int)
    case artist(Int)

    func resource(_ service: ServarrService, page: Int, pageSize: Int) -> Resource<ArrPage<ArrHistoryRecord>> {
        switch self {
        case let .record(id):
            service.historyFor(entityID: id, page: page, pageSize: pageSize)
        case let .episode(seriesId, episodeId):
            service.historyFor(entityID: seriesId, page: page, pageSize: pageSize, filters: [("episodeId", String(episodeId))])
        case let .artist(id):
            service.history(page: page, pageSize: pageSize, filters: [("artistIds", String(id))])
        }
    }

    func admits(_ record: ArrHistoryRecord) -> Bool {
        switch self {
        case .record: true
        case let .episode(_, episodeId): record.episodeId == episodeId
        case let .artist(id): record.artistId == id
        }
    }
}
