import Foundation

struct CodexQuotaWindow: Equatable, Sendable {
    let remainingPercent: Int
    let windowDurationMins: Int
    let resetsAt: Date
}

struct CodexQuotaSnapshot: Equatable, Sendable {
    let primary: CodexQuotaWindow
    let secondary: CodexQuotaWindow?
    let fetchedAt: Date
}

enum CodexQuotaDecodingError: Error {
    case invalidResponse
    case missingCodexLimit
    case missingPrimaryWindow
}

enum CodexQuotaDecoder {
    static func decode(resultData: Data, fetchedAt: Date = Date()) throws -> CodexQuotaSnapshot {
        guard
            let root = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
            let limitsByID = root["rateLimitsByLimitId"] as? [String: Any],
            let codexLimit = limitsByID["codex"] as? [String: Any]
        else {
            throw CodexQuotaDecodingError.missingCodexLimit
        }

        guard let primary = decodeWindow(codexLimit["primary"]) else {
            throw CodexQuotaDecodingError.missingPrimaryWindow
        }

        return CodexQuotaSnapshot(
            primary: primary,
            secondary: decodeWindow(codexLimit["secondary"]),
            fetchedAt: fetchedAt
        )
    }

    private static func decodeWindow(_ value: Any?) -> CodexQuotaWindow? {
        guard
            let object = value as? [String: Any],
            let usedValue = object["usedPercent"] as? NSNumber,
            let durationValue = object["windowDurationMins"] as? NSNumber,
            let resetValue = object["resetsAt"] as? NSNumber
        else {
            return nil
        }

        let usedPercent = usedValue.doubleValue
        let duration = durationValue.intValue
        let reset = resetValue.doubleValue
        guard usedPercent.isFinite, duration > 0, reset.isFinite, reset > 0 else { return nil }

        let remaining = max(0, min(100, 100 - Int(usedPercent.rounded())))
        return CodexQuotaWindow(
            remainingPercent: remaining,
            windowDurationMins: duration,
            resetsAt: Date(timeIntervalSince1970: reset)
        )
    }
}
