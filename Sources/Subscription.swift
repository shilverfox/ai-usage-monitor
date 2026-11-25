import Foundation
import SwiftUI

// MARK: - 数据模型

/// 由 scripts/fetch_google_subscription.py 写入的订阅快照
struct SubscriptionSnapshot: Codable {
    var schemaVersion: Int?
    var fetchedAt: String?
    var needsLogin: Bool?
    var lastError: String?
    var subscription: SubInfo?
    var storage: StorageInfo?
    var charges: [Charge]?
    var chargesFetchedAt: String?
}

struct SubInfo: Codable {
    var provider: String?
    var plan: String?
    var status: String?
    var statusText: String?
    var periodEnd: String?
    var renewalPrice: String?
    var renewalCycle: String?
    var autoRenew: Bool?
}

struct StorageInfo: Codable {
    var usedText: String?
    var totalText: String?
    var usedGB: Double?
    var totalGB: Double?
    var percent: Double?
    var planStorage: String?
    var planName: String?
    var planEnd: String?
    var breakdown: [StorageItem]?
}

struct StorageItem: Codable, Identifiable {
    var name: String
    var sizeText: String
    var sizeGB: Double
    var id: String { name }
}

struct Charge: Codable, Identifiable {
    var date: String
    var amount: String
    var title: String?
    var detail: String?
    var refunded: Bool
    var id: String { date + "|" + amount + "|" + (detail ?? "") }
}

// MARK: - 工具

enum SubDate {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        return f
    }()

    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return day.date(from: s)
    }

    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// 自然日差（今天到目标日），避免整除取整带来的「明天显示 0 天后」
    static func daysBetween(_ from: Date, _ to: Date) -> Int {
        let cal = Calendar.current
        let a = cal.startOfDay(for: from)
        let b = cal.startOfDay(for: to)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}

// MARK: - 派生属性

extension SubscriptionSnapshot {
    var fetchedDate: Date? { SubDate.parseTimestamp(fetchedAt) }
    var chargesDate: Date? { SubDate.parseTimestamp(chargesFetchedAt) }

    var periodEndDate: Date? { SubDate.parse(subscription?.periodEnd ?? storage?.planEnd) }

    /// 距到期还有几天（负数表示已过期）
    var daysLeft: Int? {
        guard let end = periodEndDate else { return nil }
        return SubDate.daysBetween(Date(), end)
    }

    var isCancelled: Bool { subscription?.status == "cancelled" }
    var autoRenew: Bool { subscription?.autoRenew ?? false }

    /// 自动续订时才有「下次扣款」；已取消则为 nil（这是用户最关心的结论）
    var nextChargeDate: Date? { autoRenew ? periodEndDate : nil }

    /// 最近一次真实扣款（排除已退款）
    var lastCharge: Charge? {
        (charges ?? [])
            .filter { !$0.refunded }
            .sorted { $0.date > $1.date }
            .first
    }

    /// 最早一笔 Google One / AI 相关记录，用作「订阅始于」
    var firstCharge: Charge? {
        (charges ?? [])
            .filter { ($0.title ?? "").contains("Google AI") || ($0.title ?? "").contains("GB") }
            .sorted { $0.date < $1.date }
            .first ?? (charges ?? []).sorted { $0.date < $1.date }.first
    }

    /// 本次付费周期的起始日 = 上次扣款日
    var cycleStartDate: Date? { SubDate.parse(lastCharge?.date) }
}

// MARK: - Store

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published var snapshot: SubscriptionSnapshot?
    @Published var refreshing = false
    @Published var loadError: String?

    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/usagemonitor/subscriptions.json")

    /// 脚本位置：优先 app bundle 内（build.sh 会拷进去），否则退回源码仓库路径
    private var scriptPath: String? {
        if let bundled = Bundle.main.path(forResource: "fetch_google_subscription", ofType: "py") {
            return bundled
        }
        let repo = NSHomeDirectory() + "/workshop/ai/Claude/UsageMonitor/scripts/fetch_google_subscription.py"
        return FileManager.default.fileExists(atPath: repo) ? repo : nil
    }

    init() {
        load()
        // 打开面板时如果缓存超过 6 小时，静默刷新一次
        if let f = snapshot?.fetchedDate, Date().timeIntervalSince(f) > 6 * 3600 {
            refresh(visible: false)
        } else if snapshot == nil {
            refresh(visible: false)
        }
    }

    /// 菜单栏提醒：只有「会自动扣款且 ≤7 天」才追加，避免常驻噪声
    var menuSuffix: String {
        guard let s = snapshot, s.autoRenew,
              let d = s.daysLeft, d >= 0, d <= 7 else { return "" }
        return " · 💳\(d)天"
    }

    func load() {        guard let data = try? Data(contentsOf: cacheURL) else {
            snapshot = nil
            return
        }
        do {
            snapshot = try JSONDecoder().decode(SubscriptionSnapshot.self, from: data)
            loadError = nil
        } catch {
            loadError = "缓存解析失败：\(error.localizedDescription)"
        }
    }

    /// visible=true 会弹出 Chrome 窗口，用于重新登录或抓取扣款记录
    func refresh(visible: Bool) {
        guard !refreshing, let script = scriptPath else {
            if scriptPath == nil { loadError = "找不到抓取脚本（scripts/fetch_google_subscription.py）" }
            return
        }
        refreshing = true
        let args = visible ? [script, "--visible"] : [script]

        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var code: Int32 = -1
            do {
                try p.run()
                p.waitUntilExit()
                code = p.terminationStatus
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "启动抓取脚本失败：\(error.localizedDescription)"
                    self.refreshing = false
                }
                return
            }
            DispatchQueue.main.async {
                self.load()
                if code == 2 {
                    self.loadError = "登录态失效，需要点「登录」重新授权一次"
                } else if code != 0 {
                    self.loadError = "抓取失败（退出码 \(code)）"
                }
                self.refreshing = false
            }
        }
    }
}
