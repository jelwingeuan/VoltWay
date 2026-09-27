import CoreLocation
import Foundation

enum ConnectorKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case type2
    case ccs2
    case chademo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type2: "Type 2"
        case .ccs2: "CCS2"
        case .chademo: "CHAdeMO"
        }
    }

    var systemImage: String {
        switch self {
        case .type2: "bolt.circle"
        case .ccs2: "bolt.fill"
        case .chademo: "bolt.horizontal.circle"
        }
    }
}

struct VehicleProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var userID: String?
    var name: String
    var connectors: [ConnectorKind]
    var minimumPowerKW: Double?
    var updatedAt: Date?

    static let demo = VehicleProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Demo EV", connectors: [.type2, .ccs2], minimumPowerKW: nil)

    init(id: UUID = UUID(), userID: String? = nil, name: String = "My EV", connectors: [ConnectorKind], minimumPowerKW: Double?, updatedAt: Date? = nil) {
        self.id = id
        self.userID = userID
        self.name = name
        self.connectors = connectors
        self.minimumPowerKW = minimumPowerKW
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case userID = "user_id"
        case connectors
        case minimumPowerKW = "minimum_power_kw"
        case updatedAt = "updated_at"
    }

    func accepts(_ station: ChargingStation) -> Bool {
        let matchesConnector = !Set(connectors).isDisjoint(with: station.connectors.map(\.kind))
        let meetsPower = minimumPowerKW.map { minimum in
            station.connectors.contains { ($0.powerKW ?? 0) >= minimum && connectors.contains($0.kind) }
        } ?? true
        return matchesConnector && meetsPower
    }
}

struct ActiveVehiclePreference: Codable, Sendable {
    let userID: String
    let activeVehicleID: UUID?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case activeVehicleID = "active_vehicle_id"
    }
}

struct CatalogImportReport: Decodable, Sendable {
    let fetched: Int
    let included: Int
    let `private`: Int
    let invalid: Int
    let license: Int
    let providerIDsNeedingReview: [Int]
    let providers: [CatalogProviderImportReport]?
    let excludedIDs: CatalogExcludedIDs?
}

struct CatalogProviderImportReport: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let fetched: Int
    let included: Int
    let `private`: Int
    let invalid: Int
    let license: Int
}

struct CatalogExcludedIDs: Decodable, Sendable {
    let `private`: [Int]?
    let invalid: [Int]?
    let license: [Int]?
}

struct MEVnetImportReport: Decodable, Sendable {
    let fetched: Int
    let included: Int
    let existing: Int
    let proposed: Int
    let unknown: Int
    let invalid: Int
    let `private`: Int?
    let accessUnverified: Int?
    let states: [String: MEVnetStateReport]
}

struct MEVnetStateReport: Decodable, Sendable {
    let fetched: Int
    let included: Int
    let proposed: Int
    let invalid: Int
    let `private`: Int?
    let accessUnverified: Int?
}

struct Coordinate: Codable, Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var coreLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct Connector: Codable, Equatable, Hashable, Sendable {
    let kind: ConnectorKind
    let powerKW: Double?
    let count: Int?
}

enum StationSource: String, Codable, Equatable, Hashable, Sendable {
    case gentari
    case openChargeMap
    case ownerProvided
    case mevnet

    var attribution: String {
        switch self {
        case .gentari: "Gentari partner feed"
        case .openChargeMap: "Open Charge Map · CC BY 4.0"
        case .ownerProvided: "Owner supplied · private sharing"
        case .mevnet: "PLANMalaysia MEVnet · planning catalog"
        }
    }
}

enum StationAccess: String, Codable, Equatable, Hashable, Sendable {
    case publicAccess = "public"
    case limited
    case unknown
    case privateAccess = "private"

    var title: String {
        switch self {
        case .publicAccess: "Public access"
        case .limited: "Limited access - check requirements"
        case .unknown: "Access requirements unknown"
        case .privateAccess: "Private · invited users only"
        }
    }
}

enum ChargingType: String, CaseIterable, Identifiable {
    case ac = "AC"
    case dc = "DC"
    var id: Self { self }
}

