import Foundation

// 一个额度窗口：对应 Claude 官方 rate_limits 里的 five_hour / seven_day。
// percent 直接来自官方 used_percentage；resetsAt 来自官方 resets_at（用于倒计时）。
struct RateWindow: Equatable {
    var percent: Int          // 0...100
    var resetsAt: Date?       // 重置时间点；nil 表示官方未给
}

// 底部额度条要展示的全部数据。Equatable：内容不变就不重发布，避免多余重绘。
struct UsageStats: Equatable {
    var fiveHour: RateWindow?   // 官方 5 小时窗口
    var sevenDay: RateWindow?   // 官方 7 天（周）窗口
    var fableTokens: Int        // 本地统计：Fable 近 7 天 work-tokens（官方无 Fable 单独窗口）
    var hasOfficial: Bool       // 是否已读到官方上报（未读到时 5h/周 显示占位）

    static let empty = UsageStats(fiveHour: nil, sevenDay: nil, fableTokens: 0, hasOfficial: false)
}
