import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ClingSync

// All bridge-backed tests share this one serialized suite. The bridge keeps the
// open repository in process-global state, so two bridge tests must never run
// concurrently. Swift Testing serializes within a suite, so each bridge test
// (in any file) is an `extension BridgeSuite`.
@Suite(.serialized)
struct BridgeSuite {}

struct BridgeTestError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

func sha256Hex(of url: URL) -> String {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func writeTempFile(_ contents: String, ext: String = "jpg") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clingtest-\(UUID().uuidString).\(ext)")
    try Data(contents.utf8).write(to: url)
    return url
}

// A fresh, isolated repository provisioned by the Go driver (ios/go TestIOSUnit),
// served by its own in-process S3 server. The bridge runs in-process, so tests
// call the production Bridge directly. Tests gate on `isAvailable` (the driver's
// fixed port being reachable), so a run without the driver skips them.
struct TestRepo {
    let url: String
    let passphrase: String
    let s3KeyId: String
    let s3Key: String

    // Must match `provisionPort` in ios/go/unit_test.go.
    private static let provisionPort: UInt16 = 47645

    static var isAvailable: Bool { canConnect(toLoopbackPort: provisionPort) }

    static func fresh() async throws -> TestRepo {
        guard let url = URL(string: "http://127.0.0.1:\(provisionPort)/new-repo") else {
            throw BridgeTestError("bad provisioning URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BridgeTestError("provisioning /new-repo failed: \(response)")
        }
        return TestRepo(
            url: json["url"] as? String ?? "",
            passphrase: json["passphrase"] as? String ?? "",
            s3KeyId: json["s3KeyId"] as? String ?? "",
            s3Key: json["s3Key"] as? String ?? "")
    }

    // A blocking connect to 127.0.0.1 returns immediately on loopback: success
    // when the Go driver is serving, ECONNREFUSED otherwise.
    private static func canConnect(toLoopbackPort port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
