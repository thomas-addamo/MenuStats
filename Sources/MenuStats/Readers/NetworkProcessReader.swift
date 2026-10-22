import Foundation

struct ProcessNetworkUsage {
    var pid: pid_t
    var name: String
    var downloadRate: Double
    var uploadRate: Double
}

/// Per-process network throughput from a long-running `nettop` (cumulative byte counts every second).
/// Started only while the network tab is visible, since it is the most expensive reader.
final class NetworkProcessReader {
    private var task: Process?
    private var output: FileHandle?
    private var pending = ""
    private var block: [String] = []
    private var previous: [String: (received: UInt64, sent: UInt64)] = [:]
    private var previousTime: Double?

    private(set) var latest: [ProcessNetworkUsage] = []
    /// Called on the main thread after each nettop sample.
    var onUpdate: (([ProcessNetworkUsage]) -> Void)?
    var isRunning: Bool { task?.isRunning == true }

    func start() {
        guard !isRunning else { return }
        let task = Process()
        // nettop block-buffers into a pipe (~20 s before the first sample); `script` gives it a pseudo-terminal,
        // so it flushes every sample (1 s).
        task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        task.arguments = ["-q", "/dev/null", "/usr/bin/nettop", "-P", "-L", "0", "-s", "1", "-x", "-J", "bytes_in,bytes_out"]
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data means end of file (nettop quit or was stopped). The handler keeps firing at EOF, so
            // without removing it this loop spins a whole core for as long as the app runs.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }
        do {
            try task.run()
            self.task = task
            output = pipe.fileHandleForReading
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            NSLog("MenuStats: cannot start nettop: \(error.localizedDescription)")
        }
    }

    func stop() {
        output?.readabilityHandler = nil
        output = nil
        task?.terminate()
        task = nil
        previous = [:]
        previousTime = nil
        latest = []
        pending = ""
        block = []
    }

    private func consume(_ text: String) {
        // The pseudo-terminal ends lines with CRLF, which Swift treats as a single Character.
        pending += text.replacingOccurrences(of: "\r\n", with: "\n")
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.hasPrefix(",bytes_in") {
                // A header starts a new sample: the lines gathered so far are one complete sample.
                if !block.isEmpty { process(block) }
                block = []
            } else if !line.isEmpty {
                block.append(line)
            }
        }
    }

    private func process(_ lines: [String]) {
        let now = uptimeSeconds()
        var totals: [String: (received: UInt64, sent: UInt64)] = [:]
        var usage: [ProcessNetworkUsage] = []
        let elapsed = previousTime.map { now - $0 } ?? 0

        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let received = UInt64(fields[1]), let sent = UInt64(fields[2]) else { continue }
            let key = String(fields[0])
            totals[key] = (received, sent)

            guard elapsed > 0, let old = previous[key], received >= old.received, sent >= old.sent else { continue }
            let down = Double(received - old.received) / elapsed
            let up = Double(sent - old.sent) / elapsed
            guard down > 0 || up > 0 else { continue }

            // "name.pid": the name itself may contain dots.
            let dot = key.lastIndex(of: ".")
            let name = dot.map { String(key[..<$0]) } ?? key
            let pid = dot.flatMap { pid_t(key[key.index(after: $0)...]) } ?? 0
            usage.append(ProcessNetworkUsage(pid: pid, name: name, downloadRate: down, uploadRate: up))
        }
        previous = totals
        previousTime = now
        latest = usage
        onUpdate?(usage)
    }
}
