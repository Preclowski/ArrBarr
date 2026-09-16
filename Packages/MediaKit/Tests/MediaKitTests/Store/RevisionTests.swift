import Foundation
import Observation
import Testing
@testable import MediaKit

@Suite struct RevisionTests {
    @Test func observationsEmitOnBump() async throws {
        let revision = StoreRevision()
        let tag = InvalidationTag.collection(.queue, InstanceID(.radarr))
        var iterator = Observations { revision.tick(for: tag) }.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        let bump = Task {
            try await Task.sleep(for: .milliseconds(20))
            revision.bump([tag])
        }
        #expect(await iterator.next() == 1)
        try await bump.value
        revision.bump([.collection(.history, InstanceID(.radarr))])
        #expect(revision.tick(for: tag) == 1 && revision.all == 2)
    }
}
