import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Hand-written next to the generated client (`Generated/` is rewritten by `make contract`; this file is not).
///
/// One `Client` per server + device key + company. Every request carries the device key as
/// `Authorization: Bearer` (never in a URL) and, inside a company, its id as `X-Citadel-Company` — the contract's
/// two request headers. Times decode as RFC 3339 with milliseconds, the only shape the server writes.
public enum CitadelConnection {
    /// The company-scoping header (`info.description` of the contract).
    public static let companyHeader = "X-Citadel-Company"

    /// A client for `server` (its origin; operation paths carry `/api/v1`).
    public static func client(server: URL, deviceKey: String, company: Int64?, session: URLSession) -> Client {
        Client(
            serverURL: server,
            configuration: Configuration(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: [CitadelHeaders(deviceKey: deviceKey, company: company)])
    }

    /// The request headers every call to the server carries, for requests made outside the generated client
    /// (the event stream's upgrade and its HTTP replay).
    public static func headers(deviceKey: String, company: Int64?) -> [String: String] {
        var headers = ["Authorization": "Bearer \(deviceKey)"]
        if let company { headers[companyHeader] = String(company) }
        return headers
    }
}

/// Adds the device key and the company to every request of the generated client.
struct CitadelHeaders: ClientMiddleware {
    let deviceKey: String
    let company: Int64?

    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for (name, value) in CitadelConnection.headers(deviceKey: deviceKey, company: company) {
            if let field = HTTPField.Name(name) { request.headerFields[field] = value }
        }
        return try await next(request, body, baseURL)
    }
}
