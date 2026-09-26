import CoreLocation
import Foundation
import MapKit
import Security

struct AppConfiguration: Equatable, Sendable {
    let supabaseURL: URL?
    let supabaseAnonKey: String

    var isConfigured: Bool {
        supabaseURL != nil && !supabaseAnonKey.isEmpty && !supabaseAnonKey.contains("$(")
    }

    static var current: AppConfiguration {
        let rawURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let rawKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let url = URL(string: rawURL).flatMap { $0.scheme == "https" ? $0 : nil }
        return AppConfiguration(supabaseURL: url, supabaseAnonKey: rawKey)
    }
}

enum BackendError: LocalizedError, Equatable {
    case notConfigured
    case invalidResponse
    case server(status: Int, message: String)
    case missingSession

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Supabase URL and anonymous key in VoltWay’s build settings."
        case .invalidResponse: "VoltWay received an invalid server response."
        case let .server(_, message): message
        case .missingSession: "Please sign in again."
        }
    }
}

struct StationFetchResult: Decodable, Sendable {
    let stations: [ChargingStation]
    let warnings: [String]?
    let catalogSyncedAt: Date?
}

actor BackendClient {
    private let configuration: AppConfiguration
    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let credentialAccount: String
    private var currentSession: UserSession?
    private var refreshTask: Task<UserSession, any Error>?

    init(configuration: AppConfiguration = .current, urlSession: URLSession = .shared, credentialAccount: String = "supabase-session") {
        self.configuration = configuration
        self.urlSession = urlSession
        self.credentialAccount = credentialAccount

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                ?? (try? Date.ISO8601FormatStyle().parse(value)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
            }
            return date
        }
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    var isConfigured: Bool { configuration.isConfigured }

    func restoreSession() throws -> UserSession? {
        guard let data = try KeychainStore.read(account: credentialAccount) else {
            currentSession = nil
            return nil
        }
        let session = try decoder.decode(UserSession.self, from: data)
        currentSession = session
        return session
    }

    func signUp(email: String, password: String) async throws -> UserSession? {
        let response: AuthResponse = try await request(
            path: "auth/v1/signup",
            method: "POST",
            body: AuthRequest(email: email, password: password)
        )
        guard let session = response.session(fallbackEmail: email) else { return nil }
        try save(session)
        return session
    }

    func signIn(email: String, password: String) async throws -> UserSession {
        let response: AuthResponse = try await request(
            path: "auth/v1/token",
            method: "POST",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            body: AuthRequest(email: email, password: password)
        )
        guard let session = response.session(fallbackEmail: email) else { throw BackendError.invalidResponse }
        try save(session)
        return session
    }

    func requestPasswordReset(email: String) async throws {
        let _: EmptyResponse = try await request(
            path: "auth/v1/recover",
            method: "POST",
            body: RecoveryRequest(email: email)
        )
    }

    func signOut() throws {
        try KeychainStore.delete(account: credentialAccount)
        currentSession = nil
        refreshTask = nil
    }

    func stations(profile: VehicleProfile, session: UserSession?) async throws -> StationFetchResult {
        guard configuration.isConfigured else { return StationFetchResult(stations: DemoData.stations, warnings: nil, catalogSyncedAt: nil) }
        guard let session else { throw BackendError.missingSession }

        var queryItems = [URLQueryItem(name: "connectors", value: profile.connectors.map(\.rawValue).joined(separator: ","))]
        if let minimumPowerKW = profile.minimumPowerKW {
            queryItems.append(URLQueryItem(name: "minimumPowerKW", value: String(minimumPowerKW)))
        }
        let response: StationFetchResult = try await request(
            path: "functions/v1/stations",
            method: "GET",
            queryItems: queryItems,
            session: session
        )
        return response
    }

    func loadProfile(session: UserSession) async throws -> VehicleProfile? {
        let profiles: [VehicleProfile] = try await request(
            path: "rest/v1/vehicle_profiles",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(session.userID)"),
                URLQueryItem(name: "select", value: "*")
            ],
            session: session
        )
        return profiles.first
    }

    func saveProfile(_ profile: VehicleProfile, session: UserSession) async throws {
        var payload = profile
        payload.userID = session.userID
        payload.updatedAt = .now
        let _: EmptyResponse = try await request(
            path: "rest/v1/vehicle_profiles",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id")],
            body: payload,
            session: session,
            additionalHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
    }

    func loadFavorites(session: UserSession) async throws -> [FavoriteStation] {
        try await request(
            path: "rest/v1/favorite_stations",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(session.userID)"),
                URLQueryItem(name: "select", value: "*")
            ],
            session: session
        )
    }

    func saveFavorite(_ station: ChargingStation, session: UserSession) async throws {
        let favorite = FavoriteStation(userID: session.userID, stationID: station.id, stationSnapshot: station, createdAt: .now)
        let _: EmptyResponse = try await request(
            path: "rest/v1/favorite_stations",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id,station_id")],
            body: favorite,
            session: session,
            additionalHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
    }

    func deleteFavorite(stationID: String, session: UserSession) async throws {
        let _: EmptyResponse = try await request(
            path: "rest/v1/favorite_stations",
            method: "DELETE",
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(session.userID)"),
                URLQueryItem(name: "station_id", value: "eq.\(stationID)")
            ],
            session: session
        )
    }

    private func save(_ session: UserSession) throws {
        try KeychainStore.save(encoder.encode(session), account: credentialAccount)
        currentSession = session
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        session: UserSession? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        try await performRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            bodyData: nil,
            session: session,
            additionalHeaders: additionalHeaders
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        session: UserSession? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        try await performRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            bodyData: try encoder.encode(body),
            session: session,
            additionalHeaders: additionalHeaders
        )
    }

    private func performRequest<Response: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        bodyData: Data?,
        session: UserSession?,
        additionalHeaders: [String: String],
        allowsRefresh: Bool = true
    ) async throws -> Response {
        guard configuration.isConfigured, let baseURL = configuration.supabaseURL else { throw BackendError.notConfigured }

        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw BackendError.invalidResponse }

        let authorizedSession: UserSession?
        if let session {
            guard let currentSession, currentSession.userID == session.userID else { throw BackendError.missingSession }
            authorizedSession = currentSession
        } else {
            authorizedSession = nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue(configuration.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizedSession.map { "Bearer \($0.accessToken)" } ?? "Bearer \(configuration.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        for (field, value) in additionalHeaders { request.setValue(value, forHTTPHeaderField: field) }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        if http.statusCode == 401, let authorizedSession, allowsRefresh {
            let refreshed = try await refreshSession(afterRejecting: authorizedSession.accessToken)
            return try await performRequest(
                path: path,
                method: method,
                queryItems: queryItems,
                bodyData: bodyData,
                session: refreshed,
                additionalHeaders: additionalHeaders,
                allowsRefresh: false
            )
        }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data).displayMessage)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw BackendError.server(status: http.statusCode, message: message)
        }

        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func refreshSession(afterRejecting accessToken: String) async throws -> UserSession {
        guard let currentSession else { throw BackendError.missingSession }
        if currentSession.accessToken != accessToken { return currentSession }

        if let refreshTask { return try await refreshTask.value }
        let original = currentSession
        let task = Task {
            let refreshed = try await self.performRefresh(using: original)
            guard self.currentSession == original else { throw BackendError.missingSession }
            try self.save(refreshed)
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch {
            if case let BackendError.server(status, _) = error,
               status == 400 || status == 401,
               self.currentSession == original {
                try? KeychainStore.delete(account: credentialAccount)
                self.currentSession = nil
                throw BackendError.missingSession
            }
            throw error
        }
    }

    private func performRefresh(using original: UserSession) async throws -> UserSession {
        let response: AuthResponse = try await request(
            path: "auth/v1/token",
            method: "POST",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: RefreshRequest(refreshToken: original.refreshToken)
        )
        guard let refreshed = response.refreshedSession(from: original) else { throw BackendError.invalidResponse }
        return refreshed
    }
}

