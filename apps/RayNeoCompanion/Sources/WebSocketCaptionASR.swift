import Foundation
import RayNeoCaptions

@MainActor protocol CaptionSocket: AnyObject {
    var httpStatus: Int? { get }
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

private final class CaptionSocketDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // A provider key must never follow a redirect to another host.
    }
}

@MainActor private final class NativeCaptionSocket: CaptionSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: CaptionSocketDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 262_144
    }
    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

/// One selected service per session. A serial sender bounds pending PCM, and every
/// asynchronous result is gated by generation so a stopped socket cannot leak into a new session.
@MainActor final class WebSocketCaptionASR: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    private let service: CaptionService
    private let makeSocket: (URLRequest) -> CaptionSocket
    private var socket: CaptionSocket?
    private var generation = UUID()
    private var buffer = CaptionAudioBuffer()
    private var receiver: Task<Void, Never>?, sender: Task<Void, Never>?, keepAlive: Task<Void, Never>?
    private var ready = false, keepAliveDue = false
    private var lastSent: TimeInterval = 0

    init(service: CaptionService, makeSocket: ((URLRequest) -> CaptionSocket)? = nil) {
        self.service = service
        self.makeSocket = makeSocket ?? { NativeCaptionSocket(request: $0) }
    }
    func start(options: CaptionOptions, key: String) {
        stop()
        do {
            guard options.service == service else { throw CaptionConnectionFailure.configuration }
            let connection = makeSocket(try CaptionStreamingAPI.request(options: options, key: key))
            socket = connection; let token = generation
            lastSent = ProcessInfo.processInfo.systemUptime
            connection.resume()
            receiver = Task { [weak self, connection] in
                do {
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        guard let self, self.generation == token else { return }
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: throw CaptionConnectionFailure.invalidResponse
                        }
                        self.accept(try CaptionStreamingAPI.event(data, service: self.service))
                    }
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.fail((error as? CaptionConnectionFailure) ?? .httpStatus(connection.httpStatus))
                }
            }
            if service == .deepgram {
                keepAlive = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                        guard let self, self.generation == token else { return }
                        if ProcessInfo.processInfo.systemUptime - self.lastSent >= 3 {
                            self.keepAliveDue = true; self.pump()
                        }
                    }
                }
            }
        } catch { fail((error as? CaptionConnectionFailure) ?? .configuration) }
    }
    func append(_ pcm: Data) {
        guard socket != nil else { return }
        do { try buffer.append(pcm); pump() }
        catch { fail((error as? CaptionConnectionFailure) ?? .backpressure) }
    }
    private func accept(_ event: CaptionStreamEvent) {
        switch event {
        case .ready: markReady(); pump()
        case .text(let text, let final): onText?(text, final)
        case .failure(let failure): fail(failure)
        case .ignored: break
        }
    }
    private func markReady() {
        guard !ready else { return }; ready = true; onReady?()
    }
    private func nextMessage() throws -> URLSessionWebSocketTask.Message? {
        if let pcm = buffer.next() {
            return service == .deepgram ? .data(pcm) : .string(try CaptionStreamingAPI.elevenLabsAudio(pcm))
        }
        if keepAliveDue { keepAliveDue = false; return .string("{\"type\":\"KeepAlive\"}") }
        return nil
    }
    private func pump() {
        guard sender == nil, let connection = socket, service == .deepgram || ready else { return }
        let token = generation
        sender = Task { [weak self, connection] in
            do {
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    guard let message = try self.nextMessage() else { self.sender = nil; return }
                    try await connection.send(message)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.lastSent = ProcessInfo.processInfo.systemUptime
                    // URLSession completes send only after the WebSocket handshake succeeds.
                    if self.service == .deepgram { self.markReady() }
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.fail((error as? CaptionConnectionFailure) ?? .httpStatus(connection.httpStatus))
            }
        }
    }
    private func fail(_ failure: CaptionConnectionFailure) {
        stop(); onFailure?(failure) // Raw server errors, headers and keys never reach UI/history/logs.
    }
    func stop() {
        generation = UUID()
        receiver?.cancel(); sender?.cancel(); keepAlive?.cancel()
        receiver = nil; sender = nil; keepAlive = nil
        socket?.close(); socket = nil; buffer = CaptionAudioBuffer()
        ready = false; keepAliveDue = false
    }
}
