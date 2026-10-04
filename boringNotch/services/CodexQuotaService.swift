import Combine
import Foundation

@MainActor
final class CodexQuotaService: ObservableObject {
    static let shared = CodexQuotaService()

    @Published private(set) var snapshot: CodexQuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshFailed = false

    private var inFlight: Task<CodexQuotaSnapshot, Error>?

    private init() {}

    func refresh() async {
        if let inFlight {
            isRefreshing = true
            do {
                snapshot = try await inFlight.value
                lastRefreshFailed = false
            } catch {
                lastRefreshFailed = true
            }
            isRefreshing = false
            self.inFlight = nil
            return
        }

        isRefreshing = true
        lastRefreshFailed = false
        let request = Task<CodexQuotaSnapshot, Error> {
            guard let resultData = await XPCHelperClient.shared.readCodexQuota() else {
                throw CodexQuotaRequestError.unavailable
            }
            return try CodexQuotaDecoder.decode(resultData: resultData)
        }
        inFlight = request

        do {
            snapshot = try await request.value
            lastRefreshFailed = false
        } catch {
            lastRefreshFailed = true
        }
        isRefreshing = false
        inFlight = nil
    }
}

private enum CodexQuotaRequestError: Error {
    case unavailable
}
