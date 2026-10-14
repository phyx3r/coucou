#if !APPSTORE
import SwiftUI

// MARK: - Kiro plan usage

/// Kiro reports a single monthly credit window, not the 5-hour/weekly windows of
/// Claude and Codex. We map the one window onto `PlanUsage.sevenDay` so the shared
/// gauge helpers (dominantPct, color) work unchanged.
struct KiroPlanUsage {
    var usedPct: Double          // 0–100
    var resetsAt: Date?          // next monthly reset
    var creditsUsed: Double?     // e.g. 2183.07
    var creditsTotal: Double?    // e.g. 5000
    var planType: String?        // e.g. "KIRO PRO MAX"
    var updatedAt: Date

    var planUsage: PlanUsage {
        let window = PlanWindow(usedPct: min(100, max(0, usedPct)),
                                resetsAt: resetsAt ?? Date.distantFuture)
        return PlanUsage(fiveHour: nil, sevenDay: window, updatedAt: updatedAt)
    }
}

// MARK: - Fetching (kiro-cli chat --no-interactive, the /usage slash command)

enum KiroPlanGauge {

    static func kiroExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            "/opt/homebrew/bin/kiro-cli",
            "\(home)/.npm-global/bin/kiro-cli",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Pipes `/usage` into a non-interactive chat session. nil if Kiro is missing or not signed in.
    static func fetch() async -> KiroPlanUsage? {
        guard let kiro = kiroExecutable() else { return nil }
        return await Task.detached { readUsage(kiro: kiro) }.value
    }

    private static func readUsage(kiro: String) -> KiroPlanUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kiro)
        process.arguments = ["chat", "--no-interactive"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [URL(fileURLWithPath: kiro).deletingLastPathComponent().path,
                       "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                       env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        // Give up after 20 s.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }

        input.fileHandleForWriting.write(Data("/usage\n".utf8))
        try? input.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Parses the plain-text output of `/usage`, e.g.
    ///   Estimated Usage | resets on 2026-11-01 | KIRO PRO MAX
    ///   Credits (2183.07 of 5000 covered in plan), 43.7%
    static func parse(_ text: String) -> KiroPlanUsage? {
        var usedPct: Double?
        var resetsAt: Date?
        var creditsUsed: Double?
        var creditsTotal: Double?
        var planType: String?

        // Percentage: last "NN.N%" on any line.
        if let m = text.range(of: #"(\d+(?:\.\d+)?)\s*%"#, options: .regularExpression) {
            usedPct = Double(text[m].replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces))
        }
        // Credits "(2183.07 of 5000 ...)".
        if let m = text.range(of: #"\(\s*([\d.]+)\s+of\s+([\d.]+)"#, options: .regularExpression) {
            let nums = text[m].components(separatedBy: CharacterSet(charactersIn: "( of"))
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if nums.count >= 2 { creditsUsed = nums[0]; creditsTotal = nums[1] }
        }
        // Reset date "resets on 2026-11-01".
        if let m = text.range(of: #"resets on\s+(\d{4}-\d{2}-\d{2})"#, options: .regularExpression) {
            let iso = String(text[m]).replacingOccurrences(of: "resets on", with: "")
                .trimmingCharacters(in: .whitespaces)
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            resetsAt = fmt.date(from: iso)
        }
        // Plan type: tail segment after the last "|" on the header line.
        if let header = text.split(separator: "\n").first(where: { $0.contains("|") }) {
            let parts = header.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if let last = parts.last, !last.isEmpty, !last.lowercased().contains("resets on") {
                planType = last
            }
        }
        // Fall back to credits ratio if the explicit percentage is missing.
        if usedPct == nil, let u = creditsUsed, let t = creditsTotal, t > 0 {
            usedPct = u / t * 100
        }
        guard let pct = usedPct else { return nil }
        return KiroPlanUsage(usedPct: pct, resetsAt: resetsAt,
                             creditsUsed: creditsUsed, creditsTotal: creditsTotal,
                             planType: planType, updatedAt: Date())
    }

    static func pillLabel(_ usage: KiroPlanUsage?) -> String {
        guard let usage else { return "Kiro —" }
        return "Kiro \(Int(usage.usedPct.rounded()))%"
    }

    static func color(_ usage: KiroPlanUsage?) -> String {
        ClaudePlanGauge.color(for: usage.map { min(100, max(0, $0.usedPct)) })
    }
}

// MARK: - Kiro Plan Card View

private let kiroResetFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "MMM d"
    return fmt
}()

struct KiroPlanCardView: View {
    let usage: KiroPlanUsage?   // nil = loading or unavailable

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: KiroPlanGauge.color(usage)))
                    .frame(width: 7, height: 7)
                Text("Kiro plan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Gauge + credits
            VStack(alignment: .leading, spacing: 5) {
                GaugeRowView(label: "Month", window: usage?.planUsage.sevenDay, now: now, weekly: true)
                HStack(spacing: 5) {
                    Text("Credits")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 40, alignment: .leading)
                    Text(creditsText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return "Asking Kiro…" }
        let plan = usage.planType.map { "\($0) · " } ?? ""
        let diff = now.timeIntervalSince(usage.updatedAt)
        if diff < 60 { return plan + "just now" }
        let mins = Int(diff / 60)
        if mins < 60 { return plan + "\(mins) min ago" }
        return plan + "\(mins / 60) h ago"
    }

    private var creditsText: String {
        guard let used = usage?.creditsUsed, let total = usage?.creditsTotal else { return "—" }
        return "\(Int(used.rounded())) of \(Int(total.rounded()))"
    }
}
#endif
