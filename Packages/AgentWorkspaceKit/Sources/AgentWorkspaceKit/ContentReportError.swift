import Foundation

public struct ContentReportError: Error, LocalizedError, Sendable {
    public let message: String
    public let uncertain: Bool
    public let httpStatus: Int?
    public var errorDescription: String? { message }
    public init(_ message: String, uncertain: Bool, httpStatus: Int? = nil) {
        self.message = message; self.uncertain = uncertain; self.httpStatus = httpStatus
    }
}
