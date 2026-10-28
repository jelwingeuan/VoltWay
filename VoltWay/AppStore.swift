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
    private(set) var stationCatalogRevision = 0
    private(set) var compatibleResultRevision = 0
    private(set) var favorites: [FavoriteStation] = []
    private(set) var favoriteStationIDs: Set<String> = []
    private(set) var favoriteStations: [ChargingStation] = []
    private(set) var favoriteMutationIDs: Set<String> = []
    private(set) var currentLocation: Coordinate?
    private(set) var lastSuccessfulStationFetchAt: Date?
    private(set) var catalogSyncedAt: Date?
    private(set) var catalogImportReport: CatalogImportReport?
    private(set) var mevnetSyncedAt: Date?
    private(set) var mevnetImportReport: MEVnetImportReport?
    private(set) var duplicateCount = 0
    private(set) var sourceWarnings: [String] = []
    private(set) var isBootstrapping = true
    private(set) var isLoadingStations = false
    private(set) var isLoadingAccountData = false
    private(set) var accountDataNeedsRetry = false
    private(set) var isAuthenticating = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    let isDemoMode: Bool

    @ObservationIgnored private let backend: BackendClient
    @ObservationIgnored private let locationService: LocationService
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var accountRevision = 0
    @ObservationIgnored private var stationRefreshRevision = 0
    @ObservationIgnored private var isSigningOut = false
    @ObservationIgnored private var cachedCompatibleStations: [ChargingStation] = []
    @ObservationIgnored private var compatibleSortDate = Date.distantPast
    @ObservationIgnored private var nextCompatibleStatusActivation: Date?
    @ObservationIgnored private var nextCompatibleStatusExpiry: Date?
    @ObservationIgnored private var favoriteSourceIDsByStationID: [String: Set<String>] = [:]

    init(configuration: AppConfiguration = .current, backend: BackendClient? = nil) {
        self.backend = backend ?? BackendClient(configuration: configuration)
        locationService = LocationService()
        isDemoMode = !configuration.isConfigured
        profile = isDemoMode ? .demo : VehicleProfile(connectors: [], minimumPowerKW: nil)
        vehicles = isDemoMode ? [.demo] : []
        activeVehicleID = isDemoMode ? VehicleProfile.demo.id : nil
        stations = isDemoMode ? DemoData.stations : []
        rebuildCompatibleStations()
    }

    var compatibleStations: [ChargingStation] {
        compatibleStations(at: .now)
    }

    func compatibleStations(at date: Date) -> [ChargingStation] {
        _ = compatibleResultRevision
        if needsCompatibleRebuild(at: date) { rebuildCompatibleStations(at: date, notify: false) }
        return cachedCompatibleStations
    }

    var hasTimedStationFacts: Bool {
        stations.contains { $0.availability.lastUpdated != nil || $0.price?.lastUpdated != nil }
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

        let revision = accountRevision
        do {
            let restored = try await backend.restoreSession()
            guard accountRevision == revision else { return }
            session = restored
            if session != nil {
                await retryAccountData()
            } else {
                CarPlaySnapshotStore.clear()
            }
        } catch {
            guard accountRevision == revision else { return }
            if session == nil { CarPlaySnapshotStore.clear() }
            show(error)
        }
    }

    func signIn(email: String, password: String) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, password.count >= 8 else {
            errorMessage = "Enter a valid email and a password with at least 8 characters."
            return
        }
        guard !isAuthenticating, !isSigningOut else { return }

        let revision = accountRevision
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let signedIn = try await backend.signIn(email: email, password: password)
            guard accountRevision == revision else { return }
            accountRevision += 1
            favoriteMutationIDs = []
            session = signedIn
            await retryAccountData()
        } catch {
            if accountRevision == revision { show(error) }
        }
    }

    func signUp(email: String, password: String) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, password.count >= 8 else {
            errorMessage = "Enter a valid email and a password with at least 8 characters."
            return
        }
        guard !isAuthenticating, !isSigningOut else { return }

        let revision = accountRevision
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let signedUp = try await backend.signUp(email: email, password: password)
            guard accountRevision == revision else { return }
            if let signedUp {
                accountRevision += 1
                favoriteMutationIDs = []
                session = signedUp
                await retryAccountData()
            } else {
                noticeMessage = "Check your email to confirm your VoltWay account, then sign in."
            }
        } catch {
            if accountRevision == revision { show(error) }
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
        guard !isSigningOut else { return }
        isSigningOut = true
        accountRevision += 1
        let revision = accountRevision
        isAuthenticating = true
        defer {
            isSigningOut = false
            isAuthenticating = false
        }
        session = nil
        stations = []
        stationCatalogRevision += 1
        vehicles = []
        activeVehicleID = nil
        profile = VehicleProfile(connectors: [], minimumPowerKW: nil)
        isLoadingAccountData = false
        accountDataNeedsRetry = false
        favorites = []
        favoriteMutationIDs = []
        rebuildFavorites()
        currentLocation = nil
        cachedCompatibleStations = []
        compatibleSortDate = .distantPast
        nextCompatibleStatusActivation = nil
        nextCompatibleStatusExpiry = nil
        compatibleResultRevision += 1
        lastSuccessfulStationFetchAt = nil
        catalogSyncedAt = nil
        catalogImportReport = nil
        mevnetSyncedAt = nil
        mevnetImportReport = nil
        duplicateCount = 0
        sourceWarnings = []
        isLoadingStations = false
        CarPlaySnapshotStore.clear()
        do {
            try await backend.signOut()
        } catch {
            if accountRevision == revision { show(error) }
        }
    }

    func refreshStations() async {
        guard isDemoMode || session != nil else { return }
        stationRefreshRevision += 1
        let refreshRevision = stationRefreshRevision
        let accountRevision = accountRevision
        let requestedSession = session
        isLoadingStations = true
        defer {
            if stationRefreshRevision == refreshRevision { isLoadingStations = false }
        }
        do {
            let result = try await backend.stations(profile: profile, session: requestedSession)
            guard isCurrentAccount(accountRevision, userID: requestedSession?.userID),
                  stationRefreshRevision == refreshRevision else { return }
            stations = result.stations
            stationCatalogRevision += 1
            rebuildCompatibleStations()
            rebuildFavorites()
            sourceWarnings = result.warnings ?? []
            catalogSyncedAt = result.catalogSyncedAt
            catalogImportReport = result.catalogImportReport
            mevnetSyncedAt = result.mevnetSyncedAt
            mevnetImportReport = result.mevnetImportReport
            duplicateCount = result.duplicateCount ?? 0
            if !isDemoMode { lastSuccessfulStationFetchAt = .now }
            errorMessage = nil
            persistCarPlaySnapshot()
        } catch {
            if isCurrentAccount(accountRevision, userID: requestedSession?.userID),
               stationRefreshRevision == refreshRevision { show(error) }
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
        let accountRevision = accountRevision
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
            guard isCurrentAccount(accountRevision, userID: session.userID) else { return false }
            await refreshStations()
            guard isCurrentAccount(accountRevision, userID: session.userID) else { return false }
            noticeMessage = cleanEmail.isEmpty
                ? "Private charger saved for your account."
                : "Private charger saved and shared with the invited account."
            return true
        } catch {
            if isCurrentAccount(accountRevision, userID: session.userID) { show(error) }
            return false
        }
    }

    @discardableResult
    func useCurrentLocation() async -> Coordinate? {
        let accountRevision = accountRevision
        let userID = session?.userID
        do {
            let location = try await locationService.requestLocation()
            guard isCurrentAccount(accountRevision, userID: userID) else { return nil }
            currentLocation = location
            rebuildCompatibleStations()
            return location
        } catch {
            if isCurrentAccount(accountRevision, userID: userID) { show(error) }
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
        let accountRevision = accountRevision
        do {
            if let session {
                try await backend.saveProfile(updated, session: session)
                if createsNew || vehicles.isEmpty { try await backend.setActiveVehicle(updated.id, session: session) }
            }
            guard isCurrentAccount(accountRevision, userID: session?.userID) else { return false }
            if let index = vehicles.firstIndex(where: { $0.id == updated.id }) { vehicles[index] = updated }
            else { vehicles.append(updated) }
            if createsNew || previous?.id == activeVehicleID || activeVehicleID == nil {
                activeVehicleID = updated.id
                profile = updated
                rebuildCompatibleStations()
            }
            persistCarPlaySnapshot()
            errorMessage = nil
            return true
        } catch {
            if isCurrentAccount(accountRevision, userID: session?.userID) { show(error) }
            return false
        }
    }

    func selectVehicle(_ vehicle: VehicleProfile) async {
        guard vehicles.contains(where: { $0.id == vehicle.id }) else { return }
        let accountRevision = accountRevision
        let userID = session?.userID
        do {
            if let session { try await backend.setActiveVehicle(vehicle.id, session: session) }
            guard isCurrentAccount(accountRevision, userID: userID) else { return }
            activeVehicleID = vehicle.id
            profile = vehicle
            rebuildCompatibleStations()
            persistCarPlaySnapshot()
        } catch {
            if isCurrentAccount(accountRevision, userID: userID) { show(error) }
        }
    }

    func deleteVehicle(_ vehicle: VehicleProfile) async {
        guard vehicles.contains(where: { $0.id == vehicle.id }) else { return }
        let accountRevision = accountRevision
        let userID = session?.userID
        do {
            if let session { try await backend.deleteProfile(vehicle.id, session: session) }
            guard isCurrentAccount(accountRevision, userID: userID) else { return }
            vehicles.removeAll { $0.id == vehicle.id }
            let deletedActiveVehicle = activeVehicleID == vehicle.id
            if deletedActiveVehicle {
                let next = vehicles.first
                activeVehicleID = next?.id
                profile = next ?? VehicleProfile(userID: session?.userID, connectors: [], minimumPowerKW: nil)
                rebuildCompatibleStations()
            }
            persistCarPlaySnapshot()
            if deletedActiveVehicle, let session { try await backend.setActiveVehicle(activeVehicleID, session: session) }
        } catch {
            if isCurrentAccount(accountRevision, userID: userID) { show(error) }
        }
    }

    func toggleFavorite(_ station: ChargingStation) async {
        guard favoriteMutationIDs.insert(station.id).inserted else { return }
        let accountRevision = accountRevision
        let userID = session?.userID
        defer {
            if isCurrentAccount(accountRevision, userID: userID) {
                favoriteMutationIDs.remove(station.id)
            }
        }
        let previous = favorites
        let savedIDs = Set(previous.map(\.stationID))
        let matchingIDs = favoriteSourceIDsByStationID[station.id, default: []]
            .union(Self.stationIdentityIDs(station).filter { savedIDs.contains($0) })
        if !matchingIDs.isEmpty {
            favorites.removeAll { matchingIDs.contains($0.stationID) }
        } else {
            let snapshot = station.id.hasPrefix("private:") || station.source == .ownerProvided ? nil : station
            favorites.append(FavoriteStation(userID: session?.userID, stationID: station.id, stationSnapshot: snapshot, createdAt: .now))
        }
        rebuildFavorites()
        persistCarPlaySnapshot()

        guard let session else { return }
        do {
            if !matchingIDs.isEmpty {
                for stationID in matchingIDs.sorted() {
                    try await backend.deleteFavorite(stationID: stationID, session: session)
                }
            } else {
                try await backend.saveFavorite(station, session: session)
            }
        } catch {
            let operationError = error
            guard isCurrentAccount(accountRevision, userID: userID) else { return }
            if !matchingIDs.isEmpty {
                do {
                    let confirmedFavorites = try await backend.loadFavorites(session: session)
                    guard isCurrentAccount(accountRevision, userID: userID) else { return }
                    // Reconcile only this station; another charger can be saved concurrently.
                    favorites = favorites.filter { !matchingIDs.contains($0.stationID) }
                        + confirmedFavorites.filter { matchingIDs.contains($0.stationID) }
                } catch {
                    guard isCurrentAccount(accountRevision, userID: userID) else { return }
                    // The DELETE may have committed despite its failed response; keep the prior
                    // saved state until a fresh read can establish what actually remains.
                    favorites = favorites.filter { !matchingIDs.contains($0.stationID) }
                        + previous.filter { matchingIDs.contains($0.stationID) }
                    rebuildFavorites()
                    persistCarPlaySnapshot()
                    accountDataNeedsRetry = true
                    errorMessage = "Saved chargers could not be verified. Reload account data to check them."
                    return
                }
            } else {
                // A different charger's save may have completed while this request was in flight.
                favorites.removeAll { $0.stationID == station.id }
            }
            rebuildFavorites()
            persistCarPlaySnapshot()
            if !matchingIDs.isEmpty && matchingIDs.isDisjoint(with: Set(favorites.map(\.stationID))) {
                errorMessage = nil
                noticeMessage = "Saved charger removed; confirmation was interrupted."
            } else {
                show(operationError)
            }
        }
    }

    func clearMessages() {
        errorMessage = nil
        noticeMessage = nil
    }

    func retryAccountData() async {
        guard let session, !isLoadingAccountData, !isSigningOut else { return }
        let revision = accountRevision
        isLoadingAccountData = true
        defer {
            if isCurrentAccount(revision, userID: session.userID) { isLoadingAccountData = false }
        }

        do {
            try await loadAccountData()
            guard isCurrentAccount(revision, userID: session.userID) else { return }
            accountDataNeedsRetry = false
        } catch {
            guard isCurrentAccount(revision, userID: session.userID) else { return }
            accountDataNeedsRetry = true
            show(error)
        }
    }

    func showValidationError(_ message: String) {
        errorMessage = message
    }

    private func loadAccountData() async throws {
        guard let session else { return }
        let accountRevision = accountRevision
        async let loadedProfiles = backend.loadProfiles(session: session)
        async let loadedActiveID = backend.loadActiveVehicleID(session: session)
        async let loadedFavorites = backend.loadFavorites(session: session)
        let profiles = try await loadedProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selectedID = try await loadedActiveID
        let loadedFavoritesResult = try await loadedFavorites
        guard isCurrentAccount(accountRevision, userID: session.userID) else { return }
        vehicles = profiles
        let selected = profiles.first(where: { $0.id == selectedID }) ?? profiles.first
        activeVehicleID = selected?.id
        profile = selected ?? VehicleProfile(userID: session.userID, connectors: [], minimumPowerKW: nil)
        rebuildCompatibleStations()
        favorites = loadedFavoritesResult
        rebuildFavorites()
        // The account is usable before the independent charger catalog finishes loading.
        accountDataNeedsRetry = false
        isLoadingAccountData = false
        isBootstrapping = false
        await refreshStations()
    }

    func refreshAvailabilityOrderingIfNeeded(at date: Date) {
        guard needsCompatibleRebuild(at: date) else { return }
        rebuildCompatibleStations(at: date)
    }

    private func needsCompatibleRebuild(at date: Date) -> Bool {
        date < compatibleSortDate
            || (nextCompatibleStatusActivation.map { date >= $0 } ?? false)
            || (nextCompatibleStatusExpiry.map { date > $0 } ?? false)
    }

    private func rebuildCompatibleStations(at date: Date = .now, notify: Bool = true) {
        cachedCompatibleStations = StationDiscovery.compatibleStations(from: stations, profile: profile, near: currentLocation, now: date)
        compatibleSortDate = date
        nextCompatibleStatusActivation = cachedCompatibleStations.compactMap { station -> Date? in
            guard station.availability.state != .unknown, let updatedAt = station.availability.lastUpdated else { return nil }
            return updatedAt > date ? updatedAt : nil
        }.min()
        nextCompatibleStatusExpiry = cachedCompatibleStations.compactMap { station -> Date? in
            guard station.availability.state != .unknown, let updatedAt = station.availability.lastUpdated else { return nil }
            let expiry = updatedAt.addingTimeInterval(300)
            return expiry >= date ? expiry : nil
        }.min()
        if notify { compatibleResultRevision += 1 }
    }

    private func isCurrentAccount(_ revision: Int, userID: String?) -> Bool {
        accountRevision == revision && session?.userID == userID
    }

    private static func stationIdentityIDs(_ station: ChargingStation) -> Set<String> {
        var ids: Set<String> = [station.id]
        for key in ["openChargeMap", "ocm"] {
            if let id = station.sourceIDs?[key], !id.isEmpty {
                ids.insert(id.hasPrefix("ocm:") ? id : "ocm:\(id)")
            }
        }
        if let id = station.sourceIDs?["mevnet"], !id.isEmpty {
            ids.insert(id.hasPrefix("mevnet:") ? id : "mevnet:\(id)")
        }
        if let id = station.sourceIDs?["gentari"], !id.isEmpty { ids.insert(id) }
        return ids
    }

    private func rebuildFavorites() {
        guard !favorites.isEmpty else {
            favoriteStationIDs = []
            favoriteStations = []
            favoriteSourceIDsByStationID = [:]
            return
        }

        var stationIndexByID: [String: Int] = [:]
        stationIndexByID.reserveCapacity(stations.count * 2)
        for (index, station) in stations.enumerated() where stationIndexByID[station.id] == nil {
            stationIndexByID[station.id] = index
        }
        for (index, station) in stations.enumerated() {
            for id in Self.stationIdentityIDs(station) where stationIndexByID[id] == nil {
                stationIndexByID[id] = index
            }
        }

        var ids = Set(favorites.map(\.stationID))
        var visible: [ChargingStation] = []
        var visibleIDs: Set<String> = []
        var sourceIDsByStationID: [String: Set<String>] = [:]
        for favorite in favorites {
            if let index = stationIndexByID[favorite.stationID] {
                let current = stations[index]
                ids.insert(current.id)
                sourceIDsByStationID[current.id, default: []].insert(favorite.stationID)
                if visibleIDs.insert(current.id).inserted { visible.append(current) }
            } else {
                sourceIDsByStationID[favorite.stationID, default: []].insert(favorite.stationID)
                // A directory snapshot cannot prove a site is still public or licensed after it leaves the catalog.
                if let snapshot = favorite.stationSnapshot,
                    snapshot.source != .openChargeMap && snapshot.source != .mevnet && snapshot.source != .ownerProvided
                    && !favorite.stationID.hasPrefix("ocm:") && !favorite.stationID.hasPrefix("mevnet:") && !favorite.stationID.hasPrefix("private:")
                    && visibleIDs.insert(snapshot.id).inserted {
                    visible.append(snapshot)
                }
            }
        }
        favoriteStationIDs = ids
        favoriteStations = visible
        favoriteSourceIDsByStationID = sourceIDsByStationID
    }

    private func persistCarPlaySnapshot() {
        CarPlaySnapshotStore.save(stations: compatibleStations, favoriteStationIDs: favoriteStationIDs, isDemo: isDemoMode)
    }

    private func show(_ error: any Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
