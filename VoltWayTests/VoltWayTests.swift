import Foundation
import Synchronization
import Testing
@testable import VoltWay

struct VoltWayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Directory-only demo needs no recurring freshness redraw")
    @MainActor func demoHasNoTimedFacts() {
        let store = VoltWayStore(configuration: AppConfiguration(supabaseURL: nil, supabaseAnonKey: ""))
        #expect(store.hasTimedStationFacts == false)
    }

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

    @Test("All sites retains unknown connectors while compatible discovery excludes them")
    func allSitesAndCompatibility() {
        let unknown = ChargingStation(
            id: "ocm:2", name: "Unknown plug", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Directory",
            connectors: [], availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .openChargeMap
        )
        let profile = VehicleProfile(connectors: [.ccs2], minimumPowerKW: nil)
        #expect(!profile.accepts(unknown))
        #expect(StationDiscovery.visibleStations(from: [unknown], query: "", availableNowOnly: false,
            profile: profile, showAll: true).map(\.id) == ["ocm:2"])
        #expect(StationDiscovery.visibleStations(from: [unknown], query: "", availableNowOnly: false,
            profile: profile, showAll: false).isEmpty)
        #expect(unknown.connectorSummary == "Connector details unavailable")
    }

    @Test("MEVnet planning sites decode without invented connectors and proposed sites stay opt-in")
    func mevnetPlanningRecords() throws {
        let payload = #"{"id":"mevnet:4","name":"City Mall","address":"Selangor","coordinate":{"latitude":3.14,"longitude":101.68},"operatorName":"Gentari","connectors":[],"availability":{"state":"unknown","availableConnectors":null,"totalConnectors":null,"lastUpdated":null},"price":null,"source":"mevnet","lifecycle":"proposed","acCount":2,"dcCount":1,"sourceSequence":4,"stateCode":10,"pbtCode":17,"indoorOutdoor":"Indoor","sourceIDs":{"mevnet":"4"}}"#
        let record = try JSONDecoder().decode(ChargingStation.self, from: Data(payload.utf8))
        #expect(record.lifecycle == .proposed)
        #expect(record.acCount == 2)
        #expect(record.sourceSequence == 4)
        #expect(record.stateCode == 10)
        #expect(record.pbtCode == 17)
        #expect(record.indoorOutdoor == "Indoor")
        #expect(record.connectorSummary == "Connector details unavailable")
        #expect(!VehicleProfile.demo.accepts(record))
        #expect(StationDiscovery.visibleStations(from: [record], query: "", availableNowOnly: false,
            showAll: true).isEmpty)
        #expect(StationDiscovery.visibleStations(from: [record], query: "", availableNowOnly: false,
            showAll: true, includeProposed: true).map(\.id) == ["mevnet:4"])
        #expect(StationDiscovery.visibleStations(from: [record], query: "", availableNowOnly: true,
            showAll: true, includeProposed: true).isEmpty)
    }

    @Test("Proposed sites remain outside Compatible even when the All sites option was enabled")
    func proposedSiteCannotLeakIntoCompatible() async {
        var planned = station(id: "mevnet:planned", connector: .ccs2, power: 150, state: .unknown)
        planned.lifecycle = .proposed
        let profile = VehicleProfile(connectors: [.ccs2], minimumPowerKW: nil)
        #expect(profile.accepts(planned))

        let compatibleFilter = DiscoveryFilter(
            query: "", availableNowOnly: false, network: nil, profile: profile,
            showAll: false, chargingType: nil, minimumListedPowerKW: nil,
            access: nil, includeProposed: true
        )
        let compatible = await StationDiscovery.resultsOffMain(
            from: [planned], filter: compatibleFilter, networkChoices: nil, now: now
        )
        #expect(compatible.stations.isEmpty)
        #expect(StationDiscovery.visibleStations(
            from: [planned], query: "", availableNowOnly: false,
            profile: profile, showAll: true, includeProposed: true
        ).map(\.id) == ["mevnet:planned"])
    }

    @Test("Catalog response keeps MEVnet accounting separate from OCM and tolerates older station snapshots")
    func mevnetCoverageDecoding() throws {
        let payload = #"{"stations":[],"mevnetSyncedAt":"2026-09-28T00:00:00Z","mevnetImportReport":{"fetched":3,"included":2,"existing":1,"proposed":1,"unknown":0,"invalid":1,"private":0,"states":{"PERAK":{"fetched":3,"included":2,"proposed":1,"invalid":1,"private":0}}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(StationFetchResult.self, from: Data(payload.utf8))
        #expect(response.mevnetImportReport?.fetched == 3)
        #expect(response.mevnetImportReport?.states["PERAK"]?.proposed == 1)
        let legacy = try decoder.decode(StationFetchResult.self, from: Data(#"{"stations":[]}"#.utf8))
        #expect(legacy.mevnetImportReport == nil)
    }

    @Test("Quick filters share map and list results without treating directory status as live")
    func quickDiscoveryFilters() {
        let ac = ChargingStation(
            id: "ocm:3", name: "AC site", address: "Malaysia",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "ChargeSini",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .openChargeMap, sourceAttribution: "ChargeSini via Open Charge Map · CC0", access: .limited
        )
        let profile = VehicleProfile(connectors: [.ccs2], minimumPowerKW: nil)
        #expect(StationDiscovery.visibleStations(from: [ac], query: "", availableNowOnly: false,
            profile: profile, showAll: true, chargingType: .ac, minimumListedPowerKW: 20, access: .limited).map(\.id) == ["ocm:3"])
        #expect(StationDiscovery.visibleStations(from: [ac], query: "", availableNowOnly: true,
            profile: profile, showAll: true).isEmpty)
        #expect(ac.attributionText == "ChargeSini via Open Charge Map · CC0")
        let unclassified = station(id: "gentari-unknown-access", connector: .ccs2, power: 100, state: .unknown)
        #expect(StationDiscovery.visibleStations(from: [ac, unclassified], query: "", availableNowOnly: false,
            showAll: true, access: .unknown).map(\.id) == ["gentari-unknown-access"])
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
        #expect(DemoData.stations.allSatisfy { $0.availability.state == .unknown && $0.price == nil })
        #expect(StationDiscovery.visibleStations(from: DemoData.stations, query: "", availableNowOnly: true).isEmpty)
    }

    @Test("Coverage separates station sites from source-reported charge points")
    func sourceCoverageCounts() throws {
        let coverage = CatalogCoverage.networks(in: DemoData.stations)
        let handal = try #require(coverage.first { $0.network == "DC Handal" })
        #expect(handal.sites == 1)
        #expect(handal.knownChargePoints == 5)
        #expect(handal.sitesWithoutChargePointCount == 0)
        #expect(handal.hasDirectoryRecords)
        #expect(!handal.hasPartnerFeed)

        let shell = try #require(coverage.first { $0.network == "Shell Recharge" })
        #expect(shell.sites == 2)
        #expect(shell.knownChargePoints == 2)
        #expect(shell.sitesWithoutChargePointCount == 1)
    }

    @Test("Network coverage separates proposed sites from existing directory locations")
    func proposedCoverageCounts() throws {
        let shellStations = DemoData.stations.filter { $0.networkName == "Shell Recharge" }
        #expect(shellStations.count == 2)
        var planned = shellStations[0]
        planned.lifecycle = .proposed
        let summary = try #require(CatalogCoverage.networks(in: [planned, shellStations[1]]).first)
        #expect(summary.sites == 2)
        #expect(summary.proposedSites == 1)
        #expect(summary.otherSites == 1)
    }

    @Test("Network aliases produce one filter choice and identical map/list results")
    func networkDiscovery() {
        let stations = DemoData.stations
        let choices = StationDiscovery.networks(from: stations)
        #expect(Array(choices.prefix(3)) == ["Shell Recharge", "TNB Electron", "ChargeSini"])
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

    @Test("Future-dated status is unavailable and cannot pass Available now")
    func futureAvailabilityIsUnavailable() {
        let future = Availability(state: .available, availableConnectors: 2, totalConnectors: 2,
                                  lastUpdated: now.addingTimeInterval(60))
        let station = station(id: "future", connector: .ccs2, power: 180, state: .available,
                              updatedAt: now.addingTimeInterval(60))

        #expect(future.isStale(at: now))
        #expect(future.isReportedAvailable(at: now) == false)
        #expect(future.displayText(at: now) == "Status unavailable")
        #expect(StationDiscovery.visibleStations(from: [station], query: "", availableNowOnly: true, now: now).isEmpty)
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

    @Test("Future-dated price is unavailable and cannot produce an estimate")
    func futurePriceIsUnavailable() {
        let future = Price(amountMYR: 1.50, unit: .kWh, lastUpdated: now.addingTimeInterval(60))

        #expect(future.isStale(at: now))
        #expect(future.displayText(at: now) == "Price unavailable")
        #expect(ChargingCostEstimate.amount(for: future, energyKWh: 20, at: now) == nil)
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

    @Test("Off-main route matching preserves ordered corridor results")
    @MainActor func offMainRouteStops() async {
        let route = [Coordinate(latitude: 3, longitude: 101), Coordinate(latitude: 3, longitude: 102)]
        let nearEnd = station(id: "end", connector: .ccs2, power: 100, state: .unknown,
                              coordinate: Coordinate(latitude: 3.01, longitude: 101.8))
        let nearStart = station(id: "start", connector: .ccs2, power: 100, state: .unknown,
                                coordinate: Coordinate(latitude: 3.01, longitude: 101.2))
        let farAway = station(id: "far", connector: .ccs2, power: 100, state: .unknown,
                              coordinate: Coordinate(latitude: 4, longitude: 101.5))
        let stations = [nearEnd, farAway, nearStart]

        let offMain = await RouteStopMatcher.stopsOffMain(along: route, compatibleStations: stations)
        let synchronous = RouteStopMatcher.stops(along: route, compatibleStations: stations)
        #expect(offMain == synchronous)
        #expect(offMain.map { $0.station.id } == ["start", "end"])
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

    @Test("Apple Maps handoff keeps the selected directory site's coordinate")
    @MainActor func mapsHandoffCoordinate() throws {
        let station = try #require(DemoData.stations.first { $0.id == "ocm:505443" })
        let item = MapsHandoff.mapItem(for: station)
        #expect(item.name == station.name)
        #expect(item.location.coordinate.latitude == station.coordinate.latitude)
        #expect(item.location.coordinate.longitude == station.coordinate.longitude)
    }

    @Test("Private charger coordinates are excluded from CarPlay snapshots")
    func privateSitesStayOutOfCarPlay() {
        let publicStation = DemoData.stations[0]
        let privateStation = ChargingStation(
            id: "private:site-1", name: "Workplace depot", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .ownerProvided, access: .privateAccess
        )
        let snapshot = CarPlaySnapshot(
            stations: [publicStation, privateStation],
            favoriteStationIDs: [publicStation.id, privateStation.id], savedAt: now
        )
        #expect(snapshot.stations.map(\.id) == [publicStation.id])
        #expect(snapshot.favoriteStationIDs == [publicStation.id])
    }

    @Test("CarPlay excludes private sites when either access or ID identifies them")
    @MainActor func privateSitesWithoutSourceStayOutOfCarPlay() throws {
        let publicStation = DemoData.stations[0]
        func site(id: String, access: StationAccess?) -> ChargingStation {
            ChargingStation(
                id: id, name: "Private depot", address: "Kuala Lumpur",
                coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
                connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
                availability: Availability(state: .unknown, availableConnectors: nil,
                                           totalConnectors: nil, lastUpdated: nil),
                price: nil, access: access
            )
        }
        let privateByID = site(id: "private:site-1", access: nil)
        let privateByAccess = site(id: "site-2", access: .privateAccess)
        let stations = [publicStation, privateByID, privateByAccess]
        let favoriteIDs = Set(stations.map(\.id))

        let snapshot = CarPlaySnapshot(stations: stations, favoriteStationIDs: favoriteIDs, savedAt: now)
        #expect(snapshot.stations.map(\.id) == [publicStation.id])
        #expect(snapshot.favoriteStationIDs == [publicStation.id])

        // Older snapshots may already contain a private record, so decoding must scrub it too.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        object["stations"] = try JSONSerialization.jsonObject(with: encoder.encode(stations))
        object["favoriteStationIDs"] = Array(favoriteIDs)
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let restored = try decoder.decode(CarPlaySnapshot.self, from: legacyData)
        #expect(restored.stations.map(\.id) == [publicStation.id])
        #expect(restored.favoriteStationIDs == [publicStation.id])

        let defaults = try #require(UserDefaults(suiteName: "VoltWayTests.\(UUID().uuidString)"))
        defaults.set(legacyData, forKey: "carplay-snapshot")
        let loaded = CarPlaySnapshotStore.load(defaults: defaults)
        #expect(loaded.stations.map(\.id) == [publicStation.id])
        let storedData = try #require(defaults.data(forKey: "carplay-snapshot"))
        let storedObject = try #require(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        let storedStations = try #require(storedObject["stations"] as? [[String: Any]])
        #expect(storedStations.compactMap { $0["id"] as? String } == [publicStation.id])
        #expect(Set(storedObject["favoriteStationIDs"] as? [String] ?? []) == [publicStation.id])
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
        #expect(decoded.stationSnapshot?.id == favorite.stationSnapshot?.id)
    }

    @Test("Private favorites encode an explicit null instead of retaining a coordinate")
    func privateFavoriteStoresOnlyID() throws {
        let privateStation = ChargingStation(
            id: "private:site-1", name: "Workplace depot", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .ownerProvided, access: .privateAccess
        )
        let favorite = FavoriteStation(userID: "user-1", stationID: privateStation.id,
                                       stationSnapshot: privateStation, createdAt: nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(favorite)) as? [String: Any])
        #expect(object["station_id"] as? String == privateStation.id)
        #expect(object["station_snapshot"] is NSNull)
    }

    @Test("Private access removes a favorite coordinate even when source and ID look public")
    func privateAccessFavoriteStoresOnlyID() throws {
        let station = ChargingStation(
            id: "site-2", name: "Private depot", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil,
                                       totalConnectors: nil, lastUpdated: nil),
            price: nil, access: .privateAccess
        )
        let favorite = FavoriteStation(userID: "user-1", stationID: station.id,
                                       stationSnapshot: station, createdAt: nil)
        let encoder = JSONEncoder()
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(favorite)) as? [String: Any])
        #expect(object["station_snapshot"] is NSNull)

        // Older rows may still carry a full station; scrub it when decoding.
        var legacyObject = object
        legacyObject["station_snapshot"] = try JSONSerialization.jsonObject(with: encoder.encode(station))
        let decoded = try JSONDecoder().decode(FavoriteStation.self,
            from: JSONSerialization.data(withJSONObject: legacyObject))
        #expect(decoded.stationSnapshot == nil)
    }

    @Test("Nullable private favorite rows decode and re-encode with an explicit null")
    func nullablePrivateFavoriteDecoding() throws {
        let nullable = Data(#"{"user_id":"user-1","station_id":"private:site-1","station_snapshot":null}"#.utf8)
        let decoded = try JSONDecoder().decode(FavoriteStation.self, from: nullable)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(object["station_snapshot"] is NSNull)
    }

    @Test("Legacy private favorite snapshots are scrubbed when decoded")
    func legacyPrivateFavoriteDecoding() throws {
        let privateStation = ChargingStation(
            id: "private:site-1", name: "Workplace depot", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .ownerProvided, access: .privateAccess
        )
        let stationObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(privateStation))
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "user_id": "user-1", "station_id": privateStation.id, "station_snapshot": stationObject
        ])
        let decoded = try JSONDecoder().decode(FavoriteStation.self, from: legacyData)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(object["station_snapshot"] is NSNull)
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
        object.removeValue(forKey: "sourceAttribution")
        object.removeValue(forKey: "access")
        let decoded = try decoder.decode(ChargingStation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.source == nil)
        #expect(decoded.sourceAttribution == nil)
        #expect(decoded.access == nil)
        #expect(decoded.id == original.id)
    }

    @Test("Migrated vehicle records retain their identity and name")
    func migratedVehicleProfile() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let record = #"{"id":"00000000-0000-0000-0000-000000000042","user_id":"user-1","name":"Family EV","connectors":["ccs2"],"minimum_power_kw":50}"#
        let profile = try JSONDecoder().decode(VehicleProfile.self, from: Data(record.utf8))
        #expect(profile.id == id)
        #expect(profile.name == "Family EV")
        #expect(profile.connectors == [.ccs2])
        #expect(profile.minimumPowerKW == 50)
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