enum AvailabilityState: String, Codable, Equatable, Hashable, Sendable {
    case available
    case occupied
    case offline
    case unknown

    var title: String {
        switch self {
        case .available: "Available"
        case .occupied: "In use"
        case .offline: "Offline"
        case .unknown: "Status unavailable"
        }
    }

    var sortRank: Int {
        switch self {
        case .available: 0
        case .occupied: 1
        case .unknown: 2
        case .offline: 3
        }
    }
}

struct Availability: Codable, Equatable, Hashable, Sendable {
    let state: AvailabilityState
    let availableConnectors: Int?
    let totalConnectors: Int?
    let lastUpdated: Date?

    func isStale(at date: Date = .now, after interval: TimeInterval = 300) -> Bool {
        guard let lastUpdated else { return true }
        return date.timeIntervalSince(lastUpdated) > interval
    }

    func isReportedAvailable(at date: Date = .now) -> Bool {
        state == .available && !isStale(at: date) && (availableConnectors ?? 0) > 0
    }

    func displayText(at date: Date = .now) -> String {
        guard !isStale(at: date) else { return "Status unavailable" }
        if state == .available, let availableConnectors {
            return "\(availableConnectors) available"
        }
        return state.title
    }
}

enum PriceUnit: String, Codable, Equatable, Hashable, Sendable {
    case kWh
    case minute
    case session

    var suffix: String {
        switch self {
        case .kWh: "/kWh"
        case .minute: "/min"
        case .session: "/session"
        }
    }
}

struct Price: Codable, Equatable, Hashable, Sendable {
    let amountMYR: Decimal
    let unit: PriceUnit
    let lastUpdated: Date?

    func isStale(at date: Date = .now, after interval: TimeInterval = 86_400) -> Bool {
        guard let lastUpdated else { return true }
        return date.timeIntervalSince(lastUpdated) > interval
    }

    func displayText(at date: Date = .now) -> String {
        guard !isStale(at: date) else { return "Price unavailable" }
        let amount = amountMYR.formatted(.currency(code: "MYR").precision(.fractionLength(2)))
        return "\(amount)\(unit.suffix)"
    }
}

enum ChargingCostEstimate {
    static func amount(for price: Price?, energyKWh: Int, at date: Date = .now) -> Decimal? {
        guard let price,
              energyKWh > 0,
              price.unit == .kWh,
              price.amountMYR > 0,
              !price.isStale(at: date)
        else { return nil }

        var product = price.amountMYR * Decimal(energyKWh)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 2, .plain)
        return rounded
    }
}

struct RouteStopCandidate: Equatable, Sendable {
    let station: ChargingStation
    let offRouteMeters: Double
    let routeProgressMeters: Double
}

enum RouteStopMatcher {
    // ponytail: a local equirectangular projection is accurate enough for the 5 km Malaysia pilot corridor.
    static func stops(
        along route: [Coordinate],
        compatibleStations: [ChargingStation],
        corridorMeters: Double = 5_000
    ) -> [RouteStopCandidate] {
        guard !route.isEmpty, corridorMeters >= 0 else { return [] }
        return compatibleStations.compactMap { station in
            guard let match = nearestPoint(to: station.coordinate, on: route), match.distance <= corridorMeters else { return nil }
            return RouteStopCandidate(station: station, offRouteMeters: match.distance, routeProgressMeters: match.progress)
        }
        .sorted {
            if $0.routeProgressMeters != $1.routeProgressMeters { return $0.routeProgressMeters < $1.routeProgressMeters }
            return $0.station.id < $1.station.id
        }
    }