private struct AuthRequest: Encodable { let email: String; let password: String }
private struct RefreshRequest: Encodable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}
private struct RecoveryRequest: Encodable { let email: String }
private struct EmptyResponse: Codable {}

private struct AuthResponse: Decodable {
    struct User: Decodable { let id: String; let email: String? }
    let accessToken: String?
    let refreshToken: String?
    let user: User?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }

    func session(fallbackEmail: String) -> UserSession? {
        guard let accessToken, let refreshToken, let user else { return nil }
        return UserSession(userID: user.id, email: user.email ?? fallbackEmail, accessToken: accessToken, refreshToken: refreshToken)
    }

    func refreshedSession(from original: UserSession) -> UserSession? {
        guard let accessToken, let refreshToken else { return nil }
        guard user == nil || user?.id == original.userID else { return nil }
        return UserSession(
            userID: original.userID,
            email: user?.email ?? original.email,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }
}

private struct ErrorEnvelope: Decodable {
    let message: String?
    let errorDescription: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case message
        case errorDescription = "error_description"
        case error
    }

    var displayMessage: String { message ?? errorDescription ?? error ?? "The request failed." }
}

private enum KeychainStore {
    private static let service = "com.jelwingeuan.VoltWay"

    static func save(_ data: Data, account: String) throws {
        try delete(account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BackendError.server(status: Int(status), message: "Could not securely save your session.")
        }
    }

    static func read(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BackendError.server(status: Int(status), message: "Could not read your saved session.")
        }
        return data
    }

    static func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackendError.server(status: Int(status), message: "Could not clear your saved session.")
        }
    }
}

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Coordinate, any Error>?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse
    }

    func requestLocation() async throws -> Coordinate {
        if let continuation {
            continuation.resume(throwing: CancellationError())
            self.continuation = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
            case .denied, .restricted: finish(throwing: LocationError.permissionDenied)
            @unknown default: finish(throwing: LocationError.unavailable)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(throwing: LocationError.permissionDenied)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(returning: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        finish(throwing: error)
    }

    private func finish(returning coordinate: Coordinate) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    private func finish(throwing error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

enum LocationError: LocalizedError {
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Location access is off. Enable it in Settings to use location-dependent features."
        case .unavailable: "Your current location is unavailable."
        }
    }
}

@MainActor
enum MapsHandoff {
    static func open(_ station: ChargingStation) {
        let coordinate = CLLocationCoordinate2D(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = station.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

@MainActor
enum CarPlaySnapshotStore {
    private static let key = "carplay-snapshot"

    static func save(stations: [ChargingStation], favoriteStationIDs: Set<String>, isDemo: Bool = false, defaults: UserDefaults = .standard) {
        let snapshot = CarPlaySnapshot(stations: stations, favoriteStationIDs: favoriteStationIDs, savedAt: .now, isDemo: isDemo)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try? encoder.encode(snapshot), forKey: key)
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: .voltWayCarPlaySnapshotDidChange, object: nil)
        }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: .voltWayCarPlaySnapshotDidChange, object: nil)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> CarPlaySnapshot {
        let empty = CarPlaySnapshot(stations: [], favoriteStationIDs: [], savedAt: .distantPast)
        guard let data = defaults.data(forKey: key) else {
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CarPlaySnapshot.self, from: data)) ?? empty
    }
}

extension Notification.Name {
    static let voltWayCarPlaySnapshotDidChange = Notification.Name("VoltWayCarPlaySnapshotDidChange")
}
