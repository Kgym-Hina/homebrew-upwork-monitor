import AuthenticationServices
import CryptoKit
import Foundation
import Security

#if os(macOS)
import AppKit
import Darwin
#else
import UIKit
#endif

enum MCPAuthError: LocalizedError {
    case discoveryFailed
    case registrationFailed(String)
    case invalidRegistration
    case invalidConfiguration
    case cancelled
    case invalidState
    case missingAuthorizationCode
    case missingRefreshToken
    case tokenRequest(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .discoveryFailed:
            "Could not retrieve Upwork MCP authorization settings. Try again later."
        case .registrationFailed(let message):
            "Upwork MCP client registration failed: \(message)"
        case .invalidRegistration:
            "Upwork MCP did not return a usable client registration."
        case .invalidConfiguration:
            "Upwork MCP returned incomplete OAuth configuration."
        case .cancelled:
            "Upwork sign-in was cancelled."
        case .invalidState:
            "The Upwork sign-in response could not be verified."
        case .missingAuthorizationCode:
            "Upwork did not return an authorization code."
        case .missingRefreshToken:
            "The Upwork connection expired. Connect again to continue."
        case .tokenRequest(let message):
            "Upwork token request failed: \(message)"
        case .httpError(let status, let message):
            "Upwork MCP request failed (HTTP \(status)): \(message)"
        }
    }
}

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let resource = "https://mcp.upwork.com/mcp"
#if os(macOS)
    static let callbackScheme = "com.hina.upworkmonitor.macos"
    static let redirectURI = "http://localhost:49153/oauth/callback"
    private static let registrationStorageKey = "upwork-mcp-registration-loopback-v3"
#else
    static let callbackScheme = "com.hina.upworkmonitor.ios"
    static let redirectURI = "com.hina.upworkmonitor.ios:/oauth/callback"
    private static let registrationStorageKey = "upwork-mcp-registration-v2"
#endif

    private let keychain: KeychainStore
    private let session: URLSession
    private var authenticationSession: ASWebAuthenticationSession?
    private var registration: MCPAuthRegistration?
    private var credentials: MCPAuthCredentials?
#if os(macOS)
    private var loopbackCallbackServer: LoopbackOAuthCallbackServer?