    private static func nearestPoint(to coordinate: Coordinate, on route: [Coordinate]) -> (distance: Double, progress: Double)? {
        let earthRadius = 6_371_000.0
        guard route.count > 1 else {
            let point = route[0]
            return (point.coreLocation.distance(from: coordinate.coreLocation), 0)
        }

        var routeProgress = 0.0
        var nearest: (distance: Double, progress: Double)?
        for index in 0..<(route.count - 1) {
            let start = route[index]
            let end = route[index + 1]
            let meanLatitude = (start.latitude + end.latitude + coordinate.latitude) / 3 * .pi / 180
            func point(_ value: Coordinate) -> (x: Double, y: Double) {
                (value.longitude * .pi / 180 * earthRadius * cos(meanLatitude), value.latitude * .pi / 180 * earthRadius)
            }
            let a = point(start)
            let b = point(end)
            let p = point(coordinate)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let segmentLength = hypot(dx, dy)
            let fraction = segmentLength == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (segmentLength * segmentLength)))
            let projectedX = a.x + fraction * dx
            let projectedY = a.y + fraction * dy
            let distance = hypot(p.x - projectedX, p.y - projectedY)
            let progress = routeProgress + fraction * segmentLength
            if let current = nearest {
                if distance < current.distance { nearest = (distance, progress) }
            } else {
                nearest = (distance, progress)
            }
            routeProgress += segmentLength
        }
        return nearest
    }
}

struct ChargingStation: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let address: String
    let coordinate: Coordinate
    let operatorName: String
    let connectors: [Connector]
    let availability: Availability
    let price: Price?
    var source: StationSource? = nil
    var sourceAttribution: String? = nil
    var access: StationAccess? = nil
    var chargePointCount: Int? = nil
    var state: String? = nil
    var sourceSequence: Int? = nil
    var stateCode: Int? = nil
    var pbtCode: Int? = nil
    var pbt: String? = nil
    var indoorOutdoor: String? = nil
    var lifecycle: StationLifecycle? = nil
    var acCount: Int? = nil
    var dcCount: Int? = nil
    var proposedChargePointCount: Int? = nil
    var indoorCount: Int? = nil
    var outdoorCount: Int? = nil
    var category: String? = nil
    var networkCounts: [String: Int]? = nil
    var sourceIDs: [String: String]? = nil
    var sourceAttributions: [String]? = nil
    var sourceUpdatedAt: Date? = nil

    var attributionText: String? { sourceAttributions?.joined(separator: " · ") ?? sourceAttribution ?? source?.attribution }

    var networkName: String {
        switch operatorName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gentari", "gentari go", "gentari go (my)": "Gentari"
        case "shell recharge", "shell recharge (malaysia)", "parkeasy": "Shell Recharge"
        case "tnb electron", "tnb electron (my)", "tnbx", "tnbx electron", "tnb electron / tnbx / go to-u": "TNB Electron"
        case "jom charge", "jomcharge": "JomCharge"
        case "chargev", "chargeev", "chargeev (my)": "chargEV"
        case "chargesini": "ChargeSini"
        case "handal green mobility", "dc handal": "DC Handal"
        case "evpower", "evpower (my)": "EVPower"
        case "tesla", "tesla supercharger": "Tesla"
        case "charge n go", "chargengo", "charge n' go": "Charge N Go"
        case "go to-u", "go to u", "gotou": "Go To-U"
        case "charge+", "charge plus": "Charge+"
        default: operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var maximumPowerKW: Double? {
        connectors.compactMap(\.powerKW).max()
    }

    var connectorSummary: String {
        guard !connectors.isEmpty else { return "Connector details unavailable" }
        return connectors
            .sorted { ($0.powerKW ?? -1) > ($1.powerKW ?? -1) }
            .map { connector in
                guard let powerKW = connector.powerKW else { return "\(connector.kind.title) · Power unavailable" }
                return "\(connector.kind.title) \(powerKW.formatted(.number.precision(.fractionLength(0)))) kW"
            }
            .joined(separator: " · ")
    }

    var sourceURL: URL? {
        if let ocmID = sourceIDs?["openChargeMap"] ?? sourceIDs?["ocm"] {
            return URL(string: "https://openchargemap.org/poi/details/\(ocmID.replacingOccurrences(of: "ocm:", with: ""))")
        }
        if id.hasPrefix("ocm:") { return URL(string: "https://openchargemap.org/poi/details/\(id.dropFirst(4))") }
        return nil
    }

    func distance(from coordinate: Coordinate?) -> CLLocationDistance? {
        guard let coordinate else { return nil }
        return self.coordinate.coreLocation.distance(from: coordinate.coreLocation)
    }
}

