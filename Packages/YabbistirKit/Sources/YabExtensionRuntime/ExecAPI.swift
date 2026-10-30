import Foundation
import JavaScriptCore
import YabExtensionKit

/// `yab.exec`: runs one of the manifest's `requires.tools`, agreed to, without
/// a shell (the arguments reach the program as they are), in the call's work folder and with a small
/// environment of its own. Only in a run the person started.
///
/// Each tool leads its own process group, so stopping it stops whatever it started too (yt-dlp's
/// ffmpeg). Stopping never waits for the extension's queue: see `ToolRegistry`.
enum ExecAPI {
    /// How much of each stream the result keeps: its last 64 KB.
    static let tailLimit = 65_536
    /// What follows the search path in a tool's PATH.
    static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func install(in runtime: ExtensionRuntime) {
        let context = runtime.context
        let yab = context.objectForKeyedSubscript("yab")!
        let exec: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue? = { [weak runtime] tool, args, options in
            guard let runtime else { return nil }
            return run(tool, args, options, runtime: runtime)
        }
        yab.setValue(unsafeBitCast(exec, to: AnyObject.self), forProperty: "exec")
    }

    /// The variables a tool gets, and only these: PATH (the search path, then the system's folders),
    /// HOME, TMPDIR and USER as the helper has them, and LANG (UTF-8 English when the helper has
    /// none: apps opened from the Finder often have no LANG, and video titles are Turkish).
    static func environment(searchPath: [String], from helper: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var variables = ["PATH=" + (searchPath + systemPath).joined(separator: ":")]
        for name in ["HOME", "TMPDIR", "USER"] {
            if let value = helper[name] { variables.append("\(name)=\(value)") }
        }
        variables.append("LANG=" + (helper["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8"))
        return variables
    }

    private struct Prepared {
        var executable: String
        var arguments: [String]
        var onLine: JSValue?
        var signal: JSValue?
        var input: Data?
    }

    private static func run(_ tool: JSValue?, _ args: JSValue?, _ options: JSValue?, runtime: ExtensionRuntime) -> JSValue? {
        let scope = runtime.currentScope
        return JSValue(newPromiseIn: runtime.context) { resolve, reject in
            let execution = Execution(runtime: runtime, scope: scope, resolve: resolve, reject: reject)
            do throws(ExtensionError) {
                guard let scope else { throw ExtensionError(.permissionDenied, "yab.exec works inside a call") }
                try HostAPI.require("exec", in: scope)
                let prepared = try prepare(tool, args, options, scope: scope, runtime: runtime)
                if prepared.signal?.forProperty("aborted")?.toBool() == true { throw CallScope.cancelled }
                let directory = try scope.workFolder.path
                execution.onLine = prepared.onLine
                let queue = runtime.queue
                var lines: (@Sendable (String, ToolProcess.Stream) -> Void)?
                if prepared.onLine != nil {
                    lines = { line, stream in queue.async { execution.line(line, stream) } }
                }
                let process = ToolProcess(onLine: lines, onExit: { outcome in queue.async { execution.complete(outcome) } })
                // Registered before it exists, so a cancel arriving meanwhile still reaches it.
                guard ToolRegistry.shared.add(process, owner: runtime.toolOwner, callID: scope.callID) else {
                    throw ExtensionError(.interrupted, "the extension host is stopping")
                }
                do throws(ExtensionError) {
                    try process.start(executable: prepared.executable, arguments: prepared.arguments,
                                      environment: environment(searchPath: runtime.effectiveToolSearchPath), directory: directory,
                                      input: prepared.input)
                } catch {
                    ToolRegistry.shared.remove(process)
                    throw error
                }
                // The call's end stops the process through the registry (ExtensionRuntime.end); here the promise follows.
                execution.token = scope.whenEnded { reason in execution.settle(.failure(reason)) }
                if let signal = prepared.signal {
                    // Taken off when the exec settles, so a finished one leaves nothing on the signal.
                    execution.listener = AbortListener(signal: signal, in: runtime.context) {
                        process.stop()
                        execution.settle(.failure(CallScope.cancelled))
                    }
                }
            } catch {
                execution.settle(.failure(error))
            }
        }
    }

    /// The checks, in order: the tool is agreed to, it is installed, the arguments are strings.
    private static func prepare(_ tool: JSValue?, _ args: JSValue?, _ options: JSValue?, scope: CallScope,
                                runtime: ExtensionRuntime) throws(ExtensionError) -> Prepared {
        guard let tool, tool.isString, let name = tool.toString() else {
            throw ExtensionError(.badResult, "yab.exec takes the name of a tool from requires.tools")
        }
        guard scope.grant.tools.contains(name) else {
            throw ExtensionError(.permissionDenied, "\(name) is not in the extension's required tools")
        }
        guard let executable = ToolLocator(searchPath: runtime.effectiveToolSearchPath).locate(name) else {
            let install = runtime.toolSpecs.first { $0.name == name }?.install
            throw ExtensionError(.toolMissing, "\(name) is not installed" + (install.map { ". Install it with: \($0)" } ?? ""))
        }
        guard let args, args.isArray, case .array(let items) = runtime.json(args) else {
            throw ExtensionError(.badResult, "args must be an array of strings")
        }
        let arguments = items.compactMap(\.stringValue)
        // Every one crosses (a very long array would be cut at the bridge), and none holds a NUL: a C
        // string ends there, so the tool would get it cut short.
        guard arguments.count == items.count, args.forProperty("length")?.toDouble() == Double(items.count),
              !arguments.contains(where: { $0.contains("\0") }) else {
            throw ExtensionError(.badResult, "args must be an array of strings")
        }

        let options = options.flatMap { $0.isObject ? $0 : nil }
        func option(_ key: String) -> JSValue? {
            options?.forProperty(key).flatMap { $0.isUndefined || $0.isNull ? nil : $0 }
        }
        let onLine = option("onLine")
        if let onLine, !runtime.isFunction(onLine) { throw ExtensionError(.badResult, "onLine must be a function") }
        var input: Data?
        if let value = option("input") {
            guard value.isString else { throw ExtensionError(.badResult, "input must be a string") }
            input = Data((value.toString() ?? "").utf8)
        }
        return Prepared(executable: executable.path, arguments: arguments, onLine: onLine, signal: option("signal"), input: input)
    }

    /// Settles one exec's promise, once, inside the call that made it, and passes its lines on until
    /// then. Touched only on the extension's queue.
    private final class Execution: @unchecked Sendable {
        weak var runtime: ExtensionRuntime?
        let scope: CallScope?
        var onLine: JSValue?
        var token: Int?
        var listener: AbortListener?
        private var resolve: JSValue?
        private var reject: JSValue?
        private var settled = false

        init(runtime: ExtensionRuntime, scope: CallScope?, resolve: JSValue?, reject: JSValue?) {
            (self.runtime, self.scope, self.resolve, self.reject) = (runtime, scope, resolve, reject)
        }

        func line(_ text: String, _ stream: ToolProcess.Stream) {
            guard !settled, let runtime, let onLine else { return }
            // What the listener throws goes where a timer's would: nowhere.
            runtime.within(scope) { _ = onLine.call(withArguments: [text, stream.rawValue]) }
        }

        func complete(_ outcome: ToolProcess.Outcome) {
            settle(.success(outcome))
        }

        func settle(_ result: Result<ToolProcess.Outcome, ExtensionError>) {
            guard !settled, let runtime else { return }
            settled = true
            if let token, let scope { scope.forget(token) }
            listener?.remove()
            let (resolve, reject) = (self.resolve, self.reject)
            // Let go of the script's values: a listener holding this keeps none of them alive.
            (self.resolve, self.reject, self.onLine, listener) = (nil, nil, nil, nil)
            runtime.within(scope) {
                switch result {
                case .success(let outcome):
                    let object = JSValue(newObjectIn: runtime.context)!
                    object.setValue(Int(outcome.exitCode), forProperty: "exitCode")
                    object.setValue(String(decoding: outcome.stdout, as: UTF8.self), forProperty: "stdout")
                    object.setValue(String(decoding: outcome.stderr, as: UTF8.self), forProperty: "stderr")
                    resolve?.call(withArguments: [object])
                case .failure(let error):
                    reject?.call(withArguments: [NativeAPI.errorValue(error, in: runtime.context)])
                }
            }
        }
    }
}

extension ExtensionRuntime {
    /// Where tools are looked for: the search path the app gave, or the standard one.
    var effectiveToolSearchPath: [String] {
        toolSearchPath.isEmpty ? ToolLocator.standard.searchPath : toolSearchPath
    }
}

// MARK: - Processes

/// One tool process, spawned as the leader of a new process group, with its output pipes and the
/// thread that reaps it. Stopping signals the whole group.
///
/// Thread safety: `pid`, `stopRequested` and `isDone` are only touched under `lock`; the output state
/// (`tails`, `splitters`, `openStreams`, `status`, the handlers) only on the serial `io` queue.
final class ToolProcess: @unchecked Sendable {
    enum Stream: String, Sendable {
        case stdout, stderr
    }

