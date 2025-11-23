//
//  GrowGuardAPIClient.swift
//  GrowGuard
//
//  API client for communicating with the GrowGuard server
//

import Foundation

/// API client for communicating with the GrowGuard server
actor GrowGuardAPIClient {

    // MARK: - Singleton

    static let shared = GrowGuardAPIClient()

    // MARK: - Types

    enum APIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case serverError(statusCode: Int, message: String?)
        case encodingError
        case decodingError
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL"
            case .invalidResponse:
                return "Invalid response from server"
            case .serverError(let statusCode, let message):
                return "Server error (\(statusCode)): \(message ?? "Unknown error")"
            case .encodingError:
                return "Failed to encode request"
            case .decodingError:
                return "Failed to decode response"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Request/Response Models

    struct DeviceRegistrationRequest: Encodable {
        let deviceToken: String
    }

    struct DeviceRegistrationResponse: Decodable {
        let success: Bool
        let message: String?
    }

    struct DeviceUnregistrationRequest: Encodable {
        let deviceToken: String
    }

    struct DeviceUnregistrationResponse: Decodable {
        let success: Bool
        let message: String?
    }

    struct DeviceCountResponse: Decodable {
        let count: Int
    }

    // MARK: - Properties

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        AppLogger.network.info("GrowGuardAPIClient initialized")
    }

    // MARK: - Public API

    /// Registers a device token with the server for push notifications
    /// - Parameter deviceToken: The APNs device token in hex format
    /// - Returns: The registration response from the server
    func registerDevice(token deviceToken: String) async throws -> DeviceRegistrationResponse {
        let url = try buildURL(path: "/devices/register")
        let body = DeviceRegistrationRequest(deviceToken: deviceToken)

        AppLogger.network.info("Registering device token with server")

        let response: DeviceRegistrationResponse = try await post(url: url, body: body)

        if response.success {
            AppLogger.network.info("Device registered successfully: \(response.message ?? "")")
        } else {
            AppLogger.network.warning("Device registration failed: \(response.message ?? "Unknown error")")
        }

        return response
    }

    /// Unregisters a device token from the server
    /// - Parameter deviceToken: The APNs device token in hex format
    /// - Returns: The unregistration response from the server
    func unregisterDevice(token deviceToken: String) async throws -> DeviceUnregistrationResponse {
        let url = try buildURL(path: "/devices/unregister")
        let body = DeviceUnregistrationRequest(deviceToken: deviceToken)

        AppLogger.network.info("Unregistering device token from server")

        let response: DeviceUnregistrationResponse = try await post(url: url, body: body)

        if response.success {
            AppLogger.network.info("Device unregistered successfully: \(response.message ?? "")")
        } else {
            AppLogger.network.warning("Device unregistration failed: \(response.message ?? "Unknown error")")
        }

        return response
    }

    /// Gets the count of registered devices from the server
    /// - Returns: The device count response
    func getDeviceCount() async throws -> DeviceCountResponse {
        let url = try buildURL(path: "/devices/count")

        AppLogger.network.info("Fetching device count from server")

        let response: DeviceCountResponse = try await get(url: url)

        AppLogger.network.info("Server has \(response.count) registered device(s)")

        return response
    }

    /// Performs a health check on the server
    /// - Returns: True if the server is reachable
    func healthCheck() async throws -> Bool {
        let url = try buildURL(path: "/")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            return httpResponse.statusCode == 200
        } catch {
            AppLogger.network.warning("Server health check failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Methods

    private func buildURL(path: String) throws -> URL {
        let baseURL = SettingsStore.shared.serverURL

        guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        return url
    }

    private func get<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await performRequest(request)
    }

    private func post<T: Decodable, B: Encodable>(url: URL, body: B) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw APIError.encodingError
        }

        return try await performRequest(request)
    }

    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.network.error("Failed to decode response: \(error.localizedDescription)")
            throw APIError.decodingError
        }
    }
}
