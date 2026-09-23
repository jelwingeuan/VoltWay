import Combine
import MapKit
import SwiftUI

struct RootView: View {
    let store: VoltWayStore

    var body: some View {
        Group {
            if store.isBootstrapping {
                ZStack {
                    Color.voltBackground.ignoresSafeArea()
                    ProgressView("Preparing VoltWay…")
                }
            } else if store.isDemoMode || store.session != nil {
                MainTabView(store: store)
            } else {
                AuthenticationView(store: store)
            }
        }
    }
}

struct AuthenticationView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in"
        case createAccount = "Create account"
        var id: String { rawValue }
    }

    enum Field { case email, password }

    let store: VoltWayStore
    @State private var mode = Mode.signIn
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 48)
                brand
                credentials
                messages
                submitButton
                if mode == .signIn {
                    Button("Forgot password?") {
                        Task { await store.requestPasswordReset(email: email) }
                    }
                    .frame(maxWidth: .infinity)
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(background)
        .onSubmit(submit)
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.voltBlue.gradient)
                Image(systemName: "bolt.car.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 68, height: 68)
            .accessibilityHidden(true)

            Text("VoltWay")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Find a compatible charger. Know its status. Keep moving.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var credentials: some View {
        VoltSurface {
            VStack(spacing: 18) {
                Picker("Account action", selection: $mode) {
                    ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }

                Divider()

                SecureField("Password", text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)

                Text("Use at least 8 characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = store.errorMessage {
            MessageBanner(message: error, isError: true, dismiss: store.clearMessages)
        } else if let notice = store.noticeMessage {
            MessageBanner(message: notice, isError: false, dismiss: store.clearMessages)
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Group {
                if store.isAuthenticating {
                    ProgressView().tint(.white)
                } else {
                    Text(mode.rawValue)
                }
            }
        }
        .buttonStyle(VoltPrimaryButtonStyle())
        .disabled(store.isAuthenticating)
    }

    private var background: some View {
        ZStack {
            Color.voltBackground
            Circle()
                .fill(Color.voltBlue.opacity(0.17))
                .frame(width: 360, height: 360)
                .blur(radius: 50)
                .offset(x: 150, y: -280)
        }
        .ignoresSafeArea()
    }

    private func submit() {
        focusedField = nil
        Task {
            switch mode {
            case .signIn: await store.signIn(email: email, password: password)
            case .createAccount: await store.signUp(email: email, password: password)
            }
        }
    }
}

struct MainTabView: View {
    let store: VoltWayStore

    var body: some View {
        TabView {
            NavigationStack { DiscoverView(store: store) }
                .tabItem { Label("Chargers", systemImage: "bolt.car") }

            NavigationStack { FavoritesView(store: store) }
                .tabItem { Label("Saved", systemImage: "heart") }

            NavigationStack { AccountView(store: store) }
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
    }
}

struct DiscoverView: View {
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case list = "List"
        case map = "Map"

        var id: Self { self }
    }

    let store: VoltWayStore
    @State private var showingVehicleProfile = false
    @State private var showsDemoBanner = true
    @State private var displayMode = DisplayMode.list
    @State private var searchText = ""
    @State private var availableNowOnly = false
    @State private var selectedStationID: String?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var freshnessTime = Date.now
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visibleStations: [ChargingStation] {
        StationDiscovery.visibleStations(
            from: store.compatibleStations,
            query: searchText,
            availableNowOnly: availableNowOnly,
            now: freshnessTime
        )
    }

    private var selectedStation: ChargingStation? {
        visibleStations.first { $0.id == selectedStationID }
    }

    private var accessibilityStationSelection: Binding<ChargingStation?> {
        Binding(
            get: { dynamicTypeSize.isAccessibilitySize && displayMode == .map ? selectedStation : nil },
            set: { selectedStationID = $0?.id }
        )
    }

    var body: some View {
        Group {
            switch displayMode {
            case .list: listContent
            case .map: mapContent
            }
        }
        .background(Color.voltBackground)
        .navigationTitle("VoltWay")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Vehicle", systemImage: "car.side") { showingVehicleProfile = true }
                    .accessibilityLabel("Edit vehicle profile")
            }
        }
        .sheet(isPresented: $showingVehicleProfile) {
            NavigationStack { VehicleProfileView(store: store) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: accessibilityStationSelection) { station in
            NavigationStack {
                ScrollView {
                    StationMapPreview(station: station, store: store)
                        .padding(20)
                }
                .background(Color.voltBackground)
                .navigationTitle("Selected charger")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { selectedStationID = nil }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .onChange(of: visibleStations.map(\.id)) { _, stationIDs in
            if let selectedStationID, !stationIDs.contains(selectedStationID) {
                self.selectedStationID = nil
            }
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { time in
            freshnessTime = time
        }
        .task {
            if store.stations.isEmpty && !store.profile.connectors.isEmpty { await store.refreshStations() }
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                messages

                discoveryControls

                DiscoveryHero(
                    stationCount: visibleStations.count,
                    profileSummary: store.profileSummary,
                    hasLocation: store.currentLocation != nil,
                    isLoading: store.isLoadingStations,
                    locate: { Task { await store.useCurrentLocation() } },
                    editVehicle: { showingVehicleProfile = true }
                )

                HStack(alignment: .firstTextBaseline) {
                    Text("Compatible chargers")
                        .font(.title2.weight(.bold))
                    Spacer()
                    if store.isLoadingStations { ProgressView().controlSize(.small) }
                }

                if hasNoResults {
                    emptyResults
                } else {
                    ForEach(visibleStations) { station in
                        NavigationLink {
                            StationDetailView(station: station, store: store)
                        } label: {
                            StationRow(
                                station: station,
                                distance: station.distance(from: store.currentLocation),
                                isFavorite: store.favoriteStationIDs.contains(station.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .refreshable { await store.refreshStations() }
    }

    private var mapContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    mapMessages
                    discoveryControls
                    HStack {
                        Text("\(visibleStations.count) compatible chargers")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if store.isLoadingStations { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 370 : 380)

            if hasNoResults {
                ScrollView {
                    emptyResults
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                }
            } else {
                Map(position: $mapPosition, selection: $selectedStationID) {
                    ForEach(visibleStations) { station in
                        Marker(
                            station.name,
                            systemImage: "bolt.car.fill",
                            coordinate: station.coordinate.coreLocation.coordinate
                        )
                        .tint(station.availability.isReportedAvailable(at: freshnessTime) ? Color.voltMint : Color.voltBlue)
                        .tag(station.id)
                    }
                }
                .mapControls { MapCompass() }
                .overlay(alignment: .topTrailing) {
                    Button {
                        Task { await locateOnMap() }
                    } label: {
                        Label("Use my location", systemImage: "location.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .padding(14)
                }
                .safeAreaInset(edge: .bottom) {
                    if !dynamicTypeSize.isAccessibilitySize, let selectedStation {
                        StationMapPreview(station: selectedStation, store: store)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if store.isDemoMode && showsDemoBanner {
            MessageBanner(
                message: "Demo data is active. Connect Supabase and the Gentari feed for live status.",
                isError: false,
                dismiss: { showsDemoBanner = false }
            )
        }
        if let error = store.errorMessage {
            MessageBanner(message: error, isError: true, dismiss: store.clearMessages)
        }
    }

    @ViewBuilder private var mapMessages: some View {
        if store.isDemoMode && showsDemoBanner {
            MessageBanner(
                message: "Demo · not live",
                isError: false,
                dismiss: { showsDemoBanner = false }
            )
        }
        if let error = store.errorMessage {
            MessageBanner(message: error, isError: true, dismiss: store.clearMessages)
        }
    }

    private var discoveryControls: some View {
        VStack(spacing: 12) {
            Picker("Charger view", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search name or address", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { searchText = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.voltSurface, in: .rect(cornerRadius: 14))

            Toggle("Available now", isOn: $availableNowOnly)
                .font(.subheadline.weight(.medium))
                .accessibilityHint("Shows only chargers with a fresh available status and a positive connector count")
        }
    }

    private var hasNoResults: Bool {
        store.profile.connectors.isEmpty
            || (!store.isLoadingStations && visibleStations.isEmpty)
    }

    @ViewBuilder private var emptyResults: some View {
        if store.profile.connectors.isEmpty {
            EmptyState(
                icon: "car.side.lock",
                title: "Add your EV",
                detail: "Choose its connectors before searching for compatible chargers.",
                actionTitle: "Set up vehicle",
                action: { showingVehicleProfile = true }
            )
        } else if store.errorMessage != nil && store.stations.isEmpty {
            EmptyState(
                icon: "wifi.exclamationmark",
                title: "Chargers unavailable",
                detail: "We couldn't load chargers. Try again when you have a connection.",
                actionTitle: "Retry",
                action: { Task { await store.refreshStations() } }
            )
        } else if store.compatibleStations.isEmpty {
            EmptyState(
                icon: "bolt.slash",
                title: "No compatible chargers",
                detail: "Try lowering the minimum power or changing your connector selection.",
                actionTitle: "Edit vehicle",
                action: { showingVehicleProfile = true }
            )
        } else {
            EmptyState(
                icon: "magnifyingglass",
                title: "No matching chargers",
                detail: "Try another search or turn off Available now.",
                actionTitle: "Clear filters",
                action: {
                    searchText = ""
                    availableNowOnly = false
                }
            )
        }
    }

    private func locateOnMap() async {
        guard let location = await store.useCurrentLocation() else { return }
        mapPosition = .region(MKCoordinateRegion(
            center: location.coreLocation.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
        ))
    }
}

private struct StationMapPreview: View {
    let station: ChargingStation
    let store: VoltWayStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VoltSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text(station.name)
                    .font(.headline)
                Text(station.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        AvailabilityPill(availability: station.availability)
                        priceText
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        detailsLink
                        navigateButton
                    }
                } else {
                    HStack {
                        AvailabilityPill(availability: station.availability)
                        Spacer(minLength: 8)
                        priceText
                    }
                    HStack(spacing: 16) {
                        detailsLink
                        Spacer()
                        navigateButton
                    }
                }
            }
        }
    }

    private var priceText: some View {
        Text(station.price?.displayText() ?? "Price unavailable")
            .font(.caption.weight(.semibold))
    }

    private var detailsLink: some View {
        NavigationLink("Details") {
            StationDetailView(station: station, store: store)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var navigateButton: some View {
        Button("Navigate with Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond") {
            MapsHandoff.open(station)
        }
        .font(.subheadline.weight(.semibold))
    }
}

struct DiscoveryHero: View {
    let stationCount: Int
    let profileSummary: String
    let hasLocation: Bool
    let isLoading: Bool
    let locate: () -> Void
    let editVehicle: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("READY FOR THE ROAD")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.72))
                    Text("\(stationCount) matches")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    Text(profileSummary.isEmpty ? "Vehicle setup required" : profileSummary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                }
                Spacer()
                Image(systemName: "bolt.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.voltMint)
                    .padding(14)
                    .background(.white.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { heroActions }
            } else {
                HStack(spacing: 12) { heroActions }
            }

            Label("Location is used in memory only and is never saved.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
        }
        .padding(22)
        .background(
            LinearGradient(colors: [Color.voltInk, Color.voltBlue.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(.rect(cornerRadius: 26))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var heroActions: some View {
        Button(action: locate) {
            Label(hasLocation ? "Location updated" : "Use my location", systemImage: hasLocation ? "location.fill" : "location")
        }
        .buttonStyle(VoltGlassButtonStyle())
        .foregroundStyle(.white)
        .disabled(isLoading)

        Button("Edit EV", action: editVehicle)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .frame(minHeight: 44)
    }
}

struct StationRow: View {
    let station: ChargingStation
    let distance: Double?
    let isFavorite: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VoltSurface {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "bolt.car.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.voltBlue)
                    .frame(width: 44, height: 44)
                    .background(Color.voltBlue.opacity(0.10), in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(station.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if isFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(Color.voltBlue)
                                .accessibilityLabel("Favorite")
                        }
                    }
                    Text(station.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        AvailabilityPill(availability: station.availability)
                        if let distance {
                            Text(distanceText(distance))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            connectorSummary
                            priceLabel
                        }
                    } else {
                        HStack {
                            connectorSummary
                            Spacer(minLength: 4)
                            priceLabel
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
    }

    private var connectorSummary: some View {
        Text(station.connectorSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    private var priceLabel: some View {
        Text(station.price?.displayText() ?? "Price unavailable")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

struct StationDetailView: View {
    let station: ChargingStation
    let store: VoltWayStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isFavorite: Bool { store.favoriteStationIDs.contains(station.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeader
                statusCard
                connectorCard
                Button {
                    MapsHandoff.open(station)
                } label: {
                    Label("Navigate with Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(VoltPrimaryButtonStyle())
            }
            .padding(20)
        }
        .background(Color.voltBackground)
        .navigationTitle("Charger")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.toggleFavorite(station) }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                }
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(station.operatorName.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(Color.voltBlue)
            Text(station.name)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(station.address)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        VoltSurface {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        AvailabilityPill(availability: station.availability)
                        priceLabel
                    }
                } else {
                    HStack {
                        AvailabilityPill(availability: station.availability)
                        Spacer(minLength: 4)
                        priceLabel
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(updateText("Status", at: station.availability.lastUpdated))
                    Text(updateText("Price", at: station.price?.lastUpdated))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var connectorCard: some View {
        VoltSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connectors")
                    .font(.headline)
                ForEach(station.connectors, id: \.self) { connector in
                    HStack {
                        Label(connector.kind.title, systemImage: connector.kind.systemImage)
                        Spacer()
                        Text("\(connector.powerKW.formatted(.number.precision(.fractionLength(0)))) kW · \(connector.count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var priceLabel: some View {
        Text(station.price?.displayText() ?? "Price unavailable")
            .font(.headline)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }

    private func updateText(_ field: String, at date: Date?) -> String {
        guard let date else { return "\(field) update time unavailable" }
        return "\(field) updated \(date.formatted(.relative(presentation: .named)))"
    }
}

struct FavoritesView: View {
    let store: VoltWayStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if store.favoriteStations.isEmpty {
                    EmptyState(
                        icon: "heart",
                        title: "No saved chargers",
                        detail: "Save a reliable charger to keep it one tap away.",
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    ForEach(store.favoriteStations) { station in
                        NavigationLink {
                            StationDetailView(station: station, store: store)
                        } label: {
                            StationRow(station: station, distance: station.distance(from: store.currentLocation), isFavorite: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.voltBackground)
        .navigationTitle("Saved")
    }
}

struct AccountView: View {
    let store: VoltWayStore
    @State private var showingVehicleProfile = false

    var body: some View {
        List {
            Section("Vehicle") {
                Button {
                    showingVehicleProfile = true
                } label: {
                    Label(store.profileSummary.isEmpty ? "Set up vehicle" : store.profileSummary, systemImage: "car.side")
                }
            }

            Section("Privacy") {
                Label("Location is never persisted", systemImage: "location.slash")
                Label("Session stored in Keychain", systemImage: "key.fill")
                Label("Partner credentials stay on the server", systemImage: "server.rack")
            }

            if store.isDemoMode {
                Section("Environment") {
                    Text("Demo mode")
                    Text("Configure SUPABASE_URL and SUPABASE_ANON_KEY to enable accounts and live data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await store.signOut() }
                    }
                }
            }
        }
        .navigationTitle("Account")
        .sheet(isPresented: $showingVehicleProfile) {
            NavigationStack { VehicleProfileView(store: store) }
                .presentationDetents([.medium, .large])
        }
    }
}

struct VehicleProfileView: View {
    let store: VoltWayStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedConnectors: Set<ConnectorKind>
    @State private var minimumPower: String
    @State private var isSaving = false

    init(store: VoltWayStore) {
        self.store = store
        selectedConnectors = Set(store.profile.connectors)
        minimumPower = store.profile.minimumPowerKW.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? ""
    }

    var body: some View {
        Form {
            Section {
                ForEach(ConnectorKind.allCases) { connector in
                    Button {
                        toggle(connector)
                    } label: {
                        HStack {
                            Label(connector.title, systemImage: connector.systemImage)
                            Spacer()
                            if selectedConnectors.contains(connector) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.voltBlue)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(selectedConnectors.contains(connector) ? .isSelected : [])
                }
            } header: {
                Text("Connectors")
            } footer: {
                Text("Choose every connector your EV can use.")
            }

            Section("Minimum power") {
                TextField("Optional, for example 50", text: $minimumPower)
                    .keyboardType(.decimalPad)
                Text("Only chargers with at least this power will appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Your EV")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(isSaving || selectedConnectors.isEmpty)
            }
        }
    }

    private func toggle(_ connector: ConnectorKind) {
        if selectedConnectors.contains(connector) {
            selectedConnectors.remove(connector)
        } else {
            selectedConnectors.insert(connector)
        }
    }

    private func save() {
        let normalized = minimumPower.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let power = normalized.isEmpty ? nil : Double(normalized)
        isSaving = true
        Task {
            let saved = await store.saveProfile(connectors: selectedConnectors, minimumPowerKW: power)
            isSaving = false
            if saved { dismiss() }
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VoltSurface {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.voltBlue)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(VoltGlassButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
    }
}