    struct Outcome: Sendable {
        /// The exit code; 128 + the signal's number when a signal ended the process.
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
    }

    /// How long a stopped group has between SIGTERM and SIGKILL.
    static let grace: DispatchTimeInterval = .seconds(2)

    private let io = DispatchQueue(label: "dev.yabbistir.extension.tool")
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopRequested = false
    /// The group is known to be gone (or was sent SIGKILL): it is never signalled again, as its
    /// number may belong to another group by then.
    private var isDone = false

    private var onLine: (@Sendable (String, Stream) -> Void)?
    private var onExit: (@Sendable (Outcome) -> Void)?
    private var tails: [Stream: Data] = [.stdout: Data(), .stderr: Data()]
    private var splitters: [Stream: LineSplitter] = [.stdout: LineSplitter(), .stderr: LineSplitter()]
    private var openStreams = 2
    private var status: Int32?

    /// `onLine` hears each line of either stream in order (without its newline, decoded as UTF-8 with
    /// bad bytes replaced); `onExit` the outcome once the process has exited and both streams ended.
    /// Both on the process's own queue.
    init(onLine: (@Sendable (String, Stream) -> Void)?, onExit: @escaping @Sendable (Outcome) -> Void) {
        (self.onLine, self.onExit) = (onLine, onExit)
    }