#endif

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func restoreFromKeychain() async {
        if registration == nil {
            registration = try? await keychain.load(MCPAuthRegistration.self, for: Self.registrationStorageKey)
        }
        if credentials == nil {
            credentials = try? await keychain.load(MCPAuthCredentials.self, for: "upwork-mcp-credentials")
        }
    }

    var hasCredentials: Bool { credentials != nil }

    func connect() async throws -> MCPAuthCredentials {
#if os(macOS)
        let callbackServer = LoopbackOAuthCallbackServer()
        try callbackServer.start()
        loopbackCallbackServer = callbackServer
        defer {
            loopbackCallbackServer = nil
            callbackServer.stop()
        }
#endif
        let client = try await registeredClient()
        let tokens = try await authorize(clientID: client.clientID)
        let saved = MCPAuthCredentials(
            clientID: client.clientID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        try await keychain.save(saved, for: "upwork-mcp-credentials")
        try? await keychain.delete(key: "credentials")
        credentials = saved
        return saved
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credentials else { throw MCPAuthError.missingRefreshToken }
        guard forceRefresh || credentials.isExpired else { return credentials.accessToken }
        guard let refreshToken = credentials.refreshToken else {
            throw MCPAuthError.missingRefreshToken
        }

        let refreshed = try await requestToken([
            "grant_type": "refresh_token",
            "client_id": credentials.clientID,
            "refresh_token": refreshToken,
            "resource": Self.resource
        ])
        let updated = MCPAuthCredentials(
            clientID: credentials.clientID,
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            expiresAt: refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        try await keychain.save(updated, for: "upwork-mcp-credentials")
        self.credentials = updated
        return updated.accessToken
    }

    func disconnect() async {
        if let credentials {
            await revoke(credentials)
        }
        try? await keychain.delete(key: "upwork-mcp-credentials")
        try? await keychain.delete(key: "credentials")
        credentials = nil
    }

    private func registeredClient() async throws -> MCPAuthRegistration {
        if let registration { return registration }

        let resourceMetadata = try await fetchJSON(
            URL(string: "https://mcp.upwork.com/.well-known/oauth-protected-resource/mcp")!
        )
        guard let issuers = resourceMetadata["authorization_servers"] as? [String],
              let issuer = issuers.first,
              let metadataURL = URL(string: "\(issuer)/.well-known/oauth-authorization-server") else {
            throw MCPAuthError.discoveryFailed
        }

        let metadata = try await fetchJSON(metadataURL)
        guard let registrationEndpoint = string(metadata["registration_endpoint"]),
              let endpoint = URL(string: registrationEndpoint) else {
            throw MCPAuthError.invalidConfiguration
        }

        let payload: [String: Any] = [
            "application_type": "native",
            "client_name": "Upwork Monitor",
            "grant_types": ["authorization_code", "refresh_token"],
            "redirect_uris": [Self.redirectURI],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let response: [String: Any]
        do {
            response = try await perform(request)
        } catch MCPAuthError.httpError(let status, let message) {
            throw MCPAuthError.registrationFailed("HTTP \(status): \(message)")
        }
        guard let clientID = string(response["client_id"]), !clientID.isEmpty else {
            throw MCPAuthError.registrationFailed(errorMessage(in: response) ?? "Missing client_id")
        }
        let saved = MCPAuthRegistration(clientID: clientID, createdAt: Date())
        try await keychain.save(saved, for: Self.registrationStorageKey)
        registration = saved
        return saved
    }

    private func authorize(clientID: String) async throws -> TokenResponse {
        let resourceMetadata = try await fetchJSON(
            URL(string: "https://mcp.upwork.com/.well-known/oauth-protected-resource/mcp")!
        )
        guard let issuers = resourceMetadata["authorization_servers"] as? [String],
              let issuer = issuers.first,
              let metadataURL = URL(string: "\(issuer)/.well-known/oauth-authorization-server") else {
            throw MCPAuthError.discoveryFailed
        }
        let metadata = try await fetchJSON(metadataURL)
        guard let authorizationEndpoint = string(metadata["authorization_endpoint"]),
              let tokenEndpoint = string(metadata["token_endpoint"]),
              URL(string: authorizationEndpoint) != nil,
              URL(string: tokenEndpoint) != nil else {
            throw MCPAuthError.invalidConfiguration
        }

        let state = Self.randomString(length: 36)
        let verifier = Self.randomString(length: 64)
        var components = URLComponents(string: authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: Self.resource)
        ]
        guard let authorizationURL = components.url else {
            throw MCPAuthError.invalidConfiguration
        }

#if os(macOS)
        guard let loopbackCallbackServer else { throw MCPAuthError.invalidConfiguration }
        let callbackURL = try await loopbackCallbackServer.openAuthorizationURL(
            authorizationURL,
            expectedState: state
        )
#else
        let callbackURL = try await startWebAuthentication(url: authorizationURL, callbackScheme: Self.callbackScheme)
#endif
        let callbackItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let providerError = callbackItems.first(where: { $0.name == "error_description" })?.value
            ?? callbackItems.first(where: { $0.name == "error" })?.value {
            throw MCPAuthError.tokenRequest(providerError)
        }
        guard callbackItems.first(where: { $0.name == "state" })?.value == state else {
            throw MCPAuthError.invalidState
        }
        guard let code = callbackItems.first(where: { $0.name == "code" })?.value else {
            throw MCPAuthError.missingAuthorizationCode
        }

        return try await requestToken([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
            "resource": Self.resource
        ])
    }

    private func requestToken(_ parameters: [String: String]) async throws -> TokenResponse {
        let metadata = try await fetchJSON(
            URL(string: "https://mcp.upwork.com/.well-known/oauth-authorization-server")!
        )
        guard let tokenURL = string(metadata["token_endpoint"]).flatMap({ URL(string: $0) }) else {
            throw MCPAuthError.invalidConfiguration
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded(parameters).data(using: .utf8)

        let response: [String: Any]
        do {
            response = try await perform(request)
        } catch MCPAuthError.httpError(let status, let message) {
            throw MCPAuthError.tokenRequest("HTTP \(status): \(message)")
        }
        guard let accessToken = string(response["access_token"]), !accessToken.isEmpty else {
            throw MCPAuthError.tokenRequest(errorMessage(in: response) ?? "Missing access_token")
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: string(response["refresh_token"]),
            expiresIn: integer(response["expires_in"])
        )
    }

    private func revoke(_ credentials: MCPAuthCredentials) async {
        guard let metadata = try? await fetchJSON(
            URL(string: "https://mcp.upwork.com/.well-known/oauth-authorization-server")!
        ), let endpoint = string(metadata["revocation_endpoint"]).flatMap({ URL(string: $0) }) else {
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            "token": credentials.refreshToken ?? credentials.accessToken,
            "token_type_hint": credentials.refreshToken == nil ? "access_token" : "refresh_token",
            "client_id": credentials.clientID
        ]).data(using: .utf8)
        _ = try? await session.data(for: request)
    }

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPAuthError.discoveryFailed
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = errorMessage(in: object)
                ?? String(data: data.prefix(500), encoding: .utf8)
                ?? "HTTP \(httpResponse.statusCode)"
            throw MCPAuthError.httpError(httpResponse.statusCode, message)
        }
        return object
    }

    private func startWebAuthentication(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                self?.authenticationSession = nil
                if let url {
                    continuation.resume(returning: url)
                } else if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: MCPAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: MCPAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            if !session.start() {
                authenticationSession = nil
                continuation.resume(throwing: MCPAuthError.cancelled)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
        return UIWindow()
        #endif
    }

    private static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            let fallback = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
            return String(fallback.prefix(length))
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ values: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery ?? ""
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func errorMessage(in object: [String: Any]) -> String? {
        string(object["error_description"])
            ?? string(object["error"])
            ?? string(object["message"])
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
    }
}

