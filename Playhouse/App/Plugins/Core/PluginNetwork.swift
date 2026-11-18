import Foundation

/// A plugin's `fetch(url, options)`: one HTTP or HTTPS request, made the same
/// way in the window and in `plugin render`. The prelude sends it as the host
/// call `net.fetch` with `{url, method, headers, body, timeout}` and turns the
/// answer, `{url, status, statusText, redirected, headers, body}`, into a
/// Response. Bodies are text both ways: a request body is a string, and a
/// response body is read as UTF-8.
enum PluginNetwork {
    static let maxResponseBytes = 10 * 1024 * 1024
    static let defaultTimeout: TimeInterval = 30

    /// No cookies, credentials or cache shared with anything else.
    static let session = URLSession(configuration: .ephemeral)

    static func fetch(_ arguments: PluginValue) async -> Result<PluginValue, PluginHostError> {
        let request: URLRequest
        do {
            request = try makeRequest(arguments)
        } catch let error as PluginHostError {
            return .failure(error)
        } catch {
            return .failure(PluginHostError(code: "invalid_argument", message: error.localizedDescription))
        }
        do {
            let redirects = RedirectCounter()
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            guard let http = response as? HTTPURLResponse else {
                return .failure(PluginHostError(code: "network_error", message: "\(request.url?.absoluteString ?? "The URL") didn't answer over HTTP."))
            }
            if http.expectedContentLength > maxResponseBytes { throw tooLarge() }
            var body: [UInt8] = []
            body.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(maxResponseBytes)))))
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxResponseBytes { throw tooLarge() }
            }
            var headers: [String: PluginValue] = [:]
            for (name, value) in http.allHeaderFields {
                headers[String(describing: name).lowercased()] = .string(String(describing: value))
            }
            let url = http.url?.absoluteString ?? request.url?.absoluteString ?? ""
            return .success(.object([
                "url": .string(url),
                "status": .number(Double(http.statusCode)),
                "statusText": .string(HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized),
                "redirected": .bool(redirects.followed),
                "headers": .object(headers),
                "body": .string(String(decoding: body, as: UTF8.self))
            ]))
        } catch let error as PluginHostError {
            return .failure(error)
        } catch {
            return .failure(PluginHostError(code: "network_error", message: error.localizedDescription))
        }
    }

    static func makeRequest(_ arguments: PluginValue) throws -> URLRequest {
        let fields = arguments.object ?? [:]
        guard let text = fields["url"]?.string, let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw PluginHostError(code: "invalid_argument", message: "fetch needs an absolute http or https URL, not \"\(fields["url"]?.string ?? "")\".")
        }
        guard scheme == "http" || scheme == "https" else {
            throw PluginHostError(code: "invalid_argument", message: "fetch only reaches http and https URLs, not \(scheme).")
        }
        let method = (fields["method"]?.string ?? "GET").uppercased()
        guard method.range(of: #"^[A-Z]+$"#, options: .regularExpression) != nil else {
            throw PluginHostError(code: "invalid_argument", message: "\"\(method)\" is not an HTTP method.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: defaultTimeout)
        request.httpMethod = method
        if case .number(let timeout)? = fields["timeout"] {
            guard timeout > 0 else { throw PluginHostError(code: "invalid_argument", message: "fetch's timeout must be a positive number of seconds.") }
            request.timeoutInterval = timeout
        }
        for (name, value) in fields["headers"]?.object ?? [:] {
            guard let value = value.string else {
                throw PluginHostError(code: "invalid_argument", message: "The header \(name) must be a string.")
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = fields["body"]?.string {
            guard method != "GET", method != "HEAD" else {
                throw PluginHostError(code: "invalid_argument", message: "A \(method) request can't have a body.")
            }
            request.httpBody = Data(body.utf8)
        }
        return request
    }

    private static func tooLarge() -> PluginHostError {
        PluginHostError(code: "network_error", message: "The response is larger than \(maxResponseBytes / 1024 / 1024) MB.")
    }
}

/// Notes whether the session followed a redirect, which it then follows as usual.
private final class RedirectCounter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var followed: Bool { lock.withLock { count > 0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        lock.withLock { count += 1 }
        return request
    }
}