    /// The group's id (the leader's pid) once spawned.
    var group: pid_t? {
        lock.withLock { pid > 0 ? pid : nil }
    }

    /// Spawns the process: no shell, its own process group, standard input from `input` (closed once
    /// written) or /dev/null, the pipes and the working folder as its only inheritance, default
    /// signal handling and an empty signal mask.
    func start(executable: String, arguments: [String], environment: [String], directory: String,
               input: Data?) throws(ExtensionError) {
        var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1], feed: [Int32] = [-1, -1]
        func closeAll() { for fd in output + errors + feed where fd >= 0 { close(fd) } }
        guard pipe(&output) == 0, pipe(&errors) == 0, input == nil || pipe(&feed) == 0 else {
            let reason = String(cString: strerror(errno))
            closeAll()
            throw ExtensionError(.unavailable, "the tool could not be started: \(reason)")
        }
        // Not handed to any other program this process starts.
        for fd in output + errors + feed where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, feed[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new group led by the tool; every descriptor not named above closed; the helper's ignored
        // signals (SIGPIPE, SIGTERM, SIGINT) back to their defaults.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var spawned: pid_t = 0
        let result = posix_spawn(&spawned, executable, &actions, &attributes, argv, envp)
        // The child's ends are the child's now.
        for fd in [output[1], errors[1], feed[0]] where fd >= 0 { close(fd) }
        guard result == 0 else {
            for fd in [output[0], errors[0], feed[1]] where fd >= 0 { close(fd) }
            throw ExtensionError(.unavailable, "the tool could not be started: \(String(cString: strerror(result)))")
        }

        read(output[0], .stdout)
        read(errors[0], .stderr)
        if let input { write(input, to: feed[1]) }
        let leader = spawned
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(leader, &raw, 0) } while reaped == -1 && errno == EINTR
            let status: Int32? = reaped == leader ? raw : nil
            io.async { self.exited(status) }
        }
        let stopNow = lock.withLock { pid = leader; return stopRequested }
        if stopNow { terminate(leader) }
    }

    /// SIGTERM to the whole group now, SIGKILL to whatever is left of it two seconds later. Once,
    /// from any thread; before the process is spawned, it is stopped as soon as it is.
    func stop() {
        let target: pid_t? = lock.withLock {
            guard !stopRequested, !isDone else { return nil }
            stopRequested = true
            return pid > 0 ? pid : nil
        }
        if let target { terminate(target) }
    }

    /// Whether any process of the group is left.
    static func isAlive(_ group: pid_t) -> Bool {
        killpg(group, 0) == 0
    }

    private func terminate(_ group: pid_t) {
        // A group is only signalled while it has members: once empty its number may be reused.
        guard Self.isAlive(group) else { return done() }
        killpg(group, SIGTERM)
        escalate(group, at: .now() + Self.grace)
    }

    private func escalate(_ group: pid_t, at deadline: DispatchTime) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: min(deadline, .now() + .milliseconds(50))) { [self] in
            if Self.isAlive(group), DispatchTime.now() < deadline { return escalate(group, at: deadline) }
            if Self.isAlive(group) { killpg(group, SIGKILL) }
            done()
        }
    }

    private func done() {
        lock.withLock { isDone = true }
        ToolRegistry.shared.remove(self)
    }

    // MARK: Output (on `io`)

    private func read(_ fd: Int32, _ stream: Stream) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        source.setEventHandler { [self] in
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                received(Data(chunk[0..<count]), stream)
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { [self] in
            close(fd)
            ended(stream)
        }
        source.resume()
    }

    private func received(_ data: Data, _ stream: Stream) {
        var tail = tails[stream, default: Data()]
        tail.append(data)
        if tail.count > ExecAPI.tailLimit {
            tail.removeFirst(tail.count - ExecAPI.tailLimit)
            // Starts on a character, not inside one.
            while let first = tail.first, first & 0xC0 == 0x80 { tail.removeFirst() }
        }
        tails[stream] = tail
        guard let onLine, let splitter = splitters[stream] else { return }
        for line in splitter.append(data) { onLine(String(decoding: line, as: UTF8.self), stream) }
    }

    private func ended(_ stream: Stream) {
        // A last line without a newline still counts.
        if let onLine, let splitter = splitters[stream] {
            for line in splitter.append(Data([0x0A])) { onLine(String(decoding: line, as: UTF8.self), stream) }
        }
        openStreams -= 1
        finishIfDone()
    }

    private func exited(_ status: Int32?) {
        self.status = status ?? -1
        finishIfDone()
    }

    private func finishIfDone() {
        guard openStreams == 0, let status, let onExit else { return }
        (self.onExit, onLine) = (nil, nil)
        onExit(Outcome(exitCode: Self.exitCode(status), stdout: tails[.stdout] ?? Data(), stderr: tails[.stderr] ?? Data()))
        // Whatever it left running stays registered until the call ends (and is stopped then); an empty group is done with.
        if let group, !Self.isAlive(group) { done() }
    }

    /// A `waitpid` status as an exit code: 128 + the signal for a process a signal ended.
    static func exitCode(_ status: Int32) -> Int32 {
        if status == -1 { return -1 }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// Writes `data` to the tool's standard input on a thread of its own (the tool may read slowly,
    /// or never), then closes it. A tool that exits first ends the write with EPIPE, not a signal.
    private func write(_ data: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        Thread.detachNewThread {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, base + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written == -1, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            close(fd)
        }
    }
}

