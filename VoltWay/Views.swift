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
                Spacer(minLength: 28)
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
        .background(Color.voltBackground)
        .onSubmit(submit)
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.car.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.voltBlue, in: .rect(cornerRadius: 16))
                Text("VoltWay")
                    .font(.title2.weight(.bold))
            }
            Text("Find your next charge.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Compatible chargers, clear status, and a route when you need one.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Account action", selection: $mode) {
                ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("Email").font(.subheadline.weight(.semibold))
                TextField("name@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Password").font(.subheadline.weight(.semibold))
                SecureField("At least 8 characters", text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
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
    @State private var showingAccount = false

    var body: some View {
        TabView {
            NavigationStack {
                DiscoverView(store: store)
                    .toolbar { accountButton }
            }
            .tabItem { Label("Explore", systemImage: "map") }

            NavigationStack {
                TripPlannerView(store: store)
                    .toolbar { accountButton }
            }
            .tabItem { Label("Trip", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }

            NavigationStack {
                FavoritesView(store: store)
                    .toolbar { accountButton }
            }
            .tabItem { Label("Saved", systemImage: "heart") }
        }
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                AccountView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAccount = false }
                        }
                    }
            }
        }
    }

    @ToolbarContentBuilder private var accountButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Account", systemImage: "person.crop.circle") { showingAccount = true }
                .accessibilityLabel("Account and vehicle")
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
    @State private var displayMode = DisplayMode.map
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
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
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
            LazyVStack(alignment: .leading, spacing: 16) {
                messages
                discoveryControls
                resultsHeader

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
                        Divider().padding(.leading, 58)
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
                    messages
                    discoveryControls
                    resultsHeader
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 380 : 290)

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
        if store.isDemoMode {
            Label("Demo chargers · not live", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if let lastSuccessfulStationFetchAt = store.lastSuccessfulStationFetchAt {
            Label("Station list last fetched \(lastSuccessfulStationFetchAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = store.errorMessage {
            MessageBanner(message: error, isError: true, dismiss: store.clearMessages)
        }
    }

    private var resultsHeader: some View {
        HStack {
            Text("\(visibleStations.count) compatible chargers")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if store.isLoadingStations {
                ProgressView().controlSize(.small)
            } else if !store.isDemoMode {
                Button("Refresh chargers", systemImage: "arrow.clockwise") {
                    Task { await store.refreshStations() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }
        }
    }

    private var discoveryControls: some View {
        VStack(spacing: 12) {
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

            Picker("Charger view", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("Available now", isOn: $availableNowOnly)
                    .font(.subheadline.weight(.medium))
                    .accessibilityHint("Shows only chargers with a fresh available status and a positive connector count")
                if displayMode == .list {
                    Button("Use my location", systemImage: "location") {
                        Task { await store.useCurrentLocation() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                }
            }
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

struct StationRow: View {
    let station: ChargingStation
    let distance: Double?
    let isFavorite: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
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
        .padding(.vertical, 12)
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
    @State private var selectedEnergyKWh = 20
    @State private var freshnessTime = Date.now
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFavorite: Bool { store.favoriteStationIDs.contains(station.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeader
                statusCard
                alternativeChargers
                costEstimateCard
                connectorCard
            }
            .padding(20)
        }
        .background(Color.voltBackground)
        .safeAreaInset(edge: .bottom) {
            Button {
                MapsHandoff.open(station)
            } label: {
                Label("Navigate with Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .buttonStyle(VoltPrimaryButtonStyle())
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
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
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { time in
            freshnessTime = time
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

    private var alternativeChargers: some View {
        let alternatives = StationDiscovery.nearbyAlternatives(
            to: station, compatibleStations: store.compatibleStations, now: freshnessTime
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text("Other compatible chargers")
                .font(.title3.weight(.bold))
            Text("Within 10 km of this charger · straight-line distance")
                .font(.caption)
                .foregroundStyle(.secondary)
            if alternatives.isEmpty {
                Text("No other compatible chargers within 10 km.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alternatives) { alternative in
                    NavigationLink {
                        StationDetailView(station: alternative, store: store)
                    } label: {
                        StationRow(
                            station: alternative,
                            distance: alternative.distance(from: station.coordinate),
                            isFavorite: store.favoriteStationIDs.contains(alternative.id)
                        )
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var connectorCard: some View {
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
                Divider()
            }
        }
    }

    private var costEstimateCard: some View {
        let estimate = ChargingCostEstimate.amount(for: station.price, energyKWh: selectedEnergyKWh)
        return VoltSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Energy cost estimate")
                    .font(.headline)
                energyPicker

                if let estimate {
                    let priceText = station.price?.displayText() ?? "Price unavailable"
                    Text(estimate.formatted(.currency(code: "MYR").precision(.fractionLength(2))))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .contentTransition(.numericText())
                    Text("For \(selectedEnergyKWh) kWh at \(priceText). Energy only; excludes fees and does not estimate your battery’s state of charge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Estimate unavailable")
                        .font(.title3.weight(.semibold))
                    Text(estimateUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .animation(reduceMotion ? nil : .default, value: selectedEnergyKWh)
    }

    @ViewBuilder private var energyPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Menu {
                ForEach([10, 20, 40], id: \.self) { amount in
                    Button("\(amount) kWh") { selectedEnergyKWh = amount }
                }
            } label: {
                Label("\(selectedEnergyKWh) kWh", systemImage: "bolt")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Energy amount, \(selectedEnergyKWh) kilowatt-hours")
        } else {
            Picker("Energy amount", selection: $selectedEnergyKWh) {
                ForEach([10, 20, 40], id: \.self) { amount in
                    Text("\(amount) kWh").tag(amount)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose an energy amount to estimate its cost")
        }
    }

    private var estimateUnavailableReason: String {
        guard let price = station.price else { return "A current MYR per-kWh price has not been reported." }
        guard price.unit == .kWh else { return "This charger reports a per-\(price.unit == .minute ? "minute" : "session") price, so an energy-only estimate cannot be calculated." }
        guard !price.isStale() else { return "The reported per-kWh price is missing its update time or is older than 24 hours." }
        return "A valid per-kWh price is unavailable."
    }

    private var priceLabel: some View {
        Text(station.price?.displayText() ?? "Price unavailable")
            .font(.title3.weight(.bold))
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }

    private func updateText(_ field: String, at date: Date?) -> String {
        guard let date else { return "\(field) update time unavailable" }
        return "\(field) updated \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct TripDestination: Identifiable, Hashable {
    let name: String
    let address: String
    let coordinate: Coordinate

    var id: String { "\(name)|\(coordinate.latitude)|\(coordinate.longitude)" }
}

struct TripPlannerView: View {
    let store: VoltWayStore
    @State private var destinationQuery = ""
    @State private var destinations: [TripDestination] = []
    @State private var selectedDestination: TripDestination?
    @State private var isSearching = false
    @State private var isPlanning = false
    @State private var routeCoordinates: [Coordinate] = []
    @State private var routeStops: [RouteStopCandidate] = []
    @State private var routeDistanceMeters: Double?
    @State private var routeTravelTime: TimeInterval?
    @State private var routeMessage: String?
    @State private var searchMessage: String?
    @State private var selectedStationID: String?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showingVehicleProfile = false

    private var selectedStation: ChargingStation? {
        routeStops.first { $0.station.id == selectedStationID }?.station
    }

    private var selectedStationBinding: Binding<ChargingStation?> {
        Binding(get: { selectedStation }, set: { selectedStationID = $0?.id })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                if store.isDemoMode {
                    Label("Demo charger data · not live", systemImage: "info.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.voltBlue)
                        .padding(.vertical, 4)
                }
                if let error = store.errorMessage {
                    MessageBanner(message: error, isError: true, dismiss: store.clearMessages)
                }
                destinationSearch
                if let searchMessage { MessageBanner(message: searchMessage, isError: true, dismiss: { self.searchMessage = nil }) }
                if !destinations.isEmpty { destinationResults }
                if let selectedDestination { chosenDestination(selectedDestination) }
                if let routeMessage { MessageBanner(message: routeMessage, isError: true, dismiss: { self.routeMessage = nil }) }
                if !routeCoordinates.isEmpty { routeResults }
            }
            .padding(20)
        }
        .background(Color.voltBackground)
        .navigationTitle("Trip")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingVehicleProfile) {
            NavigationStack { VehicleProfileView(store: store) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: selectedStationBinding) { station in
            NavigationStack {
                StationDetailView(station: station, store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selectedStationID = nil }
                        }
                    }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where are you going?")
                .font(.system(.title, design: .rounded).weight(.bold))
            Text("Choose a destination to see compatible chargers along the drive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("VoltWay doesn’t save trip details. Apple MapKit processes your location and destination for routing.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var destinationSearch: some View {
        VoltSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Destination")
                    .font(.subheadline.weight(.semibold))
                TextField("City, place or address", text: $destinationQuery)
                    .textContentType(.fullStreetAddress)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await searchDestinations() } }
                Button {
                    Task { await searchDestinations() }
                } label: {
                    if isSearching { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Search destination", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                }
                .buttonStyle(VoltPrimaryButtonStyle())
                .disabled(isSearching || destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var destinationResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a destination")
                .font(.headline)
            ForEach(destinations) { destination in
                Button {
                    selectedDestination = destination
                    routeCoordinates = []
                    routeStops = []
                    routeMessage = nil
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(destination.name).font(.headline).foregroundStyle(.primary)
                        Text(destination.address).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func chosenDestination(_ destination: TripDestination) -> some View {
        VoltSurface {
            VStack(alignment: .leading, spacing: 12) {
                Label("Destination", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Text(destination.name).font(.title3.weight(.semibold))
                Text(destination.address).font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task { await planRoute(to: destination) }
                } label: {
                    if isPlanning || store.isLoadingStations { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Find chargers along route", systemImage: "point.topleft.down.to.point.bottomright.curvepath").frame(maxWidth: .infinity) }
                }
                .buttonStyle(VoltPrimaryButtonStyle())
                .disabled(isPlanning || store.isLoadingStations || store.profile.connectors.isEmpty)
                if store.isLoadingStations {
                    Text("Loading compatible chargers…").font(.caption).foregroundStyle(.secondary)
                }
                if store.profile.connectors.isEmpty {
                    Button("Set up vehicle connectors") { showingVehicleProfile = true }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder private var routeResults: some View {
        if let routeDistanceMeters, let routeTravelTime {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended driving route").font(.title2.weight(.bold))
                    Text("\((routeDistanceMeters / 1_000).formatted(.number.precision(.fractionLength(0)))) km · \(Int((routeTravelTime / 60).rounded())) min")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                routeMap
                    .frame(height: 340)
                    .clipShape(.rect(cornerRadius: 18))
                Text("Compatible chargers within 5 km of route")
                    .font(.title3.weight(.bold))
                if routeStops.isEmpty {
                    EmptyState(
                        icon: "bolt.slash",
                        title: "No chargers along this route",
                        detail: "No compatible stations were found within 5 km of the recommended route.",
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    ForEach(routeStops, id: \.station.id) { stop in
                        NavigationLink {
                            StationDetailView(station: stop.station, store: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                StationRow(station: stop.station, distance: nil, isFavorite: store.favoriteStationIDs.contains(stop.station.id))
                                Label("\(distanceText(stop.offRouteMeters)) from route", systemImage: "arrow.turn.up.right")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 10)
                            }
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                Text("Stations are listed in travel order. Off-route distance is measured to the route geometry, not a road detour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var routeMap: some View {
        Map(position: $cameraPosition, selection: $selectedStationID) {
            if routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(Color.voltBlue, lineWidth: 5)
            }
            if let first = routeCoordinates.first {
                Marker("Start", systemImage: "location.fill", coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                    .tint(Color.voltBlue)
            }
            if let last = routeCoordinates.last {
                Marker("Destination", systemImage: "mappin.and.ellipse", coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                    .tint(.red)
            }
            ForEach(routeStops, id: \.station.id) { stop in
                Marker(stop.station.name, systemImage: "bolt.car.fill", coordinate: CLLocationCoordinate2D(latitude: stop.station.coordinate.latitude, longitude: stop.station.coordinate.longitude))
                    .tint(stop.station.availability.isReportedAvailable() ? Color.voltMint : Color.voltBlue)
                    .tag(stop.station.id)
            }
        }
        .mapControls { MapCompass() }
        .accessibilityLabel("Recommended route with \(routeStops.count) compatible charger stops")
    }

    private func searchDestinations() async {
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchMessage = nil
        destinations = []
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 4.2, longitude: 102.0),
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
        )
        do {
            let response = try await MKLocalSearch(request: request).start()
            destinations = response.mapItems.compactMap { item in
                guard let name = item.name else { return nil }
                let coordinate = item.placemark.coordinate
                guard (0.8...7.5).contains(coordinate.latitude), (99.5...119.8).contains(coordinate.longitude) else { return nil }
                return TripDestination(
                    name: name,
                    address: item.placemark.title ?? "Malaysia",
                    coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                )
            }
            if destinations.isEmpty { searchMessage = "No matching destinations were found. Try another place name or address." }
        } catch {
            searchMessage = "Destination search failed. Check your connection and try again."
        }
    }

    private func planRoute(to destination: TripDestination) async {
        isPlanning = true
        routeMessage = nil
        routeCoordinates = []
        routeStops = []
        routeDistanceMeters = nil
        routeTravelTime = nil
        defer { isPlanning = false }

        guard let origin = await store.useCurrentLocation() else {
            routeMessage = "Location is unavailable or denied. Allow location access in Settings to plan this trip."
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.coordinate.latitude, longitude: destination.coordinate.longitude)))
        request.transportType = .automobile
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                routeMessage = "No driving route was found between your location and the selected destination."
                return
            }
            var coordinates = Array(repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: route.polyline.pointCount))
            routeCoordinates = coordinates.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            routeStops = RouteStopMatcher.stops(along: routeCoordinates, compatibleStations: store.compatibleStations)
            routeDistanceMeters = route.distance
            routeTravelTime = route.expectedTravelTime
            cameraPosition = .region(routeRegion(for: routeCoordinates))
        } catch {
            routeMessage = "No route could be calculated. Check your connection or choose another destination."
        }
    }

    private func routeRegion(for coordinates: [Coordinate]) -> MKCoordinateRegion {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let latitudeSpan = max((latitudes.max() ?? 0) - (latitudes.min() ?? 0), 0.025) * 1.3
        let longitudeSpan = max((longitudes.max() ?? 0) - (longitudes.min() ?? 0), 0.025) * 1.3
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: ((latitudes.max() ?? 0) + (latitudes.min() ?? 0)) / 2, longitude: ((longitudes.max() ?? 0) + (longitudes.min() ?? 0)) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 1_000 ? "\(Int(meters.rounded())) m" : "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
    }
}

struct FavoritesView: View {
    let store: VoltWayStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isDemoMode {
                    Label("Demo chargers · not live", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 18)
                }
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
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.voltBackground)
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
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
        .navigationBarTitleDisplayMode(.inline)
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
