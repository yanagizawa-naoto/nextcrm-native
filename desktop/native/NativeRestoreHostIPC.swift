import Foundation
import Darwin

enum NativeRestoreHostIPCFailure: Error, Equatable {
    case invalidDescriptor, closed, cancelled, timedOut, invalidFrame, incompleteFrame, tooLarge, io, invalidMessage, handoffNotIdle
}

private final class NativeRestoreHostIPCOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: NativeRestoreHostIPCFailure?
    private var onFailure: ((NativeRestoreHostIPCFailure) -> Void)?
    private var timer: DispatchSourceTimer?
    let deadline: TimeInterval?
    init(timeout: TimeInterval?) throws {
        if let timeout {
            guard timeout.isFinite, timeout >= 0, timeout <= 86400 else { throw NativeRestoreHostIPCFailure.timedOut }
            deadline = ProcessInfo.processInfo.systemUptime + timeout
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.fail(.timedOut) }
            self.timer = timer; timer.resume()
        } else { deadline = nil }
    }
    deinit { timer?.cancel() }
    private func fail(_ error: NativeRestoreHostIPCFailure) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error; let action = onFailure; onFailure = nil; lock.unlock()
        action?(error)
    }
    func cancel() { fail(.cancelled) }
    func observeFailure(_ action: @escaping (NativeRestoreHostIPCFailure) -> Void) {
        lock.lock(); let error = failure; if error == nil { onFailure = action }; lock.unlock()
        if let error { action(error) }
    }
    func clearObserver() { lock.lock(); onFailure = nil; lock.unlock() }
    func check() throws {
        lock.lock(); let error = failure; lock.unlock()
        if let error { throw error }
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw NativeRestoreHostIPCFailure.timedOut }
    }
    var pollMilliseconds: Int32 {
        guard let deadline else { return 20 }
        return Int32(max(0, min(20, ceil((deadline - ProcessInfo.processInfo.systemUptime) * 1000))))
    }
}

/// FIFO admission suspends callers instead of occupying cooperative executor
/// threads. Only the admitted read and write use blocking OS I/O, on GCD.
private final class NativeRestoreHostIPCSerial: @unchecked Sendable {
    private struct Waiter {
        let id: UUID, operation: NativeRestoreHostIPCOperation
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var busy = false, closed = false, waiters: [Waiter] = []
    #if RESTORE_HOST_IPC_TESTS
    var testingState: (Bool, Int) { lock.lock(); defer { lock.unlock() }; return (busy, waiters.count) }
    #endif
    func acquire(_ operation: NativeRestoreHostIPCOperation) async throws {
        let id = UUID()
        operation.observeFailure { [weak self] error in self?.remove(id, error: error) }
        defer { operation.clearObserver() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            do {
                try operation.check()
                guard !closed else { throw NativeRestoreHostIPCFailure.closed }
                if busy { waiters.append(.init(id: id, operation: operation, continuation: continuation)); lock.unlock() }
                else { busy = true; lock.unlock(); continuation.resume() }
            } catch { lock.unlock(); continuation.resume(throwing: error) }
        }
    }
    private func remove(_ id: UUID, error: NativeRestoreHostIPCFailure) {
        lock.lock()
        let index = waiters.firstIndex { $0.id == id }
        let waiter = index.map { waiters.remove(at: $0) }; lock.unlock()
        waiter?.continuation.resume(throwing: error)
    }
    func release() {
        var rejected: [(Waiter, Error)] = [], next: Waiter?
        lock.lock()
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            do { try waiter.operation.check(); next = waiter; break }
            catch { rejected.append((waiter, error)) }
        }
        busy = next != nil; lock.unlock()
        for (waiter, error) in rejected { waiter.continuation.resume(throwing: error) }
        next?.continuation.resume()
    }
    func close() {
        lock.lock(); closed = true; let pending = waiters; waiters = []; lock.unlock()
        for waiter in pending { waiter.continuation.resume(throwing: NativeRestoreHostIPCFailure.closed) }
    }
}

