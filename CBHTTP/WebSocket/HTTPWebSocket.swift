// Copyright (c) 2017-2019 Coinbase Inc. See LICENSE

import RxSwift
import Starscream

/// Represents an HTTP web socket
public final class HTTPWebSocket: WebSocketDelegate {
    private let socket: WebSocket
    private let incomingSubject = PublishSubject<HTTPWebSocketIncomingDataType>()
    private let connectionStateSubject = BehaviorSubject<HTTPWebSocketConnectionState>(value: .disconnected(nil))
    private let minReconnectDelay: TimeInterval
    private let maxReconnectDelay: TimeInterval
    private let connectionTimeout: TimeInterval
    private var isAutoReconnectEnabled = false
    private var reconnectAttempts: UInt64 = 0

    /// Observable for all incoming text or data messages
    public let incomingObservable: Observable<HTTPWebSocketIncomingDataType>

    /// Observable for web socket connection state
    public let connectionStateObservable: Observable<HTTPWebSocketConnectionState>

    /// Default constructor for given URL
    ///
    /// - Parameters:
    ///     - url: Websocket URL
    ///     - connectionTimeout: number of seconds before connection attempts timeout.
    ///     - minReconnectDelay: Min number of seconds to wait before reconnecting.
    ///     - maxReconnectDelay: Max number of seconds to wait before reconnecting.
    public init(
        url: URL,
        connectionTimeout: TimeInterval = 15,
        minReconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 5
    ) {
        socket = WebSocket(url: url)
        self.connectionTimeout = connectionTimeout
        self.minReconnectDelay = minReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        incomingObservable = incomingSubject.asObservable()
        connectionStateObservable = connectionStateSubject.asObservable()
        socket.delegate = self
    }

    /// Connect to given web socket
    ///
    /// - Returns: A single indication a successful connection. Otherwise, an error is thrown.
    public func connect() -> Single<Void> {
        isAutoReconnectEnabled = true
        if socket.isConnected {
            return .just(())
        }

        socket.connect()

        return connectionStateObservable
            .filter { $0.isConnected }
            .take(1)
            .asSingle()
            .timeout(connectionTimeout, scheduler: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .flatMap { _ in .just(()) }
    }

    /// Disconnect from websocket if connection is live
    ///
    /// - Returns: A single indication connection was terminated
    public func disconnect() -> Single<Void> {
        isAutoReconnectEnabled = false

        guard socket.isConnected else { return .just(()) }

        socket.disconnect()

        return connectionStateObservable
            .filter { !$0.isConnected }
            .take(1)
            .asSingle()
            .flatMap { _ in .just(()) }
    }

    /// Send string-based message to server
    ///
    /// - Parameters:
    ///     - string: String-based message to send
    ///
    /// - Returns: A single wrapping `Void` fired when send request completes
    public func send(string: String) -> Single<Void> {
        return Single.create { observer -> Disposable in
            self.socket.write(string: string) { observer(.success(())) }
            return Disposables.create()
        }
    }

    /// Send string-based message to server
    ///
    /// - Parameters:
    ///     - string: Data-based message to send
    ///
    /// - Returns: A single wrapping `Void` fired when send request completes
    public func send(data: Data) -> Single<Void> {
        return Single.create { observer -> Disposable in
            self.socket.write(data: data) { observer(.success(())) }
            return Disposables.create()
        }
    }

    deinit {
        _ = disconnect().subscribe()
    }

    // MARK: - WebSocketDelegate

    public func websocketDidConnect(socket _: WebSocketClient) {
        reconnectAttempts = 0
        connectionStateSubject.onNext(.connected)
    }

    public func websocketDidDisconnect(socket _: WebSocketClient, error: Error?) {
        connectionStateSubject.onNext(.disconnected(error))

        if isAutoReconnectEnabled {
            reconnectAttempts += 1

            let delay = min(minReconnectDelay * TimeInterval(reconnectAttempts), maxReconnectDelay)

            _ = Internet.statusChanges
                .filter { $0.isOnline }
                .take(1)
                .delay(RxTimeInterval(delay), scheduler: ConcurrentDispatchQueueScheduler(qos: .background))
                .map { [weak self] _ in self?.socket.connect() }
                .asSingle()
                .subscribe()
        }
    }

    public func websocketDidReceiveMessage(socket _: WebSocketClient, text: String) {
        incomingSubject.onNext(.string(text))
    }

    public func websocketDidReceiveData(socket _: WebSocketClient, data: Data) {
        incomingSubject.onNext(.data(data))
    }
}
