import SwiftUI
import AppKit

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude = Summary()
    @Published var codex = Summary()
    /// 按账号分组的 Codex 额度（当前账号排最前）
    @Published var codexAccounts: [CodexAccountView] = []
    /// 无法归属到具体账号的观测条数与 token
    @Published var codexUnattributed = 0
    @Published var codexUnattributedTokens = 0
    @Published var loading = true
    @Published var lastUpdate: Date?

    private let claudeParser = ClaudeParser()
    private let codexParser = CodexParser()
    private let timeline = AccountTimeline()
    private let queue = DispatchQueue(label: "usage.parse", qos: .utility)
    @Published var claudeQuota: ClaudeQuotaState = .idle

    private let quotaClient = ClaudeQuotaClient()
    private let quotaQueue = DispatchQueue(label: "usage.quota", qos: .utility)
    private var timer: Timer?
    private var quotaTimer: Timer?
    private var busy = false
    private var quotaBusy = false

    init() {
        refresh()
        refreshQuota()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // 官方接口有频率限制，每分钟查一次即可
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota() }
        }
    }

    func refreshQuota() {
        guard !quotaBusy else { return }
        quotaBusy = true
        let client = quotaClient
        quotaQueue.async {
            let state = client.fetch()
            DispatchQueue.main.async {
                // 临时网络错误时保留上一次的成功数据
                if case .failed = state, case .ok = self.claudeQuota {} else { self.claudeQuota = state }
                self.quotaBusy = false
            }
        }
    }

    var claudeQuotaWindows: [ClaudeQuotaWindow] {
        if case .ok(let w, _) = claudeQuota { return w }
        return []
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let cp = claudeParser, xp = codexParser, tl = timeline
        queue.async {
            let since = Date().addingTimeInterval(-8 * 86400)
            cp.refresh(retainSince: since)
            xp.refresh(retainSince: since)
            // 先更新登录时间线，才能给没有账号字段的旧日志做归因
            let identity = tl.refresh()
            let c = summarize(cp.events), x = summarize(xp.events)
            let result = buildCodexAccounts(observations: xp.observations,
                                            events: xp.events,
                                            timeline: tl,
                                            current: identity,
                                            since: since)
            DispatchQueue.main.async {
                self.claude = c
                self.codex = x
                self.codexAccounts = result.accounts
                self.codexUnattributed = result.unattributed
                self.codexUnattributedTokens = result.unattributedTokens
                self.loading = false
                self.lastUpdate = Date()
                self.busy = false
            }
        }
    }

    /// 当前登录账号（拿不到就退回第一个）
    var currentCodexAccount: CodexAccountView? {
        codexAccounts.first { $0.isCurrent } ?? codexAccounts.first
    }

    /// 菜单栏用的主额度：当前账号的第一个窗口
    var codexPrimary: RateWindow? { currentCodexAccount?.windows.first?.1 }

    var menuTitle: String {
        if loading { return "⏳" }
        var parts: [String] = []
        parts.append("CC " + Self.percentOrTokens(claudeQuotaWindows.first?.window, claude.today))
        parts.append("CX " + Self.percentOrTokens(codexPrimary, codex.today))
        return parts.joined(separator: " · ")
    }

    /// 有窗口且未过期 → 百分比；窗口已过期 → 「–%」（数据过期，不等于 0%）；没有窗口 → token 数
    private static func percentOrTokens(_ w: RateWindow?, _ tokens: Int) -> String {
        guard let w else { return fmt(tokens) }
        guard let pct = effectivePercent(w) else { return "–%" }
        return "\(Int(pct.rounded()))%"
    }
}

/// 若重置时间已过，返回 nil 表示「额度未知」——把「日志过期」渲染成 0% 会误导成「额度刚回满」
func effectivePercent(_ w: RateWindow) -> Double? {
    if let r = w.resetsAt, r < Date() { return nil }
    return w.usedPercent
}

func fmt(_ n: Int) -> String {
    let d = Double(n)
    switch d {
    case 1e9...: return String(format: "%.2fB", d / 1e9)
    case 1e6...: return String(format: "%.1fM", d / 1e6)
    case 1e3...: return String(format: "%.1fK", d / 1e3)
    default: return "\(n)"
    }
}

