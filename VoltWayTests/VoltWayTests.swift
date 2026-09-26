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

    @Test("Unknown connector power is usable only without a minimum-power requirement")
    func unknownConnectorPower() {
        let charger = ChargingStation(
            id: "ocm:1", name: "City Mall", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "chargEV",
            connectors: [Connector(kind: .ccs2, powerKW: nil, count: nil)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .openChargeMap
        )
        #expect(VehicleProfile(connectors: [.ccs2], minimumPowerKW: nil).accepts(charger))
        #expect(!VehicleProfile(connectors: [.ccs2], minimumPowerKW: 50).accepts(charger))
        #expect(charger.connectorSummary.contains("Power unavailable"))
        #expect(charger.source?.attribution == "Open Charge Map · CC BY 4.0")
        #expect(!charger.availability.isReportedAvailable(at: now))
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

    @Test("Search matches station names and addresses without case or surrounding-space sensitivity")
    func stationSearch() {
        let solaris = station(id: "solaris", connector: .ccs2, power: 180, state: .available)
        let valley = station(id: "valley", connector: .ccs2, power: 120, state: .occupied)
        let stations = [solaris, valley]

        #expect(StationDiscovery.visibleStations(from: stations, query: "  SOLARIS  ", availableNowOnly: false, now: now).map(\.id) == ["solaris"])
        #expect(StationDiscovery.visibleStations(from: stations, query: "kuala lumpur", availableNowOnly: false, now: now).count == 2)
        #expect(StationDiscovery.visibleStations(from: stations, query: "   ", availableNowOnly: false, now: now).count == 2)
        #expect(StationDiscovery.visibleStations(from: stations, query: "no match", availableNowOnly: false, now: now).isEmpty)
    }

    @Test("Search also matches charging operators")
    func operatorSearch() {
        let charger = ChargingStation(
            id: "ocm:2", name: "City Mall", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "DC Handal",
            connectors: [Connector(kind: .ccs2, powerKW: 100, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .openChargeMap
        )
        #expect(StationDiscovery.visibleStations(from: [charger], query: "handal", availableNowOnly: false).map(\.id) == ["ocm:2"])
        #expect(StationDiscovery.visibleStations(from: [charger], query: "", availableNowOnly: true).isEmpty)
    }

    @Test("Demo includes attributed, non-live Shell, TNB, and other network locations")
    func reviewedDemoNetworks() throws {
        let expected: [String: String] = [
            "ocm:279460": "Shell Recharge", "ocm:479684": "Shell Recharge",
            "ocm:480555": "TNB Electron", "ocm:480140": "TNB Electron",
            "ocm:505071": "JomCharge", "ocm:497573": "chargEV",
            "ocm:259727": "ChargeSini"
        ]
        let ids = DemoData.stations.map(\.id)
        #expect(Set(ids).count == ids.count)
        for (id, network) in expected {
            let charger = try #require(DemoData.stations.first { $0.id == id })
            #expect(charger.networkName == network)
            #expect(charger.source == .openChargeMap)
            #expect(charger.sourceURL?.absoluteString == "https://openchargemap.org/poi/details/\(id.dropFirst(4))")
            #expect(charger.availability.displayText() == "Status unavailable")
            #expect(charger.price == nil)
            #expect(!charger.availability.isReportedAvailable())
            #expect(ChargingCostEstimate.amount(for: charger.price, energyKWh: 20) == nil)
            #expect(charger.connectors.contains { $0.kind == .ccs2 || $0.kind == .type2 })
        }
    }

    @Test("Network aliases produce one filter choice and identical map/list results")
    func networkDiscovery() {
        let stations = DemoData.stations
        let choices = StationDiscovery.networks(from: stations)
        #expect(Array(choices.prefix(3)) == ["Shell Recharge", "TNB Electron", "Gentari"])
        #expect(stations.allSatisfy(VehicleProfile.demo.accepts))
        #expect(choices.contains("Shell Recharge"))
        #expect(choices.contains("TNB Electron"))
        #expect(choices.contains("chargEV"))
        #expect(choices.filter { $0 == "chargEV" }.count == 1)

        let compatible = StationDiscovery.compatibleStations(
            from: stations, profile: VehicleProfile(connectors: [.ccs2], minimumPowerKW: nil), near: nil
        )
        let mapAndList = StationDiscovery.visibleStations(
            from: compatible, query: "shell", availableNowOnly: false, network: "Shell Recharge"
        )
        #expect(Set(mapAndList.map(\.id)) == Set(["ocm:279460", "ocm:479684"]))
        #expect(StationDiscovery.visibleStations(
            from: compatible, query: "", availableNowOnly: true, network: "Shell Recharge"
        ).isEmpty)
        #expect(StationDiscovery.visibleStations(
            from: compatible, query: "tnb", availableNowOnly: false, network: "TNB Electron"
        ).count == 2)
    }

    @Test("Available now requires fresh status and at least one reported connector")
    func availableNowFilter() {
        let available = station(id: "available", connector: .ccs2, power: 180, state: .available)
        let stale = station(id: "stale", connector: .ccs2, power: 180, state: .available, updatedAt: now.addingTimeInterval(-301))
        let zero = station(id: "zero", connector: .ccs2, power: 180, state: .available, availableConnectors: 0)
        let missing = station(id: "missing", connector: .ccs2, power: 180, state: .available, availableConnectors: nil)
        let occupied = station(id: "occupied", connector: .ccs2, power: 180, state: .occupied)

        let results = StationDiscovery.visibleStations(
            from: [available, stale, zero, missing, occupied],
            query: "",
            availableNowOnly: true,
            now: now
        )
        #expect(results.map(\.id) == ["available"])
    }

    @Test("Reported availability becomes unusable after five minutes or without a timestamp")
    func reportedAvailabilityBoundary() {
        let current = Availability(state: .available, availableConnectors: 1, totalConnectors: 2, lastUpdated: now.addingTimeInterval(-300))
        let old = Availability(state: .available, availableConnectors: 1, totalConnectors: 2, lastUpdated: now.addingTimeInterval(-301))
        let unknownTime = Availability(state: .available, availableConnectors: 1, totalConnectors: 2, lastUpdated: nil)

        #expect(current.isReportedAvailable(at: now))
        #expect(!old.isReportedAvailable(at: now))
        #expect(!unknownTime.isReportedAvailable(at: now))
        #expect(!current.isReportedAvailable(at: now.addingTimeInterval(1)))
    }

    @Test("Combined search and availability filters preserve the input sort order")
    func combinedDiscoveryFilters() {
        let first = station(id: "first", connector: .ccs2, power: 180, state: .available)
        let second = station(id: "second", connector: .ccs2, power: 120, state: .available)
        let other = station(id: "other", connector: .ccs2, power: 60, state: .occupied)

        let results = StationDiscovery.visibleStations(
            from: [second, other, first],
            query: "kuala",
            availableNowOnly: true,
            now: now
        )
        #expect(results.map(\.id) == ["second", "first"])
    }

    @Test("Nearby alternatives prefer confirmed availability, then distance, and show at most three")
    func nearbyAlternativeRanking() {
        let origin = station(id: "origin", connector: .ccs2, power: 100, state: .occupied)
        let nearOccupied = station(id: "occupied", connector: .ccs2, power: 100, state: .occupied,
                                   coordinate: Coordinate(latitude: 3.141, longitude: 101.6869))
        let nearAvailable = station(id: "near", connector: .ccs2, power: 100, state: .available,
                                    coordinate: Coordinate(latitude: 3.149, longitude: 101.6869))
        let fartherAvailable = station(id: "farther", connector: .ccs2, power: 100, state: .available,
                                       coordinate: Coordinate(latitude: 3.16, longitude: 101.6869))
        let stale = station(id: "stale", connector: .ccs2, power: 100, state: .available,
                            updatedAt: now.addingTimeInterval(-301),
                            coordinate: Coordinate(latitude: 3.14, longitude: 101.6869))

        let results = StationDiscovery.nearbyAlternatives(
            to: origin,
            compatibleStations: [stale, nearOccupied, fartherAvailable, origin, nearAvailable],
            now: now
        )
        #expect(results.map(\.id) == ["near", "farther", "stale"])
    }

    @Test("Nearby alternatives include the distance boundary but exclude incompatible and distant stations")
    func nearbyAlternativeBoundary() throws {
        let origin = station(id: "origin", connector: .ccs2, power: 100, state: .available)
        let boundary = station(id: "boundary", connector: .ccs2, power: 100, state: .available,
                               coordinate: Coordinate(latitude: 3.18, longitude: 101.6869))
        let outside = station(id: "outside", connector: .ccs2, power: 100, state: .available,
                              coordinate: Coordinate(latitude: 3.20, longitude: 101.6869))
        let incompatible = station(id: "type2", connector: .type2, power: 100, state: .available,
                                   coordinate: Coordinate(latitude: 3.14, longitude: 101.6869))
        let profile = VehicleProfile(connectors: [.ccs2], minimumPowerKW: 50)
        let compatible = StationDiscovery.compatibleStations(
            from: [outside, incompatible, boundary, origin], profile: profile, near: nil, now: now
        )
        let radius = try #require(boundary.distance(from: origin.coordinate))

        let results = StationDiscovery.nearbyAlternatives(
            to: origin, compatibleStations: compatible, radiusMeters: radius, now: now
        )
        #expect(results.map(\.id) == ["boundary"])
        #expect(StationDiscovery.nearbyAlternatives(to: origin, compatibleStations: [origin], now: now).isEmpty)
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

    @Test("Energy estimates use only fresh per-kWh MYR prices and round to cents")
    func chargingCostEstimates() {
        let price = Price(amountMYR: Decimal(string: "1.237")!, unit: .kWh, lastUpdated: now)
        #expect(ChargingCostEstimate.amount(for: price, energyKWh: 10, at: now) == Decimal(string: "12.37"))
        #expect(ChargingCostEstimate.amount(for: price, energyKWh: 20, at: now) == Decimal(string: "24.74"))
        #expect(ChargingCostEstimate.amount(for: price, energyKWh: 40, at: now) == Decimal(string: "49.48"))
        let halfCent = Price(amountMYR: Decimal(string: "1.2345")!, unit: .kWh, lastUpdated: now)
        #expect(ChargingCostEstimate.amount(for: halfCent, energyKWh: 10, at: now) == Decimal(string: "12.35"))
        #expect(ChargingCostEstimate.amount(for: price, energyKWh: 0, at: now) == nil)
        #expect(ChargingCostEstimate.amount(for: price, energyKWh: -1, at: now) == nil)
    }

    @Test("Missing, stale, and non-energy tariffs cannot produce an estimate")
    func unavailableChargingEstimates() {
        let missingTime = Price(amountMYR: 1.50, unit: .kWh, lastUpdated: nil)
        let stale = Price(amountMYR: 1.50, unit: .kWh, lastUpdated: now.addingTimeInterval(-86_401))
        let perMinute = Price(amountMYR: 0.50, unit: .minute, lastUpdated: now)
        let perSession = Price(amountMYR: 5, unit: .session, lastUpdated: now)

        #expect(ChargingCostEstimate.amount(for: nil, energyKWh: 20, at: now) == nil)
        #expect(ChargingCostEstimate.amount(for: missingTime, energyKWh: 20, at: now) == nil)
        #expect(ChargingCostEstimate.amount(for: stale, energyKWh: 20, at: now) == nil)
        #expect(ChargingCostEstimate.amount(for: perMinute, energyKWh: 20, at: now) == nil)
        #expect(ChargingCostEstimate.amount(for: perSession, energyKWh: 20, at: now) == nil)
    }

    @Test("Route stops use compatible chargers, an inclusive corridor, and travel order")
    func routeStops() throws {
        let profile = VehicleProfile(connectors: [.ccs2], minimumPowerKW: 50)
        let route = [Coordinate(latitude: 3, longitude: 101), Coordinate(latitude: 3, longitude: 102)]
        let first = station(id: "first", connector: .ccs2, power: 100, state: .available,
                            coordinate: Coordinate(latitude: 3.01, longitude: 101.2))
        let second = station(id: "second", connector: .ccs2, power: 100, state: .available,
                             coordinate: Coordinate(latitude: 3.044, longitude: 101.8))
        let boundaryLatitude = 3.0 + 5_000.0 / 111_195.0
        let boundary = station(id: "boundary", connector: .ccs2, power: 100, state: .available,
                               coordinate: Coordinate(latitude: boundaryLatitude, longitude: 101.5))
        let outside = station(id: "outside", connector: .ccs2, power: 100, state: .available,
                             coordinate: Coordinate(latitude: 3.0 + 5_100.0 / 111_195.0, longitude: 101.5))
        let incompatible = station(id: "incompatible", connector: .type2, power: 100, state: .available,
                                  coordinate: Coordinate(latitude: 3, longitude: 101.3))
        let compatible = StationDiscovery.compatibleStations(
            from: [second, boundary, outside, incompatible, first], profile: profile, near: nil, now: now
        )

        let stops = RouteStopMatcher.stops(along: route, compatibleStations: compatible, corridorMeters: 5_000)
        #expect(stops.map { $0.station.id } == ["first", "boundary", "second"])
        #expect(try #require(stops.first).offRouteMeters < 1_200)
        #expect(try #require(stops.first).routeProgressMeters < stops[1].routeProgressMeters)
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

    @Test("CarPlay snapshot preserves demo disclosure")
    @MainActor func carPlayDemoDisclosure() throws {
        let defaults = try #require(UserDefaults(suiteName: "VoltWayTests.\(UUID().uuidString)"))
        CarPlaySnapshotStore.save(stations: DemoData.stations, favoriteStationIDs: [], isDemo: true, defaults: defaults)
        #expect(CarPlaySnapshotStore.load(defaults: defaults).isDemo)
    }

    @Test("Older CarPlay snapshots without a demo field remain readable")
    func legacyCarPlaySnapshot() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = CarPlaySnapshot(stations: [DemoData.stations[0]], favoriteStationIDs: [], savedAt: now)
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "isDemo")
        let restored = try decoder.decode(CarPlaySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!restored.isDemo)
        #expect(restored.stations.count == 1)
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

    @Test("Old favorite snapshots without source metadata remain decodable")
    func legacyFavoriteSnapshot() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let original = station(id: "gentari-old", connector: .ccs2, power: 120, state: .available)
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        object.removeValue(forKey: "source")
        let decoded = try decoder.decode(ChargingStation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.source == nil)
        #expect(decoded.id == original.id)
    }

    private func station(
        id: String,
        connector: ConnectorKind,
        power: Double,
        state: AvailabilityState,
        availableConnectors: Int? = 1,
        updatedAt: Date? = nil,
        coordinate: Coordinate = Coordinate(latitude: 3.1390, longitude: 101.6869)
    ) -> ChargingStation {
        ChargingStation(
            id: id,
            name: id.capitalized,
            address: "Kuala Lumpur",
            coordinate: coordinate,
            operatorName: "Gentari",
            connectors: [Connector(kind: connector, powerKW: power, count: 2)],
            availability: Availability(state: state, availableConnectors: availableConnectors, totalConnectors: 2, lastUpdated: updatedAt ?? now),
            price: Price(amountMYR: 1.50, unit: .kWh, lastUpdated: now)
        )
    }
}

