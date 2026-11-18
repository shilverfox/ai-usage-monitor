import Foundation

// MARK: - Shared models

struct TokenEvent {
    let date: Date
    let model: String
    let input: Int        // 非缓存输入
    let cacheWrite: Int
    let cacheRead: Int
    let output: Int
    /// Codex 事件所属账号（来自 session_meta.creator_account_id）；Claude 侧为 nil
    var accountId: String? = nil
    var total: Int { input + cacheWrite + cacheRead + output }
}

struct RateWindow {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

/// 一次额度观测。accountId 为空表示日志文件本身没写账号（旧版 CLI），需靠登录时间线补归因。
struct CodexObservation {
    let date: Date
    let accountId: String?
    let limitId: String
    let primary: RateWindow?
    let secondary: RateWindow?
}

// MARK: - Helpers

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

/// 增量读取 JSONL：记录每个文件已读的字节偏移，只处理新追加的完整行。
final class IncrementalReader {
    private var offsets: [String: UInt64] = [:]
    private let chunkSize = 4 << 20

    /// 对每个新行调用 handler；needle 非空时只把包含该字节串的行交给 handler（跳过无关行的 JSON 解析）。
    func readNewLines(path: String, needle: Data?, handler: (Data) -> Void) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var offset = offsets[path] ?? 0
        if size < offset { offset = 0 } // 文件被截断/重写
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)

        var carry = Data()
        var consumed = offset
        while true {
            guard let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            var buf = carry
            buf.append(chunk)
            var lineStart = buf.startIndex
            while let nl = buf[lineStart...].firstIndex(of: 0x0A) {
                let line = buf[lineStart..<nl]
                if !line.isEmpty, needle == nil || line.range(of: needle!) != nil {
                    handler(Data(line))
                }
                consumed += UInt64(nl - lineStart + 1)
                lineStart = buf.index(after: nl)
            }
            carry = Data(buf[lineStart...])
        }
        // 未以换行结尾的半行留到下次再读
        offsets[path] = consumed
    }
}

func jsonlFiles(under root: URL, modifiedSince: Date) -> [String] {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
    var out: [String] = []
    for case let url as URL in en where url.pathExtension == "jsonl" {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let m = vals?.contentModificationDate, m >= modifiedSince { out.append(url.path) }
    }
    return out
}

// MARK: - Claude Code

/// 解析 ~/.claude/projects/**/*.jsonl 中 assistant 消息的 usage。
final class ClaudeParser: @unchecked Sendable { // 只在串行队列上访问
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let reader = IncrementalReader()
    private var seen = Set<String>()
    private(set) var events: [TokenEvent] = []
    private let needle = "\"usage\"".data(using: .utf8)!

    func refresh(retainSince: Date) {
        for path in jsonlFiles(under: root, modifiedSince: retainSince) {
            reader.readNewLines(path: path, needle: needle) { line in
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let date = parseDate(obj["timestamp"] as? String), date >= retainSince
                else { return }
                // 同一条消息流式写入时会出现多行，按 message.id + requestId 去重
                let key = "\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
                if key != "|" { guard seen.insert(key).inserted else { return } }
                let model = msg["model"] as? String ?? "unknown"
                if model == "<synthetic>" { return }
                events.append(TokenEvent(date: date, model: model,
                                         input: int(usage["input_tokens"]),
                                         cacheWrite: int(usage["cache_creation_input_tokens"]),
                                         cacheRead: int(usage["cache_read_input_tokens"]),
                                         output: int(usage["output_tokens"])))
            }
        }
        events.removeAll { $0.date < retainSince }
    }
}

// MARK: - Codex

/// 解析 ~/.codex/sessions/**/*.jsonl 中的 token_count 事件（含官方额度 rate_limits）。
/// 多账号：每个 rollout 首行 session_meta.creator_account_id 决定该文件归谁；
/// 额度按「账号 × limit_id」各自留最新一条，互不覆盖。
final class CodexParser: @unchecked Sendable { // 只在串行队列上访问
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    private let reader = IncrementalReader()
    private var lastTotal: [String: Int] = [:]
    private var currentModel: [String: String] = [:]
    /// rollout 文件 → 账号 ID
    private var fileAccount: [String: String] = [:]
    private(set) var events: [TokenEvent] = []
    private(set) var observations: [CodexObservation] = []
    private let tokenNeedle = "\"token_count\"".data(using: .utf8)!
    private let ctxNeedle = "\"turn_context\"".data(using: .utf8)!
    private let metaNeedle = "\"session_meta\"".data(using: .utf8)!