/// Private, inherited Unix socket only. This is transport, not administrator
/// authority: the host must bind messages to the registered process, selected
/// roots, candidate seal and a fresh approval. Payloads are never logged here.
final class NativeRestoreHostIPC: @unchecked Sendable {
    static let maximumMessageBytes = 262144
    private let state = NSLock(), sending = NativeRestoreHostIPCSerial(), receiving = NativeRestoreHostIPCSerial()
    private var descriptor: Int32
    private var performedIO = false
    #if RESTORE_HOST_IPC_TESTS
    var testingReceiveState: (Bool, Int) { receiving.testingState }
    var testingSendState: (Bool, Int) { sending.testingState }
    var testingDidStartIO: Bool { state.lock(); defer { state.unlock() }; return performedIO }
    func testingDuplicate() throws -> Int32 { try duplicateForIO() }
    #endif

    /// Consumes owned fd >= 3 on success and failure. A handoff is an explicit
    /// dup2 of takeForHandoff(), never an inherited descriptor sweep.
    init(consumingConnectedSocket fd: Int32) throws {
        guard fd >= 3 else { throw NativeRestoreHostIPCFailure.invalidDescriptor }
        var type: Int32 = 0, typeLength = socklen_t(MemoryLayout<Int32>.size)
        var address = sockaddr_un(), addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let addressResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressLength) }
        }
        var uid: uid_t = 0, gid: gid_t = 0, noSignal: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeLength) == 0, type == SOCK_STREAM,
              addressResult == 0, address.sun_family == sa_family_t(AF_UNIX),
              getpeereid(fd, &uid, &gid) == 0, uid == geteuid(), flags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd); throw NativeRestoreHostIPCFailure.invalidDescriptor
        }
        descriptor = fd
    }
    static func pair() throws -> (NativeRestoreHostIPC, NativeRestoreHostIPC) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw NativeRestoreHostIPCFailure.io }
        // A helper can legitimately start with all three stdio slots closed.
        // Internal descriptors must never be mistaken for inherited stdio.
        for i in fds.indices where fds[i] < 3 {
            let copy = fcntl(fds[i], F_DUPFD_CLOEXEC, 3)
            guard copy >= 0 else { fds.forEach { Darwin.close($0) }; throw NativeRestoreHostIPCFailure.io }
            Darwin.close(fds[i]); fds[i] = copy
        }
        let first: NativeRestoreHostIPC
        do { first = try .init(consumingConnectedSocket: fds[0]) }
        catch { Darwin.close(fds[1]); throw error }
        do { return (first, try .init(consumingConnectedSocket: fds[1])) }
        catch { first.close(); throw error }
    }
    deinit { close() }
    var isClosed: Bool { state.lock(); defer { state.unlock() }; return descriptor < 0 }
    func close() {
        state.lock(); let fd = descriptor; descriptor = -1
        // shutdown affects outstanding duplicates too, interrupting blocked I/O.
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        state.unlock()
        sending.close(); receiving.close()
    }
    private func duplicateForIO() throws -> Int32 {
        state.lock(); defer { state.unlock() }
        guard descriptor >= 0 else { throw NativeRestoreHostIPCFailure.closed }
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else { throw NativeRestoreHostIPCFailure.io }
        performedIO = true
        return copy
    }
    /// Atomically consumes a never-used endpoint. No old read or write may
    /// race a child's protocol. Close the returned descriptor after explicit
    /// spawn/adoption; do not shutdown it while a child holds a duplicate.
    func takeForHandoff() throws -> Int32 {
        state.lock()
        guard descriptor >= 0 else { state.unlock(); throw NativeRestoreHostIPCFailure.closed }
        guard !performedIO else { state.unlock(); throw NativeRestoreHostIPCFailure.handoffNotIdle }
        let fd = descriptor; descriptor = -1; state.unlock()
        sending.close(); receiving.close()
        return fd
    }
    private func poll(_ fd: Int32, event: Int16, operation: NativeRestoreHostIPCOperation) throws {
        while true {
            try operation.check()
            guard !isClosed else { throw NativeRestoreHostIPCFailure.closed }
            var p = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&p, 1, operation.pollMilliseconds)
            if result < 0 { if errno == EINTR { continue }; throw NativeRestoreHostIPCFailure.io }
            if result == 0 { continue }
            if p.revents & Int16(POLLNVAL) != 0 { throw NativeRestoreHostIPCFailure.invalidDescriptor }
            if p.revents & (event | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
        }
    }
    private func read(_ count: Int, fd: Int32, operation: NativeRestoreHostIPCOperation) throws -> Data {
        guard count > 0, count <= Self.maximumMessageBytes else { throw NativeRestoreHostIPCFailure.invalidFrame }
        var data = Data(count: count), consumed = 0
        try data.withUnsafeMutableBytes { buffer in
            while consumed < count {
                try poll(fd, event: Int16(POLLIN), operation: operation)
                let amount = Darwin.read(fd, buffer.baseAddress!.advanced(by: consumed), count - consumed)
                if amount > 0 { consumed += amount; continue }
                if amount == 0 { throw consumed == 0 ? NativeRestoreHostIPCFailure.closed : .incompleteFrame }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw NativeRestoreHostIPCFailure.io
            }
        }
        return data
    }
    private func write(_ data: Data, fd: Int32, operation: NativeRestoreHostIPCOperation) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            while sent < data.count {
                try poll(fd, event: Int16(POLLOUT), operation: operation)
                let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), data.count - sent)
                if amount > 0 { sent += amount; continue }
                if amount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw NativeRestoreHostIPCFailure.io
            }
        }
    }
    private func perform<T>(_ serial: NativeRestoreHostIPCSerial, operation: NativeRestoreHostIPCOperation,
                            body: @escaping (Int32) throws -> T) async throws -> T {
        try await serial.acquire(operation)
        defer { serial.release() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    try operation.check()
                    let fd = try duplicateForIO(); defer { Darwin.close(fd) }
                    continuation.resume(returning: try body(fd))
                } catch {
                    // A cancelled/failed partial frame cannot be reused.
                    close(); continuation.resume(throwing: error)
                }
            }
        }
    }
    func send<T: Encodable>(_ value: T, timeout: TimeInterval? = 15) async throws {
        let operation = try NativeRestoreHostIPCOperation(timeout: timeout)
        try await withTaskCancellationHandler(operation: {
            try await sending.acquire(operation)
            defer { sending.release() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async { [self] in
                    var touchedWire = false
                    do {
                        // Only one encoded message is retained per direction.
                        // Local typed messages must still bound their own fields:
                        // Foundation's encoder has no streaming byte ceiling.
                        try operation.check()
                        let bytes: Data
                        do { bytes = try JSONEncoder().encode(value) }
                        catch { throw NativeRestoreHostIPCFailure.invalidMessage }
                        guard !bytes.isEmpty, bytes.count <= Self.maximumMessageBytes else { throw NativeRestoreHostIPCFailure.tooLarge }
                        try operation.check()
                        let fd = try duplicateForIO(); defer { Darwin.close(fd) }
                        touchedWire = true
                        let n = UInt32(bytes.count)
                        let header = Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
                        try write(header, fd: fd, operation: operation)
                        try write(bytes, fd: fd, operation: operation)
                        continuation.resume()
                    } catch {
                        if touchedWire { close() }
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { operation.cancel() })
    }
    func receive<T: Decodable>(_ type: T.Type, timeout: TimeInterval? = 15) async throws -> T {
        let operation = try NativeRestoreHostIPCOperation(timeout: timeout)
        return try await withTaskCancellationHandler(operation: {
            try await perform(receiving, operation: operation) { [self] fd in
                let header = try read(4, fd: fd, operation: operation)
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0 else { throw NativeRestoreHostIPCFailure.invalidFrame }
                guard length <= UInt32(Self.maximumMessageBytes) else { throw NativeRestoreHostIPCFailure.tooLarge }
                let bytes: Data
                do { bytes = try read(Int(length), fd: fd, operation: operation) }
                catch NativeRestoreHostIPCFailure.closed { throw NativeRestoreHostIPCFailure.incompleteFrame }
                do { return try JSONDecoder().decode(type, from: bytes) }
                catch { throw NativeRestoreHostIPCFailure.invalidMessage }
            }
        }, onCancel: { operation.cancel() })
    }
}
