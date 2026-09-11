import Foundation
import OSLog

struct TubeTrackAPIConfiguration: Sendable {
    let baseURL: URL

    static var app: TubeTrackAPIConfiguration {
        TubeTrackAPIConfiguration(
            baseURL: URL(string: "https://api.skynolimit.dev/tube-track")!
        )
    }
}

enum TubeTrackAPIClientError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case rateLimited(retryAfter: Date?)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The Tube Track request could not be created."
        case .invalidResponse: "The Tube Track API returned an invalid response."
        case .httpStatus: "Live transport data is temporarily unavailable."
        case .rateLimited: "Live data is temporarily unavailable."
        case let .decoding(message): "Live transport data could not be read: \(message)"
        }
    }
}

struct TubeTrackAPIResponse<Value: Sendable>: Sendable {
    let data: Value
    /// When the server last fetched the underlying data, not when this phone
    /// received a potentially cached HTTP response.
    let updatedAt: Date
    let cached: Bool
    let stale: Bool
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

actor TubeTrackAPIClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TubeTrackUK",
        category: "TubeTrackAPIClient"
    )

    private let baseURL: URL
    private let session: URLSession

    init(
        configuration: TubeTrackAPIConfiguration = .app,
        session: URLSession? = nil
    ) {
        baseURL = configuration.baseURL
        self.session = session ?? URLSession(configuration: Self.defaultSessionConfiguration())
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

    func getSnapshot<Value: Decodable & Sendable>(
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
