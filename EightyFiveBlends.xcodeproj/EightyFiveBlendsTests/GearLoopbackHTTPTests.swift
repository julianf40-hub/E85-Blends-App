//
//  GearLoopbackHTTPTests.swift
//  EightyFiveBlendsTests
//
//  GearBoundedDownloader against a REAL HTTP/1.1 server on the loopback interface, so the URL
//  loading system's own HTTP stack (Content-Length handling, chunked transfer encoding, response
//  delivery, cancellation closing the TCP connection) is exercised rather than a custom
//  URLProtocol, whose behaviour on Darwin differs (Xcode Cloud Build 288: stub chunks were batched,
//  and a fully held stub body kept the response from reaching the delegate).
//
//  The server is scripted per path: headers, body bytes sent at once, and bytes HELD until the test
//  releases them. It records the body bytes it actually sent and whether the client closed the
//  connection before the body was complete. "Client closed while the body was held" is the
//  server-side proof that the downloader cancelled the transfer.
//
//  REQUIRES APPLE FRAMEWORKS (Network). Plain http to 127.0.0.1 (an IP address, loopback only).
//  If App Transport Security refuses it in the test host, the tests fail with a message saying so.
//

#if canImport(Network)
import Foundation
import Network
import Testing
@testable import EightyFiveBlends