enum StationLifecycle: String, Codable, Equatable, Hashable, Sendable {
    case existing
    case proposed
    case unknown

    var title: String {
        switch self {
        case .existing: "Existing site · planning record"
        case .proposed: "Proposed site · not confirmed open"
        case .unknown: "Site lifecycle unknown"
        }
    }
}

struct CatalogNetworkSummary: Equatable, Identifiable, Sendable {
    let network: String
    let sites: Int
    let proposedSites: Int
    let otherSites: Int
    let knownChargePoints: Int
    let sitesWithoutChargePointCount: Int
    let hasDirectoryRecords: Bool
    let hasPartnerFeed: Bool
    let hasOwnerProvidedRecords: Bool

    var id: String { network }
}

enum CatalogCoverage {
    static func networks(in stations: [ChargingStation]) -> [CatalogNetworkSummary] {
        var grouped: [String: [ChargingStation]] = [:]
        for station in stations {
            grouped[station.networkName, default: []].append(station)
        }
        let summaries = grouped.map { network, records in
            let knownChargePoints = records.compactMap(\.chargePointCount).reduce(0, +)
            let missingPointCounts = records.filter { $0.chargePointCount == nil }.count
            let hasDirectoryRecords = records.contains { $0.source == .openChargeMap || $0.source == .mevnet }
            let hasPartnerFeed = records.contains { $0.source == .gentari }
            let hasOwnerProvidedRecords = records.contains { $0.source == .ownerProvided }
            return CatalogNetworkSummary(
                network: network,
                sites: records.count,
                proposedSites: records.filter { $0.lifecycle == .proposed }.count,
                otherSites: records.filter { $0.lifecycle != .proposed }.count,
                knownChargePoints: knownChargePoints,
                sitesWithoutChargePointCount: missingPointCounts,
                hasDirectoryRecords: hasDirectoryRecords,
                hasPartnerFeed: hasPartnerFeed,
                hasOwnerProvidedRecords: hasOwnerProvidedRecords
            )
        }
        return summaries.sorted { lhs, rhs in
            lhs.network.localizedStandardCompare(rhs.network) == .orderedAscending
        }
    }
}

struct FavoriteStation: Codable, Equatable, Identifiable, Sendable {
    let userID: String?
    let stationID: String
    let stationSnapshot: ChargingStation
    let createdAt: Date?

    var id: String { stationID }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case stationID = "station_id"
        case stationSnapshot = "station_snapshot"
        case createdAt = "created_at"
    }
}