// MARK: - Registry

/// The tool processes this helper started that may still be running, by the call that started
/// them. A cancel, a call's end and the helper's exit stop them from here, on whatever thread they
/// happen, so none of them waits for an extension's queue (a script stuck in a loop holds it).
///
/// Call ids are unique among one runtime's calls in progress (the host's request ids); `owner`
/// tells runtimes apart. Thread safety: every stored property is only touched under `lock`.
final class ToolRegistry: @unchecked Sendable {
    static let shared = ToolRegistry()

    private struct Key: Hashable {
        let owner: Int
        let callID: Int
    }

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: (key: Key, process: ToolProcess)] = [:]
    /// Calls cancelled but not yet ended: a tool one of them starts meanwhile is stopped at once.
    private var cancelled: Set<Key> = []
    private var nextOwner = 0
    private var closed = false

    /// A new runtime's owner number.
    func newOwner() -> Int {
        lock.withLock {
            nextOwner += 1
            return nextOwner
        }
    }

    /// False once the helper is exiting: nothing new starts then.
    func add(_ process: ToolProcess, owner: Int, callID: Int) -> Bool {
        let key = Key(owner: owner, callID: callID)
        let (accepted, stopNow): (Bool, Bool) = lock.withLock {
            guard !closed else { return (false, false) }
            processes[ObjectIdentifier(process)] = (key, process)
            return (true, cancelled.contains(key))
        }
        if stopNow { process.stop() }
        return accepted
    }

    func remove(_ process: ToolProcess) {
        _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) }
    }

    /// The call is cancelled: its tools stop now, and any it starts before it ends.
    func cancel(owner: Int, callID: Int) {
        let key = Key(owner: owner, callID: callID)
        let stopping = lock.withLock {
            cancelled.insert(key)
            return processes.values.filter { $0.key == key }.map(\.process)
        }
        stopping.forEach { $0.stop() }
    }

    /// The call ended, answered or cancelled: its tools stop, and what they left running.
    func end(owner: Int, callID: Int) {
        let key = Key(owner: owner, callID: callID)
        let stopping = lock.withLock {
            cancelled.remove(key)
            return processes.values.filter { $0.key == key }.map(\.process)
        }
        stopping.forEach { $0.stop() }
    }

    /// The helper is exiting: SIGTERM to every group, a moment to go, SIGKILL to what is left. The
    /// moment is short: the app kills a helper that is still there 200 ms after its SIGTERM.
    func stopAll(grace: Duration = .milliseconds(100)) {
        let first = lock.withLock {
            closed = true
            return processes.values.map(\.process)
        }
        first.forEach { $0.stop() }
        let clock = ContinuousClock(), deadline = clock.now + grace
        func remaining() -> [pid_t] {
            lock.withLock { processes.values.compactMap { $0.process.group } }.filter(ToolProcess.isAlive)
        }
        while !remaining().isEmpty, clock.now < deadline { usleep(5_000) }
        for group in remaining() { killpg(group, SIGKILL) }
    }
}
