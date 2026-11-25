// EcoFlow cloud authentication — resolves the account userId from the
// user's own EcoFlow credentials, so BLE auth works without reverse
// engineering anything by hand.
//
// Endpoint (community-verified, used by the official app):
//   POST https://<region-host>/auth/login
//   { "scene": "IOT_APP", "appVersion": "1.0.0",
//     "password": <base64>, "oauth": {"bundleId": "com.ef.EcoFlow"},
//     "email" | "phone": <identifier>, "userType": "ECOFLOW" }
//   → { "code": "0", "data": { "token": ..., "user": { "userId": ... } } }
//
// Privacy: the password is used in memory for this one request and never
// stored. Only the derived BLE secret (MD5hex(userId + SN)) is persisted,
// and it lives in the Keychain.

import Foundation

public enum EcoFlowRegion: CaseIterable, Sendable {
    case global, europe, us, asia, japan, russia, china   // china = phone accounts only

    public var host: String {
        switch self {
        case .global: return "api.ecoflow.com"
        case .europe: return "api-e.ecoflow.com"
        case .us: return "api-a.ecoflow.com"
        case .asia: return "api-a.ecoflow.com"
        case .japan: return "api-j.ecoflow.com"
        case .russia: return "api-r.ecoflow.com"
        case .china: return "api-cn.ecoflow.com"
        }
    }

    public var title: String {
        switch self {
        case .global: return "Global"
        case .europe: return "Europe"
        case .us: return "US"
        case .asia: return "Asia / MEA"
        case .japan: return "Japan"
        case .russia: return "Russia"
        case .china: return "China (phone)"
        }
    }
}

public enum EcoFlowCloudError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case apiError(code: String, message: String)
    case missingUserId
    case badIdentifier
}

public struct EcoFlowCloudAuth: Sendable {
    public var region: EcoFlowRegion

    public init(region: EcoFlowRegion = .global) {
        self.region = region
    }

    /// A phone-number account routes to the CN host; email to the chosen host.
    static func isPhoneNumber(_ identifier: String) -> Bool {
        let digits = identifier.dropFirst(identifier.hasPrefix("+") ? 1 : 0)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) && digits.count >= 6
    }

    /// Build the login request (pure — unit-testable without network).
    public func loginRequest(identifier: String, password: String) throws -> URLRequest {
        let identifier = identifier.trimmingCharacters(in: .whitespaces)
        let password = password
        guard !identifier.isEmpty, !password.isEmpty else {
            throw EcoFlowCloudError.badIdentifier
        }
        var host = region.host
        var body: [String: Any] = [
            "scene": "IOT_APP",
            "appVersion": "1.0.0",
            "password": Data(password.utf8).base64EncodedString(),
            "oauth": ["bundleId": "com.ef.EcoFlow"],
            "userType": "ECOFLOW",
        ]
        if Self.isPhoneNumber(identifier) {
            if host != EcoFlowRegion.china.host {
                // phone accounts live on the CN host in upstream tooling
                host = EcoFlowRegion.china.host
            }
            body["phone"] = identifier.hasPrefix("+86")
                ? String(identifier.dropFirst(3))
                : identifier
        } else {
            if host == EcoFlowRegion.china.host {
                body["email"] = identifier   // user chose CN explicitly; send as-is
            } else {
                body["email"] = identifier
            }
        }
        var request = URLRequest(url: URL(string: "https://\(host)/auth/login")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20   // never hang the sign-in UI
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parse the login response body → userId (pure — unit-testable).
    public static func userId(fromResponse data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EcoFlowCloudError.invalidResponse
        }
        let code = json["code"] as? String ?? ""
        guard code == "0" else {
            throw EcoFlowCloudError.apiError(code: code,
                                             message: json["message"] as? String ?? "")
        }
        guard
            let user = (json["data"] as? [String: Any])?["user"] as? [String: Any],
            let userId = user["userId"] as? String, !userId.isEmpty
        else {
            throw EcoFlowCloudError.missingUserId
        }
        return userId
    }

    /// Full flow: login and return the userId.
    public func fetchUserId(identifier: String, password: String,
                            session: URLSession = .shared) async throws -> String {
        let request = try loginRequest(identifier: identifier, password: password)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EcoFlowCloudError.httpStatus(http.statusCode)
        }
        return try Self.userId(fromResponse: data)
    }

    /// Derive the BLE auth secret from the account identity.
    /// secretKey = MD5hex(userId + SN), uppercase hex — same bytes the
    /// official app sends in the auth packet.
    public static func bleSecret(userId: String, deviceSN: String) -> String {
        md5(Data((userId + deviceSN).utf8)).map { String(format: "%02X", $0) }.joined()
    }
}