@Suite(.serialized)
struct BackendClientTests {
    private let configuration = AppConfiguration(supabaseURL: URL(string: "https://voltway.test"), supabaseAnonKey: "public-anon-key")

    @Test("Station responses preserve partial-source warnings and fractional sync timestamps")
    @MainActor func partialCoverageMetadata() async throws {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if request.url?.path == "/functions/v1/stations" {
                return (200, Data(#"{"stations":[],"warnings":["Gentari live feed unavailable; showing open-data locations only."],"catalogSyncedAt":"2026-09-26T12:34:56.789Z"}"#.utf8))
            }
            return (200, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.errorMessage == nil)
        #expect(store.sourceWarnings.count == 1)
        #expect(store.catalogSyncedAt != nil)
        await store.signOut()
        #expect(store.sourceWarnings.isEmpty)
        #expect(store.catalogSyncedAt == nil)
    }

    @Test("Only a successful live fetch updates the list-check time, and sign-out clears it")
    @MainActor func successfulFetchTime() async throws {
        let stationRequests = LockedCounter()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stationList = try encoder.encode([DemoData.stations[0]])
        let response = Data(#"{"stations": "#.utf8) + stationList + Data("}".utf8)
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if path == "/functions/v1/stations" {
                stationRequests.increment()
                return stationRequests.value == 2
                    ? (503, Data(#"{"message":"Refresh failed"}"#.utf8))
                    : (200, response)
            }
            return (200, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let store = VoltWayStore(configuration: configuration, backend: client)
        await store.signIn(email: "driver@example.com", password: "password-123")
        let firstCheck = try #require(store.lastSuccessfulStationFetchAt)
        #expect(store.stations.map(\.id) == ["gentari-petronas-solaris"])

        await store.refreshStations()
        #expect(store.lastSuccessfulStationFetchAt == firstCheck)
        #expect(store.stations.map(\.id) == ["gentari-petronas-solaris"])
        #expect(store.errorMessage == "Refresh failed")

        await store.refreshStations()
        #expect(try #require(store.lastSuccessfulStationFetchAt) > firstCheck)
        #expect(store.errorMessage == nil)

        await store.signOut()
        #expect(store.lastSuccessfulStationFetchAt == nil)
    }

    @Test("Changing the vehicle invalidates a prior list-check time when its refresh fails")
    @MainActor func profileChangeInvalidatesFetchTime() async throws {
        let stationRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if path == "/functions/v1/stations" {
                stationRequests.increment()
                return stationRequests.value == 1
                    ? (200, Data(#"{"stations":[]}"#.utf8))
                    : (503, Data(#"{"message":"Refresh failed"}"#.utf8))
            }
            if path == "/rest/v1/vehicle_profiles", request.httpMethod == "POST" { return (204, Data()) }
            return (200, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let store = VoltWayStore(configuration: configuration, backend: client)
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.lastSuccessfulStationFetchAt != nil)

        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100)
        #expect(saved)
        #expect(store.lastSuccessfulStationFetchAt == nil)
        #expect(store.errorMessage == "Refresh failed")
        await store.signOut()
    }

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
        #expect(stations.stations.isEmpty)
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
        let previousFetchAt = try #require(store.lastSuccessfulStationFetchAt)
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100)
        #expect(!saved)
        #expect(store.profile == previous)
        #expect(store.lastSuccessfulStationFetchAt == previousFetchAt)
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