    func refresh(retainSince: Date) {
        for path in jsonlFiles(under: root, modifiedSince: retainSince) {
            reader.readNewLines(path: path, needle: nil) { line in
                let isToken = line.range(of: tokenNeedle) != nil
                let isMeta = !isToken && line.range(of: metaNeedle) != nil
                let isCtx = !isToken && !isMeta && line.range(of: ctxNeedle) != nil
                guard isToken || isCtx || isMeta,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { return }

                if isMeta {
                    if let acc = payload["creator_account_id"] as? String, !acc.isEmpty {
                        fileAccount[path] = acc
                    }
                    return
                }
                if obj["type"] as? String == "turn_context" {
                    if let m = payload["model"] as? String { currentModel[path] = m }
                    return
                }
                guard payload["type"] as? String == "token_count",
                      let date = parseDate(obj["timestamp"] as? String) else { return }
                let account = fileAccount[path]

                if let rl = payload["rate_limits"] as? [String: Any] {
                    let id = rl["limit_id"] as? String ?? "codex"
                    let p = Self.window(rl["primary"]), s = Self.window(rl["secondary"])
                    // premium 等计费桶没有窗口，跳过（不参与额度展示）
                    if (p != nil || s != nil), date >= retainSince {
                        observations.append(CodexObservation(date: date, accountId: account,
                                                             limitId: id, primary: p, secondary: s))
                    }
                }

                // total_token_usage 是会话累计值；只有它变化时才计入 last_token_usage，避免重复事件重复计数
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else { return }
                let t = int(total["total_tokens"])
                if t == lastTotal[path] { return }
                lastTotal[path] = t
                guard date >= retainSince else { return }
                let input = int(last["input_tokens"]), cached = int(last["cached_input_tokens"])
                events.append(TokenEvent(date: date, model: currentModel[path] ?? "codex",
                                         input: max(0, input - cached),
                                         cacheWrite: int(last["cache_write_input_tokens"]),
                                         cacheRead: cached,
                                         output: int(last["output_tokens"]),
                                         accountId: account))
            }
        }
        events.removeAll { $0.date < retainSince }
        observations.removeAll { $0.date < retainSince }
    }

    private static func window(_ v: Any?) -> RateWindow? {
        guard let d = v as? [String: Any], let used = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateWindow(usedPercent: used, windowMinutes: int(d["window_minutes"]), resetsAt: reset)
    }
}

// MARK: - Aggregation

struct Summary {
    var today = 0
    var last5h = 0
    var week = 0
    var byModel: [(String, Int)] = []
    var hourly: [Int] = Array(repeating: 0, count: 24)   // 最近 24 小时，每小时 token
    var lastActivity: Date?
    var blockStart: Date?     // Claude 5 小时计费窗口（推算）
    var blockTokens = 0
}

func summarize(_ events: [TokenEvent], now: Date = Date()) -> Summary {
    var s = Summary()
    let cal = Calendar.current
    let startOfDay = cal.startOfDay(for: now)
    let weekAgo = now.addingTimeInterval(-7 * 86400)
    let fiveH = now.addingTimeInterval(-5 * 3600)
    var models: [String: Int] = [:]
    for e in events {
        if e.date >= startOfDay { s.today += e.total }
        if e.date >= fiveH { s.last5h += e.total }
        if e.date >= weekAgo { s.week += e.total; models[e.model, default: 0] += e.total }
        let hoursAgo = Int(now.timeIntervalSince(e.date) / 3600)
        if hoursAgo >= 0 && hoursAgo < 24 { s.hourly[23 - hoursAgo] += e.total }
        if e.date > (s.lastActivity ?? .distantPast) { s.lastActivity = e.date }
    }
    s.byModel = models.sorted { $0.value > $1.value }

    // 5 小时窗口：从第一条消息所在整点开始，超过 5 小时或间隔 ≥5 小时则开新窗口
    var blockStart: Date?
    var blockTokens = 0
    var prev: Date?
    for e in events.sorted(by: { $0.date < $1.date }) {
        if let b = blockStart, e.date < b.addingTimeInterval(5 * 3600),
           let p = prev, e.date.timeIntervalSince(p) < 5 * 3600 {
            blockTokens += e.total
        } else {
            blockStart = cal.dateInterval(of: .hour, for: e.date)?.start ?? e.date
            blockTokens = e.total
        }
        prev = e.date
    }
    if let b = blockStart, now < b.addingTimeInterval(5 * 3600) {
        s.blockStart = b
        s.blockTokens = blockTokens
    }
    return s
}
