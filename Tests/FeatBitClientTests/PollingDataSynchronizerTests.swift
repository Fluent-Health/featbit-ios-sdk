import XCTest
@testable import FeatBitClient

final class PollingDataSynchronizerTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func makeSynchronizer(store: MemoryStore) -> PollingDataSynchronizer {
        let options = FBOptions.Builder("secret")
            .polling("https://eval.example.com", interval: 60)
            .build()
        let user = FBUser.builder("u1").build()
        let getUserFlags = GetUserFlags(options: options, user: user, session: MockURLProtocol.session())
        return PollingDataSynchronizer(options: options, user: user, store: store, getUserFlags: getUserFlags)
    }

    func testStartInitializesAndPopulatesStore() async {
        MockURLProtocol.handler = { _ in
            let body = #"{"data":{"featureFlags":[{"id":"f1","variation":"true","matchReason":"default"}]}}"#
            return (200, Data(body.utf8))
        }
        let store = DefaultMemoryStore()
        let sync = makeSynchronizer(store: store)

        let ready = await sync.start()

        XCTAssertTrue(ready)
        XCTAssertTrue(sync.initialized)
        XCTAssertEqual(store.get("f1")?.variation, "true")
        sync.close()
    }

    func testFatalErrorFailsStart() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let store = DefaultMemoryStore()
        let sync = makeSynchronizer(store: store)

        let ready = await sync.start()

        XCTAssertFalse(ready)
        XCTAssertFalse(sync.initialized)
    }
}