enum StationDiscovery {
    static func compatibleStations(
        from stations: [ChargingStation],
        profile: VehicleProfile,
        near coordinate: Coordinate?,
        now: Date = .now
    ) -> [ChargingStation] {
        stations
            .filter { $0.lifecycle != .proposed && profile.accepts($0) }
            .sorted { lhs, rhs in
                let lhsRank = lhs.availability.isStale(at: now) ? AvailabilityState.unknown.sortRank : lhs.availability.state.sortRank
                let rhsRank = rhs.availability.isStale(at: now) ? AvailabilityState.unknown.sortRank : rhs.availability.state.sortRank
                if lhsRank != rhsRank { return lhsRank < rhsRank }

                let lhsDistance = lhs.distance(from: coordinate) ?? .greatestFiniteMagnitude
                let rhsDistance = rhs.distance(from: coordinate) ?? .greatestFiniteMagnitude
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func visibleStations(
        from stations: [ChargingStation],
        query: String,
        availableNowOnly: Bool,
        network: String? = nil,
        profile: VehicleProfile? = nil,
        showAll: Bool = false,
        chargingType: ChargingType? = nil,
        minimumListedPowerKW: Double? = nil,
        access: StationAccess? = nil,
        includeProposed: Bool = false,
        now: Date = .now
    ) -> [ChargingStation] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return stations.filter { station in
            let matchesSearch = search.isEmpty
                || station.name.localizedStandardContains(search)
                || station.address.localizedStandardContains(search)
                || station.operatorName.localizedStandardContains(search)
                || station.networkName.localizedStandardContains(search)
            let matchesAvailability = !availableNowOnly || station.availability.isReportedAvailable(at: now)
            let matchesVehicle = showAll || profile.map { $0.accepts(station) } ?? true
            let matchesChargingType = chargingType.map { type in
                station.connectors.contains { type == .ac ? $0.kind == .type2 : $0.kind == .ccs2 || $0.kind == .chademo }
            } ?? true
            let matchesPower = minimumListedPowerKW.map { (station.maximumPowerKW ?? 0) >= $0 } ?? true
            return (includeProposed || station.lifecycle != .proposed) && matchesSearch && matchesAvailability && matchesVehicle && matchesChargingType && matchesPower &&
                (network == nil || station.networkName == network) && (access == nil || (station.access ?? .unknown) == access)
        }
    }

    static func networks(from stations: [ChargingStation]) -> [String] {
        let priority = ["Shell Recharge": 0, "TNB Electron": 1, "Gentari": 2]
        return Array(Set(stations.map(\.networkName)))
            .sorted {
                let first = priority[$0] ?? Int.max
                let second = priority[$1] ?? Int.max
                return first == second ? $0.localizedStandardCompare($1) == .orderedAscending : first < second
            }
    }

    static func nearbyAlternatives(
        to station: ChargingStation,
        compatibleStations: [ChargingStation],
        radiusMeters: Double = 10_000,
        limit: Int = 3,
        now: Date = .now
    ) -> [ChargingStation] {
        guard radiusMeters >= 0, limit > 0 else { return [] }
        return Array(compatibleStations
            .filter { $0.id != station.id && ($0.distance(from: station.coordinate) ?? .infinity) <= radiusMeters }
            .sorted { lhs, rhs in
                let lhsAvailable = lhs.availability.isReportedAvailable(at: now)
                let rhsAvailable = rhs.availability.isReportedAvailable(at: now)
                if lhsAvailable != rhsAvailable { return lhsAvailable }
                let lhsDistance = lhs.distance(from: station.coordinate) ?? .infinity
                let rhsDistance = rhs.distance(from: station.coordinate) ?? .infinity
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.id < rhs.id
            }
            .prefix(limit))
    }
}

struct UserSession: Codable, Equatable, Sendable {
    let userID: String
    let email: String
    let accessToken: String
    let refreshToken: String
}

struct CarPlaySnapshot: Codable, Equatable, Sendable {
    let stations: [ChargingStation]
    let favoriteStationIDs: Set<String>
    let savedAt: Date
    let isDemo: Bool

    init(stations: [ChargingStation], favoriteStationIDs: Set<String>, savedAt: Date, isDemo: Bool = false) {
        let carPlayStations = stations.filter { $0.source != .ownerProvided }
        self.stations = carPlayStations
        self.favoriteStationIDs = favoriteStationIDs.intersection(Set(carPlayStations.map(\.id)))
        self.savedAt = savedAt
        self.isDemo = isDemo
    }