nonisolated final class GearLoopbackHTTPServer: @unchecked Sendable {
    nonisolated struct Route {
        var status = 200
        var headers: [(String, String)] = [("Content-Type", "application/json")]
        /// Send the body with `Transfer-Encoding: chunked` (no Content-Length).
        var chunked = false
        /// Body pieces sent right after the headers.
        var initial: [Data] = []
        /// Body pieces sent only after `release(_:)`; then the response ends.
        var held: [Data] = []
    }

    nonisolated struct Observation: Equatable {
        var requests = 0
        var sentBodyBytes = 0
        var completed = false
        var clientClosedEarly = false
    }

    private let queue = DispatchQueue(label: "GearLoopbackHTTPServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var observations: [String: Observation] = [:]
    private var waiting: [String: NWConnection] = [:]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func route(_ path: String, _ route: Route) {
        locked {
            routes[path] = route
            observations[path] = Observation()
        }
    }

    func observation(_ path: String) -> Observation {
        locked { observations[path] ?? Observation() }
    }

    /// Starts listening on an ephemeral loopback port and returns the base URL.
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        locked { self.listener = listener }
        /// Resumes the start continuation exactly once, from the listener's state handler.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Error>?
            init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
            func resume(_ result: Result<Void, Error>) {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume(with: result)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let error): once.resume(.failure(error))
                case .cancelled: once.resume(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        let (listener, connections) = locked { (self.listener, Array(waiting.values)) }
        connections.forEach { $0.cancel() }
        listener?.cancel()
    }

    /// Sends a held body and ends that response.
    func release(_ path: String) {
        guard let connection = locked({ waiting.removeValue(forKey: path) }) else { return }
        let route = locked { routes[path] } ?? Route()
        queue.async { [self] in
            for piece in route.held { send(piece, chunked: route.chunked, on: connection, path: path) }
            finish(connection, path: path, chunked: route.chunked)
        }
    }

    // MARK: Connection handling (on `queue`)

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let path = head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                respond(connection, path: path)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        guard let route = locked({ () -> Route? in
            observations[path]?.requests += 1
            return routes[path]
        }) else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(notFound.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        var head = "HTTP/1.1 \(route.status) OK\r\n"
        for (name, value) in route.headers { head += "\(name): \(value)\r\n" }
        if route.chunked { head += "Transfer-Encoding: chunked\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        for piece in route.initial { send(piece, chunked: route.chunked, on: connection, path: path) }
        watchForClientClose(connection, path: path)
        if route.held.isEmpty {
            finish(connection, path: path, chunked: route.chunked)
        } else {
            locked { waiting[path] = connection }
        }
    }

    private func send(_ piece: Data, chunked: Bool, on connection: NWConnection, path: String) {
        var framed = Data()
        if chunked { framed.append(Data((String(piece.count, radix: 16) + "\r\n").utf8)) }
        framed.append(piece)
        if chunked { framed.append(Data("\r\n".utf8)) }
        locked { observations[path]?.sentBodyBytes += piece.count }
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func finish(_ connection: NWConnection, path: String, chunked: Bool) {
        locked { observations[path]?.completed = true }
        let terminator = chunked ? Data("0\r\n\r\n".utf8) : Data()
        connection.send(content: terminator, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// After the request, a well-behaved client sends nothing more; the read completes only when
    /// it closes (or resets) the connection. Before the response finished, that means it gave up.
    private func watchForClientClose(_ connection: NWConnection, path: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [self] data, _, isComplete, error in
            if isComplete || error != nil {
                locked {
                    if observations[path]?.completed == false { observations[path]?.clientClosedEarly = true }
                    waiting[path] = nil
                }
            } else if data != nil {
                watchForClientClose(connection, path: path)
            }
        }
    }
}

@MainActor
struct GearLoopbackHTTPTests {
    private static func body(_ count: Int, size: Int) -> [Data] {
        (0..<count).map { Data(repeating: UInt8(65 + $0 % 26), count: size) }
    }

    private static func downloader() -> GearBoundedDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return GearBoundedDownloader(configuration: configuration, cancellationLogCapacity: 16)
    }

    /// Bounded wait for a server-side observation.
    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while condition() == false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func explainFixtureFailure(_ error: Error, sourceLocation: SourceLocation = #_sourceLocation) {
        if let urlError = error as? URLError, urlError.code == .appTransportSecurityRequiresSecureConnection {
            Issue.record("App Transport Security refused http://127.0.0.1 in the test host; the loopback fixture needs a local-networking exception", sourceLocation: sourceLocation)
        }
    }

    /// Sanity check that the fixture works end to end, so the failures below can't be fixture noise.
    @Test func fixtureServesABodyWithinTheLimit() async throws {
        let server = GearLoopbackHTTPServer()
        defer { server.stop() }
        server.route("/ok", .init(headers: [("Content-Type", "application/json"), ("Content-Length", "2000")],
                                  initial: Self.body(2, size: 1_000)))
        let base = try await server.start()
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        do {
            let (data, response) = try await GearDownloadTests.download(downloader, URLRequest(url: base.appendingPathComponent("ok")), limit: 2_500)
            #expect(response.statusCode == 200)
            #expect(data.count == 2_000)
            #expect(downloader.cancellationLog.isEmpty)
        } catch {
            Self.explainFixtureFailure(error)
            Issue.record("fixture request failed: \(error)")
        }
    }

    /// Content-Length 50,000 against a 2,500-byte limit: refused from the declared length. The
    /// server sends 1,000 body bytes and holds the rest; it must see the client close the
    /// connection with the held body never sent, and no body byte may be kept.
    @Test func declaredOversizeIsRefusedBeforeAcceptingBody() async throws {
        let server = GearLoopbackHTTPServer()
        defer { server.stop() }
        server.route("/declared", .init(headers: [("Content-Type", "application/json"), ("Content-Length", "50000")],
                                        initial: Self.body(1, size: 1_000), held: Self.body(49, size: 1_000)))
        let base = try await server.start()
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            do {
                _ = try await GearDownloadTests.download(downloader, URLRequest(url: base.appendingPathComponent("declared")), limit: 2_500)
            } catch {
                Self.explainFixtureFailure(error)
                throw error
            }
        }
        #expect(downloader.cancellationLog.map(\.reason) == [.declaredLengthOverLimit])
        #expect(downloader.cancellationLog.first?.retainedBytes == 0, "no body data accepted")
        await Self.waitUntil { server.observation("/declared").clientClosedEarly }
        let seen = server.observation("/declared")
        #expect(seen.clientClosedEarly, "the client closed the connection: the transfer was cancelled")
        #expect(seen.completed == false)
        #expect(seen.sentBodyBytes == 1_000, "the held body was never sent")
    }

    /// Chunked encoding (no Content-Length): 3,000 bytes sent, 17,000 held. The 2,500-byte limit is
    /// crossed by data actually received, and the client must close the connection while the rest
    /// is still held. How URLSession batches the 3,000 bytes into callbacks is not assumed.
    @Test func unknownLengthOverflowCancelsPromptly() async throws {
        let server = GearLoopbackHTTPServer()
        defer { server.stop() }
        server.route("/chunked", .init(chunked: true, initial: Self.body(3, size: 1_000), held: Self.body(17, size: 1_000)))
        let base = try await server.start()
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            do {
                _ = try await GearDownloadTests.download(downloader, URLRequest(url: base.appendingPathComponent("chunked")), limit: 2_500)
            } catch {
                Self.explainFixtureFailure(error)
                throw error
            }
        }
        #expect(downloader.cancellationLog.map(\.reason) == [.bodyOverLimit])
        #expect((downloader.cancellationLog.first?.retainedBytes ?? .max) <= 2_500)
        await Self.waitUntil { server.observation("/chunked").clientClosedEarly }
        let seen = server.observation("/chunked")
        #expect(seen.clientClosedEarly, "the client closed the connection while the body was held")
        #expect(seen.sentBodyBytes == 3_000, "the held 17,000 bytes were never sent")
    }

    /// 40,000 bytes sent at once: data keeps arriving after the limit is crossed. What the
    /// downloader keeps never exceeds the limit, and the rest is discarded.
    @Test func dataArrivingAfterTheLimitNeverExceedsIt() async throws {
        let server = GearLoopbackHTTPServer()
        defer { server.stop() }
        server.route("/burst", .init(chunked: true, initial: Self.body(40, size: 1_000)))
        let base = try await server.start()
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            do {
                _ = try await GearDownloadTests.download(downloader, URLRequest(url: base.appendingPathComponent("burst")), limit: 2_500)
            } catch {
                Self.explainFixtureFailure(error)
                throw error
            }
        }
        let log = downloader.cancellationLog
        #expect(log.count == 1)
        let retained = log.first?.retainedBytes ?? .max
        let ignored = log.first?.ignoredBytes ?? -1
        #expect(retained <= 2_500, "never more than the limit kept")
        #expect(ignored >= 0 && retained + ignored <= 40_000)
    }
}
#endif