struct CarPlayPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("CarPlay fact refresh follows status and price expiry")
    func freshnessTransitions() throws {
        let station = ChargingStation(
            id: "live", name: "Live charger", address: "Malaysia",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 150, count: 2)],
            availability: Availability(state: .available, availableConnectors: 1, totalConnectors: 2,
                                       lastUpdated: now.addingTimeInterval(-300)),
            price: Price(amountMYR: 1.50, unit: .kWh, lastUpdated: now.addingTimeInterval(-86_300))
        )

        let statusChange = try #require(CarPlayPresentation.nextFreshnessUpdate(in: [station], after: now))
        #expect(statusChange > now)
        #expect(statusChange < now.addingTimeInterval(1))
        #expect(station.availability.displayText(at: statusChange) == "Status unavailable")

        let priceChange = try #require(CarPlayPresentation.nextFreshnessUpdate(in: [station], after: statusChange))
        #expect(priceChange > now.addingTimeInterval(100))
        #expect(priceChange < now.addingTimeInterval(101))
        #expect(station.price?.displayText(at: priceChange) == "Price unavailable")
        #expect(CarPlayPresentation.nextFreshnessUpdate(in: [station], after: priceChange) == nil)
        #expect(CarPlayPresentation.nextFreshnessUpdate(in: DemoData.stations, after: now) == nil)
    }

    @Test("CarPlay tracks a future timestamp becoming current")
    func futureTimestampTransition() throws {
        let station = ChargingStation(
            id: "future", name: "Future report", address: "Malaysia",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 150, count: 2)],
            availability: Availability(state: .available, availableConnectors: 1, totalConnectors: 2,
                                       lastUpdated: now.addingTimeInterval(60)), price: nil
        )

        #expect(station.availability.displayText(at: now) == "Status unavailable")
        let transition = try #require(CarPlayPresentation.nextFreshnessUpdate(in: [station], after: now))
        #expect(transition > now.addingTimeInterval(60))
        #expect(transition < now.addingTimeInterval(61))
        let expiry = try #require(CarPlayPresentation.nextFreshnessUpdate(in: [station], after: transition))
        #expect(expiry > now.addingTimeInterval(360))
        #expect(expiry < now.addingTimeInterval(361))
    }

    @Test("CarPlay pages every saved charger within the template item limit")
    func savedPagesAreReachable() {
        let first = CarPlayPresentation.page(totalCount: 27, startingAt: 0, maximumItemCount: 12)
        let second = CarPlayPresentation.page(totalCount: 27, startingAt: 11, maximumItemCount: 12)
        let third = CarPlayPresentation.page(totalCount: 27, startingAt: 22, maximumItemCount: 12)

        #expect(Array(first.range) + Array(second.range) + Array(third.range) == Array(0..<27))
        #expect(first.nextStart == 11)
        #expect(second.nextStart == 22)
        #expect(third.nextStart == 0)
        #expect(first.range.count + 1 <= 12)
        #expect(second.range.count + 1 <= 12)
        #expect(third.range.count + 1 <= 12)

        let small = CarPlayPresentation.page(totalCount: 5, startingAt: 0, maximumItemCount: 3)
        #expect(small.range == 0..<2)
        #expect(small.nextStart == 2)
        let constrained = CarPlayPresentation.page(totalCount: 5, startingAt: 0, maximumItemCount: 1)
        #expect(constrained.hasUnreachableItems)
        let exact = CarPlayPresentation.page(totalCount: 12, startingAt: 0, maximumItemCount: 12)
        #expect(exact.range == 0..<12)
        #expect(exact.nextStart == nil)
    }
}

