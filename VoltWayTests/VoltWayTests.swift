import Foundation
import Testing
@testable import VoltWay

struct VoltWayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Vehicle profile filters connector and charging power")
    func vehicleCompatibility() {
        let profile = VehicleProfile(connectors: [.ccs2], minimumPowerKW: 100)
        let fastCCS = station(id: "fast", connector: .ccs2, power: 180, state: .available)
        let slowCCS = station(id: "slow", connector: .ccs2, power: 50, state: .available)
        let fastType2 = station(id: "type2", connector: .type2, power: 180, state: .available)

        #expect(profile.accepts(fastCCS))
        #expect(!profile.accepts(slowCCS))
        #expect(!profile.accepts(fastType2))
    }

    @Test("Available chargers sort ahead of unavailable chargers")
    func stationSorting() throws {
        let profile = VehicleProfile(connectors: [.ccs2], minimumPowerKW: nil)
        let available = station(id: "available", connector: .ccs2, power: 60, state: .available)
        let offline = station(id: "offline", connector: .ccs2, power: 180, state: .offline)

        let sorted = StationDiscovery.compatibleStations(from: [offline, available], profile: profile, near: nil, now: now)
        #expect(try #require(sorted.first).id == "available")
    }

    @Test("Stale availability is reported as unavailable")
    func staleAvailability() {
        let stale = Availability(
            state: .available,
            availableConnectors: 3,
            totalConnectors: 4,
            lastUpdated: now.addingTimeInterval(-301)
        )

        #expect(stale.isStale(at: now))
        #expect(stale.displayText(at: now) == "Status unavailable")
    }

    @Test("Missing and old price timestamps never imply a current price")
    func stalePrice() {
        let missing = Price(amountMYR: 1.50, unit: .kWh, lastUpdated: nil)
        let stale = Price(amountMYR: 1.50, unit: .kWh, lastUpdated: now.addingTimeInterval(-86_401))
        let current = Price(amountMYR: 1.50, unit: .kWh, lastUpdated: now)

        #expect(missing.displayText(at: now) == "Price unavailable")
        #expect(stale.isStale(at: now))
        #expect(stale.displayText(at: now) == "Price unavailable")
        #expect(current.displayText(at: now).contains("1.50"))
    }

    @Test("CarPlay does not fabricate stations after its snapshot is cleared")
    @MainActor func clearedCarPlaySnapshot() throws {
        let defaults = try #require(UserDefaults(suiteName: "VoltWayTests.\(UUID().uuidString)"))
        CarPlaySnapshotStore.save(stations: [station(id: "saved", connector: .ccs2, power: 100, state: .available)], favoriteStationIDs: ["saved"], defaults: defaults)
        #expect(CarPlaySnapshotStore.load(defaults: defaults).stations.count == 1)

        CarPlaySnapshotStore.clear(defaults: defaults)
        let empty = CarPlaySnapshotStore.load(defaults: defaults)
        #expect(empty.stations.isEmpty)
        #expect(empty.favoriteStationIDs.isEmpty)
    }

    @Test("Favorite snapshots preserve stable station identity")
    func favoriteRoundTrip() throws {
        let favorite = FavoriteStation(
            userID: "user-1",
            stationID: "favorite",
            stationSnapshot: station(id: "favorite", connector: .ccs2, power: 120, state: .available),
            createdAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(FavoriteStation.self, from: encoder.encode(favorite))
        #expect(decoded.id == "favorite")
        #expect(decoded.stationSnapshot.id == favorite.stationSnapshot.id)
    }

    private func station(
        id: String,
        connector: ConnectorKind,
        power: Double,
        state: AvailabilityState
    ) -> ChargingStation {
        ChargingStation(
            id: id,
            name: id.capitalized,
            address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.1390, longitude: 101.6869),
            operatorName: "Gentari",
            connectors: [Connector(kind: connector, powerKW: power, count: 2)],
            availability: Availability(state: state, availableConnectors: state == .available ? 1 : 0, totalConnectors: 2, lastUpdated: now),
            price: Price(amountMYR: 1.50, unit: .kWh, lastUpdated: now)
        )
    }
}

@Suite(.serialized)
struct BackendClientTests {
    private let configuration = AppConfiguration(supabaseURL: URL(string: "https://voltway.test"), supabaseAnonKey: "public-anon-key")

    @Test("Concurrent expired-token requests share one refresh and persist rotated tokens")
    func concurrentRefresh() async throws {
        let refreshes = LockedCounter()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/token", request.url?.query?.contains("password") == true {
                return (200, Data(#"{"access_token":"expired","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if path == "/auth/v1/token", request.url?.query?.contains("refresh_token") == true {
                refreshes.increment()
                Thread.sleep(forTimeInterval: 0.05)
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-2","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if path == "/rest/v1/favorite_stations" {
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                    ? (200, Data("[]".utf8))
                    : (401, Data(#"{"message":"Expired token"}"#.utf8))
            }
            return (404, Data())
        }
        defer { MockURLProtocol.handler = nil }

        let account = "test-\(UUID().uuidString)"
        let client = makeClient(account: account)
        let session = try await client.signIn(email: "driver@example.com", password: "password-123")
        async let first = client.loadFavorites(session: session)
        async let second = client.loadFavorites(session: session)
        let firstResult = try await first
        let secondResult = try await second
        #expect(firstResult.isEmpty && secondResult.isEmpty)
        #expect(refreshes.value == 1)
        let restored = try await client.restoreSession()
        #expect(restored?.accessToken == "fresh")
        #expect(restored?.refreshToken == "refresh-2")
        try await client.signOut()
    }

    @Test("Charger search sends connector filters but never coordinates")
    func coordinatePrivacy() async throws {
        let observedURL = LockedURL()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            observedURL.set(request.url)
            return (200, Data(#"{"stations":[]}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let session = try await client.signIn(email: "driver@example.com", password: "password-123")
        let stations = try await client.stations(profile: .demo, session: session)
        #expect(stations.isEmpty)
        let url = try #require(observedURL.value)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "connectors" })
        #expect(!query.contains { $0.name == "latitude" || $0.name == "longitude" })
        try await client.signOut()
    }

    @Test("Failed vehicle profile save restores the previous local profile")
    @MainActor func profileRollback() async throws {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if path == "/rest/v1/vehicle_profiles", request.httpMethod == "POST" {
                return (500, Data(#"{"message":"Save failed"}"#.utf8))
            }
            if path == "/functions/v1/stations" { return (200, Data(#"{"stations":[]}"#.utf8)) }
            return (200, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let store = VoltWayStore(configuration: configuration, backend: client)
        await store.signIn(email: "driver@example.com", password: "password-123")
        let previous = store.profile
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100)
        #expect(!saved)
        #expect(store.profile == previous)
        #expect(store.errorMessage == "Save failed")
        CarPlaySnapshotStore.save(stations: [DemoData.stations[0]], favoriteStationIDs: [])
        await store.signOut()
        #expect(CarPlaySnapshotStore.load().stations.isEmpty)
    }

    private func makeClient(account: String) -> BackendClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        return BackendClient(configuration: configuration, urlSession: URLSession(configuration: sessionConfiguration), credentialAccount: account)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ value: URL?) { lock.lock(); defer { lock.unlock() }; url = value }
    var value: URL? { lock.lock(); defer { lock.unlock() }; return url }
}
