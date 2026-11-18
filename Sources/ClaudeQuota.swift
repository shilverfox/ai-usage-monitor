import Foundation

// MARK: - Claude 官方额度（订阅账号的 5 小时 / 每周用量百分比）

struct ClaudeQuotaWindow {
    let key: String
    let window: RateWindow
}

enum ClaudeQuotaState {
    case idle
    case ok([ClaudeQuotaWindow], fetchedAt: Date)
    case noCredentials      // 本机没有 Claude Code CLI 的登录凭证
    case expired            // token 过期，且自动调用 CLI 续期也没成功
    case failed(String)
}

/// 从钥匙串（或 ~/.claude/.credentials.json）读取 Claude Code 登录凭证，
/// 请求 Anthropic 官方 usage 接口。凭证只发往 api.anthropic.com，不落盘、不写回。
final class ClaudeQuotaClient: @unchecked Sendable { // 只在串行队列上访问
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private var lastCLIRefresh: Date?

    func fetch() -> ClaudeQuotaState {
        let first = request()
        guard case .expired = first, tryCLIRefresh() else { return first }
        // CLI 续期后钥匙串里已是新 token，重读后再试一次
        return request()
    }

    /// 凭证过期时，后台让 CLI 发一个极小的 Haiku 请求；CLI 发请求前会用 refresh token 自行续期。
    /// （`claude auth status` 只查状态、不续期。）由 CLI 自己写回钥匙串，避免和它争用 refresh token。
    /// 10 分钟内最多尝试一次。
    private func tryCLIRefresh() -> Bool {
        if let last = lastCLIRefresh, Date().timeIntervalSince(last) < 600 { return false }
        lastCLIRefresh = Date()
        guard let cli = Self.claudeCLIPath() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-p", "reply with just: ok", "--model", "haiku", "--max-turns", "1"]
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        // 最多等 60 秒，卡住就终止
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return false }
        return true
    }

    private static func claudeCLIPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [home + "/.local/bin/claude", home + "/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func request() -> ClaudeQuotaState {
        guard let token = Self.accessToken() else { return .noCredentials }
        if let exp = token.expiresAt, exp < Date() { return .expired }

        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let sem = DispatchSemaphore(value: 0)
        var result: ClaudeQuotaState = .failed("无响应")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failed(err.localizedDescription); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { result = .expired; return }
            guard code == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { result = .failed("HTTP \(code)"); return }
            result = .ok(Self.parse(obj), fetchedAt: Date())
        }.resume()
        sem.wait()
        return result
    }

    /// 接口返回形如 {"five_hour": {"utilization": 12.0, "resets_at": "..."}, "seven_day": {...}, ...}
    private static func parse(_ obj: [String: Any]) -> [ClaudeQuotaWindow] {
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        return obj.compactMap { key, value -> ClaudeQuotaWindow? in
            guard let d = value as? [String: Any],
                  let used = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = key.hasPrefix("five_hour") ? 300 : key.hasPrefix("seven_day") ? 10080 : 0
            return ClaudeQuotaWindow(key: key, window: RateWindow(
                usedPercent: used, windowMinutes: minutes, resetsAt: parseDate(d["resets_at"] as? String)))
        }
        .sorted { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
    }

    private struct Token { let value: String; let expiresAt: Date? }

    private static func accessToken() -> Token? {
        let data = keychainData(service: "Claude Code-credentials")
            ?? FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/.credentials.json")
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String else { return nil }
        let exp = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Token(value: value, expiresAt: exp)
    }

    /// 通过系统自带的 /usr/bin/security 读取，而不是 SecItemCopyMatching：
    /// CLI 每次续期都会用 security 改写这条钥匙串项，访问控制随之重置为只信任 security，
    /// 本应用之前点的「始终允许」会失效、反复弹窗。走 security 读取就不会弹窗。
    private static func keychainData(service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}

func claudeQuotaName(_ key: String) -> String {
    switch key {
    case "five_hour": return "当前会话"
    case "seven_day": return "本周"
    case "seven_day_opus": return "本周 · Opus"
    case "seven_day_sonnet": return "本周 · Sonnet"
    default: return key
    }
}
