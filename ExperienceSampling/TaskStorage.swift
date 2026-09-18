import Foundation
import Darwin

struct TaskDocument: Codable {
    let version: Int
    var rows: [[String]]

    static func decode(_ data: Data) throws -> TaskDocument {
        guard let document = try? JSONDecoder().decode(TaskDocument.self, from: data), document.version == 1,
              document.rows.allSatisfy({ $0.count == 9 && !$0[0].isEmpty && $0[0] == $0[0].trimmingCharacters(in: .whitespacesAndNewlines) }),
              Set(document.rows.map { $0[0] }).count == document.rows.count else {
            throw TaskStorageError.unavailable("Invalid task document; refusing to replace it.")
        }
        return document
    }
}

enum TaskStorageError: Error {
    case conflict
    case authentication
    case unavailable(String)
    case configuration
    case requestFailed
    case unconfirmedWrite

    var coachError: CoachError {
        switch self {
        case .conflict: return .tasksUnavailable("The task list changed concurrently; retry the edit.")
        case .authentication: return .tasksAuthRequired("AWS sign-in expired or unavailable. Run `aws sso login`.")
        case .unavailable(let detail): return .tasksUnavailable(detail)
        case .configuration: return .tasksNotConfigured("Set TASKS_S3_URI to an s3://bucket/key object URI.")
        case .requestFailed: return .tasksUnavailable("AWS request could not complete; check your sign-in and connectivity.")
        case .unconfirmedWrite: return .tasksUnavailable("Save outcome unknown: it may have reached S3. Refresh the task list before retrying.")
        }
    }

    static func from(stderr: String) -> TaskStorageError {
        let text = stderr.lowercased()
        if text.contains("preconditionfailed") || text.contains("conditionalrequestconflict") { return .conflict }
        if ["expiredtoken", "sso session", "sso token", "token has expired", "invalid_grant", "invalidclienttokenid", "unable to locate credentials"].contains(where: text.contains) {
            return .authentication
        }
        if text.contains("nosuchkey") {
            return .unavailable("Task document missing; explicitly initialize or import it using task-store.")
        }
        if text.contains("accessdenied") { return .unavailable("AWS denied access; check your sign-in and task storage configuration.") }
        if text.contains("unknown options") { return .unavailable("Update the AWS CLI: conditional S3 writes are required.") }
        return .requestFailed
    }
}

enum TaskCommand {
    static func run(executable: String, arguments: [String]) throws -> (Int32, Data, Data) {
        let directory = try S3TaskStore.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout")
        let errors = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["AWS_PAGER"] = ""
        environment["AWS_CLI_AUTO_PROMPT"] = "off"
        environment["AWS_MAX_ATTEMPTS"] = "1"
        environment["PATH"] = "\((executable as NSString).deletingLastPathComponent):\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 40) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw TaskStorageError.requestFailed
        }
        return (process.terminationStatus, try Data(contentsOf: output), try Data(contentsOf: errors))
    }
}

struct S3TaskStore {
    typealias Runner = ([String]) throws -> (Int32, Data, Data)
    struct Snapshot {
        var document: TaskDocument
        let etag: String
        let data: Data
    }

    let bucket: String
    let key: String
    let region: String?
    let run: Runner

    static func parseURI(_ uri: String) throws -> (bucket: String, key: String) {
        guard uri.hasPrefix("s3://"), let slash = uri.dropFirst(5).firstIndex(of: "/") else { throw TaskStorageError.configuration }
        let bucket = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<slash])
        let key = String(uri[uri.index(after: slash)...])
        guard !bucket.isEmpty, !key.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty,
              !bucket.contains(where: { $0.isWhitespace || ":@?#".contains($0) }),
              !key.contains("?"), !key.contains("#") else { throw TaskStorageError.configuration }
        return (bucket, key)
    }

    init(uri: String, region: String? = nil, runner: Runner? = nil) throws {
        (bucket, key) = try Self.parseURI(uri)
        self.region = region
        if let runner { run = runner } else {
            let configured = TaskConfiguration.value("TASKS_AWS_CLI", defaultsKey: "awsPath")
            let candidates = configured.map { [$0] } ?? ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "\(NSHomeDirectory())/.local/bin/aws", "/usr/bin/aws"]
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw TaskStorageError.unavailable("AWS CLI not found; install a current AWS CLI or set TASKS_AWS_CLI.")
            }
            run = { try TaskCommand.run(executable: executable, arguments: $0) }
        }
    }

    static func configured() throws -> S3TaskStore {
        guard let uri = TaskConfiguration.s3URI else { throw TaskStorageError.configuration }
        return try S3TaskStore(uri: uri, region: TaskConfiguration.region)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func aws(_ arguments: [String]) throws -> [String: Any] {
        var args = ["s3api"] + arguments + ["--output", "json", "--no-cli-pager", "--cli-connect-timeout", "10", "--cli-read-timeout", "20"]
        if let region { args += ["--region", region] }
        let (status, output, errors) = try run(args)
        guard status == 0 else { throw TaskStorageError.from(stderr: String(data: errors, encoding: .utf8) ?? "") }
        guard let metadata = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw TaskStorageError.requestFailed
        }
        return metadata
    }

    func read() throws -> Snapshot {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("document.json")
        let metadata = try aws(["get-object", "--bucket", bucket, "--key", key, file.path])
        guard let etag = metadata["ETag"] as? String, !etag.isEmpty else {
            throw TaskStorageError.unavailable("S3 response has no ETag; refusing an unsafe update.")
        }
        let data = try Data(contentsOf: file)
        return Snapshot(document: try TaskDocument.decode(data), etag: etag, data: data)
    }

    private func put(key: String, data: Data, condition: [String]) throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("document.json")
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try aws(["put-object", "--bucket", bucket, "--key", key, "--body", file.path, "--content-type", "application/json"] + condition)
    }

    func append(row: [String]) throws {
        _ = try TaskDocument.decode(JSONEncoder().encode(TaskDocument(version: 1, rows: [row])))
        for _ in 0..<3 {
            let snapshot = try read()
            if snapshot.document.rows.contains(where: { $0[0] == row[0] }) { return }
            var document = snapshot.document
            document.rows.append(row)
            let data = try JSONEncoder().encode(document)
            _ = try TaskDocument.decode(data)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try put(key: "\(key).history/\(stamp)-\(UUID().uuidString).json", data: snapshot.data, condition: ["--if-none-match", "*"])
            do {
                try put(key: key, data: data, condition: ["--if-match", snapshot.etag])
                return
            } catch TaskStorageError.conflict { continue } catch TaskStorageError.requestFailed {
                if let confirmed = try? read(), confirmed.document.rows == document.rows { return }
                throw TaskStorageError.unconfirmedWrite
            }
        }
        throw TaskStorageError.conflict
    }
}
