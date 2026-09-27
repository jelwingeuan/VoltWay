import Foundation
import Observation

@MainActor
@Observable
final class VoltWayStore {
    private(set) var session: UserSession?
    private(set) var profile: VehicleProfile
    private(set) var vehicles: [VehicleProfile]
    private(set) var activeVehicleID: UUID?
    private(set) var stations: [ChargingStation]
    private(set) var favorites: [FavoriteStation] = []
    private(set) var currentLocation: Coordinate?
    private(set) var lastSuccessfulStationFetchAt: Date?
    private(set) var catalogSyncedAt: Date?
    private(set) var catalogImportReport: CatalogImportReport?
    private(set) var duplicateCount = 0
    private(set) var sourceWarnings: [String] = []
    private(set) var isBootstrapping = true
    private(set) var isLoadingStations = false
    private(set) var isAuthenticating = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    let isDemoMode: Bool

    @ObservationIgnored private let backend: BackendClient
    @ObservationIgnored private let locationService: LocationService
    @ObservationIgnored private var didBootstrap = false

    init(configuration: AppConfiguration = .current, backend: BackendClient? = nil) {
        self.backend = backend ?? BackendClient(configuration: configuration)
        locationService = LocationService()
        isDemoMode = !configuration.isConfigured
        profile = .demo
        vehicles = isDemoMode ? [.demo] : []
        activeVehicleID = isDemoMode ? VehicleProfile.demo.id : nil
        stations = isDemoMode ? DemoData.stations : []
    }

    var compatibleStations: [ChargingStation] {
        StationDiscovery.compatibleStations(from: stations, profile: profile, near: currentLocation)
    }

    var favoriteStationIDs: Set<String> {
        Set(favorites.map(\.stationID))
    }

    var favoriteStations: [ChargingStation] {
        return favorites.compactMap { favorite in
            if let current = stations.first(where: { $0.id == favorite.stationID }) { return current }
            // A directory snapshot cannot prove a site is still public or licensed after it leaves the catalog.
            return favorite.stationSnapshot.source == .openChargeMap || favorite.stationSnapshot.source == .ownerProvided
                || favorite.stationID.hasPrefix("ocm:") || favorite.stationID.hasPrefix("private:")
                ? nil : favorite.stationSnapshot
        }
    }

    var profileSummary: String {
        let connectors = profile.connectors.map(\.title).joined(separator: " + ")
        guard let minimumPowerKW = profile.minimumPowerKW else { return "\(profile.name) · \(connectors)" }
        return "\(profile.name) · \(connectors) · \(minimumPowerKW.formatted(.number.precision(.fractionLength(0))))+ kW"
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        defer { isBootstrapping = false }

        if isDemoMode {
            persistCarPlaySnapshot()
            return
        }

        do {
            session = try await backend.restoreSession()
            if session != nil {
                try await loadAccountData()
            } else {
                CarPlaySnapshotStore.clear()
            }
        } catch {
            if session == nil { CarPlaySnapshotStore.clear() }
            show(error)
        }
    }

