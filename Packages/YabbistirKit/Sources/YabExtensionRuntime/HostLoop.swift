import Foundation
import Synchronization
import YabExtensionKit

/// The extension host's main loop: reads requests line by line, runs them on the extensions'
/// runtimes and writes answers, log, progress and call events back.
public enum HostLoop {
    /// Blocks until the input closes.
    public static func run(input: FileHandle, output: FileHandle) {
        let server = HostServer(output: output)
        let splitter = LineSplitter()
        while true {
            let data = input.availableData
            if data.isEmpty { break }
            for line in splitter.append(data) { server.handle(line) }
        }
    }

    /// The helper program's entry point. Whatever ends it (its input closing, SIGTERM from the app,
    /// SIGINT) first stops every tool still running (`yab.exec`), and what they started.
    ///
    /// A helper that is killed outright (SIGKILL, a crash) cannot: macOS has no parent-death signal,
    /// so its tools run on as orphans until they finish by themselves. A known limit.
    public static func runStandardIO() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let stops = [SIGTERM, SIGINT].map { number -> any DispatchSourceSignal in
            // Heard on a queue instead of ending the process at once; tools get the default back (ToolProcess.start).
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { shutDown() }
            source.resume()
            return source
        }
        withExtendedLifetime(stops) { run(input: .standardInput, output: .standardOutput) }
        shutDown()
    }

    private static let exiting = Mutex(false)

    /// Stops every tool, then exits. Only the first caller does; another (a signal while the input
    /// closes) waits for that exit.
    private static func shutDown() -> Never {
        let first = exiting.withLock { (exiting: inout Bool) -> Bool in
            defer { exiting = true }
            return !exiting
        }
        guard first else { while true { pause() } }
        ToolRegistry.shared.stopAll()
        exit(0)
    }
}

final class HostServer: @unchecked Sendable {
    private let output: FileHandle
    private let writeLock: NSLock
    /// Requests the extensions make of the app, and the app's replies.
    private let hostCalls: HostCallChannel
    private let lock = NSLock()
    private var runtimes: [String: ExtensionRuntime] = [:]
    /// Invokes in progress by request id, so a cancel finds its runtime.
    private var calls: [Int: ExtensionRuntime] = [:]

    init(output: FileHandle) {
        let writeLock = NSLock()
        self.output = output
        self.writeLock = writeLock
        hostCalls = HostCallChannel { message in HostServer.write(message, to: output, lock: writeLock) }
    }

    func handle(_ line: Data) {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: line) else { return }
        if let cancel = request.cancel {
            // Right here on the reading loop: the call may still be busy on its extension's queue.
            lock.withLock { calls[cancel.callID] }?.cancel(callID: cancel.callID)
        } else if let reply = request.reply {
            // Matched here, settled on the asking extension's queue.
            hostCalls.deliver(reply)
        } else if let load = request.load {
            // index.js's top level runs here; a slow or endless one must not stop the reading.
            DispatchQueue.global(qos: .userInitiated).async { self.send(self.load(load, id: request.id)) }
        } else if let unload = request.unload {
            lock.withLock { runtimes[unload.extensionID] = nil }
            send(HostMessage(id: request.id, done: true))
        } else if let invoke = request.invoke {
            guard let runtime = lock.withLock({ runtimes[invoke.extensionID] }) else {
                send(HostMessage(id: request.id, error: ExtensionError(.notFound, "\(invoke.extensionID) is not loaded")))
                return
            }
            let id = request.id
            lock.withLock { calls[id] = runtime }
            Task {
                defer { self.lock.withLock { self.calls[id] = nil } }
                do throws(ExtensionError) {
                    let output = try await runtime.invoke(invoke.kind, name: invoke.name, item: invoke.item, context: invoke.context,
                                                          effects: invoke.effects, source: invoke.source, callID: id) { [weak self] fraction, message in
                        self?.send(.progress(id, fraction: fraction, message: message))
                    }
                    self.send(HostMessage(id: id, ok: output))
                } catch {
                    self.send(HostMessage(id: id, error: error))
                }
            }
        }
    }

    private func load(_ request: LoadRequest, id: Int) -> HostMessage {
        let folder = URL(fileURLWithPath: request.folder)
        guard case .valid(let manifest, let localization) = ManifestValidator.validate(folder: folder) else {
            let issues = ManifestValidator.validate(folder: folder).issues.map(\.description).joined(separator: "; ")
            return HostMessage(id: id, error: ExtensionError(.unsupported, issues))
        }
        do {
            let extensionID = manifest.id
            let runtime = try ExtensionRuntime(folder: folder, manifest: manifest, localization: localization,
                                               dataFolder: URL(fileURLWithPath: request.dataFolder), grant: request.grant,
                                               toolSearchPath: request.toolSearchPath, secrets: request.secrets, hostCalls: hostCalls) { [weak self] line in
                self?.send(.log(extensionID, line))
            }
            lock.withLock { runtimes[extensionID] = runtime }
            return HostMessage(id: id, done: true)
        } catch {
            return HostMessage(id: id, error: error)
        }
    }

    private func send(_ message: HostMessage) {
        Self.write(message, to: output, lock: writeLock)
    }

    private static func write(_ message: HostMessage, to output: FileHandle, lock: NSLock) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        lock.withLock { try? output.write(contentsOf: data) }
    }
}
