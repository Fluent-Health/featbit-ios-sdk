import Foundation
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Spins up a real FeatBit stack (Postgres + api-server + evaluation-server) and seeds a known
/// feature flag, so the SDK can be exercised against a real evaluation server.
///
/// Swift has no mature Testcontainers, so this drives the **Docker CLI** via `Process` (the same
/// strategy as the Android SDK's Testcontainers-based `FeatBitStack`): a user-defined network, the
/// three containers with matching env/ports, the vendored Postgres schema mounted into
/// `/docker-entrypoint-initdb.d`, then the FeatBit management-API seeding flow over HTTP.
///
/// Used only by the `FEATBIT_E2E=1`-gated E2E tests.
final class FeatBitStack {
    struct SeedResult {
        let evaluationBaseURL: String
        let clientSecret: String
        let flagKey: String
    }

    static let flagKey = "e2e-bool-flag"
    private static let apiPort = 5000
    private static let evalPort = 5100
    private let pgConn = "Host=postgresql;Port=5432;Username=postgres;Password=please_change_me;Database=featbit"

    private let suffix = UUID().uuidString.prefix(8).lowercased()
    private lazy var network = "featbit-e2e-\(suffix)"
    private lazy var pgName = "featbit-pg-\(suffix)"
    private lazy var apiName = "featbit-api-\(suffix)"
    private lazy var evalName = "featbit-eval-\(suffix)"

    private var apiBase = ""
    private var evalBase = ""
    private var token = ""
    private var workspaceId = ""
    private var organizationId = ""
    private var envId = ""

    private let initScripts = [
        "v0.0.0.sql", "v5.0.4.sql", "v5.0.5.sql", "v5.1.0.sql",
        "v5.2.0.sql", "v5.2.1.sql", "v5.3.0.sql", "v5.3.2.sql", "v5.4.0.sql",
    ]

    // MARK: Lifecycle

    func start() throws {
        let initDir = try initdbDirectory()

        shell(["docker", "network", "create", network])

        // Postgres with the vendored schema mounted; runs *.sql in /docker-entrypoint-initdb.d.
        shell([
            "docker", "run", "-d", "--name", pgName, "--network", network, "--network-alias", "postgresql",
            "-e", "POSTGRES_USER=postgres", "-e", "POSTGRES_PASSWORD=please_change_me",
            "-v", "\(initDir):/docker-entrypoint-initdb.d:ro",
            "postgres:15.10",
        ])
        try waitForPostgres()

        shell([
            "docker", "run", "-d", "--name", apiName, "--network", network,
            "-e", "DbProvider=Postgres", "-e", "MqProvider=Postgres", "-e", "CacheProvider=None",
            "-e", "Postgres__ConnectionString=\(pgConn)",
            "-e", "OLAP__ServiceHost=http://da-server",
            "-e", "Jwt__Algorithm=HS256", "-e", "Jwt__Key=please_change_me_to_a_secure_secret_key",
            "-p", "127.0.0.1:0:\(Self.apiPort)",
            "featbit/featbit-api-server:latest",
        ])
        shell([
            "docker", "run", "-d", "--name", evalName, "--network", network,
            "-e", "DbProvider=Postgres", "-e", "MqProvider=Postgres", "-e", "CacheProvider=None",
            "-e", "Postgres__ConnectionString=\(pgConn)",
            "-p", "127.0.0.1:0:\(Self.evalPort)",
            "featbit/featbit-evaluation-server:latest",
        ])

        apiBase = "http://127.0.0.1:\(try hostPort(container: apiName, containerPort: Self.apiPort))"
        evalBase = "http://127.0.0.1:\(try hostPort(container: evalName, containerPort: Self.evalPort))"
    }

    /// Logs in, discovers the workspace/org, onboards a project, and creates an enabled boolean flag.
    func seed() throws -> SeedResult {
        token = try retryForToken()
        workspaceId = try firstId(get("/api/v1/user/workspaces"))
        organizationId = try firstId(get("/api/v1/organizations", workspace: workspaceId))

        _ = try post(
            "/api/v1/organizations/onboarding",
            body: #"{"organizationName":"playground","organizationKey":"playground","projectName":"e2e","projectKey":"e2e","environments":["prod"]}"#,
            workspace: workspaceId, organization: organizationId
        )

        let (env, secret) = try readEnvAndClientSecret()
        envId = env
        try createBooleanFlag(Self.flagKey)

        return SeedResult(evaluationBaseURL: evalBase, clientSecret: secret, flagKey: Self.flagKey)
    }

    /// Toggles the seeded flag on/off via the management API (drives change-detection tests).
    func toggleFlag(enabled: Bool) throws {
        _ = try put(
            "/api/v1/envs/\(envId)/feature-flags/\(Self.flagKey)/toggle/\(enabled)",
            workspace: workspaceId, organization: organizationId
        )
    }

    func close() {
        for name in [evalName, apiName, pgName] {
            shell(["docker", "rm", "-f", name], allowFailure: true)
        }
        shell(["docker", "network", "rm", network], allowFailure: true)
    }

    // MARK: Management API helpers

