import Foundation
import OSLog

public struct TubeTrackAPIConfiguration: Sendable {
    public let baseURL: URL

    public init(
        baseURL: URL
    ) {
        self.baseURL = baseURL
    }

    public static var app: TubeTrackAPIConfiguration {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-DebugAPIBaseURL"),
           arguments.indices.contains(flag + 1),
           let url = URL(string: arguments[flag + 1]),
           ["localhost", "127.0.0.1"].contains(url.host),
           ["http", "https"].contains(url.scheme) {
            return TubeTrackAPIConfiguration(baseURL: url)
        }
        #endif
        return TubeTrackAPIConfiguration(
            baseURL: URL(string: "https://api.skynolimit.dev/tube-track")!
        )
    }
}

public enum TubeTrackAPIClientError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case rateLimited(retryAfter: Date?)
    case decoding(String)
    case serviceError(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The Tube Track request could not be created."
        case .invalidResponse: "The Tube Track API returned an invalid response."
        case .httpStatus: "Live transport data is temporarily unavailable."
        case .rateLimited: "Live data is temporarily unavailable."
        case let .decoding(message): "Live transport data could not be read: \(message)"
        case let .serviceError(_, message): message
        }
    }
}

public struct TubeTrackAPIResponse<Value: Sendable>: Sendable {
    public let data: Value
    /// When the server last fetched the underlying data, not when this phone
    /// received a potentially cached HTTP response.
    public let updatedAt: Date
    public let cached: Bool
    public let stale: Bool

    public init(data: Value, updatedAt: Date, cached: Bool, stale: Bool) {
        self.data = data
        self.updatedAt = updatedAt
        self.cached = cached
        self.stale = stale
    }
}

private struct TubeTrackAPIMetadata: Decodable, Sendable {
    let updatedAt: Date?
    let cached: Bool?
    let stale: Bool?
}

private struct TubeTrackAPIEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let data: Value
    let meta: TubeTrackAPIMetadata?

    private enum CodingKeys: String, CodingKey { case data, meta }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(Value.self, forKey: .data)
        // Metadata was absent in older API versions. An incompatible optional
        // field must not break otherwise valid data for existing API callers.
        meta = try? container.decodeIfPresent(TubeTrackAPIMetadata.self, forKey: .meta)
    }
}

public actor TubeTrackAPIClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TubeTrackUK",
        category: "TubeTrackAPIClient"
    )

    private let baseURL: URL
    private let session: URLSession

    public init(
        configuration: TubeTrackAPIConfiguration = .app,
        session: URLSession? = nil
    ) {
        baseURL = configuration.baseURL
        self.session = session ?? URLSession(configuration: Self.defaultSessionConfiguration())
    }

    public nonisolated static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1_024 * 1_024,
            diskCapacity: 0
        )
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return configuration
    }

    public func get<Value: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        forceRefresh: Bool = false,
        as type: Value.Type = Value.self
    ) async throws -> Value {
        try await getSnapshot(
            path,
            queryItems: queryItems,
            forceRefresh: forceRefresh,
            as: type
        ).data
    }

    public func getSnapshot<Value: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        forceRefresh: Bool = false,
        as type: Value.Type = Value.self
    ) async throws -> TubeTrackAPIResponse<Value> {
        guard var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw TubeTrackAPIClientError.invalidURL
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw TubeTrackAPIClientError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = forceRefresh
            ? .reloadRevalidatingCacheData
            : .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TubeTrackUK/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        guard let response = response as? HTTPURLResponse else {
            throw TubeTrackAPIClientError.invalidResponse
        }
        if response.statusCode == 429 {
            let retryAfter = Self.retryAfterDate(from: response, now: .now)
            Self.logger.warning("Tube Track API rate limit response")
            throw TubeTrackAPIClientError.rateLimited(retryAfter: retryAfter)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            if path == "/api/v1/journeys",
               let failure = try? JSONDecoder().decode(JourneyAPIError.self, from: data),
               [400, 422, 503].contains(response.statusCode) {
                throw TubeTrackAPIClientError.serviceError(
                    code: failure.error.code, message: failure.error.message
                )
            }
            throw TubeTrackAPIClientError.httpStatus(response.statusCode)
        }

        let decoder = JSONDecoder.tfl
        do {
            let envelope = try decoder.decode(TubeTrackAPIEnvelope<Value>.self, from: data)
            return TubeTrackAPIResponse(
                data: envelope.data,
                updatedAt: envelope.meta?.updatedAt ?? .now,
                cached: envelope.meta?.cached ?? false,
                stale: envelope.meta?.stale ?? false
            )
        } catch let envelopeError {
            // Raw decoding keeps local URLProtocol fixtures useful and allows a
            // controlled transition if an older API instance is encountered.
            do {
                return TubeTrackAPIResponse(
                    data: try decoder.decode(Value.self, from: data),
                    updatedAt: .now,
                    cached: false,
                    stale: false
                )
            } catch {
                throw TubeTrackAPIClientError.decoding(
                    "\(envelopeError.localizedDescription); \(error.localizedDescription)"
                )
            }
        }
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

private struct JourneyAPIError: Decodable {
    struct Detail: Decodable { let code: String; let message: String }
    let error: Detail
}
