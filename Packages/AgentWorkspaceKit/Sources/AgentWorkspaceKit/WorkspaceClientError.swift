import Foundation

public enum WorkspaceClientError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidCredentials
    case unauthorized
    case serverError(Int)
    case custom(String)
    case invalidResponse
    case secureStorage(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请填写有效的服务器地址。公网连接需要 HTTPS；HTTP 仅可用于本机或局域网。"
        case .invalidCredentials: return "邮箱或密码不正确，请重新输入。"
        case .unauthorized: return "登录已过期，请重新登录。"
        case .serverError(let status): return "服务器暂时无法完成请求（\(status)）。"
        case .custom(let message): return message
        case .invalidResponse: return "服务器返回了无法识别的内容，请检查服务器地址与版本。"
        case .secureStorage: return "无法访问设备的安全存储，请解锁设备后重试。"
        }
    }
}

public struct ControlCallError: Error, LocalizedError, Sendable {
    public var message: String
    public var call: PendingCall
    public var retryable: Bool
    public var uncertain: Bool
    public var httpStatus: Int?
    public var errorDescription: String? { message }
    public init(_ message: String, call: PendingCall, retryable: Bool = true, uncertain: Bool = false, httpStatus: Int? = nil) {
        self.message = message; self.call = call; self.retryable = retryable; self.uncertain = uncertain; self.httpStatus = httpStatus
    }
}