    func signIn(email: String, password: String) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, password.count >= 8 else {
            errorMessage = "Enter a valid email and a password with at least 8 characters."
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            session = try await backend.signIn(email: email, password: password)
            try await loadAccountData()
        } catch {
            show(error)
        }
    }

    func signUp(email: String, password: String) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, password.count >= 8 else {
            errorMessage = "Enter a valid email and a password with at least 8 characters."
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            session = try await backend.signUp(email: email, password: password)
            if session != nil {
                try await loadAccountData()
            } else {
                noticeMessage = "Check your email to confirm your VoltWay account, then sign in."
            }
        } catch {
            show(error)
        }
    }

    func requestPasswordReset(email: String) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter your email address first."
            return
        }
        do {
            try await backend.requestPasswordReset(email: email)
            noticeMessage = "Password reset instructions were sent to your email."
        } catch {
            show(error)
        }
    }

    func signOut() async {
        do {
            try await backend.signOut()
            session = nil
            stations = []
            vehicles = []
            activeVehicleID = nil
            profile = VehicleProfile(connectors: [], minimumPowerKW: nil)
            favorites = []
            currentLocation = nil
            lastSuccessfulStationFetchAt = nil
            catalogSyncedAt = nil
            catalogImportReport = nil
            duplicateCount = 0
            sourceWarnings = []
            CarPlaySnapshotStore.clear()
        } catch {
            show(error)
        }
    }

    func refreshStations() async {
        isLoadingStations = true
        defer { isLoadingStations = false }
        do {
            let result = try await backend.stations(profile: profile, session: session)
            stations = result.stations
            sourceWarnings = result.warnings ?? []
            catalogSyncedAt = result.catalogSyncedAt
            catalogImportReport = result.catalogImportReport
            duplicateCount = result.duplicateCount ?? 0
            if !isDemoMode { lastSuccessfulStationFetchAt = .now }
            errorMessage = nil
            persistCarPlaySnapshot()
        } catch {
            show(error)
        }
    }

    func addPrivateSite(
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        operatorName: String,
        connector: ConnectorKind,
        powerKW: Double?,
        chargePointCount: Int?,
        invitedEmail: String,
        ownerPermissionGranted: Bool
    ) async -> Bool {
        guard let session else {
            errorMessage = "Sign in to share a private charger."
            return false
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOperator = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = invitedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanName.isEmpty, cleanName.count <= 100, !cleanAddress.isEmpty, cleanAddress.count <= 240,
              !cleanOperator.isEmpty, cleanOperator.count <= 100,
              latitude >= 0.8, latitude <= 7.5, longitude >= 99, longitude <= 120.5,
              ownerPermissionGranted else {
            errorMessage = "Enter valid Malaysian site details and confirm owner permission."
            return false
        }
        guard powerKW.map({ $0.isFinite && $0 > 0 && $0 <= 1_000 }) ?? true,
              chargePointCount.map({ $0 > 0 && $0 <= 1_000 }) ?? true else {
            errorMessage = "Check the listed power and charge point count."
            return false
        }
        if !cleanEmail.isEmpty,
           cleanEmail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            errorMessage = "Enter a valid invitation email or leave it blank."
            return false
        }

        let id = UUID()
        let station = ChargingStation(
            id: "private:\(id.uuidString.lowercased())",
            name: cleanName,
            address: cleanAddress,
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            operatorName: cleanOperator,
            connectors: [Connector(kind: connector, powerKW: powerKW, count: chargePointCount)],
            availability: Availability(state: .unknown, availableConnectors: nil, totalConnectors: nil, lastUpdated: nil),
            price: nil,
            source: .ownerProvided,
            sourceAttribution: "Owner supplied · shared by invitation",
            access: .privateAccess,
            chargePointCount: chargePointCount
        )
        do {
            try await backend.createPrivateSite(
                id: id,
                station: station,
                invitedEmail: cleanEmail.isEmpty ? nil : cleanEmail,
                session: session
            )
            await refreshStations()
            noticeMessage = cleanEmail.isEmpty
                ? "Private charger saved for your account."
                : "Private charger saved and shared with the invited account."
            return true
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    func useCurrentLocation() async -> Coordinate? {
        do {
            let location = try await locationService.requestLocation()
            currentLocation = location
            return location
        } catch {
            show(error)
            return nil
        }
    }

    func saveProfile(connectors: Set<ConnectorKind>, minimumPowerKW: Double?, name: String? = nil,
                     vehicleID: UUID? = nil, createsNew: Bool = false) async -> Bool {
        guard !connectors.isEmpty else {
            errorMessage = "Choose at least one connector."
            return false
        }
        if let minimumPowerKW, !minimumPowerKW.isFinite || minimumPowerKW <= 0 {
            errorMessage = "Minimum charging power must be greater than zero."
            return false
        }

        let previous = createsNew ? nil : vehicles.first { $0.id == (vehicleID ?? profile.id) }
        let vehicleName = (name ?? previous?.name ?? "My EV").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vehicleName.isEmpty && vehicleName.count <= 60 else {
            errorMessage = "Vehicle name must be 1 to 60 characters."
            return false
        }
        let updated = VehicleProfile(
            id: previous?.id ?? UUID(),
            userID: session?.userID,
            name: vehicleName,
            connectors: connectors.sorted { $0.rawValue < $1.rawValue },
            minimumPowerKW: minimumPowerKW,
            updatedAt: .now
        )
        do {
            if let session {
                try await backend.saveProfile(updated, session: session)
                if createsNew || vehicles.isEmpty { try await backend.setActiveVehicle(updated.id, session: session) }
            }
            if let index = vehicles.firstIndex(where: { $0.id == updated.id }) { vehicles[index] = updated }
            else { vehicles.append(updated) }
            if createsNew || previous?.id == activeVehicleID || activeVehicleID == nil {
                activeVehicleID = updated.id
                profile = updated
            }
            persistCarPlaySnapshot()
            errorMessage = nil
            return true
        } catch {
            show(error)
            return false
        }
    }

    func selectVehicle(_ vehicle: VehicleProfile) async {
        guard vehicles.contains(where: { $0.id == vehicle.id }) else { return }
        do {
            if let session { try await backend.setActiveVehicle(vehicle.id, session: session) }
            activeVehicleID = vehicle.id
            profile = vehicle
            persistCarPlaySnapshot()
        } catch { show(error) }
    }

    func deleteVehicle(_ vehicle: VehicleProfile) async {
        guard vehicles.contains(where: { $0.id == vehicle.id }) else { return }
        do {
            if let session { try await backend.deleteProfile(vehicle.id, session: session) }
            vehicles.removeAll { $0.id == vehicle.id }
            let deletedActiveVehicle = activeVehicleID == vehicle.id
            if deletedActiveVehicle {
                let next = vehicles.first
                activeVehicleID = next?.id
                profile = next ?? VehicleProfile(userID: session?.userID, connectors: [], minimumPowerKW: nil)
            }
            persistCarPlaySnapshot()
            if deletedActiveVehicle, let session { try await backend.setActiveVehicle(activeVehicleID, session: session) }
        } catch { show(error) }
    }

    func toggleFavorite(_ station: ChargingStation) async {
        let previous = favorites
        if favoriteStationIDs.contains(station.id) {
            favorites.removeAll { $0.stationID == station.id }
        } else {
            favorites.append(FavoriteStation(userID: session?.userID, stationID: station.id, stationSnapshot: station, createdAt: .now))
        }
        persistCarPlaySnapshot()

        guard let session else { return }
        do {
            if previous.contains(where: { $0.stationID == station.id }) {
                try await backend.deleteFavorite(stationID: station.id, session: session)
            } else {
                try await backend.saveFavorite(station, session: session)
            }
        } catch {
            favorites = previous
            persistCarPlaySnapshot()
            show(error)
        }
    }

    func clearMessages() {
        errorMessage = nil
        noticeMessage = nil
    }

    func showValidationError(_ message: String) {
        errorMessage = message
    }

    private func loadAccountData() async throws {
        guard let session else { return }
        async let loadedProfiles = backend.loadProfiles(session: session)
        async let loadedActiveID = backend.loadActiveVehicleID(session: session)
        async let loadedFavorites = backend.loadFavorites(session: session)
        vehicles = try await loadedProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selectedID = try await loadedActiveID
        let selected = vehicles.first(where: { $0.id == selectedID }) ?? vehicles.first
        activeVehicleID = selected?.id
        profile = selected ?? VehicleProfile(userID: session.userID, connectors: [], minimumPowerKW: nil)
        favorites = try await loadedFavorites
        await refreshStations()
    }

    private func persistCarPlaySnapshot() {
        CarPlaySnapshotStore.save(stations: compatibleStations, favoriteStationIDs: favoriteStationIDs, isDemo: isDemoMode)
    }

    private func show(_ error: any Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
