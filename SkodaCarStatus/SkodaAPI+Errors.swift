import Foundation

extension SkodaAPI {
    static func failure(for http: HTTPURLResponse, body: Data) -> Failure {
        let problem = try? JSONDecoder().decode(Problem.self, from: body)

        switch (http.statusCode, problem?.kind) {
        case (401, .apiKeyExpired):
            return Failure(message: "API key expired. Create a new one in MyŠkoda.")
        case (401, _):
            return Failure(message: "API key not accepted.")
        case (403, _):
            return Failure(message: "This API key doesn't cover the vehicle.")
        case (400, _):
            return Failure(message: "Invalid VIN.")
        case (404, _):
            return Failure(message: "Vehicle not found.")
        case (429, .vehicleNotAcceptingRequests):
            return Failure(message: "The vehicle isn't accepting requests right now.", retryAfter: retryDelay(http))
        case (429, _):
            return Failure(message: "Too many requests.", retryAfter: retryDelay(http))
        case (503, _):
            return Failure(message: "The Škoda service is temporarily unavailable.", retryAfter: retryDelay(http))
        case (500..., _):
            return Failure(message: "The Škoda service is unavailable.")
        default:
            return Failure(message: problem?.detail ?? problem?.title ?? "Request failed (\(http.statusCode)).")
        }
    }

    /// The spec gives `Retry-After` and `RateLimit-Reset` as seconds; anything else is ignored and the result is capped at one hour.
    private static func retryDelay(_ http: HTTPURLResponse) -> TimeInterval? {
        for header in ["Retry-After", "RateLimit-Reset"] {
            if let value = http.value(forHTTPHeaderField: header), let seconds = TimeInterval(value),
               seconds.isFinite, seconds >= 0 {
                return min(seconds, 3600)
            }
        }
        return nil
    }

    private enum ProblemType: String, TolerantEnum {
        case apiKeyExpired = "api-key-expired"
        case vehicleNotAcceptingRequests = "vehicle-not-accepting-requests"
        case unknown
    }

    private struct Problem: Decodable {
        var type: String?
        var title: String?
        var detail: String?

        /// `type` is a URI whose last segment names the problem; `about:blank` and unlisted types are `unknown`.
        var kind: ProblemType? {
            guard let type else { return nil }
            return ProblemType(rawValue: URL(string: type)?.lastPathComponent ?? "") ?? .unknown
        }
    }
}
