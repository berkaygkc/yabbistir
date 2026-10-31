import Foundation
import YabExtensionKit
import YabExtensionRuntime

/// How the client reaches an extension host: a line out, lines back.
public protocol HostTransport: AnyObject, Sendable {
    /// `onExit`: the host stopped without being asked to (it crashed or quit).
    func start(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) throws
    /// Queues the line; never waits for the host to read it.
    func send(_ line: Data)
    /// Drops the current host (and anything it was doing) and starts a fresh one.
    func restart() throws
    func stop()
}

public extension HostTransport {
    func start(onLine: @escaping @Sendable (Data) -> Void) throws {
        try start(onLine: onLine, onExit: {})
    }
}

/// The real thing: the helper program as a child process, spoken to over its standard input and
/// output. A restart terminates it (SIGKILL after 200 ms) and starts a new one. Writes go through
/// a serial queue: a host that stops reading holds up that queue, never the caller.
public final class ProcessTransport: HostTransport, @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.yabbistir.extension-host.writer")
    private var process: Process?
    private var input: Pipe?
    private var onLine: (@Sendable (Data) -> Void)?
    private var onExit: (@Sendable () -> Void)?

    public init(executableURL: URL, arguments: [String] = []) {
        self.executableURL = executableURL
        self.arguments = arguments
        // Writing to a host that just died must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    public var processIdentifier: Int32? { lock.withLock { process?.processIdentifier } }

    public func start(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) throws {
        lock.withLock { (self.onLine, self.onExit) = (onLine, onExit) }
        try launch()
    }

    public func send(_ line: Data) {
        var data = line
        data.append(0x0A)
        guard let handle = lock.withLock({ input })?.fileHandleForWriting else { return }
        // A dead host fails the write with EPIPE (SIGPIPE is ignored); the queue moves on.
        writer.async { try? handle.write(contentsOf: data) }
    }

    public func restart() throws {
        terminate()
        try launch()
    }

    public func stop() {
        terminate()
    }

    private func launch() throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let splitter = LineSplitter()
        let (onLine, onExit) = lock.withLock { (self.onLine, self.onExit) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.finishReading(); return }
            for line in splitter.append(data) { onLine?(line) }
        }
        // Only the current host's own exit counts; one we terminated is no longer current.
        process.terminationHandler = { [weak self] ended in
            guard let self, lock.withLock({ self.process === ended }) else { return }
            lock.withLock { (self.process, self.input) = (nil, nil) }
            onExit?()
        }
        try process.run()
        lock.withLock { (self.process, self.input) = (process, input) }
    }

    private func terminate() {
        let (process, input) = lock.withLock { () -> (Process?, Pipe?) in
            defer { (self.process, self.input) = (nil, nil) }
            return (self.process, self.input)
        }
        // Closed behind the queued writes, so a write never lands on a reused descriptor.
        if let input { writer.async { try? input.fileHandleForWriting.close() } }
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline { usleep(5_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

/// The host loop on a thread of this process, over pipes: the same protocol without a child
/// process (tests, development).
public final class PipeTransport: HostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.yabbistir.extension-host.pipe-writer")
    private var requests: Pipe?
    private var onLine: (@Sendable (Data) -> Void)?

    public init() {}

    /// A transport let go without `stop()` ends its loop too: the loop's thread, its runtimes and its pipes go with it.
    deinit {
        closeCurrent()
    }

    public func start(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) throws {
        lock.withLock { self.onLine = onLine }
        launch()
    }

    public func send(_ line: Data) {
        var data = line
        data.append(0x0A)
        guard let handle = lock.withLock({ requests })?.fileHandleForWriting else { return }
        writer.async { try? handle.write(contentsOf: data) }
    }

    public func restart() throws {
        closeCurrent()
        launch()
    }

    public func stop() {
        closeCurrent()
    }

    private func launch() {
        let requests = Pipe(), responses = Pipe()
        // In this process: a host still answering after its pipes were let go (a slow load outliving its
        // transport) fails the write with EPIPE, not a signal that ends the process.
        for pipe in [requests, responses] { _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        let thread = Thread {
            HostLoop.run(input: requests.fileHandleForReading, output: responses.fileHandleForWriting)
        }
        thread.start()
        let splitter = LineSplitter()
        let onLine = lock.withLock { self.onLine }
        responses.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.finishReading(); return }
            for line in splitter.append(data) { onLine?(line) }
        }
        lock.withLock { self.requests = requests }
    }

    /// Closing the request pipe ends the old loop; its late answers carry ids nobody waits for.
    private func closeCurrent() {
        let requests = lock.withLock { () -> Pipe? in defer { self.requests = nil }; return self.requests }
        if let requests { writer.async { try? requests.fileHandleForWriting.close() } }
    }
}

private extension FileHandle {
    /// The host's output ended (it exited, or its loop was let go): stop reading and close this end, or every host
    /// started over would leave a descriptor behind for as long as the app runs.
    func finishReading() {
        readabilityHandler = nil
        try? close()
    }
}
