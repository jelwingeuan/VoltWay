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

struct VehicleProfile: Codable, Equatable, Sendable {
    var userID: String?
    var connectors: [ConnectorKind]
    var minimumPowerKW: Double?
    var updatedAt: Date?

    static let demo = VehicleProfile(connectors: [.type2, .ccs2], minimumPowerKW: nil)

    enum CodingKeys: String, CodingKey {
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

    var attribution: String {
        switch self {
        case .gentari: "Gentari partner feed"
        case .openChargeMap: "Open Charge Map · CC BY 4.0"
        }
    }
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

    var networkName: String {
        switch operatorName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gentari", "gentari go (my)": "Gentari"
        case "shell recharge", "shell recharge (malaysia)": "Shell Recharge"
        case "tnb electron", "tnb electron (my)": "TNB Electron"
        case "jom charge", "jomcharge": "JomCharge"
        case "chargev", "chargeev", "chargeev (my)": "chargEV"
        case "chargesini": "ChargeSini"
        case "evpower", "evpower (my)": "EVPower"
        default: operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var maximumPowerKW: Double? {
        connectors.compactMap(\.powerKW).max()
    }

    var connectorSummary: String {
        connectors
            .sorted { ($0.powerKW ?? -1) > ($1.powerKW ?? -1) }
            .map { connector in
                guard let powerKW = connector.powerKW else { return "\(connector.kind.title) · Power unavailable" }
                return "\(connector.kind.title) \(powerKW.formatted(.number.precision(.fractionLength(0)))) kW"
            }
            .joined(separator: " · ")
    }

    var sourceURL: URL? {
        guard source == .openChargeMap, id.hasPrefix("ocm:") else { return nil }
        return URL(string: "https://openchargemap.org/poi/details/\(id.dropFirst(4))")
    }

    func distance(from coordinate: Coordinate?) -> CLLocationDistance? {
        guard let coordinate else { return nil }
        return self.coordinate.coreLocation.distance(from: coordinate.coreLocation)
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
            .filter(profile.accepts)
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
            return matchesSearch && matchesAvailability && (network == nil || station.networkName == network)
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
        self.stations = stations
        self.favoriteStationIDs = favoriteStationIDs
        self.savedAt = savedAt
        self.isDemo = isDemo
    }

    private enum CodingKeys: String, CodingKey {
        case stations, favoriteStationIDs, savedAt, isDemo
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stations = try values.decode([ChargingStation].self, forKey: .stations)
        favoriteStationIDs = try values.decode(Set<String>.self, forKey: .favoriteStationIDs)
        savedAt = try values.decode(Date.self, forKey: .savedAt)
        isDemo = try values.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
    }
}

enum DemoData {
    static let stations: [ChargingStation] = [
        ChargingStation(
            id: "gentari-petronas-solaris",
            name: "PETRONAS Solaris Serdang",
            address: "Serdang, Selangor",
            coordinate: Coordinate(latitude: 2.9818, longitude: 101.7080),
            operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 180, count: 2), Connector(kind: .type2, powerKW: 22, count: 2)],
            availability: Availability(state: .available, availableConnectors: 2, totalConnectors: 4, lastUpdated: .now),
            price: Price(amountMYR: Decimal(string: "1.50")!, unit: .kWh, lastUpdated: .now),
            source: .gentari
        ),
        ChargingStation(
            id: "gentari-mid-valley",
            name: "Mid Valley Megamall",
            address: "Lingkaran Syed Putra, Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.1176, longitude: 101.6770),
            operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 120, count: 2), Connector(kind: .type2, powerKW: 22, count: 4)],
            availability: Availability(state: .occupied, availableConnectors: 0, totalConnectors: 6, lastUpdated: .now),
            price: Price(amountMYR: Decimal(string: "1.40")!, unit: .kWh, lastUpdated: .now),
            source: .gentari
        ),
        ChargingStation(
            id: "gentari-klcc",
            name: "Kuala Lumpur Convention Centre",
            address: "Jalan Pinang, Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.1536, longitude: 101.7130),
            operatorName: "Gentari",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 6)],
            availability: Availability(state: .available, availableConnectors: 3, totalConnectors: 6, lastUpdated: .now),
            price: Price(amountMYR: Decimal(string: "0.10")!, unit: .minute, lastUpdated: .now),
            source: .gentari
        ),
        ChargingStation(
            id: "gentari-bangsar",
            name: "Bangsar South",
            address: "Kerinchi, Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.1106, longitude: 101.6654),
            operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 60, count: 2)],
            availability: Availability(state: .offline, availableConnectors: 0, totalConnectors: 2, lastUpdated: .now),
            price: nil,
            source: .gentari
        ),
        ChargingStation(
            id: "ocm:505443",
            name: "DC Handal | IOI Mall Damansara",
            address: "Persiaran Surian, Petaling Jaya",
            coordinate: Coordinate(latitude: 3.1488504, longitude: 101.5946795),
            operatorName: "DC Handal",
            connectors: [Connector(kind: .ccs2, powerKW: 240, count: 4)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil,
            source: .openChargeMap
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
            source: .openChargeMap
        ),
        directoryStation(
            id: 279460, name: "Pavilion KL", address: "168 Jalan Bukit Bintang, Kuala Lumpur",
            latitude: 3.1506265487112097, longitude: 101.70763605512641, operatorName: "Shell Recharge (Malaysia)",
            connectors: [Connector(kind: .ccs2, powerKW: 60, count: 2), Connector(kind: .type2, powerKW: 22, count: 2)]
        ),
        directoryStation(
            id: 479684, name: "Shell LPT 1 RNR Temerloh KTN Bound", address: "KM 129.5 East Bound, Temerloh, Pahang",
            latitude: 3.512228012084961, longitude: 102.44186401367188, operatorName: "Shell Recharge (Malaysia)",
            connectors: [Connector(kind: .ccs2, powerKW: 180, count: 2)]
        ),
        directoryStation(
            id: 480555, name: "TNB Electron - Wisma TNB Bagan Serai", address: "Jalan Taiping Batu 10, Bagan Serai, Perak",
            latitude: 5.0058708, longitude: 100.5426283, operatorName: "TNB Electron (MY)",
            connectors: [Connector(kind: .ccs2, powerKW: 240, count: 3)]
        ),
        directoryStation(
            id: 480140, name: "TNB Electron - Yard TNB PRCC Bayan Lepas", address: "Lebuhraya Kampung Jawa, Bayan Lepas, Penang",
            latitude: 5.316405322200055, longitude: 100.2957099672758, operatorName: "TNB Electron (MY)",
            connectors: [Connector(kind: .ccs2, powerKW: 200, count: 5)]
        ),
        directoryStation(
            id: 505071, name: "JomCharge | TTDI CU Mart", address: "11 Jalan Tun Mohd Fuad, Kuala Lumpur",
            latitude: 3.14157273674428, longitude: 101.62850289430958, operatorName: "Jom Charge",
            connectors: [Connector(kind: .ccs2, powerKW: 120, count: 2), Connector(kind: .type2, powerKW: 7, count: 1)]
        ),
        directoryStation(
            id: 497573, name: "chargeEV | TF Value-Mart Gemas", address: "33 Jalan DS 2/2, Gemas, Negeri Sembilan",
            latitude: 2.5864782970035662, longitude: 102.57496456588626, operatorName: "chargeEV (MY)",
            connectors: [Connector(kind: .ccs2, powerKW: 60, count: 2)]
        ),
        directoryStation(
            id: 259727, name: "ChargeSini Station Starbucks Megamall", address: "Berjaya Megamall, Kuantan, Pahang",
            latitude: 3.8151167582230556, longitude: 103.32983248955486, operatorName: "ChargeSini",
            connectors: [Connector(kind: .type2, powerKW: 11, count: 1), Connector(kind: .type2, powerKW: 22, count: 1)]
        )
    ]

    private static func directoryStation(
        id: Int, name: String, address: String, latitude: Double, longitude: Double,
        operatorName: String, connectors: [Connector]
    ) -> ChargingStation {
        ChargingStation(
            id: "ocm:\(id)", name: name, address: address,
            coordinate: Coordinate(latitude: latitude, longitude: longitude), operatorName: operatorName,
            connectors: connectors,
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil, source: .openChargeMap
        )
    }
}