@Suite(.serialized)
struct BackendClientTests {
    private let configuration = AppConfiguration(supabaseURL: URL(string: "https://voltway.test"), supabaseAnonKey: "public-anon-key")

    enum FavoriteDeleteScenario: CaseIterable, Sendable {
        case secondDeleteNotCommitted
        case responseLostAfterCommit
        case reconciliationUnavailable
    }

    private func favoriteStation(id: String = "gentari-favorite") -> ChargingStation {
        ChargingStation(
            id: id, name: "Favorite charger", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 120, count: 2)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .gentari
        )
    }

    private func waitForRequest(_ counter: LockedCounter, count: Int = 1) async throws {
        for _ in 0..<500 where counter.value < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(counter.value >= count, "Expected mocked request did not start")
    }

    @Test("Mocked JSON request bodies can arrive as a stream")
    func streamedRequestBody() {
        let payload = Data(#"{"station_id":"private:site-1"}"#.utf8)
        var request = URLRequest(url: URL(string: "https://voltway.test/rest/v1/favorite_stations")!)
        request.httpBodyStream = InputStream(data: payload)
        #expect(MockURLProtocol.bodyData(for: request) == payload)
    }

    @Test("A successful login can retry an account-data load failure", arguments: ["/auth/v1/token", "/auth/v1/signup"])
    @MainActor func accountLoadFailureCanRetry(authPath: String) async throws {
        let profileRequests = LockedCounter()
        let profile = VehicleProfile(userID: "user-1", name: "Daily EV", connectors: [.ccs2], minimumPowerKW: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profiles = try encoder.encode([profile])
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case authPath:
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case "/rest/v1/vehicle_profiles":
                profileRequests.increment()
                return profileRequests.value == 1
                    ? (503, Data(#"{"message":"Profiles unavailable"}"#.utf8))
                    : (200, profiles)
            case "/rest/v1/user_preferences", "/rest/v1/favorite_stations":
                return (200, Data("[]".utf8))
            case "/functions/v1/stations":
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (404, Data(#"{"message":"Unexpected request"}"#.utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        if authPath == "/auth/v1/signup" {
            await store.signUp(email: "driver@example.com", password: "password-123")
        } else {
            await store.signIn(email: "driver@example.com", password: "password-123")
        }

        #expect(store.session?.userID == "user-1")
        #expect(store.accountDataNeedsRetry)
        #expect(store.isLoadingAccountData == false)
        #expect(store.errorMessage == "Profiles unavailable")
        #expect(store.vehicles.isEmpty)
        #expect(store.stations.isEmpty)

        await store.retryAccountData()
        #expect(store.accountDataNeedsRetry == false)
        #expect(store.isLoadingAccountData == false)
        #expect(store.errorMessage == nil)
        #expect(store.vehicles.map(\.id) == [profile.id])
        #expect(store.activeVehicleID == nil)
        #expect(store.profile.connectors.isEmpty)
        #expect(profileRequests.value == 2)
        await store.signOut()
    }

    @Test("A slow charger refresh does not keep account loading on screen")
    @MainActor func accountReadyBeforeStationRefresh() async throws {
        let stationRequests = LockedCounter()
        let releaseStations = DispatchSemaphore(value: 0)
        let profile = VehicleProfile(userID: "user-1", name: "Daily EV", connectors: [.ccs2], minimumPowerKW: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profiles = try encoder.encode([profile])
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/token":
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case "/rest/v1/vehicle_profiles":
                return (200, profiles)
            case "/rest/v1/user_preferences", "/rest/v1/favorite_stations":
                return (200, Data("[]".utf8))
            case "/functions/v1/stations":
                stationRequests.increment()
                releaseStations.wait()
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (404, Data(#"{"message":"Unexpected request"}"#.utf8))
            }
        }
        defer {
            releaseStations.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        let signIn = Task { await store.signIn(email: "driver@example.com", password: "password-123") }
        for _ in 0..<100 where stationRequests.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stationRequests.value == 1)
        #expect(store.isBootstrapping == false)
        #expect(store.isLoadingAccountData == false)
        #expect(store.accountDataNeedsRetry == false)
        #expect(store.vehicles.map(\.id) == [profile.id])
        #expect(store.isLoadingStations)

        releaseStations.signal()
        await signIn.value
        await store.signOut()
    }

    @Test("A restored session can retry account data without signing in again")
    @MainActor func restoredAccountCanRetry() async throws {
        let profileRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/token":
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case "/rest/v1/vehicle_profiles":
                profileRequests.increment()
                return profileRequests.value == 1
                    ? (503, Data(#"{"message":"Profiles unavailable"}"#.utf8))
                    : (200, Data("[]".utf8))
            case "/rest/v1/user_preferences", "/rest/v1/favorite_stations":
                return (200, Data("[]".utf8))
            case "/functions/v1/stations":
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (404, Data(#"{"message":"Unexpected request"}"#.utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        _ = try await client.signIn(email: "driver@example.com", password: "password-123")
        let store = VoltWayStore(configuration: configuration, backend: client)
        await store.bootstrap()
        #expect(store.isBootstrapping == false)
        #expect(store.session?.userID == "user-1")
        #expect(store.accountDataNeedsRetry)
        #expect(store.errorMessage == "Profiles unavailable")

        await store.retryAccountData()
        #expect(store.accountDataNeedsRetry == false)
        #expect(store.errorMessage == nil)
        #expect(profileRequests.value == 2)
        await store.signOut()
    }

    @Test("Injected session storage supports sign-in, restore, and sign-out without Keychain")
    func injectedSessionStorage() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/auth/v1/token")
            return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let signedIn = try await client.signIn(email: "driver@example.com", password: "password-123")
        #expect(try await client.restoreSession() == signedIn)
        try await client.signOut()
        #expect(try await client.restoreSession() == nil)
    }

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
        #expect(store.stations.map(\.id) == ["ocm:505443"])

        await store.refreshStations()
        #expect(store.lastSuccessfulStationFetchAt == firstCheck)
        #expect(store.stations.map(\.id) == ["ocm:505443"])
        #expect(store.errorMessage == "Refresh failed")

        await store.refreshStations()
        #expect(try #require(store.lastSuccessfulStationFetchAt) > firstCheck)
        #expect(store.errorMessage == nil)

        await store.signOut()
        #expect(store.lastSuccessfulStationFetchAt == nil)
    }

    @Test("A charger response arriving after sign-out cannot restore account data")
    @MainActor func staleRefreshAfterSignOut() async throws {
        let stationRequests = LockedCounter()
        let releaseRefresh = DispatchSemaphore(value: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stationList = try encoder.encode([DemoData.stations[0]])
        let staleResponse = Data(#"{"stations": "#.utf8) + stationList + Data("}".utf8)
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/token":
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case "/functions/v1/stations":
                stationRequests.increment()
                if stationRequests.value == 2 {
                    releaseRefresh.wait()
                    return (200, staleResponse)
                }
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer {
            releaseRefresh.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let refresh = Task { await store.refreshStations() }
        for _ in 0..<100 where stationRequests.value < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stationRequests.value == 2)
        await store.signOut()
        releaseRefresh.signal()
        await refresh.value

        #expect(store.session == nil)
        #expect(store.stations.isEmpty)
        #expect(store.lastSuccessfulStationFetchAt == nil)
        #expect(CarPlaySnapshotStore.load().stations.isEmpty)
    }

    @Test("Changing the vehicle keeps the catalog snapshot and list-check time")
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
            if path == "/rest/v1/user_preferences", request.httpMethod == "POST" { return (204, Data()) }
            return (200, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let store = VoltWayStore(configuration: configuration, backend: client)
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.lastSuccessfulStationFetchAt != nil)

        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100)
        #expect(saved)
        #expect(store.lastSuccessfulStationFetchAt != nil)
        #expect(store.errorMessage == nil)
        #expect(stationRequests.value == 1)
        await store.signOut()
    }

    @Test("Switching active vehicles changes local compatibility without another catalog request")
    @MainActor func activeVehicleSwitch() async throws {
        let first = VehicleProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, userID: "user-1",
                                   name: "City EV", connectors: [.type2], minimumPowerKW: nil)
        let second = VehicleProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, userID: "user-1",
                                    name: "Highway EV", connectors: [.ccs2], minimumPowerKW: 100)
        let encoder = JSONEncoder()
        let profiles = try encoder.encode([first, second])
        let preference = try encoder.encode([ActiveVehiclePreference(userID: "user-1", activeVehicleID: first.id)])
        let charger = ChargingStation(id: "ccs-only", name: "Highway site", address: "Malaysia",
                                      coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
                                      connectors: [Connector(kind: .ccs2, powerKW: 150, count: 2)],
                                      availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
                                      price: nil)
        let stationResponse = Data(#"{"stations":"#.utf8) + (try encoder.encode([charger])) + Data("}".utf8)
        let requests = LockedCounter()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if path == "/rest/v1/vehicle_profiles" { return (200, profiles) }
            if path == "/rest/v1/user_preferences", request.httpMethod == "GET" { return (200, preference) }
            if path == "/rest/v1/user_preferences", request.httpMethod == "POST" { return (204, Data()) }
            if path == "/functions/v1/stations" { requests.increment(); return (200, stationResponse) }
            return (200, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.activeVehicleID == first.id)
        #expect(store.compatibleStations.isEmpty)
        await store.selectVehicle(second)
        #expect(store.activeVehicleID == second.id)
        #expect(store.profile.name == "Highway EV")
        #expect(store.compatibleStations.map(\.id) == ["ccs-only"])
        #expect(requests.value == 1)
        await store.signOut()
    }

    @Test("Compatible order updates when partner availability expires without fetching again")
    @MainActor func compatibilityFreshnessBoundary() async throws {
        let now = Date.now
        let profile = VehicleProfile(userID: "user-1", connectors: [.ccs2], minimumPowerKW: nil)
        let available = ChargingStation(
            id: "fresh", name: "Zeta Charger", address: "Malaysia",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 150, count: 2)],
            availability: Availability(state: .available, availableConnectors: 1, totalConnectors: 2,
                                       lastUpdated: now.addingTimeInterval(-240)), price: nil
        )
        let unknown = ChargingStation(
            id: "unknown", name: "Alpha Charger", address: "Malaysia",
            coordinate: Coordinate(latitude: 3.15, longitude: 101.69), operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 150, count: 2)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil,
                                       lastUpdated: nil), price: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profiles = try encoder.encode([profile])
        let stations = Data(#"{"stations": "#.utf8) + (try encoder.encode([unknown, available])) + Data("}".utf8)
        let stationRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/token":
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case "/rest/v1/vehicle_profiles":
                return (200, profiles)
            case "/functions/v1/stations":
                stationRequests.increment()
                return (200, stations)
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.hasTimedStationFacts)
        #expect(store.compatibleStations.map(\.id) == ["fresh", "unknown"])

        store.refreshAvailabilityOrderingIfNeeded(at: now.addingTimeInterval(30))
        #expect(store.compatibleStations(at: now.addingTimeInterval(30)).map(\.id) == ["fresh", "unknown"])
        #expect(store.compatibleStations(at: now.addingTimeInterval(90)).map(\.id) == ["unknown", "fresh"])
        #expect(store.compatibleStations(at: now.addingTimeInterval(90)).map(\.id) == ["unknown", "fresh"])
        #expect(stationRequests.value == 1)
        await store.signOut()
    }

    @Test("Compatible order updates when a future partner timestamp becomes current")
    @MainActor func futureCompatibilityFreshnessBoundary() async throws {
        let now = Date.now
        let activation = now.addingTimeInterval(600)
        let profile = VehicleProfile(userID: "user-1", connectors: [.ccs2], minimumPowerKW: nil)
        let futureAvailable = ChargingStation(
            id: "future", name: "Zeta Charger", address: "Malaysia",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 150, count: 2)],
            availability: Availability(state: .available, availableConnectors: 1, totalConnectors: 2,
                                       lastUpdated: activation), price: nil
        )
        let unknown = ChargingStation(
            id: "unknown", name: "Alpha Charger", address: "Malaysia",
            coordinate: Coordinate(latitude: 3.15, longitude: 101.69), operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 150, count: 2)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil,
                                       lastUpdated: nil), price: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profiles = try encoder.encode([profile])
        let stations = Data(#"{"stations": "#.utf8) + (try encoder.encode([futureAvailable, unknown])) + Data("}".utf8)
        let stationRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/token":
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case "/rest/v1/vehicle_profiles":
                return (200, profiles)
            case "/functions/v1/stations":
                stationRequests.increment()
                return (200, stations)
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.compatibleStations(at: now.addingTimeInterval(30)).map(\.id) == ["unknown", "future"])
        #expect(store.compatibleStations(at: activation.addingTimeInterval(1)).map(\.id) == ["future", "unknown"])
        #expect(stationRequests.value == 1)
        await store.signOut()
    }

    @Test("A newly private directory listing stays saved but disappears from discovery")
    @MainActor func privateFavoriteExcluded() async throws {
        let station = try #require(DemoData.stations.first { $0.id == "ocm:279460" })
        let favorite = FavoriteStation(userID: "user-1", stationID: station.id, stationSnapshot: station, createdAt: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let favoriteResponse = try encoder.encode([favorite])
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            if path == "/rest/v1/favorite_stations" { return (200, favoriteResponse) }
            if path == "/functions/v1/stations" {
                return (200, Data(#"{"stations":[],"catalogImportReport":{"fetched":1,"included":0,"private":1,"invalid":0,"license":0,"providerIDsNeedingReview":[],"excludedIDs":{"private":[279460],"invalid":[],"license":[]}}}"#.utf8))
            }
            return (200, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.favorites.count == 1)
        #expect(store.favoriteStations.isEmpty)
        await store.signOut()
    }

    @Test("A revoked private site disappears from Saved and CarPlay without a cached coordinate")
    @MainActor func revokedPrivateFavorite() async throws {
        let privateStation = ChargingStation(
            id: "private:site-1", name: "Workplace depot", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .ownerProvided, access: .privateAccess
        )
        let encoder = JSONEncoder()
        let profile = VehicleProfile(userID: "user-1", name: "City EV", connectors: [.type2], minimumPowerKW: nil)
        let profileResponse = try encoder.encode([profile])
        let visibleStations = Data(#"{"stations":"#.utf8) + (try encoder.encode([privateStation])) + Data("}".utf8)
        let stationRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/favorite_stations", "GET"):
                return (200, Data("[]".utf8))
            case ("/rest/v1/favorite_stations", "POST"):
                return (204, Data())
            case ("/rest/v1/vehicle_profiles", "GET"):
                return (200, profileResponse)
            case ("/functions/v1/stations", _):
                stationRequests.increment()
                return (200, stationRequests.value == 1 ? visibleStations : Data(#"{"stations":[]}"#.utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.compatibleStations.map(\.id) == [privateStation.id])
        #expect(CarPlaySnapshotStore.load().stations.isEmpty)
        #expect(store.favoriteStations.isEmpty)
        await store.toggleFavorite(privateStation)
        #expect(store.favoriteStations.map(\.id) == [privateStation.id])
        let favorite = try #require(store.favorites.first)
        let savedObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(favorite)) as? [String: Any])
        #expect(savedObject["station_snapshot"] is NSNull)

        await store.refreshStations()
        #expect(store.compatibleStations.isEmpty)
        #expect(store.favoriteStations.isEmpty)
        #expect(CarPlaySnapshotStore.load().stations.isEmpty)
        #expect(CarPlaySnapshotStore.load().favoriteStationIDs.isEmpty)
        await store.signOut()
    }

    @Test("Saved aliases use current catalog facts and remove their original favorite IDs")
    @MainActor func mergedFavoriteAliases() async throws {
        func station(_ id: String, name: String, source: StationSource) -> ChargingStation {
            ChargingStation(
                id: id, name: name, address: "Kuala Lumpur",
                coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
                connectors: [Connector(kind: .ccs2, powerKW: 120, count: 2)],
                availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
                price: nil, source: source
            )
        }

        var current = station("gentari-site", name: "Current catalog", source: .gentari)
        current.sourceIDs = ["gentari": "gentari-site", "openChargeMap": "ocm:42", "mevnet": "7"]
        let oldOCM = station("ocm:42", name: "Old directory", source: .openChargeMap)
        let oldMEVnet = station("mevnet:7", name: "Old planning site", source: .mevnet)
        let legacy = station("legacy-site", name: "Saved partner snapshot", source: .gentari)
        let missingPrivate = station("private:gone", name: "Private snapshot", source: .ownerProvided)
        let favorites = [oldOCM, legacy, oldMEVnet, missingPrivate].map {
            FavoriteStation(userID: "user-1", stationID: $0.id, stationSnapshot: $0, createdAt: nil)
        }
        let encoder = JSONEncoder()
        let favoriteResponse = try encoder.encode(favorites)
        let catalog = try encoder.encode([current, station("gentari-site", name: "Later duplicate", source: .gentari)])
        let stationResponse = Data(#"{"stations":"#.utf8) + catalog + Data("}".utf8)
        let deletedOCM = LockedCounter()
        let deletedMEVnet = LockedCounter()
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/favorite_stations", "GET"):
                return (200, favoriteResponse)
            case ("/functions/v1/stations", _):
                return (200, stationResponse)
            case ("/rest/v1/favorite_stations", "DELETE"):
                let stationID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "station_id" }?.value
                switch stationID {
                case "eq.ocm:42": deletedOCM.increment()
                case "eq.mevnet:7": deletedMEVnet.increment()
                default: return (400, Data(#"{"message":"Unexpected favorite ID"}"#.utf8))
                }
                return (204, Data())
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.favoriteStations == [current, legacy])
        #expect(store.favoriteStationIDs.contains("gentari-site"))
        #expect(store.favoriteStationIDs.contains("ocm:42"))
        #expect(store.favoriteStationIDs.contains("mevnet:7"))

        await store.toggleFavorite(current)
        #expect(store.favorites.map(\.stationID) == ["legacy-site", "private:gone"])
        #expect(store.favoriteStations == [legacy])
        #expect(store.favoriteStationIDs.contains("gentari-site") == false)
        #expect(deletedOCM.value == 1)
        #expect(deletedMEVnet.value == 1)
        await store.signOut()
    }

    @Test("A failed alias deletion reconciles with server state", .serialized, arguments: FavoriteDeleteScenario.allCases)
    @MainActor func partialFavoriteAliasDeletion(scenario: FavoriteDeleteScenario) async throws {
        func station(_ id: String, source: StationSource) -> ChargingStation {
            ChargingStation(
                id: id, name: "Shared charging site", address: "Kuala Lumpur",
                coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Gentari",
                connectors: [Connector(kind: .ccs2, powerKW: 120, count: 2)],
                availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
                price: nil, source: source
            )
        }

        var current = station("gentari-site", source: .gentari)
        current.sourceIDs = ["gentari": "gentari-site", "openChargeMap": "ocm:42", "mevnet": "7"]
        let oldMEVnet = station("mevnet:7", source: .mevnet)
        let oldOCM = station("ocm:42", source: .openChargeMap)
        let favorites = [oldMEVnet, oldOCM].map {
            FavoriteStation(userID: "user-1", stationID: $0.id, stationSnapshot: $0, createdAt: nil)
        }
        let profile = VehicleProfile(userID: "user-1", name: "Daily EV", connectors: [.ccs2], minimumPowerKW: nil)
        let encoder = JSONEncoder()
        let favoriteResponse = try encoder.encode(favorites)
        let remainingFavoriteResponse = try encoder.encode([favorites[1]])
        let profileResponse = try encoder.encode([profile])
        let stationResponse = Data(#"{"stations":"#.utf8) + (try encoder.encode([current])) + Data("}".utf8)
        let deleteRequests = LockedCounter()
        let firstDeletedURL = LockedURL()
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/vehicle_profiles", "GET"):
                return (200, profileResponse)
            case ("/rest/v1/favorite_stations", "GET"):
                guard deleteRequests.value >= 2 else { return (200, favoriteResponse) }
                switch scenario {
                case .secondDeleteNotCommitted: return (200, remainingFavoriteResponse)
                case .responseLostAfterCommit: return (200, Data("[]".utf8))
                case .reconciliationUnavailable: return (503, Data(#"{"message":"Read failed"}"#.utf8))
                }
            case ("/functions/v1/stations", _):
                return (200, stationResponse)
            case ("/rest/v1/favorite_stations", "DELETE"):
                deleteRequests.increment()
                if deleteRequests.value == 1 {
                    firstDeletedURL.set(request.url)
                    return (204, Data())
                }
                return deleteRequests.value == 2
                    ? (503, Data(#"{"message":"Delete failed"}"#.utf8))
                    : (204, Data())
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.favorites.count == 2)

        await store.toggleFavorite(current)
        let firstDeleted = try #require(firstDeletedURL.value)
        let deletedQuery = try #require(URLComponents(url: firstDeleted, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "station_id" })?.value)
        let deletedID = String(deletedQuery.dropFirst(3))
        #expect(deletedID == "mevnet:7")
        #expect(deleteRequests.value == 2)
        switch scenario {
        case .secondDeleteNotCommitted:
            #expect(store.favorites.map(\.stationID) == ["ocm:42"])
            #expect(store.favoriteStationIDs.contains("mevnet:7") == false)
            #expect(store.favoriteStationIDs.contains(current.id))
            #expect(CarPlaySnapshotStore.load().favoriteStationIDs == [current.id])
            await store.toggleFavorite(current)
            #expect(deleteRequests.value == 3)
            #expect(store.favorites.isEmpty)
            #expect(CarPlaySnapshotStore.load().favoriteStationIDs.isEmpty)
        case .responseLostAfterCommit:
            #expect(store.favorites.isEmpty)
            #expect(store.favoriteStationIDs.isEmpty)
            #expect(CarPlaySnapshotStore.load().favoriteStationIDs.isEmpty)
            #expect(store.errorMessage == nil)
            #expect(store.noticeMessage == "Saved charger removed; confirmation was interrupted.")
        case .reconciliationUnavailable:
            #expect(store.favorites.map(\.stationID) == ["mevnet:7", "ocm:42"])
            #expect(store.favoriteStationIDs.contains(current.id))
            #expect(CarPlaySnapshotStore.load().favoriteStationIDs == [current.id])
            #expect(store.accountDataNeedsRetry)
            #expect(store.errorMessage == "Saved chargers could not be verified. Reload account data to check them.")
        }
        await store.signOut()
    }

    @Test("Rapid save taps keep one favorite request in flight")
    @MainActor func favoriteSaveIsSingleFlight() async throws {
        let station = favoriteStation()
        let posts = LockedCounter()
        let deletes = LockedCounter()
        let releaseSave = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/favorite_stations", "POST"):
                posts.increment()
                if posts.value == 1 { _ = releaseSave.wait(timeout: .now() + 10) }
                return (204, Data())
            case ("/rest/v1/favorite_stations", "DELETE"):
                deletes.increment()
                return (204, Data())
            case ("/functions/v1/stations", _):
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer {
            releaseSave.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let firstTap = Task { await store.toggleFavorite(station) }
        try await waitForRequest(posts)
        #expect(store.favoriteMutationIDs.contains(station.id))
        let secondTap = Task { await store.toggleFavorite(station) }
        await secondTap.value
        #expect(posts.value == 1)
        #expect(deletes.value == 0)
        releaseSave.signal()
        await firstTap.value
        #expect(store.favoriteMutationIDs.isEmpty)
        #expect(store.favoriteStationIDs.contains(station.id))
        await store.signOut()
    }

    @Test("Rapid remove taps keep one favorite deletion in flight")
    @MainActor func favoriteDeleteIsSingleFlight() async throws {
        let station = favoriteStation()
        let saved = FavoriteStation(userID: "user-1", stationID: station.id, stationSnapshot: station, createdAt: nil)
        let savedResponse = try JSONEncoder().encode([saved])
        let posts = LockedCounter()
        let deletes = LockedCounter()
        let releaseDelete = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/favorite_stations", "GET"):
                return (200, savedResponse)
            case ("/rest/v1/favorite_stations", "POST"):
                posts.increment()
                return (204, Data())
            case ("/rest/v1/favorite_stations", "DELETE"):
                deletes.increment()
                if deletes.value == 1 { _ = releaseDelete.wait(timeout: .now() + 10) }
                return (204, Data())
            case ("/functions/v1/stations", _):
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer {
            releaseDelete.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.favoriteStationIDs.contains(station.id))
        let firstTap = Task { await store.toggleFavorite(station) }
        try await waitForRequest(deletes)
        #expect(store.favoriteMutationIDs.contains(station.id))
        let secondTap = Task { await store.toggleFavorite(station) }
        await secondTap.value
        #expect(deletes.value == 1)
        #expect(posts.value == 0)
        releaseDelete.signal()
        await firstTap.value
        #expect(store.favoriteMutationIDs.isEmpty)
        #expect(store.favoriteStationIDs.contains(station.id) == false)
        await store.signOut()
    }

    @Test("A failed save does not discard another charger's concurrent success")
    @MainActor func favoriteMutationsRemainPerStation() async throws {
        let first = favoriteStation(id: "gentari-first")
        let second = favoriteStation(id: "gentari-second")
        let firstPosts = LockedCounter()
        let secondPosts = LockedCounter()
        let releaseFirst = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/favorite_stations", "POST"):
                let body = String(decoding: MockURLProtocol.bodyData(for: request), as: UTF8.self)
                if body.contains(first.id) {
                    firstPosts.increment()
                    _ = releaseFirst.wait(timeout: .now() + 10)
                    return (503, Data(#"{"message":"Save failed"}"#.utf8))
                }
                if body.contains(second.id) {
                    secondPosts.increment()
                    return (204, Data())
                }
                return (400, Data(#"{"message":"Unknown favorite"}"#.utf8))
            case ("/functions/v1/stations", _):
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer {
            releaseFirst.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let firstTap = Task { await store.toggleFavorite(first) }
        try await waitForRequest(firstPosts)
        #expect(store.favoriteMutationIDs == [first.id])
        let secondTap = Task { await store.toggleFavorite(second) }
        try await waitForRequest(secondPosts)
        await secondTap.value
        #expect(store.favoriteMutationIDs == [first.id])
        #expect(store.favoriteStationIDs.contains(second.id))
        releaseFirst.signal()
        await firstTap.value
        #expect(store.favoriteMutationIDs.isEmpty)
        #expect(store.favoriteStationIDs.contains(first.id) == false)
        #expect(store.favoriteStationIDs.contains(second.id))
        #expect(store.errorMessage == "Save failed")
        await store.signOut()
    }

    @Test("Failed favorite removal reconciles its site without discarding another pending save")
    @MainActor func failedFavoriteRemovalPreservesOtherMutation() async throws {
        let removing = favoriteStation(id: "gentari-removing")
        let saving = favoriteStation(id: "gentari-saving")
        let saved = FavoriteStation(userID: "user-1", stationID: removing.id, stationSnapshot: removing, createdAt: nil)
        let savedResponse = try JSONEncoder().encode([saved])
        let deletes = LockedCounter()
        let posts = LockedCounter()
        let releaseDelete = DispatchSemaphore(value: 0)
        let releaseSave = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/favorite_stations", "GET"):
                return (200, savedResponse)
            case ("/rest/v1/favorite_stations", "DELETE"):
                deletes.increment()
                _ = releaseDelete.wait(timeout: .now() + 10)
                return (503, Data(#"{"message":"Delete failed"}"#.utf8))
            case ("/rest/v1/favorite_stations", "POST"):
                posts.increment()
                _ = releaseSave.wait(timeout: .now() + 10)
                return (204, Data())
            case ("/functions/v1/stations", _):
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer {
            releaseDelete.signal()
            releaseSave.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let removeTap = Task { await store.toggleFavorite(removing) }
        try await waitForRequest(deletes)
        let saveTap = Task { await store.toggleFavorite(saving) }
        try await waitForRequest(posts)
        #expect(store.favoriteMutationIDs == [removing.id, saving.id])

        releaseDelete.signal()
        await removeTap.value
        #expect(store.favoriteMutationIDs == [saving.id])
        #expect(store.favoriteStationIDs.contains(removing.id))
        #expect(store.favoriteStationIDs.contains(saving.id))
        #expect(store.errorMessage == "Delete failed")

        releaseSave.signal()
        await saveTap.value
        #expect(store.favoriteMutationIDs.isEmpty)
        #expect(store.favoriteStationIDs.contains(removing.id))
        #expect(store.favoriteStationIDs.contains(saving.id))
        await store.signOut()
    }

    @Test("An old account's favorite completion cannot clear a new account's busy marker")
    @MainActor func favoriteBusyStateSurvivesAccountSwitch() async throws {
        let station = favoriteStation()
        let oldPosts = LockedCounter()
        let newPosts = LockedCounter()
        let authRequests = LockedCounter()
        let releaseOld = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                authRequests.increment()
                let user = authRequests.value == 1 ? "user-1" : "user-2"
                let token = authRequests.value == 1 ? "old-token" : "new-token"
                return (200, Data(#"{"access_token":"\#(token)","refresh_token":"refresh","user":{"id":"\#(user)","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/favorite_stations", "POST"):
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" {
                    oldPosts.increment()
                    _ = releaseOld.wait(timeout: .now() + 10)
                } else {
                    newPosts.increment()
                    _ = releaseNew.wait(timeout: .now() + 10)
                }
                return (204, Data())
            case ("/functions/v1/stations", _):
                return (200, Data(#"{"stations":[]}"#.utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer {
            releaseOld.signal()
            releaseNew.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "old@example.com", password: "password-123")
        let oldTap = Task { await store.toggleFavorite(station) }
        try await waitForRequest(oldPosts)
        #expect(store.favoriteMutationIDs.contains(station.id))
        await store.signOut()
        #expect(store.favoriteMutationIDs.isEmpty)

        await store.signIn(email: "new@example.com", password: "password-123")
        let newTap = Task { await store.toggleFavorite(station) }
        try await waitForRequest(newPosts)
        #expect(store.favoriteMutationIDs.contains(station.id))
        releaseOld.signal()
        await oldTap.value
        #expect(store.favoriteMutationIDs.contains(station.id))
        releaseNew.signal()
        await newTap.value
        #expect(store.favoriteMutationIDs.isEmpty)
        #expect(store.favorites.first?.userID == "user-2")
        await store.signOut()
    }

    @Test("Private charger creation requires authenticated owner-consent RPC")
    func privateSiteCreationRPC() async throws {
        let station = ChargingStation(
            id: "owner-site", name: "Home charger", address: "Petaling Jaya",
            coordinate: Coordinate(latitude: 3.1, longitude: 101.6), operatorName: "Owner supplied",
            connectors: [Connector(kind: .type2, powerKW: 11, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .ownerProvided, sourceAttribution: "Owner supplied"
        )
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let client = makeClient(account: "test-\(UUID().uuidString)")
        MockURLProtocol.handler = { request in
            if request.url?.path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"caller-token","refresh_token":"refresh","user":{"id":"user-1","email":"owner@example.com"}}"#.utf8))
            }
            #expect(request.url?.path == "/rest/v1/rpc/create_private_charger_site")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer caller-token")
            let body = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: request)) as? [String: Any]
            #expect(body?["p_id"] as? String == id.uuidString)
            #expect(body?["p_owner_consent"] as? Bool == true)
            #expect(body?["p_invited_email"] as? String == "guest@example.com")
            let submittedStation = body?["p_station"] as? [String: Any]
            #expect(submittedStation?["id"] as? String == "owner-site")
            #expect(submittedStation?["source"] as? String == "ownerProvided")
            return (200, Data("\"\(id.uuidString)\"".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let session = try await client.signIn(email: "owner@example.com", password: "password-123")
        try await client.createPrivateSite(
            id: id, station: station, invitedEmail: "guest@example.com",
            session: session
        )
        try await client.signOut()
    }

    @Test("Saving a private favorite POSTs its ID with an explicit null snapshot")
    func privateFavoriteRequest() async throws {
        let privateStation = ChargingStation(
            id: "private:site-1", name: "Workplace depot", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .ownerProvided, access: .privateAccess
        )
        let postCount = LockedCounter()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/auth/v1/token" {
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            }
            #expect(request.url?.path == "/rest/v1/favorite_stations")
            #expect(request.httpMethod == "POST")
            let body = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: request)) as? [String: Any]
            #expect(body?["station_id"] as? String == privateStation.id)
            #expect(body?["station_snapshot"] is NSNull)
            postCount.increment()
            return (204, Data())
        }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let session = try await client.signIn(email: "driver@example.com", password: "password-123")
        try await client.saveFavorite(privateStation, session: session)
        #expect(postCount.value == 1)
        try await client.signOut()
    }

    @Test("Private access favorites keep coordinates out of optimistic state, requests, and CarPlay")
    @MainActor func privateAccessFavoriteThroughStore() async throws {
        let station = ChargingStation(
            id: "site-private-access", name: "Private depot", address: "Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.14, longitude: 101.68), operatorName: "Workplace",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1)],
            availability: Availability(state: .unknown, availableConnectors: nil,
                                       totalConnectors: nil, lastUpdated: nil),
            price: nil, access: .privateAccess
        )
        let profile = VehicleProfile(userID: "user-1", name: "City EV",
                                     connectors: [.type2], minimumPowerKW: nil)
        let encoder = JSONEncoder()
        let profiles = try encoder.encode([profile])
        let preference = try encoder.encode([ActiveVehiclePreference(userID: "user-1", activeVehicleID: profile.id)])
        let stations = Data(#"{"stations":"#.utf8) + (try encoder.encode([station])) + Data("}".utf8)
        let postedFavorite = Mutex<Data?>(nil)
        MockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/auth/v1/token", _):
                return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
            case ("/rest/v1/vehicle_profiles", "GET"):
                return (200, profiles)
            case ("/rest/v1/user_preferences", "GET"):
                return (200, preference)
            case ("/rest/v1/favorite_stations", "GET"):
                return (200, Data("[]".utf8))
            case ("/rest/v1/favorite_stations", "POST"):
                postedFavorite.withLock { $0 = MockURLProtocol.bodyData(for: request) }
                return (204, Data())
            case ("/functions/v1/stations", _):
                return (200, stations)
            default:
                return (200, Data("[]".utf8))
            }
        }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.compatibleStations.map(\.id) == [station.id])
        #expect(CarPlaySnapshotStore.load().stations.isEmpty)

        await store.toggleFavorite(station)
        #expect(store.favorites.first?.stationSnapshot == nil)
        #expect(store.favoriteStations.map(\.id) == [station.id])
        #expect(CarPlaySnapshotStore.load().stations.isEmpty)
        let body = try #require(postedFavorite.withLock { $0 })
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["station_id"] as? String == station.id)
        #expect(object["station_snapshot"] is NSNull)
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

    @Test("A sign-in response arriving after sign-out cannot save a session")
    func lateSignInAfterSignOut() async throws {
        let authRequests = LockedCounter()
        let releaseSignIn = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            guard request.url?.path == "/auth/v1/token" else { return (404, Data()) }
            authRequests.increment()
            releaseSignIn.wait()
            return (200, Data(#"{"access_token":"late","refresh_token":"late-refresh","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
        }
        defer {
            releaseSignIn.signal()
            MockURLProtocol.handler = nil
        }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let signIn = Task { try await client.signIn(email: "driver@example.com", password: "password-123") }
        for _ in 0..<100 where authRequests.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(authRequests.value == 1)
        try await client.signOut()
        releaseSignIn.signal()
        do {
            _ = try await signIn.value
            Issue.record("A signed-out account accepted a late sign-in response")
        } catch {
            #expect(error as? BackendError == .missingSession)
        }
        let restored = try await client.restoreSession()
        #expect(restored == nil)
    }

    @Test("Charger catalog request sends no vehicle or location filters")
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
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.isEmpty)
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
            if path == "/rest/v1/vehicle_profiles", request.httpMethod == "GET" {
                return (200, Data(#"[{"id":"00000000-0000-0000-0000-000000000041","user_id":"user-1","name":"Existing EV","connectors":["type2"],"minimum_power_kw":null}]"#.utf8))
            }
            if path == "/rest/v1/user_preferences", request.httpMethod == "GET" {
                return (200, Data(#"[{"user_id":"user-1","active_vehicle_id":"00000000-0000-0000-0000-000000000041"}]"#.utf8))
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
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100, name: "Renamed EV")
        #expect(!saved)
        #expect(store.profile == previous)
        #expect(store.vehicles.first?.name == "Existing EV")
        #expect(store.lastSuccessfulStationFetchAt == previousFetchAt)
        #expect(store.accountDataNeedsRetry == false)
        #expect(store.errorMessage == "Save failed")
        CarPlaySnapshotStore.save(stations: [DemoData.stations[0]], favoriteStationIDs: [])
        await store.signOut()
        #expect(CarPlaySnapshotStore.load().stations.isEmpty)
    }

    @Test("A vehicle saved before active selection fails is reconciled and retried with one ID")
    @MainActor func partialVehicleSaveUsesStableID() async throws {
        let vehicleID = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
        let server = VehicleMockServer(failingPreferenceResponses: 1)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.vehicles.isEmpty)
        #expect(store.activeVehicleID == nil)

        let firstSave = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100,
                                                name: "Highway EV", vehicleID: vehicleID, createsNew: true)
        let afterFailure = server.snapshot
        #expect(firstSave == false)
        #expect(afterFailure.profiles.map(\.id) == [vehicleID])
        #expect(afterFailure.profilePostIDs == [vehicleID])
        #expect(afterFailure.preferencePostIDs == [vehicleID])
        #expect(store.vehicles.map(\.id) == [vehicleID])
        #expect(store.activeVehicleID == nil)
        #expect(store.profile.connectors.isEmpty)
        #expect(store.errorMessage == "Vehicle saved, but active selection was not confirmed. Retry Save to select it.")
        #expect(store.accountDataNeedsRetry == false)
        #expect(afterFailure.stationRequests == 1, "Reconciliation must not reload the charger catalog")

        let secondSave = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100,
                                                 name: "Highway EV", vehicleID: vehicleID, createsNew: true)
        let afterRetry = server.snapshot
        #expect(secondSave)
        #expect(afterRetry.profiles.map(\.id) == [vehicleID])
        #expect(afterRetry.profilePostIDs == [vehicleID, vehicleID])
        #expect(afterRetry.preferencePostIDs == [vehicleID, vehicleID])
        #expect(afterRetry.stationRequests == 1)
        #expect(store.activeVehicleID == vehicleID)
        #expect(store.profile.id == vehicleID)
        await store.signOut()
    }

    @Test("A failed new-vehicle selection leaves the prior active vehicle selected")
    @MainActor func partialVehicleSavePreservesPriorSelection() async throws {
        let prior = VehicleProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000052")!, userID: "user-1",
                                   name: "Daily EV", connectors: [.type2], minimumPowerKW: nil)
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000053")!
        let server = VehicleMockServer(profiles: [prior], activeVehicleID: prior.id, failingPreferenceResponses: 1)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 80,
                                            name: "Road EV", vehicleID: newID, createsNew: true)
        #expect(saved == false)
        #expect(store.vehicles.map(\.id).contains(newID))
        #expect(store.activeVehicleID == prior.id)
        #expect(store.profile == prior)
        #expect(server.snapshot.stationRequests == 1)
        await store.signOut()
    }

    @Test("A lost active-selection response is acknowledged after the server confirms it")
    @MainActor func committedVehiclePreferenceResponseLost() async throws {
        let vehicleID = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
        let server = VehicleMockServer(committingPreferenceResponseFailures: 1)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                            name: "Confirmed EV", vehicleID: vehicleID, createsNew: true)
        #expect(saved)
        #expect(server.snapshot.profiles.map(\.id) == [vehicleID])
        #expect(store.activeVehicleID == vehicleID)
        #expect(store.profile.id == vehicleID)
        #expect(store.errorMessage == nil)
        #expect(store.noticeMessage == "Vehicle saved. Active selection was confirmed after reloading.")
        await store.signOut()
    }

    @Test("A failed vehicle reconciliation requests account sync without claiming the remote profile")
    @MainActor func failedVehicleReconciliationNeedsAccountRetry() async throws {
        let vehicleID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
        let server = VehicleMockServer(failingPreferenceResponses: 1, failingReconciliationReads: 1)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                            name: "Unverified EV", vehicleID: vehicleID, createsNew: true)
        #expect(saved == false)
        #expect(server.snapshot.profiles.map(\.id) == [vehicleID])
        #expect(store.vehicles.isEmpty)
        #expect(store.activeVehicleID == nil)
        #expect(store.accountDataNeedsRetry)
        #expect(store.errorMessage == "Vehicle saved, but account data could not be verified. Retry account sync before continuing.")
        #expect(server.snapshot.stationRequests == 1)

        await store.retryAccountData()
        #expect(store.accountDataNeedsRetry == false)
        #expect(store.vehicles.map(\.id) == [vehicleID])
        #expect(store.activeVehicleID == nil)
        await store.signOut()
    }

    @Test("Vehicle reconciliation does not dismiss an unrelated saved-charger sync warning")
    @MainActor func vehicleReconciliationPreservesFavoriteRetry() async throws {
        let vehicleID = UUID(uuidString: "00000000-0000-0000-0000-000000000062")!
        let server = VehicleMockServer(failingPreferenceResponses: 1, failingFavoriteReads: 1)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        #expect(store.accountDataNeedsRetry)
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                            name: "New EV", vehicleID: vehicleID, createsNew: true)
        #expect(saved == false)
        #expect(store.vehicles.map(\.id) == [vehicleID])
        #expect(store.activeVehicleID == nil)
        #expect(store.accountDataNeedsRetry, "Vehicle reads cannot confirm saved-charger state")
        let retrySaved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                                 name: "New EV", vehicleID: vehicleID, createsNew: true)
        #expect(retrySaved)
        #expect(store.activeVehicleID == vehicleID)
        #expect(store.accountDataNeedsRetry, "A confirmed vehicle save cannot clear the unrelated saved-charger warning")
        await store.signOut()
    }

    @Test("A null preference never becomes a confirmed active vehicle after bootstrap")
    @MainActor func nilVehiclePreferenceSurvivesRestart() async throws {
        let unselected = VehicleProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000054")!, userID: "user-1",
                                        name: "Unselected EV", connectors: [.ccs2], minimumPowerKW: nil)
        let server = VehicleMockServer(profiles: [unselected], activeVehicleID: nil)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let client = makeClient(account: "test-\(UUID().uuidString)")
        let firstStore = VoltWayStore(configuration: configuration, backend: client)
        await firstStore.signIn(email: "driver@example.com", password: "password-123")
        #expect(firstStore.vehicles.map(\.id) == [unselected.id])
        #expect(firstStore.activeVehicleID == nil)
        #expect(firstStore.profile.connectors.isEmpty)

        let restoredStore = VoltWayStore(configuration: configuration, backend: client)
        await restoredStore.bootstrap()
        #expect(restoredStore.vehicles.map(\.id) == [unselected.id])
        #expect(restoredStore.activeVehicleID == nil)
        #expect(restoredStore.profile.connectors.isEmpty)
        await restoredStore.signOut()
    }

    @Test("A lost profile-save response can be retried without creating another vehicle")
    @MainActor func lostProfileResponseRetryUsesStableID() async throws {
        let vehicleID = UUID(uuidString: "00000000-0000-0000-0000-000000000055")!
        let server = VehicleMockServer(failingProfileResponses: 1)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let firstSave = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                                name: "Retry EV", vehicleID: vehicleID, createsNew: true)
        #expect(firstSave == false)
        #expect(server.snapshot.profiles.map(\.id) == [vehicleID])
        #expect(store.accountDataNeedsRetry)
        #expect(store.errorMessage == "Vehicle save was not confirmed. Retry Save or sync account data to check it.")

        let secondSave = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                                 name: "Retry EV", vehicleID: vehicleID, createsNew: true)
        let afterRetry = server.snapshot
        #expect(secondSave)
        #expect(afterRetry.profiles.map(\.id) == [vehicleID])
        #expect(afterRetry.profilePostIDs == [vehicleID, vehicleID])
        #expect(afterRetry.preferencePostIDs == [vehicleID])
        #expect(store.activeVehicleID == vehicleID)
        #expect(store.accountDataNeedsRetry == false, "A confirmed retry resolves its own vehicle-sync warning")
        await store.signOut()
    }

    @Test("A lost create response can be recovered by account sync if the form is dismissed")
    @MainActor func lostVehicleResponseCanRecoverWithoutRetryingForm() async throws {
        let vehicleID = UUID(uuidString: "00000000-0000-0000-0000-000000000063")!
        let server = VehicleMockServer(failingProfileResponses: 1)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                            name: "Recovered EV", vehicleID: vehicleID, createsNew: true)
        #expect(saved == false)
        #expect(store.accountDataNeedsRetry)
        #expect(store.vehicles.isEmpty)
        #expect(server.snapshot.profilePostIDs == [vehicleID])
        #expect(server.snapshot.preferencePostIDs.isEmpty)
        #expect(server.snapshot.stationRequests == 1, "The failed create must not reload the charger catalog")

        await store.retryAccountData()
        #expect(store.accountDataNeedsRetry == false)
        #expect(store.vehicles.map(\.id) == [vehicleID])
        #expect(store.activeVehicleID == nil)
        #expect(server.snapshot.preferencePostIDs.isEmpty)
        await store.signOut()
    }

    @Test("Editing a vehicle removed from the current account never creates a replacement")
    @MainActor func staleVehicleEditIsRejected() async throws {
        let prior = VehicleProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000056")!, userID: "user-1",
                                   name: "Current EV", connectors: [.type2], minimumPowerKW: nil)
        let removedID = UUID(uuidString: "00000000-0000-0000-0000-000000000057")!
        let server = VehicleMockServer(profiles: [prior], activeVehicleID: prior.id)
        MockURLProtocol.handler = { server.respond(to: $0) }
        defer { MockURLProtocol.handler = nil }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let saved = await store.saveProfile(connectors: [.ccs2], minimumPowerKW: 100,
                                            name: "Removed EV", vehicleID: removedID)
        #expect(saved == false)
        #expect(server.snapshot.profilePostIDs.isEmpty)
        #expect(store.vehicles.map(\.id) == [prior.id])
        #expect(store.activeVehicleID == prior.id)
        #expect(store.errorMessage == "This vehicle is no longer in your account. Refresh account data and try again.")
        await store.signOut()
    }

    @Test("A stale profile save cannot send active selection after the account session changes")
    @MainActor func accountChangeBeforeVehiclePreferenceWrite() async throws {
        let profilePosts = LockedCounter()
        let releaseProfile = DispatchSemaphore(value: 0)
        let server = VehicleMockServer()
        let authRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/auth/v1/token" {
                authRequests.increment()
                let access = authRequests.value == 1 ? "first" : "second"
                return (200, Data("{\"access_token\":\"\(access)\",\"refresh_token\":\"refresh-1\",\"user\":{\"id\":\"user-1\",\"email\":\"driver@example.com\"}}".utf8))
            }
            if request.url?.path == "/rest/v1/vehicle_profiles", request.httpMethod == "POST" {
                profilePosts.increment()
                _ = releaseProfile.wait(timeout: .now() + 10)
            }
            return server.respond(to: request)
        }
        defer {
            releaseProfile.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let pendingSave = Task {
            await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                    name: "Old session EV", vehicleID: UUID(), createsNew: true)
        }
        try await waitForRequest(profilePosts)
        await store.signOut()
        await store.signIn(email: "driver@example.com", password: "password-123")
        releaseProfile.signal()
        let saved = await pendingSave.value
        #expect(saved == false)
        #expect(server.snapshot.preferencePostIDs.isEmpty)
        #expect(store.session?.accessToken == "second")
        #expect(store.activeVehicleID == nil)
        await store.signOut()
    }

    @Test("An old account's reconciliation cannot overwrite the newly signed-in account")
    @MainActor func accountChangeDuringVehicleReconciliation() async throws {
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000058")!
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000059")!
        let oldVehicle = VehicleProfile(id: oldID, userID: "user-1", name: "Old account EV",
                                        connectors: [.ccs2], minimumPowerKW: nil)
        let newVehicle = VehicleProfile(id: newID, userID: "user-2", name: "New account EV",
                                        connectors: [.type2], minimumPowerKW: nil)
        let oldProfiles = try JSONEncoder().encode([oldVehicle])
        let newProfiles = try JSONEncoder().encode([newVehicle])
        let newPreference = try JSONEncoder().encode([ActiveVehiclePreference(userID: "user-2", activeVehicleID: newID)])
        let authRequests = LockedCounter()
        let oldProfileReads = LockedCounter()
        let releaseOldRead = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let userFilter = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "user_id" })?.value
            if path == "/auth/v1/token" {
                authRequests.increment()
                let user = authRequests.value == 1 ? "user-1" : "user-2"
                return (200, Data("{\"access_token\":\"\(user)\",\"refresh_token\":\"refresh-1\",\"user\":{\"id\":\"\(user)\",\"email\":\"driver@example.com\"}}".utf8))
            }
            if path == "/rest/v1/vehicle_profiles", request.httpMethod == "GET" {
                if userFilter == "eq.user-1" {
                    oldProfileReads.increment()
                    if oldProfileReads.value == 1 { return (200, Data("[]".utf8)) }
                    _ = releaseOldRead.wait(timeout: .now() + 10)
                    return (200, oldProfiles)
                }
                return (200, newProfiles)
            }
            if path == "/rest/v1/vehicle_profiles", request.httpMethod == "POST" { return (204, Data()) }
            if path == "/rest/v1/user_preferences", request.httpMethod == "GET" {
                return userFilter == "eq.user-1" ? (200, Data("[]".utf8)) : (200, newPreference)
            }
            if path == "/rest/v1/user_preferences", request.httpMethod == "POST" {
                return (503, Data(#"{"message":"Selection failed"}"#.utf8))
            }
            if path == "/functions/v1/stations" { return (200, Data(#"{"stations":[]}"#.utf8)) }
            if path == "/rest/v1/favorite_stations" { return (200, Data("[]".utf8)) }
            return (404, Data())
        }
        defer {
            releaseOldRead.signal()
            MockURLProtocol.handler = nil
        }

        let store = VoltWayStore(configuration: configuration, backend: makeClient(account: "test-\(UUID().uuidString)"))
        await store.signIn(email: "driver@example.com", password: "password-123")
        let oldSave = Task {
            await store.saveProfile(connectors: [.ccs2], minimumPowerKW: nil,
                                    name: oldVehicle.name, vehicleID: oldID, createsNew: true)
        }
        try await waitForRequest(oldProfileReads, count: 2)
        await store.signOut()
        await store.signIn(email: "driver@example.com", password: "password-123")
        releaseOldRead.signal()
        #expect(await oldSave.value == false)
        #expect(store.session?.userID == "user-2")
        #expect(store.vehicles.map(\.id) == [newID])
        #expect(store.activeVehicleID == newID)
        #expect(store.profile.id == newID)
        await store.signOut()
    }

    private func makeClient(account: String) -> BackendClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        return BackendClient(configuration: configuration, urlSession: URLSession(configuration: sessionConfiguration),
                             credentialAccount: account, credentialStore: InMemoryCredentialStore())
    }
}

private final class InMemoryCredentialStore: SessionCredentialStore {
    private let stored = Mutex<[String: Data]>([:])

    func read(account: String) throws -> Data? {
        stored.withLock { $0[account] }
    }

    func save(_ data: Data, account: String) throws {
        stored.withLock { $0[account] = data }
    }

    func delete(account: String) throws {
        stored.withLock { _ = $0.removeValue(forKey: account) }
    }
}

private struct VehicleMockState: Sendable {
    var profiles: [VehicleProfile]
    var activeVehicleID: UUID?
    var profilePostIDs: [UUID] = []
    var preferencePostIDs: [UUID?] = []
    var stationRequests = 0
    var failingProfileResponses: Int
    var failingPreferenceResponses: Int
    var committingPreferenceResponseFailures: Int
    var failingReconciliationReads: Int
    var failingFavoriteReads: Int
}

private final class VehicleMockServer: Sendable {
    private let state: Mutex<VehicleMockState>

    init(profiles: [VehicleProfile] = [], activeVehicleID: UUID? = nil,
         failingProfileResponses: Int = 0, failingPreferenceResponses: Int = 0,
         committingPreferenceResponseFailures: Int = 0, failingReconciliationReads: Int = 0,
         failingFavoriteReads: Int = 0) {
        state = Mutex(VehicleMockState(profiles: profiles, activeVehicleID: activeVehicleID,
                                       failingProfileResponses: failingProfileResponses,
                                       failingPreferenceResponses: failingPreferenceResponses,
                                       committingPreferenceResponseFailures: committingPreferenceResponseFailures,
                                       failingReconciliationReads: failingReconciliationReads,
                                       failingFavoriteReads: failingFavoriteReads))
    }

    var snapshot: VehicleMockState { state.withLock { $0 } }

    func respond(to request: URLRequest) -> (Int, Data) {
        let path = request.url?.path ?? ""
        switch (path, request.httpMethod) {
        case ("/auth/v1/token", _):
            return (200, Data(#"{"access_token":"fresh","refresh_token":"refresh-1","user":{"id":"user-1","email":"driver@example.com"}}"#.utf8))
        case ("/rest/v1/vehicle_profiles", "GET"):
            let profiles = state.withLock { state -> [VehicleProfile]? in
                if !state.profilePostIDs.isEmpty && state.failingReconciliationReads > 0 {
                    state.failingReconciliationReads -= 1
                    return nil
                }
                return state.profiles
            }
            guard let profiles else { return (503, Data(#"{"message":"Profiles unavailable"}"#.utf8)) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(profiles) else { return (500, Data()) }
            return (200, data)
        case ("/rest/v1/vehicle_profiles", "POST"):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let profile = try? decoder.decode(VehicleProfile.self, from: MockURLProtocol.bodyData(for: request)) else {
                return (422, Data(#"{"message":"Invalid vehicle profile"}"#.utf8))
            }
            let fails = state.withLock { state in
                if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) { state.profiles[index] = profile }
                else { state.profiles.append(profile) }
                state.profilePostIDs.append(profile.id)
                if state.failingProfileResponses > 0 {
                    state.failingProfileResponses -= 1
                    return true
                }
                return false
            }
            return fails ? (503, Data(#"{"message":"Profile response lost"}"#.utf8)) : (204, Data())
        case ("/rest/v1/user_preferences", "GET"):
            let activeID = state.withLock { $0.activeVehicleID }
            let preference = ActiveVehiclePreference(userID: "user-1", activeVehicleID: activeID)
            guard let data = try? JSONEncoder().encode([preference]) else { return (500, Data()) }
            return (200, data)
        case ("/rest/v1/user_preferences", "POST"):
            guard let preference = try? JSONDecoder().decode(ActiveVehiclePreference.self,
                                                              from: MockURLProtocol.bodyData(for: request)) else {
                return (422, Data(#"{"message":"Invalid vehicle preference"}"#.utf8))
            }
            let fails = state.withLock { state in
                state.preferencePostIDs.append(preference.activeVehicleID)
                if state.failingPreferenceResponses > 0 {
                    state.failingPreferenceResponses -= 1
                    return true
                }
                state.activeVehicleID = preference.activeVehicleID
                if state.committingPreferenceResponseFailures > 0 {
                    state.committingPreferenceResponseFailures -= 1
                    return true
                }
                return false
            }
            return fails ? (503, Data(#"{"message":"Selection failed"}"#.utf8)) : (204, Data())
        case ("/rest/v1/favorite_stations", "GET"):
            let fails = state.withLock { state in
                if state.failingFavoriteReads > 0 {
                    state.failingFavoriteReads -= 1
                    return true
                }
                return false
            }
            if fails { return (503, Data(#"{"message":"Favorites unavailable"}"#.utf8)) }
            return (200, Data("[]".utf8))
        case ("/functions/v1/stations", "GET"):
            state.withLock { $0.stationRequests += 1 }
            return (200, Data(#"{"stations":[]}"#.utf8))
        default:
            return (404, Data(#"{"message":"Unexpected vehicle test request"}"#.utf8))
        }
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handlerState = Mutex<(@Sendable (URLRequest) -> (Int, Data))?>(nil)
    static var handler: (@Sendable (URLRequest) -> (Int, Data))? {
        get { handlerState.withLock { $0 } }
        set { handlerState.withLock { $0 = newValue } }
    }
    private let responseLock = NSRecursiveLock()
    private var isStopped = false

    static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                stream.read(bytes.baseAddress!, maxLength: bytes.count)
            }
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let handler = Self.handler
        // A synchronous gated handler blocks URLSession's protocol callback queue and can
        // prevent a second in-flight request from starting. Keep the mock requests concurrent.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let (status, data) = handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            guard sendIfActive({ $0.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }) else { return }
            guard sendIfActive({ $0.urlProtocol(self, didLoad: data) }) else { return }
            _ = sendIfActive { $0.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        responseLock.lock()
        isStopped = true
        responseLock.unlock()
    }

    private func sendIfActive(_ send: (any URLProtocolClient) -> Void) -> Bool {
        responseLock.lock()
        defer { responseLock.unlock() }
        guard !isStopped, let client else { return false }
        send(client)
        return !isStopped
    }
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