func windowName(_ minutes: Int) -> String {
    switch minutes {
    case 300: return "5 小时额度"
    case 10080: return "本周额度"
    case 43200: return "30 天额度"   // Free 账号是 30 天窗口，不是 5 小时/周
    case 1440: return "今日额度"
    default:
        if minutes >= 1440 { return "\(minutes / 1440) 天额度" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时额度" : "\(minutes) 分钟额度"
    }
}

/// 折叠摘要用的短名：5 小时额度 → 5h
func shortWindowName(_ name: String) -> String {
    name.replacingOccurrences(of: " 小时额度", with: "h")
        .replacingOccurrences(of: " 天额度", with: "天")
        .replacingOccurrences(of: "本周额度", with: "本周")
        .replacingOccurrences(of: "今日额度", with: "今日")
}

func planLabel(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw.lowercased() {
    case "plus": return "Plus"
    case "pro": return "Pro"
    case "free": return "Free"
    case "team": return "Team"
    case "business", "enterprise": return "Business"
    default: return raw.capitalized
    }
}

/// 「3小时12分后」这类相对时长，供重置时间括注
func countdown(to date: Date) -> String {
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "已到期" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)天后" }
    if h > 0 { return "\(h)小时\(m)分后" }
    return "\(m)分钟后"
}

func relative(_ date: Date?) -> String {
    guard let date else { return "无记录" }
    let s = Int(-date.timeIntervalSinceNow)
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}

// MARK: - Codex 多账号

/// 一个账号在 UI 上的一整块：身份 + 额度窗口 + 自己的 token 用量
struct CodexAccountView: Identifiable {
    let id: String                 // 账号 ID；"" 表示日志没写账号
    let label: String              // 脱敏邮箱，或 …da228，或「未归属」
    let plan: String?
    let isCurrent: Bool
    let observedAt: Date
    let windows: [(String, RateWindow)]
    let summary: Summary
}

struct CodexAccountsResult {
    var accounts: [CodexAccountView] = []
    /// 无法归属的观测条数与 token（登录时间线之前 + 日志没写账号）。不展示成"幽灵账号"，只做脚注。
    var unattributed = 0
    var unattributedTokens = 0
}

/// 把观测按账号归组：账号 ID 优先取 session_meta；缺失时用登录时间线按观测时刻反推。
/// 每个「账号 × limit_id」只保留最新一条，因此 A 账号的观测不会再把 B 账号的挤掉。
func buildCodexAccounts(observations: [CodexObservation],
                        events: [TokenEvent],
                        timeline: AccountTimeline,
                        current: CodexAuthIdentity?,
                        since: Date) -> CodexAccountsResult {
    func resolve(_ explicit: String?, at date: Date) -> String {
        // 归因顺序：登录时间线 > 文件里的 creator_account_id。
        // 依据（实测 11-17）：B 账号登录的 1 小时里 246 条观测全是 30 天窗口，
        // 其中 225 条写在 A 名下的旧会话文件里 —— 恢复旧会话会把数据写回旧文件，
        // 而 rate_limits 反映的始终是「当时登录的那个账号」。
        if let byTime = timeline.accountId(at: date) { return byTime }
        if let e = explicit, !e.isEmpty { return e }
        return ""
    }

    var latest: [String: [String: CodexObservation]] = [:]
    var unattributedObs = 0
    for o in observations where o.date >= since {
        let acc = resolve(o.accountId, at: o.date)
        if acc.isEmpty { unattributedObs += 1 }
        if let prev = latest[acc]?[o.limitId], prev.date >= o.date { continue }
        latest[acc, default: [:]][o.limitId] = o
    }

    var eventsBy: [String: [TokenEvent]] = [:]
    var unattributedTokens = 0
    for e in events {
        let acc = resolve(e.accountId, at: e.date)
        if acc.isEmpty { unattributedTokens += e.total; continue }
        eventsBy[acc, default: []].append(e)
    }

    var out: [CodexAccountView] = []
    for (acc, byLimit) in latest {
        // 选「窗口最全」的桶（通常是 limit_id=codex；premium 桶没有窗口，已被跳过）
        func windowScore(_ o: CodexObservation) -> Int {
            (o.primary != nil ? 2 : 0) + (o.secondary != nil ? 2 : 0)
        }
        guard let best = byLimit.values.max(by: { a, b in
            windowScore(a) != windowScore(b) ? windowScore(a) < windowScore(b) : a.date < b.date
        }) else { continue }

        // 归属不明的观测不伪装成一个账号
        if acc.isEmpty { continue }

        var windows: [(String, RateWindow)] = []
        if let p = best.primary { windows.append((windowName(p.windowMinutes), p)) }
        if let s = best.secondary { windows.append((windowName(s.windowMinutes), s)) }

        let isCurrent = acc == current?.accountId
        let ident = timeline.identity(for: acc)
        let email = ident?.email ?? (isCurrent ? current?.email : nil)
        let plan = ident?.plan ?? (isCurrent ? current?.plan : nil)
        let label = maskEmail(email) ?? shortAccountId(acc)

        out.append(CodexAccountView(id: acc,
                                    label: label,
                                    plan: planLabel(plan),
                                    isCurrent: isCurrent,
                                    observedAt: best.date,
                                    windows: windows,
                                    summary: summarize(eventsBy[acc] ?? [])))
    }

    out.sort { a, b in
        if a.isCurrent != b.isCurrent { return a.isCurrent }
        return a.observedAt > b.observedAt
    }
    return CodexAccountsResult(accounts: out,
                               unattributed: unattributedObs,
                               unattributedTokens: unattributedTokens)
}