    private enum CodingKeys: String, CodingKey {
        case stations, favoriteStationIDs, savedAt, isDemo
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let carPlayStations = try values.decode([ChargingStation].self, forKey: .stations)
            .filter { $0.source != .ownerProvided }
        stations = carPlayStations
        favoriteStationIDs = try values.decode(Set<String>.self, forKey: .favoriteStationIDs)
            .intersection(Set(carPlayStations.map(\.id)))
        savedAt = try values.decode(Date.self, forKey: .savedAt)
        isDemo = try values.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
    }
}

enum DemoData {
    static let stations: [ChargingStation] = [
        ChargingStation(
            id: "ocm:505443",
            name: "DC Handal | IOI Mall Damansara",
            address: "Persiaran Surian, Petaling Jaya",
            coordinate: Coordinate(latitude: 3.1488504, longitude: 101.5946795),
            operatorName: "DC Handal",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 1), Connector(kind: .ccs2, powerKW: 240, count: 4)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil,
            source: .openChargeMap,
            sourceAttribution: "Open Charge Map Contributors · CC BY 4.0",
            access: .limited,
            chargePointCount: 5
        ),
        ChargingStation(
            id: "ocm:470421",
            name: "EVPower - 168 Park Mall Selayang",
            address: "Batu Caves, Selangor",
            coordinate: Coordinate(latitude: 3.2480458, longitude: 101.6491125),
            operatorName: "EVPower",
            connectors: [Connector(kind: .ccs2, powerKW: 180, count: 5)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil,
            source: .openChargeMap,
            sourceAttribution: "Open Charge Map Contributors · CC BY 4.0",
            access: .publicAccess,
            chargePointCount: 5
        ),
        directoryStation(
            id: 279460, name: "Pavilion KL", address: "168 Jalan Bukit Bintang, Kuala Lumpur",
            latitude: 3.1506265487112097, longitude: 101.70763605512641, operatorName: "Shell Recharge (Malaysia)",
            connectors: [Connector(kind: .ccs2, powerKW: 60, count: 2), Connector(kind: .type2, powerKW: 22, count: 2)]
        ),
        directoryStation(
            id: 479684, name: "Shell LPT 1 RNR Temerloh KTN Bound", address: "KM 129.5 East Bound, Temerloh, Pahang",
            latitude: 3.512228012084961, longitude: 102.44186401367188, operatorName: "Shell Recharge (Malaysia)",
            connectors: [Connector(kind: .ccs2, powerKW: 180, count: 2)], chargePointCount: 2
        ),
        directoryStation(
            id: 480555, name: "TNB Electron - Wisma TNB Bagan Serai", address: "Jalan Taiping Batu 10, Bagan Serai, Perak",
            latitude: 5.0058708, longitude: 100.5426283, operatorName: "TNB Electron (MY)",
            connectors: [Connector(kind: .ccs2, powerKW: 240, count: 3)], chargePointCount: 3
        ),
        directoryStation(
            id: 480140, name: "TNB Electron - Yard TNB PRCC Bayan Lepas", address: "Lebuhraya Kampung Jawa, Bayan Lepas, Penang",
            latitude: 5.316405322200055, longitude: 100.2957099672758, operatorName: "TNB Electron (MY)",
            connectors: [Connector(kind: .ccs2, powerKW: 200, count: 5)], chargePointCount: 5
        ),
        directoryStation(
            id: 505071, name: "JomCharge | TTDI CU Mart", address: "11 Jalan Tun Mohd Fuad, Kuala Lumpur",
            latitude: 3.14157273674428, longitude: 101.62850289430958, operatorName: "Jom Charge",
            connectors: [Connector(kind: .ccs2, powerKW: 120, count: 2), Connector(kind: .type2, powerKW: 7, count: 1)]
        ),
        directoryStation(
            id: 497573, name: "chargeEV | TF Value-Mart Gemas", address: "33 Jalan DS 2/2, Gemas, Negeri Sembilan",
            latitude: 2.5864782970035662, longitude: 102.57496456588626, operatorName: "chargeEV (MY)",
            connectors: [Connector(kind: .ccs2, powerKW: 60, count: 2)], chargePointCount: 2
        ),
        directoryStation(
            id: 259727, name: "ChargeSini Station Starbucks Megamall", address: "Berjaya Megamall, Kuantan, Pahang",
            latitude: 3.8151167582230556, longitude: 103.32983248955486, operatorName: "ChargeSini",
            connectors: [Connector(kind: .type2, powerKW: 11, count: 1), Connector(kind: .type2, powerKW: 22, count: 1)]
        )
    ]

    private static func directoryStation(
        id: Int, name: String, address: String, latitude: Double, longitude: Double,
        operatorName: String, connectors: [Connector], chargePointCount: Int? = nil
    ) -> ChargingStation {
        ChargingStation(
            id: "ocm:\(id)", name: name, address: address,
            coordinate: Coordinate(latitude: latitude, longitude: longitude), operatorName: operatorName,
            connectors: connectors,
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .openChargeMap, chargePointCount: chargePointCount
        )
    }
}
