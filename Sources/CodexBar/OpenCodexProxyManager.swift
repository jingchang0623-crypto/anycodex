import AppKit
import Foundation

/// Manages the bundled opencodex proxy process lifecycle.
/// opencodex (https://github.com/lidge-jun/opencodex) is a universal provider
/// proxy that lets Codex CLI / Claude Code talk to any LLM provider. CodexBar
/// ships it in Contents/Helpers/opencodex and keeps it alive while enabled.
@MainActor
final class OpenCodexProxyManager {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case error(String)
    }

    static let defaultPort = 10100
    private static let enabledDefaultsKey = "openCodexProxyEnabled"

    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != self.state else { return }
            self.onStateChange?()
        }
    }

    var onStateChange: (() -> Void)?

    let port: Int
    private var process: Process?
    private var healthMonitorTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    /// Whether the proxy should run. Defaults to on: the merged client's whole
    /// point is shipping opencodex alongside usage monitoring.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    var dashboardURL: URL? {
        URL(string: "http://localhost:\(self.port)")
    }

    init(port: Int = OpenCodexProxyManager.defaultPort) {
        self.port = port
    }

    // MARK: - Lifecycle

    func start() {
        guard self.state == .stopped || self.isErrorState else { return }
        self.state = .starting
        self.startTask?.cancel()
        self.startTask = Task { [weak self] in
            guard let self else { return }
            // Adopt an already-healthy proxy (e.g. app relaunch while the previous
            // instance's proxy still serves the port) instead of spawning a
            // duplicate — `ocx start` exits with code 1 in that situation.
            if await self.checkHealth() {
                guard !Task.isCancelled else { return }
                self.state = .running(port: self.port)
                self.startHealthMonitor()
                return
            }
            do {
                try self.launchProcess()
                let port = try await self.waitForHealthy(timeout: 15)
                guard !Task.isCancelled else { return }
                self.state = .running(port: port)
                self.startHealthMonitor()
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    func stop() {
        self.startTask?.cancel()
        self.startTask = nil
        self.healthMonitorTask?.cancel()
        self.healthMonitorTask = nil

        if let proc = self.process, proc.isRunning {
            proc.terminationHandler = nil
            proc.terminate()
        } else {
            self.terminateAdoptedProxyIfNeeded()
        }
        self.process = nil
        self.state = .stopped
    }

    /// An adopted proxy (no owned Process) is stopped via the pid file that
    /// opencodex maintains — plain SIGTERM, no `ocx stop` side effects on the
    /// user's Codex config.
    private func terminateAdoptedProxyIfNeeded() {
        guard case .running = self.state, self.process == nil else { return }
        let pidPath = NSString("~/.opencodex/ocx.pid").expandingTildeInPath
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              kill(pid, 0) == 0
        else { return }
        kill(pid, SIGTERM)
    }

    /// Synchronous best-effort teardown for app termination.
    func shutdownForAppTermination() {
        self.startTask?.cancel()
        self.healthMonitorTask?.cancel()
        if let proc = self.process, proc.isRunning {
            proc.terminationHandler = nil
            proc.terminate()
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else {
            self.terminateAdoptedProxyIfNeeded()
        }
        self.process = nil
        self.state = .stopped
    }

    // MARK: - Private

    private var isErrorState: Bool {
        if case .error = self.state { return true }
        return false
    }

    private func launchProcess() throws {
        let ocxPath = try Self.resolveOCXPath()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [ocxPath, "start", "--port", "\(self.port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.process === terminated else { return }
                self.process = nil
                if case .stopped = self.state { return }
                // `ocx start` exits 1 when another instance already serves the
                // port; if that instance is healthy, adopt it instead of erroring.
                if await self.checkHealth() {
                    self.state = .running(port: self.port)
                    self.startHealthMonitor()
                    return
                }
                self.state = .error("opencodex exited (code \(status))")
            }
        }

        try proc.run()
        self.process = proc
    }

    private func waitForHealthy(timeout: TimeInterval) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if await self.checkHealth() {
                return self.port
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw OpenCodexProxyError.healthCheckTimeout
    }

    private func checkHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(self.port)/healthz") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func startHealthMonitor() {
        self.healthMonitorTask?.cancel()
        self.healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                guard case .running = self.state else { return }
                if await self.checkHealth() { continue }
                guard case .running = self.state else { return }
                self.stop()
                self.start()
                return
            }
        }
    }

    /// Locate the `ocx` launcher: bundled helper first, then dev checkout, then
    /// global installs (Homebrew Apple Silicon / Intel, npm global).
    private static func resolveOCXPath() throws -> String {
        var candidates: [String] = []
        let bundleURL = Bundle.main.bundleURL
        candidates.append(
            bundleURL.appendingPathComponent("Contents/Helpers/opencodex/ocx").path)
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("opencodex/ocx").path)
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/vendor/opencodex/ocx")
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/ocx",
            "/usr/local/bin/ocx",
            NSString("~/.npm-global/bin/ocx").expandingTildeInPath,
        ])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw OpenCodexProxyError.ocxNotFound
    }
}

enum OpenCodexProxyError: LocalizedError {
    case ocxNotFound
    case healthCheckTimeout

    var errorDescription: String? {
        switch self {
        case .ocxNotFound:
            "opencodex not found (bundle Helpers, vendor/, or npm install -g @bitkyc08/opencodex)"
        case .healthCheckTimeout:
            "opencodex proxy did not become healthy in time"
        }
    }
}
