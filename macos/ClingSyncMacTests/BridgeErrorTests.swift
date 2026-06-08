import Testing

@testable import ClingSyncMac

struct BridgeErrorTests {
    @Test func classifiesByCode() {
        #expect(BridgeError(message: "x", code: "passphrase_required").isPassphraseRequired)
        #expect(BridgeError(message: "x", code: "no_sync_targets").isNoSyncTargets)
        #expect(BridgeError(message: "x", code: "sync_already_running").isSyncAlreadyRunning)
        #expect(BridgeError(message: "x", code: "local_access_denied").isLocalAccessDenied)
        #expect(BridgeError(message: "x", code: "network_unreachable").isNetworkError)
    }

    @Test func unknownOrMissingCodeMatchesNothing() {
        let other = BridgeError(message: "boom", code: "something_else")
        #expect(!other.isPassphraseRequired)
        #expect(!other.isNoSyncTargets)
        #expect(!other.isNetworkError)

        let none = BridgeError(message: "boom", code: nil)
        #expect(!none.isPassphraseRequired)
        #expect(!none.isLocalAccessDenied)
    }
}