    private func retryForToken() throws -> String {
        let deadline = Date().addingTimeInterval(180)
        var lastError: Error?
        while Date() < deadline {
            do {
                let body = try post("/api/v1/identity/login-by-email", body: #"{"email":"test@featbit.com","password":"123456"}"#)
                return try dataObject(body)["token"] as? String ?? { throw E2EError("no token in login response") }()
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 3)
            }
        }
        throw E2EError("api-server did not become ready in time: \(String(describing: lastError))")
    }

    private func createBooleanFlag(_ key: String) throws {
        let trueId = UUID().uuidString
        let falseId = UUID().uuidString
        _ = try post(
            "/api/v1/envs/\(envId)/feature-flags",
            body: """
            {"name":"\(key)","key":"\(key)","isEnabled":true,"description":"",
             "variationType":"boolean",
             "variations":[{"id":"\(trueId)","name":"true","value":"true"},
                           {"id":"\(falseId)","name":"false","value":"false"}],
             "enabledVariationId":"\(trueId)","disabledVariationId":"\(falseId)","tags":[]}
            """,
            workspace: workspaceId, organization: organizationId
        )
    }

    private func readEnvAndClientSecret() throws -> (String, String) {
        let body = try get("/api/v1/projects", workspace: workspaceId, organization: organizationId)
        guard let data = try dataArray(body).first as? [String: Any],
              let environments = data["environments"] as? [[String: Any]],
              let env = environments.first,
              let envId = env["id"] as? String,
              let secrets = env["secrets"] as? [[String: Any]],
              let clientSecret = secrets.first(where: { ($0["type"] as? String) == "client" })?["value"] as? String
        else {
            throw E2EError("could not read env + client secret from /projects")
        }
        return (envId, clientSecret)
    }

    private func firstId(_ body: Data) throws -> String {
        guard let first = try dataArray(body).first as? [String: Any], let id = first["id"] as? String else {
            throw E2EError("expected a non-empty data array with an id")
        }
        return id
    }

    // MARK: HTTP

    private func get(_ path: String, workspace: String? = nil, organization: String? = nil) throws -> Data {
        try execute(request(path, method: "GET", body: nil, workspace: workspace, organization: organization))
    }

    @discardableResult
    private func post(_ path: String, body: String, workspace: String? = nil, organization: String? = nil) throws -> Data {
        try execute(request(path, method: "POST", body: Data(body.utf8), workspace: workspace, organization: organization))
    }

    @discardableResult
    private func put(_ path: String, workspace: String? = nil, organization: String? = nil) throws -> Data {
        try execute(request(path, method: "PUT", body: Data(), workspace: workspace, organization: organization))
    }

    private func request(_ path: String, method: String, body: Data?, workspace: String?, organization: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: apiBase + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let workspace { request.setValue(workspace, forHTTPHeaderField: "Workspace") }
        if let organization { request.setValue(organization, forHTTPHeaderField: "Organization") }
        request.httpBody = body
        return request
    }

    private func execute(_ request: URLRequest) throws -> Data {
        let (status, data) = httpSync(request)
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw E2EError("HTTP \(status) for \(request.url?.absoluteString ?? ""): \(bodyString)")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, success == false {
            throw E2EError("FeatBit API error for \(request.url?.absoluteString ?? ""): \(bodyString)")
        }
        return data
    }

    private func dataObject(_ body: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = json["data"] as? [String: Any] else {
            throw E2EError("expected a {data:{...}} object")
        }
        return data
    }

    private func dataArray(_ body: Data) throws -> [Any] {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = json["data"] as? [Any] else {
            throw E2EError("expected a {data:[...]} array")
        }
        return data
    }

    // MARK: Docker / process helpers

    private func waitForPostgres() throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let (status, _) = shellResult(["docker", "exec", pgName, "pg_isready", "-U", "postgres"], allowFailure: true)
            if status == 0 { return }
            Thread.sleep(forTimeInterval: 2)
        }
        throw E2EError("postgres did not become ready in time")
    }

    private func hostPort(container: String, containerPort: Int) throws -> Int {
        let (_, output) = shellResult(["docker", "port", container, "\(containerPort)/tcp"])
        // Output like "127.0.0.1:49160"
        guard let portString = output.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
              let port = Int(portString) else {
            throw E2EError("could not parse host port from: \(output)")
        }
        return port
    }

    private func initdbDirectory() throws -> String {
        guard let url = Bundle.module.url(forResource: "e2e", withExtension: nil)?.appendingPathComponent("initdb") else {
            throw E2EError("vendored e2e/initdb resources not found in test bundle")
        }
        return url.path
    }

    @discardableResult
    private func shell(_ args: [String], allowFailure: Bool = false) -> String {
        let (status, output) = shellResult(args, allowFailure: allowFailure)
        if status != 0 && !allowFailure {
            XCTFail("command failed (\(status)): \(args.joined(separator: " "))\n\(output)")
        }
        return output
    }

    private func shellResult(_ args: [String], allowFailure: Bool = false) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to launch: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func httpSync(_ request: URLRequest) -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let task = URLSession(configuration: config).dataTask(with: request) { data, response, _ in
            box.value = ((response as? HTTPURLResponse)?.statusCode ?? -1, data ?? Data())
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: (Int, Data) = (-1, Data())
    }
}

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
