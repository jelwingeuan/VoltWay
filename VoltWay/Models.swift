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

    static let demo = VehicleProfile(connectors: [.type2, .ccs2], minimumPowerKW: 50)

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case connectors
        case minimumPowerKW = "minimum_power_kw"
        case updatedAt = "updated_at"
    }

    func accepts(_ station: ChargingStation) -> Bool {
        let matchesConnector = !Set(connectors).isDisjoint(with: station.connectors.map(\.kind))
        let meetsPower = minimumPowerKW.map { minimum in
            station.connectors.contains { $0.powerKW >= minimum && connectors.contains($0.kind) }
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
    let powerKW: Double
    let count: Int
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

    var maximumPowerKW: Double {
        connectors.map(\.powerKW).max() ?? 0
    }

    var connectorSummary: String {
        connectors
            .sorted { $0.powerKW > $1.powerKW }
            .map { "\($0.kind.title) \($0.powerKW.formatted(.number.precision(.fractionLength(0)))) kW" }
            .joined(separator: " · ")
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
        now: Date = .now
    ) -> [ChargingStation] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return stations.filter { station in
            let matchesSearch = search.isEmpty
                || station.name.localizedStandardContains(search)
                || station.address.localizedStandardContains(search)
            let matchesAvailability = !availableNowOnly || station.availability.isReportedAvailable(at: now)
            return matchesSearch && matchesAvailability
        }
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
            price: Price(amountMYR: Decimal(string: "1.50")!, unit: .kWh, lastUpdated: .now)
        ),
        ChargingStation(
            id: "gentari-mid-valley",
            name: "Mid Valley Megamall",
            address: "Lingkaran Syed Putra, Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.1176, longitude: 101.6770),
            operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 120, count: 2), Connector(kind: .type2, powerKW: 22, count: 4)],
            availability: Availability(state: .occupied, availableConnectors: 0, totalConnectors: 6, lastUpdated: .now),
            price: Price(amountMYR: Decimal(string: "1.40")!, unit: .kWh, lastUpdated: .now)
        ),
        ChargingStation(
            id: "gentari-klcc",
            name: "Kuala Lumpur Convention Centre",
            address: "Jalan Pinang, Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.1536, longitude: 101.7130),
            operatorName: "Gentari",
            connectors: [Connector(kind: .type2, powerKW: 22, count: 6)],
            availability: Availability(state: .available, availableConnectors: 3, totalConnectors: 6, lastUpdated: .now),
            price: Price(amountMYR: Decimal(string: "0.10")!, unit: .minute, lastUpdated: .now)
        ),
        ChargingStation(
            id: "gentari-bangsar",
            name: "Bangsar South",
            address: "Kerinchi, Kuala Lumpur",
            coordinate: Coordinate(latitude: 3.1106, longitude: 101.6654),
            operatorName: "Gentari",
            connectors: [Connector(kind: .ccs2, powerKW: 60, count: 2)],
            availability: Availability(state: .offline, availableConnectors: 0, totalConnectors: 2, lastUpdated: .now),
            price: nil
        )
    ]
}
