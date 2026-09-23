import Foundation
import Observation

@MainActor
@Observable
final class VoltWayStore {
    private(set) var session: UserSession?
    private(set) var profile: VehicleProfile
    private(set) var stations: [ChargingStation]
    private(set) var favorites: [FavoriteStation] = []
    private(set) var currentLocation: Coordinate?
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
        stations = isDemoMode ? DemoData.stations : []
    }

    var compatibleStations: [ChargingStation] {
        StationDiscovery.compatibleStations(from: stations, profile: profile, near: currentLocation)
    }

    var favoriteStationIDs: Set<String> {
        Set(favorites.map(\.stationID))
    }

    var favoriteStations: [ChargingStation] {
        favorites.map { favorite in
            stations.first(where: { $0.id == favorite.stationID }) ?? favorite.stationSnapshot
        }
    }

    var profileSummary: String {
        let connectors = profile.connectors.map(\.title).joined(separator: " + ")
        guard let minimumPowerKW = profile.minimumPowerKW else { return connectors }
        return "\(connectors) · \(minimumPowerKW.formatted(.number.precision(.fractionLength(0))))+ kW"
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
            favorites = []
            currentLocation = nil
            CarPlaySnapshotStore.clear()
        } catch {
            show(error)
        }
    }

    func refreshStations() async {
        isLoadingStations = true
        defer { isLoadingStations = false }
        do {
            stations = try await backend.stations(profile: profile, session: session)
            persistCarPlaySnapshot()
        } catch {
            show(error)
        }
    }

    func useCurrentLocation() async {
        do {
            currentLocation = try await locationService.requestLocation()
            await refreshStations()
        } catch {
            show(error)
        }
    }

    func saveProfile(connectors: Set<ConnectorKind>, minimumPowerKW: Double?) async -> Bool {
        guard !connectors.isEmpty else {
            errorMessage = "Choose at least one connector."
            return false
        }
        if let minimumPowerKW, !minimumPowerKW.isFinite || minimumPowerKW <= 0 {
            errorMessage = "Minimum charging power must be greater than zero."
            return false
        }

        let previous = profile
        profile = VehicleProfile(
            userID: session?.userID,
            connectors: connectors.sorted { $0.rawValue < $1.rawValue },
            minimumPowerKW: minimumPowerKW,
            updatedAt: .now
        )

        do {
            if let session { try await backend.saveProfile(profile, session: session) }
            persistCarPlaySnapshot()
            await refreshStations()
            return true
        } catch {
            profile = previous
            persistCarPlaySnapshot()
            show(error)
            return false
        }
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

    private func loadAccountData() async throws {
        guard let session else { return }
        async let loadedProfile = backend.loadProfile(session: session)
        async let loadedFavorites = backend.loadFavorites(session: session)
        profile = try await loadedProfile ?? VehicleProfile(userID: session.userID, connectors: [], minimumPowerKW: nil, updatedAt: nil)
        favorites = try await loadedFavorites
        await refreshStations()
    }

    private func persistCarPlaySnapshot() {
        CarPlaySnapshotStore.save(stations: compatibleStations, favoriteStationIDs: favoriteStationIDs)
    }

    private func show(_ error: any Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