// MARK: - Views

struct Sparkline: View {
    let values: [Int]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let w = geo.size.width / CGFloat(values.count)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(values[i] == 0 ? 0.15 : 0.85))
                        .frame(width: max(w - 1, 1),
                               height: max(2, geo.size.height * CGFloat(values[i]) / CGFloat(maxV)))
                }
            }
        }
        .frame(height: 36)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「21:00 重置」/「星期日12:00 重置」
/// 「17:00 重置 · 3小时12分后」；日志没给重置时间时明确说出来，而不是留一行空白
func resetLabel(_ date: Date?) -> String {
    guard let date else { return "重置时间未知" }
    if date < Date() { return "窗口已重置" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEEE HH:mm"
    let clock = f.string(from: date).replacingOccurrences(of: " ", with: "")
    return "\(clock) 重置 · \(countdown(to: date))"
}

/// 按「已用比例 vs 本周已过时间比例」判断进度，生成顶部的一句话
func paceHeadline(_ w: RateWindow) -> String {
    guard let pct = effectivePercent(w) else { return "额度窗口已重置，等待新数据。" }
    guard let reset = w.resetsAt else { return "日志未提供重置时间，无法判断节奏。" }
    guard reset > Date(), w.windowMinutes > 0 else { return "额度已重置，可以放心使用。" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDateInToday(reset) ? "HH:mm" : "EEEE"
    let when = f.string(from: reset)
    if pct >= 100 { return "额度已用完，将在\(when)重置。" }
    let total = Double(w.windowMinutes) * 60
    let elapsed = max(0, min(1, 1 - reset.timeIntervalSinceNow / total))
    if pct / 100 <= elapsed + 0.05 { return "进度正常。在\(when)重置前，您的额度应该还很充裕。" }
    if pct / 100 <= elapsed + 0.2 { return "用量略快。在\(when)重置前，注意控制节奏。" }
    return "用量偏快。按当前速度，可能在\(when)重置前用完额度。"
}

struct QuotaRow: View {
    let title: String
    let subtitle: String
    let fraction: Double   // 0...1
    let trailing: String
    let expired: Bool      // 窗口已过期、数据未知

    init(title: String, window: RateWindow) {
        let pct = effectivePercent(window)
        self.init(title: title,
                  subtitle: resetLabel(window.resetsAt),
                  fraction: (pct ?? 0) / 100,
                  trailing: pct.map { "已使用 \(Int($0.rounded()))%" } ?? "等待新数据",
                  expired: pct == nil)
    }

    init(title: String, subtitle: String, fraction: Double, trailing: String, expired: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.fraction = fraction
        self.trailing = trailing
        self.expired = expired
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.18))
                    // 过期不再画成「0% 空条」——那看起来像额度刚回满
                    Capsule().fill(expired ? Color.secondary.opacity(0.35)
                                           : (fraction >= 0.9 ? Color.red : Color.accentColor))
                        .frame(width: geo.size.width * CGFloat(max(0, min(fraction, 1))))
                }
            }
            .frame(height: 5)
            Text(trailing)
                .font(.caption).monospacedDigit()
                .foregroundStyle(expired ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

/// 顶部一句话：短窗口（5 小时）快用完时优先说它，否则用周/30 天窗口判断节奏
func quotaHeadline(_ windows: [(String, RateWindow)]) -> String {
    if let (name, w) = windows.first(where: { $0.1.windowMinutes == 300 }),
       let pct = effectivePercent(w), pct >= 90 {
        let when = w.resetsAt.map { countdown(to: $0) + "重置" } ?? "重置时间未知"
        return pct >= 100
            ? "「\(name)」额度已用完，\(when)。"
            : "「\(name)」已用 \(Int(pct.rounded()))%，\(when)，注意节奏。"
    }
    let head = windows.first { $0.1.windowMinutes == 10080 }?.1
        ?? windows.first { $0.1.windowMinutes == 43200 }?.1
        ?? windows.first?.1
    return head.map(paceHeadline) ?? ""
}

struct QuotaSection: View {
    let windows: [(String, RateWindow)]

    var body: some View {
        let text = quotaHeadline(windows)
        VStack(alignment: .leading, spacing: 6) {
            if !text.isEmpty {
                Text(text).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            ForEach(windows.indices, id: \.self) { i in
                QuotaRow(title: windows[i].0, window: windows[i].1)
            }
        }
    }
}

/// 单个 Codex 账号：身份行 + （当前账号才有的）节奏提示 + 自己的额度行 + 自己的 token 用量
struct CodexAccountBlock: View {
    let account: CodexAccountView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(account.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(account.isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let p = account.plan {
                    Text(p)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if account.isCurrent {
                    Text("当前")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer()
                Text("额度观测于 " + relative(account.observedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if account.isCurrent {
                let head = quotaHeadline(account.windows)
                if !head.isEmpty {
                    Text(head).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
            }
            ForEach(account.windows.indices, id: \.self) { i in
                QuotaRow(title: account.windows[i].0, window: account.windows[i].1)
            }
            Text("该账号 token：今日 \(fmt(account.summary.today)) · 近 7 天 \(fmt(account.summary.week))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct ProviderCard<Extra: View>: View {
    let name: String
    let icon: String
    let color: Color
    let summary: Summary
    /// 折叠时头部显示的摘要（额度百分比 / 异常态），避免折叠把信息藏起来
    let folded: String
    @ViewBuilder let extra: Extra

    @AppStorage private var collapsed: Bool

    init(name: String, icon: String, color: Color, summary: Summary, folded: String,
         storageKey: String, @ViewBuilder extra: () -> Extra) {
        self.name = name
        self.icon = icon
        self.color = color
        self.summary = summary
        self.folded = folded
        self.extra = extra()
        _collapsed = AppStorage(wrappedValue: false, storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(name).font(.headline)
                Spacer()
                if collapsed {
                    Text(folded)
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("最近活动 " + relative(summary.lastActivity))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
            }
            .help(collapsed ? "点击展开" : "点击折叠")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(name)，\(collapsed ? "已折叠" : "已展开")")

            if !collapsed {
                extra
                HStack {
                    Stat(label: "今日", value: fmt(summary.today))
                    Stat(label: "近 5 小时", value: fmt(summary.last5h))
                    Stat(label: "近 7 天", value: fmt(summary.week))
                }
                Text("以上是本地日志的 token 用量（滚动统计），与上方额度百分比口径不同")
                    .font(.caption2).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("近 24 小时（每小时 token）").font(.caption2).foregroundStyle(.secondary)
                    Sparkline(values: summary.hourly, color: color)
                }
                if !summary.byModel.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("7 天按模型").font(.caption2).foregroundStyle(.secondary)
                        ForEach(summary.byModel.prefix(4), id: \.0) { m in
                            HStack {
                                Text(m.0).font(.caption).lineLimit(1)
                                Spacer()
                                Text(fmt(m.1)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct ClaudeQuotaNotice: View {
    let state: ClaudeQuotaState
    let retry: () -> Void
    var body: some View {
        let msg: String? = switch state {
        case .idle: "正在获取官方额度…"
        case .noCredentials: "未找到 Claude Code 登录凭证。在终端运行 claude 并用 /login 登录订阅账号后，这里会显示官方额度。"
        case .expired: "登录凭证已过期，自动续期未成功。在终端运行一次 claude 即可恢复。"
        case .failed(let e): "获取官方额度失败：\(e)"
        case .ok: nil
        }
        if let msg {
            HStack(alignment: .top) {
                Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("重试", action: retry).controlSize(.mini)
            }
        }
    }
}

// MARK: - 折叠摘要

func shortPct(_ w: RateWindow) -> String {
    guard let p = effectivePercent(w) else { return "–" }
    return "\(Int(p.rounded()))%"
}

/// Claude 折叠后的摘要：优先额度百分比，没有额度时把异常态说清楚
@MainActor
func claudeFolded(_ store: UsageStore) -> String {
    if !store.claudeQuotaWindows.isEmpty {
        return store.claudeQuotaWindows.prefix(2).map { item in
            "\(item.key.hasPrefix("seven_day") ? "本周" : "5h") \(shortPct(item.window))"
        }.joined(separator: " · ")
    }
    switch store.claudeQuota {
    case .expired: return "凭证已过期"
    case .noCredentials: return "未登录"
    case .failed: return "取数失败"
    case .idle: return "获取中…"
    case .ok: return "今日 \(fmt(store.claude.today))"
    }
}

/// Codex 折叠后的摘要：当前账号的额度 + 账号总数，没有额度就退回 token 数
@MainActor
func codexFolded(_ store: UsageStore) -> String {
    guard let acc = store.currentCodexAccount else { return "今日 \(fmt(store.codex.today))" }
    var parts: [String] = acc.windows.prefix(2).map { "\(shortWindowName($0.0)) \(shortPct($0.1))" }
    if parts.isEmpty { parts = ["今日 \(fmt(store.codex.today))"] }
    if store.codexAccounts.count > 1 { parts.append("\(store.codexAccounts.count) 个账号") }
    return parts.joined(separator: " · ")
}

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.loading {
                HStack { ProgressView().controlSize(.small); Text("首次扫描日志中…").font(.caption) }
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                ProviderCard(name: "Claude Code", icon: "sparkle", color: .orange, summary: store.claude,
                             folded: claudeFolded(store), storageKey: "collapsed.claude") {
                    if !store.claudeQuotaWindows.isEmpty {
                        QuotaSection(windows: store.claudeQuotaWindows.map { (claudeQuotaName($0.key), $0.window) })
                    } else {
                        ClaudeQuotaNotice(state: store.claudeQuota) { store.refreshQuota() }
                    }
                    if store.claudeQuotaWindows.isEmpty, let b = store.claude.blockStart {
                        // 没有官方百分比时：进度条表示窗口已过去的时间，右侧是本窗口已用 token
                        QuotaRow(title: "当前会话（推算）",
                                 subtitle: resetLabel(b.addingTimeInterval(5 * 3600)),
                                 fraction: Date().timeIntervalSince(b) / (5 * 3600),
                                 trailing: "已用 \(fmt(store.claude.blockTokens))")
                    }
                }
                ProviderCard(name: "Codex", icon: "terminal", color: .teal, summary: store.codex,
                             folded: codexFolded(store), storageKey: "collapsed.codex") {
                    if store.codexAccounts.isEmpty {
                        Text("暂无 Codex 额度记录。运行一次 codex 后，这里会按账号显示额度窗口与重置时间。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(store.codexAccounts) { acc in
                            CodexAccountBlock(account: acc)
                            if acc.id != store.codexAccounts.last?.id {
                                Divider().padding(.vertical, 2)
                            }
                        }
                        Text("额度按账号分开统计：各自取 Codex 日志里最新一次观测，切换账号不会覆盖另一个")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.codexUnattributed > 0 {
                            Text("另有 \(store.codexUnattributed) 条早期观测（合计 \(fmt(store.codexUnattributedTokens)) token）无法归属到账号：旧版日志没写账号字段，且早于本机记录的登录时间线，未计入上方")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Text("更新于 \(store.lastUpdate.map { $0.formatted(date: .omitted, time: .standard) } ?? "-")")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { store.refresh(); store.refreshQuota() }.controlSize(.small)
                Button("退出") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 440)
    }
}

// MARK: - App

@main
struct UsageMonitorApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            Text(store.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
