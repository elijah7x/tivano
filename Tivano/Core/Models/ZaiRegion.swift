import Foundation

enum ZaiRegion: String, CaseIterable, Identifiable, Sendable {
    case global
    case china

    static let defaultsKey = "zaiRegion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: "Global"
        case .china: "China"
        }
    }

    var host: String {
        switch self {
        case .global: "api.z.ai"
        case .china: "open.bigmodel.cn"
        }
    }

    var apiHost: String { "\(host)/api/coding/paas/v4" }

    var apiKeySource: String {
        switch self {
        case .global: "z.ai/manage-apikey/apikey-list"
        case .china: "bigmodel.cn/usercenter/proj-mgmt/apikeys"
        }
    }

    var keyPageURL: URL { URL(string: "https://\(apiKeySource)")! }

    nonisolated static var current: ZaiRegion {
        ZaiRegion(rawValue: (CaptureRun.defaults ?? .standard).string(forKey: defaultsKey) ?? "") ?? .global
    }
}
