import Foundation

@MainActor
protocol CCRGatewayConfigurationManaging: AnyObject {
    func currentGatewayHost() async throws -> String
    func updateGatewayHost(_ host: String) async throws
}

enum CCRGatewayConfigurationError: LocalizedError {
    case serviceDescriptorUnavailable
    case invalidServiceURL
    case missingAuthenticationToken
    case invalidResponse
    case transport
    case rpcFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceDescriptorUnavailable:
            return String(localized: "CCR service descriptor is unavailable.")
        case .invalidServiceURL:
            return String(localized: "CCR service URL is invalid.")
        case .missingAuthenticationToken:
            return String(localized: "CCR service authentication token is unavailable.")
        case .invalidResponse:
            return String(localized: "CCR returned an invalid configuration response.")
        case .transport:
            return String(localized: "Unable to reach the CCR management service.")
        case .rpcFailed(let message):
            return message
        }
    }
}

@MainActor
final class CCRWebConfigurationClient: CCRGatewayConfigurationManaging {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let homeDirectory: String
    private let dataLoader: DataLoader

    init(
        homeDirectory: String = NSHomeDirectory(),
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.dataLoader = dataLoader
    }

    func currentGatewayHost() async throws -> String {
        let value = try await performRPC(method: "getConfig", arguments: [])
        guard let configuration = value as? [String: Any] else {
            throw CCRGatewayConfigurationError.invalidResponse
        }

        if let gateway = configuration["gateway"] as? [String: Any],
           let host = gateway["host"] as? String {
            return AppSettings.validatedGatewayHost(host)
        }
        if let host = configuration["HOST"] as? String {
            return AppSettings.validatedGatewayHost(host)
        }
        return AppSettings.defaultGatewayHost
    }

    func updateGatewayHost(_ host: String) async throws {
        let normalizedHost = AppSettings.validatedGatewayHost(host)
        let value = try await performRPC(method: "getConfig", arguments: [])
        guard var configuration = value as? [String: Any] else {
            throw CCRGatewayConfigurationError.invalidResponse
        }

        configuration["HOST"] = normalizedHost
        var gateway = configuration["gateway"] as? [String: Any] ?? [:]
        gateway["host"] = normalizedHost
        configuration["gateway"] = gateway

        _ = try await performRPC(
            method: "saveConfig",
            arguments: [configuration, ["applyProfile": false]]
        )
    }

    private func performRPC(method: String, arguments: [Any]) async throws -> Any {
        let descriptor = try serviceDescriptor()
        var request = URLRequest(url: descriptor.rpcURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(descriptor.authenticationToken, forHTTPHeaderField: "x-ccr-web-auth")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "method": method,
            "args": arguments
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(request)
        } catch {
            throw CCRGatewayConfigurationError.transport
        }

        guard let httpResponse = response as? HTTPURLResponse,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CCRGatewayConfigurationError.invalidResponse
        }

        guard httpResponse.statusCode == 200,
              object["ok"] as? Bool == true else {
            let message = ((object["error"] as? [String: Any])?["message"] as? String)
                ?? String(localized: "CCR configuration request failed.")
            throw CCRGatewayConfigurationError.rpcFailed(message)
        }

        return object["value"] ?? NSNull()
    }

    private func serviceDescriptor() throws -> ServiceDescriptor {
        let serviceURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".claude-code-router", isDirectory: true)
            .appendingPathComponent("service.json")

        guard let data = try? Data(contentsOf: serviceURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = object["url"] as? String,
              let url = URL(string: urlString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CCRGatewayConfigurationError.serviceDescriptorUnavailable
        }

        guard let authenticationToken = components.queryItems?
            .first(where: { $0.name == "ccr_web_token" })?.value,
              !authenticationToken.isEmpty else {
            throw CCRGatewayConfigurationError.missingAuthenticationToken
        }

        components.path = "/api/ccr/rpc"
        components.query = nil
        components.fragment = nil
        guard let rpcURL = components.url else {
            throw CCRGatewayConfigurationError.invalidServiceURL
        }

        return ServiceDescriptor(
            rpcURL: rpcURL,
            authenticationToken: authenticationToken
        )
    }
}

private struct ServiceDescriptor {
    let rpcURL: URL
    let authenticationToken: String
}
