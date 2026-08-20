import Foundation

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
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The TfL request could not be created."
        case .invalidResponse: "TfL returned an invalid response."
        case let .httpStatus(code): "TfL returned HTTP status \(code)."
        case let .decoding(message): "TfL data could not be read: \(message)"
        }
    }
}

actor TfLClient {
    private let configuration: TfLConfiguration
    private let session: URLSession

    init(configuration: TfLConfiguration = .app, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? URLSession(configuration: Self.defaultSessionConfiguration())
    }

    nonisolated static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func get<Value: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        as type: Value.Type = Value.self
    ) async throws -> Value {
        guard var components = URLComponents(
            url: configuration.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw TfLClientError.invalidURL
        }
        var items = queryItems
        if let apiKey = configuration.apiKey {
            items.append(URLQueryItem(name: "app_key", value: apiKey))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw TfLClientError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TubeTrackUK/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TfLClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TfLClientError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder.tfl.decode(Value.self, from: data)
        } catch {
            throw TfLClientError.decoding(error.localizedDescription)
        }
    }
}
