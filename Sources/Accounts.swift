import Foundation

// MARK: - Codex 账号身份
//
// Codex 只有一个 ~/.codex/auth.json，切换账号＝覆写它。所以：
//   · 当前登录身份 = 解析 auth.json 里 id_token 的 JWT 声明（纯本地，不联网）
//   · 历史登录区间 = 每次 auth.json 的 mtime 变化记一条，持久化到 UserDefaults
// 有了时间线，就能把「没有 creator_account_id 的旧日志」按观测时刻归到当时登录的账号。

/// 当前登录的 Codex 账号
struct CodexAuthIdentity: Equatable {
    var accountId: String
    var email: String?
    var plan: String?
    var userId: String?
}

/// 一段登录区间：从 auth.json 写入到下次写入
struct LoginSpan: Codable, Equatable {
    var switchedAt: Date
    var accountId: String
    var email: String?
    var plan: String?
}

final class AccountTimeline: @unchecked Sendable { // 只在 usage.parse 串行队列上访问
    static let defaultsKey = "codex.loginSpans"
    private static let maxSpans = 60

    private(set) var spans: [LoginSpan] = []
    private(set) var current: CodexAuthIdentity?

    private let authPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")

    init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([LoginSpan].self, from: data) else { return }
        // 相邻同账号区间合并（token 续期会重写 auth.json，mtime 变了但账号没变）
        var merged: [LoginSpan] = []
        for s in decoded.sorted(by: { $0.switchedAt < $1.switchedAt }) {
            if var last = merged.last, last.accountId == s.accountId {
                last.email = s.email ?? last.email
                last.plan = s.plan ?? last.plan
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        spans = merged
        if merged.count != decoded.count { save() }   // 顺手把合并结果写回，避免每次启动重复合并
    }

    private func save() {
        if spans.count > Self.maxSpans { spans.removeFirst(spans.count - Self.maxSpans) }
        if let data = try? JSONEncoder().encode(spans) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// 读 auth.json。**账号变了**才记为一次新的登录区间；
    /// 同一账号的 auth.json 被重写（token 续期）只更新邮箱/套餐，不新增区间。
    @discardableResult
    func refresh() -> CodexAuthIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: authPath.path),
              let mtime = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: authPath),
              let id = Self.parseIdentity(data) else {
            current = nil
            return nil
        }
        if var last = spans.last {
            if last.accountId != id.accountId {
                spans.append(LoginSpan(switchedAt: mtime,
                                       accountId: id.accountId,
                                       email: id.email,
                                       plan: id.plan))
                save()
            } else if last.email != id.email || last.plan != id.plan {
                last.email = id.email
                last.plan = id.plan
                spans[spans.count - 1] = last
                save()
            }
        } else {
            spans.append(LoginSpan(switchedAt: mtime,
                                   accountId: id.accountId,
                                   email: id.email,
                                   plan: id.plan))
            save()
        }
        current = id
        return id
    }

    /// 某时刻登录的是谁（用于无账号字段的日志）
    func accountId(at date: Date) -> String? {
        var hit: String?
        for s in spans where s.switchedAt <= date { hit = s.accountId }
        return hit
    }

    /// 该账号最近一次被登录时记下的身份（邮箱/套餐）
    func identity(for accountId: String) -> LoginSpan? {
        spans.last { $0.accountId == accountId }
    }

    /// 解析 id_token（JWT 中间段）：email / plan / account_id 都是明文字段
    static func parseIdentity(_ data: Data) -> CodexAuthIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let payload = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard let aid = auth["chatgpt_account_id"] as? String, !aid.isEmpty else { return nil }
        return CodexAuthIdentity(accountId: aid,
                                 email: claims["email"] as? String,
                                 plan: auth["chatgpt_plan_type"] as? String,
                                 userId: auth["chatgpt_user_id"] as? String)
    }
}

/// 邮箱脱敏：`user@example.com` → `use***@example.com`（保留域名，前 3 位够区分多个账号）
func maskEmail(_ s: String?) -> String? {
    guard let s, let at = s.firstIndex(of: "@") else { return s }
    let name = String(s[s.startIndex..<at])
    let domain = String(s[at...])
    if name.count <= 3 { return name + "***" + domain }
    return String(name.prefix(3)) + "***" + domain
}

/// 账号短标识：…a1b2c3d4e5f6 → …d4e5f6
func shortAccountId(_ id: String) -> String {
    id.count > 6 ? "…" + String(id.suffix(6)) : id
}
