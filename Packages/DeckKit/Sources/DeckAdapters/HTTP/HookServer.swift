//
//  HookServer.swift · DeckAdapters/HTTP
//
//  The hook server. The only module in this repository allowed a socket.
//
//  No network egress: the listener pins its bind address to 127.0.0.1 and no
//  configuration path can point it elsewhere.
//
//  How a hook reaches this: Claude Code runs the configured command with the
//  payload on stdin and reads the command's stdout as the response. The
//  installed command is `curl -s -X POST --data-binary @-
//  http://127.0.0.1:PORT/hook`, so curl's stdin is the payload and curl's
//  stdout is whatever this returns.
//

import Foundation
import Network
import DeckCore
import DeckPorts

public actor HookServer: HookServerPort {

    /// What the deck decides for a held call, handed back as the hook's stdout.
    public typealias Decide = @Sendable (HookEvent) async -> String
    /// What the deck renders for a statusline line. The statusLine command's
    /// stdout is the terminal's rendered line, so the return value is
    /// user-visible text: short, and composed from Diagnostic-grade facts,
    /// never payload bytes.
    public typealias Statusline = @Sendable (JSONValue) async -> String

    private var listener: NWListener?
    private let decide: Decide
    private let statusline: Statusline
    private let queue = DispatchQueue(label: "deck.hook.server")

    public init(decide: @escaping Decide,
                statusline: @escaping Statusline = { _ in "" }) {
        self.decide = decide
        self.statusline = statusline
    }

    public func start(port: UInt16) async throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // Pin the bind address. Without `requiredLocalEndpoint` a listener accepts
        // on every interface, which would break the no-egress rule by omission.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        let decide = self.decide
        let statusline = self.statusline
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "deck.hook.conn"))
            Task { await Self.serve(connection, decide: decide, statusline: statusline) }
        }
        // Wait for the bind to actually succeed. `NWListener` binds asynchronously;
        // a port already held by another process puts it in `.failed`, and
        // returning early would report "listening" while accepting nothing.
        try await withCheckedThrowingContinuation { (continuation:
            CheckedContinuation<Void, Error>) in
            let once = OneShot(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.succeed()
                case .failed(let error): once.fail(error)
                case .cancelled: once.fail(PortFailure.unavailable("the listener was cancelled"))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A continuation that can only be resumed once.
    ///
    /// `stateUpdateHandler` fires on every transition, and a listener that
    /// goes `.ready` and later `.failed` would otherwise resume twice — which
    /// in Swift is a crash, not a warning.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        private func take() -> CheckedContinuation<Void, Error>? {
            lock.lock(); defer { lock.unlock() }
            let c = continuation; continuation = nil; return c
        }
        func succeed() { take()?.resume() }
        func fail(_ error: Error) { take()?.resume(throwing: error) }
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
    }

    // ------------------------------------------------------------------ HTTP
    private static func serve(_ connection: NWConnection, decide: @escaping Decide,
                              statusline: @escaping Statusline) async {
        defer { connection.cancel() }
        guard let request = await receive(connection) else { return }
        guard let body = Self.body(of: request), let json = JSONValue.parse(body) else {
            await send(connection, status: "400 Bad Request", body: "{}")
            return
        }
        // The statusline route is split by path: its payload has no
        // hook_event_name, so path routing keeps the two protocols apart.
        if request.hasPrefix("POST /statusline") || request.hasPrefix("GET /statusline") {
            let line = await statusline(json)
            await send(connection, status: "200 OK", body: line)
            return
        }
        // The caller stamps receipt time (see `stamp`), not the core.
        // The host's identity rides in the query, added by the hook itself: a
        // hook inherits its session's environment, so the session reports where
        // it lives. Absent outside cmux, which decodes to no address.
        let host = Self.query(of: request)
        var row: [String: JSONValue] = ["payload": json,
                                        "ts": .string(stamp(json)),
                                        "tool": json["tool_name"] ?? .null]
        if let surface = host["surface"], !surface.isEmpty { row["surface"] = .string(surface) }
        if let workspace = host["workspace"], !workspace.isEmpty { row["workspace"] = .string(workspace) }
        guard let event = HookIngest.event(from: .object(row), epochBase: 0) else {
            await send(connection, status: "200 OK", body: "{}")
            return
        }
        let response = await decide(event)
        await send(connection, status: "200 OK", body: response)
    }

    /// The payload carries no timestamp of its own, so the receipt is stamped
    /// here. This is the one place on the hook path that reads a clock, and it
    /// is an adapter.
    private static func stamp(_ payload: JSONValue) -> String {
        let seconds = Date().timeIntervalSince1970
        let millis = Int64((seconds * 1000).rounded())
        return isoString(fromEpochMillis: millis)
    }

    static func isoString(fromEpochMillis millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    /// The request line's query, percent-decoded. Only the two keys the deck
    /// puts there are read; anything else somebody appends is ignored rather
    /// than being an error.
    static func query(of request: String) -> [String: String] {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first
                ?? request.split(separator: "\n", maxSplits: 1).first else { return [:] }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let mark = parts[1].firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in parts[1][parts[1].index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let raw = kv.count > 1 ? String(kv[1]) : ""
            out[String(key)] = raw.removingPercentEncoding ?? raw
        }
        return out
    }

    static func body(of request: String) -> String? {
        guard let separator = request.range(of: "\r\n\r\n") ?? request.range(of: "\n\n")
        else { return nil }
        return String(request[separator.upperBound...])
    }

    /// The most a hook payload may be. Real ones are a few kilobytes; the cap
    /// exists so a client declaring `Content-Length: 999999999999` cannot make
    /// the deck hold that much memory waiting for it.
    static let maximumBody = 4 << 20

    /// How long one request gets to arrive, so a local process that opens a
    /// connection and trickles bytes (or none) cannot hold it open forever.
    static let readTimeout: Duration = .seconds(15)

    // Reads in an `await` loop that owns the buffer, one chunk at a time, so
    // there is no captured mutable state to race.
    private static func receive(_ connection: NWConnection) async -> String? {
        var accumulated = Data()
        let deadline = ContinuousClock.now + readTimeout
        while true {
            if ContinuousClock.now >= deadline { break }
            let (chunk, finished) = await receiveOnce(connection)
            if let chunk { accumulated.append(chunk) }
            // Refuse rather than grow: a body past the cap is never a valid request.
            if accumulated.count > maximumBody { return nil }
            let text = String(decoding: accumulated, as: UTF8.self)
            if finished || isComplete(text) { return text.isEmpty ? nil : text }
            if chunk == nil { return text.isEmpty ? nil : text }
        }
        let text = String(decoding: accumulated, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func receiveOnce(_ connection: NWConnection) async -> (Data?, Bool) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete || error != nil))
            }
        }
    }

    /// A request is complete when its body has reached the declared
    /// `Content-Length`. Waiting for the peer to close instead would hang on
    /// every keep-alive client, and curl is one.
    static func isComplete(_ request: String) -> Bool {
        guard let body = body(of: request) else { return false }
        guard let range = request.range(of: "Content-Length:", options: .caseInsensitive) else {
            return !body.isEmpty
        }
        let tail = request[range.upperBound...]
        let digits = tail.prefix { $0 == " " || $0.isNumber }.trimmingCharacters(in: .whitespaces)
        guard let expected = Int(digits) else { return !body.isEmpty }
        return body.utf8.count >= expected
    }

    private static func send(_ connection: NWConnection, status: String, body: String) async {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(response.utf8),
                            completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

public enum HookResponse {
    /// The wire forms, byte for byte. There are two, because the two events that
    /// can want a human answer differently:
    ///
    ///   PreToolUse         hookSpecificOutput.permissionDecision = allow|deny
    ///   PermissionRequest  hookSpecificOutput.decision = {behavior: allow|deny}
    ///
    /// Answering one event in the other's shape is not reported as an error:
    /// the engine ignores the unknown field and the deck looks ignored.
    ///
    /// `suggestions` is the hold's raw `permission_suggestions` array, needed
    /// only by `allowAndRemember` to pick the element it echoes back; `nil`
    /// otherwise.
    public static func decision(_ resolution: Resolution, reason: String,
                                event: HookKind = .preToolUse,
                                suggestions: JSONValue? = nil) -> String {
        if case .permissionRequest = event {
            switch resolution {
            case .allow:
                // No `message` member: per the CLI 2.1.223 schema, the allow branch of
                // `PermissionRequest`'s `decision` has only `updatedInput?` and
                // `updatedPermissions?`. A strict schema may reject the whole reply
                // silently, so an extra field can make Allow never land.
                return """
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest",\
                "decision":{"behavior":"allow"}}}
                """
            case .deny:
                // The deny branch does carry `message` (schema-valid).
                return """
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest",\
                "decision":{"behavior":"deny",\
                "message":\(json: reason)}}}
                """
            case .allowAndRemember(let index):
                // Echoing a suggestion back as `updatedPermissions` is clicking Claude
                // Code's own option 2, "Yes, and don't ask again for: X". The chosen
                // element goes through `WritePlan.render` (the settings writer's
                // serialiser), so a rule the engine sent comes back unchanged.
                // Value-verbatim, not byte-verbatim: `render` sorts object keys,
                // which the engine does not care about.
                if let raw = suggestions?.arrayValue, raw.indices.contains(index) {
                    return """
                    {"hookSpecificOutput":{"hookEventName":"PermissionRequest",\
                    "decision":{"behavior":"allow",\
                    "updatedPermissions":[\(WritePlan.render(raw[index]))]}}}
                    """
                }
                // No suggestion at that index (stale button, or a hold opened with
                // none): degrade to a plain allow rather than name a rule the deck
                // cannot back.
                return """
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest",\
                "decision":{"behavior":"allow"}}}
                """
            // `.answeredElsewhere` is a `.preToolUse`-kind resolution and should be
            // unreachable here; `{}` ("declines to decide") is the honest answer.
            case .release, .expire, .updatedInput, .answeredElsewhere:
                return "{}"
            }
        }
        switch resolution {
        case .allow:
            return """
            {"hookSpecificOutput":{"hookEventName":"PreToolUse",\
            "permissionDecision":"allow",\
            "permissionDecisionReason":\(json: reason)}}
            """
        case .deny:
            return """
            {"hookSpecificOutput":{"hookEventName":"PreToolUse",\
            "permissionDecision":"deny",\
            "permissionDecisionReason":\(json: reason)}}
            """
        case .allowAndRemember:
            // A `PreToolUse` hold is an `AskUserQuestion`, which never carries
            // `permission_suggestions` (that belongs to `PermissionRequest`), so
            // `DecisionBar` never offers this button here. Encoded defensively as
            // plain allow rather than claim a rule there is nothing to name.
            return """
            {"hookSpecificOutput":{"hookEventName":"PreToolUse",\
            "permissionDecision":"allow",\
            "permissionDecisionReason":\(json: reason)}}
            """
        // Release is not deny. An empty object is the deck declining to decide,
        // which lets the engine's own policy run.
        //
        // `permissionDecision: "ask"` is the documented spelling of the same
        // thing, but is deliberately not used: `{}` is verified against live
        // holds, `ask` has only been read about.
        case .release, .expire:
            return "{}"
        case .updatedInput:
            // A question's answer is not a permission decision. See `answered(_:)`.
            return "{}"
        case .answeredElsewhere:
            // The terminal already answered, so there is nothing to say over this
            // connection. `{}` is the same "no opinion" reply `.release` sends.
            return "{}"
        }
    }

    /// The wire form of an answered question.
    ///
    /// Documented shape: `allow` with `updatedInput` directly under
    /// `hookSpecificOutput` (`PermissionRequest` puts the same field one level
    /// deeper, inside `decision`). `allow` alone is not enough: the tool would
    /// run with no answer in it.
    ///
    /// `answers` is keyed by each question's own text and valued with the
    /// selected option's label, or an array of labels for a multi-select; this
    /// matches the `AskUserQuestion` `PostToolUse` rows in the corpus.
    ///
    /// The `questions` half of `updatedInput` is the tool's own input, echoed
    /// from `call.rawQuestions` through `WritePlan.render`, not rebuilt from the
    /// decoded model: a rebuilt array drops any key the model does not decode
    /// (`preview`, or one that does not exist yet). It is reconstructed only
    /// when `rawQuestions` is nil or not an array (hand-built test calls).
    public static func answered(_ call: QuestionCall, _ answers: [Answer]) -> String {
        let questionsJSON: String
        if let raw = call.rawQuestions, raw.arrayValue != nil {
            questionsJSON = WritePlan.render(raw)
        } else {
            let questions = call.questions.map { q -> String in
                let options = q.options.map {
                    "{\"label\":\(json: $0.label.value),\"description\":\(json: $0.detail.value)}"
                }
                return "{\"question\":\(json: q.text.value),\"header\":\(json: q.header.value),"
                    + "\"options\":[\(options.joined(separator: ","))],"
                    + "\"multiSelect\":\(q.multiSelect)}"
            }
            questionsJSON = "[\(questions.joined(separator: ","))]"
        }
        let map = answers.map { a -> String in
            // One label is a string; several are an array. The wire distinguishes
            // them, so the deck must too — a multi-select answer flattened into
            // one comma-joined string is a different answer.
            let value = a.labels.count == 1
                ? "\(json: a.labels[0].value)"
                : "[\(a.labels.map { "\(json: $0.value)" }.joined(separator: ","))]"
            return "\(json: a.question.value):\(value)"
        }
        return "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
            + "\"permissionDecision\":\"allow\","
            + "\"permissionDecisionReason\":\"deck\","
            + "\"updatedInput\":{\"questions\":\(questionsJSON),"
            + "\"answers\":{\(map.joined(separator: ","))}}}}"
    }

    public static let none = "{}"
}

extension String.StringInterpolation {
    /// JSON-escape at the point of interpolation, so a value cannot reach the
    /// wire unescaped by someone forgetting to call a function. Question text is
    /// Claude's prose and routinely contains quotes and apostrophes; a hand-built
    /// JSON string that does not escape them produces a body the engine rejects,
    /// and the failure would look like the deck ignoring the answer.
    mutating func appendInterpolation(json value: String) {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        appendLiteral(out + "\"")
    }
}
