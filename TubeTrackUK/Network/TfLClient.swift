import Foundation
import OSLog

struct TfLConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String?

    static var app: TfLConfiguration {
        let configuredURL = Bundle.main.object(forInfoDictionaryKey: "TfLAPIBaseURL") as? String
        let baseURL = configuredURL.flatMap(URL.init(string:)) ?? URL(string: "https://api.tfl.gov.uk")!
        let rawKey = Bundle.main.object(forInfoDictionaryKey: "TfLAPIKey") as? String
        let apiKey = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TfLConfiguration(baseURL: baseURL, apiKey: apiKey?.isEmpty == false ? apiKey : nil)
    }
}

enum TfLClientError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case rateLimited(retryAfter: Date?)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The TfL request could not be created."
        case .invalidResponse: "TfL returned an invalid response."
        case .httpStatus: "TfL data is temporarily unavailable."
        case .rateLimited: "Live data is temporarily unavailable."
        case let .decoding(message): "TfL data could not be read: \(message)"
        }
    }
}

enum TfLRequestPriority: Sendable {
    case foreground
    case background
}

struct TfLRequestLimits: Sendable {
    let maximumRequestsPerMinute: Int
    let backgroundRequestsPerMinute: Int
    let authenticatedMaximumRequestsPerMinute: Int
    let authenticatedBackgroundRequestsPerMinute: Int

    init(
        maximumRequestsPerMinute: Int,
        backgroundRequestsPerMinute: Int,
        authenticatedMaximumRequestsPerMinute: Int? = nil,
        authenticatedBackgroundRequestsPerMinute: Int? = nil
    ) {
        self.maximumRequestsPerMinute = maximumRequestsPerMinute
        self.backgroundRequestsPerMinute = backgroundRequestsPerMinute
        self.authenticatedMaximumRequestsPerMinute = authenticatedMaximumRequestsPerMinute
            ?? maximumRequestsPerMinute
        self.authenticatedBackgroundRequestsPerMinute = authenticatedBackgroundRequestsPerMinute
            ?? backgroundRequestsPerMinute
    }

    static let app = TfLRequestLimits(
        maximumRequestsPerMinute: 40,
        backgroundRequestsPerMinute: 35,
        authenticatedMaximumRequestsPerMinute: 490,
        authenticatedBackgroundRequestsPerMinute: 450
    )
}

struct TfLClientDiagnostics: Equatable, Sendable {
    var startedRequests = 0
    var coalescedRequests = 0
    var budgetRejections = 0
    var rateLimitedResponses = 0
}

private struct TfLHTTPPayload: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

actor TfLClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TubeTrackUK",
        category: "TfLClient"
    )

    private let baseURL: URL
    private var apiKey: String?
    private let session: URLSession
    private let limits: TfLRequestLimits
    private var requestDates: [Date] = []
    private var cooldownUntil: Date?
    private var rateLimitStrikeCount = 0
    private var inFlight: [URL: Task<TfLHTTPPayload, Error>] = [:]
    private var requestDiagnostics = TfLClientDiagnostics()

    init(
        configuration: TfLConfiguration = .app,
        session: URLSession? = nil,
        limits: TfLRequestLimits = .app
    ) {
        baseURL = configuration.baseURL
        apiKey = configuration.apiKey
        self.session = session ?? URLSession(configuration: Self.defaultSessionConfiguration())
        self.limits = limits
    }

    nonisolated static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1_024 * 1_024,
            diskCapacity: 0
        )
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return configuration
    }

    func get<Value: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        priority: TfLRequestPriority = .foreground,
        forceRefresh: Bool = false,
        as type: Value.Type = Value.self
    ) async throws -> Value {
        guard var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw TfLClientError.invalidURL
        }
        var items = queryItems
        if let apiKey {
            items.append(URLQueryItem(name: "app_key", value: apiKey))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw TfLClientError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = forceRefresh
            ? .reloadRevalidatingCacheData
            : .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TubeTrackUK/1.0", forHTTPHeaderField: "User-Agent")

        let payload: TfLHTTPPayload
        if let existingTask = inFlight[url] {
            requestDiagnostics.coalescedRequests += 1
            payload = try await existingTask.value
        } else {
            try reserveRequest(priority: priority, now: .now)
            let session = session
            let task = Task<TfLHTTPPayload, Error> {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw TfLClientError.invalidResponse
                }
                return TfLHTTPPayload(data: data, response: response)
            }
            inFlight[url] = task
            do {
                payload = try await task.value
                inFlight[url] = nil
            } catch {
                inFlight[url] = nil
                throw error
            }
        }

        if payload.response.statusCode == 429 {
            let retryAfter = applyRateLimitCooldown(from: payload.response, now: .now)
            requestDiagnostics.rateLimitedResponses += 1
            Self.logger.warning("TfL rate limit response; cooling down requests")
            throw TfLClientError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(payload.response.statusCode) else {
            throw TfLClientError.httpStatus(payload.response.statusCode)
        }
        rateLimitStrikeCount = 0
        do {
            return try JSONDecoder.tfl.decode(Value.self, from: payload.data)
        } catch {
            throw TfLClientError.decoding(error.localizedDescription)
        }
    }

    func diagnostics() -> TfLClientDiagnostics {
        requestDiagnostics
    }

    func setAPIKey(_ apiKey: String?) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.apiKey?.isEmpty == true {
            self.apiKey = nil
        }
    }

    private func reserveRequest(priority: TfLRequestPriority, now: Date) throws {
        if let cooldownUntil, cooldownUntil > now {
            requestDiagnostics.budgetRejections += 1
            throw TfLClientError.rateLimited(retryAfter: cooldownUntil)
        }
        cooldownUntil = nil
        requestDates.removeAll { now.timeIntervalSince($0) >= 60 }
        let limit: Int
        switch (apiKey != nil, priority) {
        case (true, .foreground):
            limit = limits.authenticatedMaximumRequestsPerMinute
        case (true, .background):
            limit = limits.authenticatedBackgroundRequestsPerMinute
        case (false, .foreground):
            limit = limits.maximumRequestsPerMinute
        case (false, .background):
            limit = limits.backgroundRequestsPerMinute
        }
        guard requestDates.count < limit else {
            let retryAfter = requestDates.first?.addingTimeInterval(60)
            requestDiagnostics.budgetRejections += 1
            Self.logger.notice("TfL request held by the local rolling budget")
            throw TfLClientError.rateLimited(retryAfter: retryAfter)
        }
        requestDates.append(now)
        requestDiagnostics.startedRequests += 1
    }

    private func applyRateLimitCooldown(
        from response: HTTPURLResponse,
        now: Date
    ) -> Date {
        rateLimitStrikeCount += 1
        let retryAfter = Self.retryAfterDate(from: response, now: now)
        let exponent = min(rateLimitStrikeCount - 1, 3)
        let fallbackDelay = min(300, 60 * pow(2, Double(exponent)))
        let fallback = now.addingTimeInterval(
            fallbackDelay + Double.random(in: 0 ... 5)
        )
        let proposed = retryAfter ?? fallback
        if let existing = cooldownUntil, existing > proposed {
            return existing
        }
        cooldownUntil = proposed
        return proposed
    }

    private nonisolated static func retryAfterDate(
        from response: HTTPURLResponse,
        now: Date
    ) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return now.addingTimeInterval(max(0, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}
