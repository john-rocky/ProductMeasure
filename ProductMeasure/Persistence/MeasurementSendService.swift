//
//  MeasurementSendService.swift
//  SnapMeasure
//

import Foundation

class MeasurementSendService {
    enum SendError: LocalizedError {
        case noURL
        case invalidURL
        case httpError(Int)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noURL:
                return "No endpoint URL configured. Set it in Settings."
            case .invalidURL:
                return "Invalid endpoint URL."
            case .httpError(let code):
                return "Server returned HTTP \(code)."
            case .networkError(let error):
                return error.localizedDescription
            }
        }
    }

    var isConfigured: Bool {
        guard let urlString = UserDefaults.standard.string(forKey: "sendEndpointURL"),
              !urlString.isEmpty else {
            return false
        }
        return URL(string: urlString) != nil
    }

    func send(measurements: [ProductMeasurement]) async throws -> Int {
        let jsonData = ExportService().exportToJSON(measurements: measurements)
        return try await sendRawJSON(jsonData)
    }

    func send(measurement: ProductMeasurement) async throws -> Int {
        try await send(measurements: [measurement])
    }

    func sendRawJSON(_ data: Data) async throws -> Int {
        guard let urlString = UserDefaults.standard.string(forKey: "sendEndpointURL"),
              !urlString.isEmpty else {
            throw SendError.noURL
        }

        guard let url = URL(string: urlString) else {
            throw SendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.upload(for: request, from: data)
        } catch {
            throw SendError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SendError.httpError(0)
        }

        let statusCode = httpResponse.statusCode
        guard (200...299).contains(statusCode) else {
            throw SendError.httpError(statusCode)
        }

        return statusCode
    }
}