#if os(macOS)
private enum LoopbackOAuthCallbackError: LocalizedError {
    case listenerUnavailable
    case browserUnavailable
    case timedOut
    case stopped

    var errorDescription: String? {
        switch self {
        case .listenerUnavailable:
            "Could not open the local OAuth callback port 49153. Close another app using that port and try again."
        case .browserUnavailable:
            "Could not open the system browser for Upwork sign-in."
        case .timedOut:
            "Upwork sign-in timed out. Try connecting again."
        case .stopped:
            "The local OAuth callback listener was stopped."
        }
    }
}

private final class LoopbackOAuthCallbackServer: @unchecked Sendable {
    private static let portNumber: UInt16 = 49153
    private static let callbackPath = "/oauth/callback"
    private static let maximumRequestSize = 16_384
    private static let timeoutNanoseconds: UInt64 = 300_000_000_000

    private let lock = NSLock()
    private var listenerSockets: [Int32] = []
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var expectedState: String?
    private var timeoutTask: Task<Void, Never>?
    private var stopped = false

    var redirectURI: String {
        "http://localhost:\(Self.portNumber)\(Self.callbackPath)"
    }

    func start() throws {
        let ipv4Socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard ipv4Socket >= 0 else { throw LoopbackOAuthCallbackError.listenerUnavailable }

        var ipv4Address = sockaddr_in()
        ipv4Address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4Address.sin_family = sa_family_t(AF_INET)
        ipv4Address.sin_port = in_port_t(Self.portNumber).bigEndian
        ipv4Address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let ipv4BindResult = withUnsafePointer(to: &ipv4Address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(ipv4Socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ipv4BindResult == 0, Darwin.listen(ipv4Socket, 4) == 0 else {
            Darwin.close(ipv4Socket)
            throw LoopbackOAuthCallbackError.listenerUnavailable
        }

        let ipv6Socket = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard ipv6Socket >= 0 else {
            Darwin.close(ipv4Socket)
            throw LoopbackOAuthCallbackError.listenerUnavailable
        }

        var ipv6Address = sockaddr_in6()
        ipv6Address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        ipv6Address.sin6_family = sa_family_t(AF_INET6)
        ipv6Address.sin6_port = in_port_t(Self.portNumber).bigEndian
        let ipv6AddressResult = "::1".withCString { inet_pton(AF_INET6, $0, &ipv6Address.sin6_addr) }
        let ipv6BindResult = withUnsafePointer(to: &ipv6Address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(ipv6Socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard ipv6AddressResult == 1,
              ipv6BindResult == 0,
              Darwin.listen(ipv6Socket, 4) == 0 else {
            Darwin.close(ipv4Socket)
            Darwin.close(ipv6Socket)
            throw LoopbackOAuthCallbackError.listenerUnavailable
        }

        let sockets = [ipv4Socket, ipv6Socket]
        lock.lock()
        listenerSockets = sockets
        lock.unlock()

        for socketFD in sockets {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.acceptLoop(socketFD)
            }
        }
    }

    @MainActor
    func openAuthorizationURL(_ url: URL, expectedState: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            lock.lock()
            self.expectedState = expectedState
            callbackContinuation = continuation
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                } catch {
                    return
                }
                self?.finishCallback(.failure(LoopbackOAuthCallbackError.timedOut))
            }
            lock.unlock()

            guard NSWorkspace.shared.open(url) else {
                finishCallback(.failure(LoopbackOAuthCallbackError.browserUnavailable))
                return
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let sockets = listenerSockets
        listenerSockets.removeAll()
        let continuation = callbackContinuation
        callbackContinuation = nil
        expectedState = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        for socketFD in sockets {
            Darwin.shutdown(socketFD, SHUT_RDWR)
            Darwin.close(socketFD)
        }
        continuation?.resume(throwing: LoopbackOAuthCallbackError.stopped)
    }

    private func acceptLoop(_ socketFD: Int32) {
        while true {
            lock.lock()
            let shouldStop = stopped || !listenerSockets.contains(socketFD)
            lock.unlock()
            if shouldStop { return }

            let clientFD = Darwin.accept(socketFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        var noSignal: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var requestData = Data()
        let headerTerminator = Data([13, 10, 13, 10])
        while requestData.count <= Self.maximumRequestSize,
              requestData.range(of: headerTerminator) == nil {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.recv(clientFD, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            requestData.append(contentsOf: buffer.prefix(count))
        }

        guard requestData.count <= Self.maximumRequestSize,
              let terminatorRange = requestData.range(of: headerTerminator),
              let header = String(data: requestData[..<terminatorRange.lowerBound], encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first else {
            sendResponse(status: 431, on: clientFD)
            return
        }

        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else {
            sendResponse(status: 400, on: clientFD)
            return
        }

        let requestTarget = String(fields[1])
        guard requestTarget.hasPrefix("/"),
              let callbackURL = URL(string: "http://localhost:\(Self.portNumber)\(requestTarget)"),
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.path == Self.callbackPath else {
            sendResponse(status: 404, on: clientFD)
            return
        }

        let queryItems = components.queryItems ?? []
        let receivedState = queryItems.first(where: { $0.name == "state" })?.value
        lock.lock()
        let stateMatches = expectedState != nil && receivedState == expectedState
        lock.unlock()
        guard stateMatches else {
            sendResponse(status: 400, on: clientFD)
            return
        }
        let hasCode = queryItems.contains(where: { $0.name == "code" })
        let hasProviderError = queryItems.contains(where: { $0.name == "error" || $0.name == "error_description" })
        guard hasCode || hasProviderError else {
            sendResponse(status: 400, on: clientFD)
            return
        }

        sendResponse(status: 200, on: clientFD)
        finishCallback(.success(callbackURL))
    }

    private func sendResponse(status: Int, on socketFD: Int32) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Bad Request"
        }
        let body = Data("<!doctype html><html><body>Authorization response received. You may return to Upwork Monitor.</body></html>".utf8)
        let response = Data(
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        ) + body
        response.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = Darwin.send(socketFD, baseAddress, bytes.count, 0)
        }
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = callbackContinuation
        callbackContinuation = nil
        expectedState = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
#endif
