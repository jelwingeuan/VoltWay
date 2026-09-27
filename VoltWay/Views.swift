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
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color.voltBackground)
        .onSubmit(submit)
    }

    private var brand: some View {
        VoltGlassPanel(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.car.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.voltBlue.gradient)
                        }
                    Text("VoltWay")
                        .font(.title2.weight(.bold))
                }
                Text("Find chargers across Malaysia.")
                    .font(.largeTitle.weight(.bold))
                Text("Explore compatible networks. See live status only when a partner provides it.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var credentials: some View {
        VoltSurface {
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
                    ProgressView()
                } else {
                    Text(mode.rawValue)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.glassProminent)
        .tint(.voltBlue)
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

    var body: some View {
        TabView {
            Tab("Explore", systemImage: "map") {
                NavigationStack {
                    DiscoverView(store: store)
                }
            }

            Tab("Trip", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                NavigationStack {
                    TripPlannerView(store: store)
                }
            }

            Tab("Saved", systemImage: "heart") {
                NavigationStack {
                    FavoritesView(store: store)
                }
            }

            Tab("Profile", systemImage: "person.crop.circle") {
                NavigationStack {
                    ProfileView(store: store)
                }
            }
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
    @State private var showingFilters = false
    @State private var stationPreviewDetent: PresentationDetent = .medium
    @State private var displayMode = DisplayMode.map
    @State private var searchText = ""
    @State private var availableNowOnly = false
    @State private var showAllSites = false
    @State private var chargingType: ChargingType?
    @State private var minimumListedPowerKW: Double?
    @State private var accessFilter: StationAccess?
    @State private var selectedNetwork: String?
    @State private var selectedStationID: String?
    @State private var mapRecenterRequest: MapRecenterRequest?
    @State private var freshnessTime = Date.now
    @FocusState private var searchIsFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visibleStations: [ChargingStation] {
        StationDiscovery.visibleStations(
            from: showAllSites ? store.stations : store.compatibleStations,
            query: searchText,
            availableNowOnly: availableNowOnly,
            network: selectedNetwork,
            profile: store.profile,
            showAll: showAllSites,
            chargingType: chargingType,
            minimumListedPowerKW: minimumListedPowerKW,
            access: accessFilter,
            now: freshnessTime
        )
    }

    private var networks: [String] {
        StationDiscovery.networks(from: showAllSites ? store.stations : store.compatibleStations)
    }

    private var selectedStation: ChargingStation? {
        visibleStations.first { $0.id == selectedStationID }
    }

    private var stationSelection: Binding<ChargingStation?> {
        Binding(
            get: { selectedStation },
            set: { selectedStationID = $0?.id }
        )
    }

    private var stationPreviewDetents: Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.height(340), .medium, .large]
    }

    private var compactStationPreviewDetent: PresentationDetent { .height(340) }

    private var activeFilterCount: Int {
        [chargingType != nil, minimumListedPowerKW != nil, accessFilter != nil]
            .filter { $0 }
            .count
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
        .sheet(item: stationSelection) { station in
            NavigationStack {
                ScrollView {
                    StationMapPreview(
                        station: station,
                        store: store,
                        isExpanded: dynamicTypeSize.isAccessibilitySize || stationPreviewDetent != compactStationPreviewDetent
                    )
                        .padding(20)
                }
                .background(Color.voltBackground)
                .navigationTitle("Charger")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { selectedStationID = nil }
                    }
                }
            }
            .presentationDetents(stationPreviewDetents, selection: $stationPreviewDetent)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingFilters) { filtersSheet }
        .onChange(of: selectedStationID) { _, stationID in
            guard stationID != nil else { return }
            stationPreviewDetent = dynamicTypeSize.isAccessibilitySize ? .medium : compactStationPreviewDetent
        }
        .onChange(of: visibleStations.map(\.id)) { _, stationIDs in
            if let selectedStationID, !stationIDs.contains(selectedStationID) {
                self.selectedStationID = nil
            }
        }
        .onChange(of: networks) { _, currentNetworks in
            if let selectedNetwork, !currentNetworks.contains(selectedNetwork) {
                self.selectedNetwork = nil
            }
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { time in
            freshnessTime = time
        }
        .task {
            if store.stations.isEmpty { await store.refreshStations() }
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                discoveryChrome

                if hasNoResults {
                    emptyResults
                } else {
                    ForEach(visibleStations) { station in
                        Button {
                            selectedStationID = station.id
                        } label: {
                            StationRow(
                                station: station,
                                distance: station.distance(from: store.currentLocation),
                                isFavorite: store.favoriteStationIDs.contains(station.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows charger status, price, and actions")
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
        ChargerMapView(
            stations: visibleStations,
            freshnessTime: freshnessTime,
            recenterRequest: mapRecenterRequest,
            selectedStationID: $selectedStationID
        )
        .ignoresSafeArea()
        .safeAreaInset(edge: .top, spacing: 0) { mapChrome }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasNoResults {
                emptyResults
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private var filtersSheet: some View {
        NavigationStack {
            Form {
                Section("Charger") {
                    Picker("Charging type", selection: $chargingType) {
                        Text("AC and DC").tag(ChargingType?.none)
                        ForEach(ChargingType.allCases) { type in Text(type.rawValue).tag(Optional(type)) }
                    }
                    Picker("Listed power", selection: $minimumListedPowerKW) {
                        Text("Any listed power").tag(Double?.none)
                        Text("50+ kW").tag(Optional(50.0))
                        Text("150+ kW").tag(Optional(150.0))
                    }
                    Picker("Access", selection: $accessFilter) {
                        Text("All access types").tag(StationAccess?.none)
                        Text("Public").tag(Optional(StationAccess.publicAccess))
                        Text("Limited").tag(Optional(StationAccess.limited))
                        Text("Unknown").tag(Optional(StationAccess.unknown))
                        Text("Private · invited").tag(Optional(StationAccess.privateAccess))
                    }
                }
                Section {
                    Text("Filters apply the same way to Map and List. Directory locations do not provide live availability or prices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingFilters = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if activeFilterCount > 0 {
                        Button("Clear") {
                            chargingType = nil
                            minimumListedPowerKW = nil
                            accessFilter = nil
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var mapChrome: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    discoveryChrome
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 340)
            } else {
                discoveryChrome
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
        }
    }

    private var discoveryChrome: some View {
        VStack(alignment: .leading, spacing: 10) {
            discoveryControls
            Group {
                if store.isDemoMode {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            DemoNotice()
                            Spacer(minLength: 0)
                            resultsHeader
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            DemoNotice()
                            resultsHeader
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Color.voltSurface, in: Capsule())
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        messages
                        resultsHeader
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.voltSurface, in: .rect(cornerRadius: 14))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var messages: some View {
        if let lastSuccessfulStationFetchAt = store.lastSuccessfulStationFetchAt {
            Label("Station list last fetched \(lastSuccessfulStationFetchAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let catalogSyncedAt = store.catalogSyncedAt {
            Label("Open Charge Map directory synced \(catalogSyncedAt.formatted(.relative(presentation: .named))) · not live status", systemImage: "books.vertical")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(store.sourceWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let error = store.errorMessage {
            MessageBanner(message: error, isError: true, dismiss: store.clearMessages)
        }
    }

    private var resultsHeader: some View {
        HStack {
            Text("\(visibleStations.count) sites · \(networks.count) networks")
                .font(.caption.weight(.semibold))
            if store.isLoadingStations {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    private var discoveryControls: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ZStack(alignment: .leading) {
                        TextField("", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($searchIsFocused)
                            .accessibilityLabel("Search name, address, or operator")
                        if searchText.isEmpty && !searchIsFocused {
                            Text("Search chargers")
                                .foregroundStyle(Color.primary.opacity(0.8))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    if !searchText.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { searchText = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .glassEffect(.regular.tint(Color.voltBlue.opacity(0.45)).interactive(), in: .rect(cornerRadius: 16))

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(DisplayMode.allCases) { mode in
                            displayButton(for: mode)
                        }

                        Button(showAllSites ? "All sites" : "Compatible") { showAllSites.toggle() }
                            .buttonStyle(.glass)
                            .tint(.voltBlue)
                            .accessibilityHint("Switch between all directory sites and chargers matching your active vehicle")

                        Button {
                            showingFilters = true
                        } label: {
                            Label {
                                Text(activeFilterCount == 0 ? "Filters" : "Filters \(activeFilterCount)")
                            } icon: {
                                Image(systemName: activeFilterCount == 0 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                            }
                        }
                        .buttonStyle(.glass)
                        .tint(.voltBlue)

                        availabilityFilterButton

                        if !store.isDemoMode {
                            Button("Refresh chargers", systemImage: "arrow.clockwise") {
                                Task { await store.refreshStations() }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .tint(.voltBlue)
                            .disabled(store.isLoadingStations)
                        }
                        Button("Use my location", systemImage: "location") {
                            Task {
                                if displayMode == .map { await locateOnMap() }
                                else { await store.useCurrentLocation() }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .tint(.voltBlue)
                    }
                }
                .scrollIndicators(.hidden)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        networkButton("All", network: nil)
                        ForEach(networks, id: \.self) { network in
                            networkButton(network, network: network)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)

            }
        }
    }

    @ViewBuilder private func networkButton(_ title: String, network: String?) -> some View {
        if selectedNetwork == network {
            Button(title) { selectedNetwork = network }
                .buttonStyle(.glassProminent)
                .tint(.voltBlue)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(title) { selectedNetwork = network }
                .buttonStyle(.glass)
                .tint(.voltBlue)
        }
    }

    private var availabilityFilterButton: some View {
        Group {
            if availableNowOnly {
                Button { availableNowOnly = false } label: {
                    Label("Available", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.voltBlue)
            } else {
                Button { availableNowOnly = true } label: {
                    Label("Available", systemImage: "checkmark.circle")
                }
                .buttonStyle(.glass)
                .tint(.voltBlue)
            }
        }
        .accessibilityLabel("Available now")
        .accessibilityValue(availableNowOnly ? "On" : "Off")
        .accessibilityHint("Shows only chargers with a fresh available status and a positive connector count")
    }

    @ViewBuilder private func displayButton(for mode: DisplayMode) -> some View {
        if displayMode == mode {
            Button(mode.rawValue) { displayMode = mode }
                .buttonStyle(.glassProminent)
                .tint(.voltBlue)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(mode.rawValue) { displayMode = mode }
                .buttonStyle(.glass)
                .tint(.voltBlue)
        }
    }

    private var hasNoResults: Bool {
        (!showAllSites && store.profile.connectors.isEmpty)
            || (!store.isLoadingStations && visibleStations.isEmpty)
    }

    @ViewBuilder private var emptyResults: some View {
        if !showAllSites && store.profile.connectors.isEmpty {
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
        } else if !showAllSites && store.compatibleStations.isEmpty {
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
                detail: "Try another search, network, access type, or turn off a quick filter.",
                actionTitle: "Clear filters",
                action: {
                    searchText = ""
                    availableNowOnly = false
                    selectedNetwork = nil
                    chargingType = nil
                    minimumListedPowerKW = nil
                    accessFilter = nil
                }
            )
        }
    }

    private func locateOnMap() async {
        guard let location = await store.useCurrentLocation() else { return }
        mapRecenterRequest = MapRecenterRequest(id: UUID(), location: location)
    }
}

private struct MapRecenterRequest: Equatable {
    let id: UUID
    let location: Coordinate
}

private struct ChargerMapView: UIViewRepresentable {
    let stations: [ChargingStation]
    let freshnessTime: Date
    let recenterRequest: MapRecenterRequest?
    @Binding var selectedStationID: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "charger")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 4.2, longitude: 109.5),
                span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 22)
            ),
            animated: false
        )
        map.showsCompass = true
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        var seen = Set<String>()
        let uniqueStations = stations.filter { seen.insert($0.id).inserted }
        let current = Dictionary(map.annotations.compactMap { annotation in
            (annotation as? ChargerAnnotation).map { ($0.stationID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let incoming = Set(uniqueStations.map(\.id))
        map.removeAnnotations(current.values.filter { !incoming.contains($0.stationID) })
        let additions = uniqueStations.filter { current[$0.id] == nil }.map {
            ChargerAnnotation(station: $0, isAvailable: $0.availability.isReportedAvailable(at: freshnessTime))
        }
        map.addAnnotations(additions)
        for station in uniqueStations {
            guard let annotation = current[station.id] else { continue }
            let isAvailable = station.availability.isReportedAvailable(at: freshnessTime)
            guard annotation.isAvailable != isAvailable else { continue }
            annotation.isAvailable = isAvailable
            if let view = map.view(for: annotation) as? MKMarkerAnnotationView {
                view.markerTintColor = annotation.isAvailable ? UIColor(Color.voltMint) : UIColor(Color.voltBlue)
            }
        }
        if !context.coordinator.hasFramed && !map.annotations.isEmpty {
            context.coordinator.hasFramed = true
            map.showAnnotations(map.annotations, animated: false)
        }
        if let request = recenterRequest, context.coordinator.lastRecenterID != request.id {
            context.coordinator.lastRecenterID = request.id
            map.setRegion(MKCoordinateRegion(center: request.location.coreLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)), animated: true)
        }
        if selectedStationID == nil, let selected = map.selectedAnnotations.first {
            map.deselectAnnotation(selected, animated: false)
        }
    }

    private final class ChargerAnnotation: NSObject, MKAnnotation {
        let stationID: String
        let title: String?
        let coordinate: CLLocationCoordinate2D
        var isAvailable: Bool

        init(station: ChargingStation, isAvailable: Bool) {
            stationID = station.id
            title = station.networkName
            coordinate = station.coordinate.coreLocation.coordinate
            self.isAvailable = isAvailable
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ChargerMapView
        var hasFramed = false
        var lastRecenterID: UUID?

        init(_ parent: ChargerMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: cluster) as! MKMarkerAnnotationView
                view.markerTintColor = UIColor(Color.voltBlue)
                view.glyphText = "\(cluster.memberAnnotations.count)"
                return view
            }
            guard let charger = annotation as? ChargerAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "charger", for: charger) as! MKMarkerAnnotationView
            view.clusteringIdentifier = "chargers"
            view.markerTintColor = charger.isAvailable ? UIColor(Color.voltMint) : UIColor(Color.voltBlue)
            view.glyphImage = UIImage(systemName: "bolt.car.fill")
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            if let cluster = annotation as? MKClusterAnnotation {
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                mapView.deselectAnnotation(cluster, animated: false)
            } else if let charger = annotation as? ChargerAnnotation {
                parent.selectedStationID = charger.stationID
            }
        }
    }
}

private struct StationMapPreview: View {
    let station: ChargingStation
    let store: VoltWayStore
    let isExpanded: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var detailTransition

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(station.networkName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.voltBlue)
                Text(station.name)
                    .font(.title3.weight(.bold))
                if isExpanded || dynamicTypeSize.isAccessibilitySize {
                    Text(station.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(station.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if store.isDemoMode { DemoNotice() }
            }

            VoltSurface {
                VStack(alignment: .leading, spacing: 12) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            AvailabilityPill(availability: station.availability)
                            priceText
                        }
                    } else {
                        HStack {
                            AvailabilityPill(availability: station.availability)
                            Spacer(minLength: 8)
                            priceText
                        }
                    }
                    if isExpanded || dynamicTypeSize.isAccessibilitySize {
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text(station.access?.title ?? "Access requirements unknown")
                            if station.connectors.isEmpty {
                                Text("Compatibility unknown · connector details unavailable")
                                    .fontWeight(.semibold)
                            } else {
                                Text(station.connectorSummary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let attribution = station.attributionText {
                            if let sourceURL = station.sourceURL {
                                Link("Data: \(attribution)", destination: sourceURL).font(.caption)
                            } else {
                                Text("Data: \(attribution)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(updateText("Status", at: station.availability.lastUpdated))
                            Text(updateText("Price", at: station.price?.lastUpdated))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            GlassEffectContainer(spacing: 12) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        detailsLink
                        navigateButton
                    }
                } else {
                    HStack(spacing: 12) {
                        detailsLink
                        Spacer(minLength: 0)
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
                .navigationTransition(.zoom(sourceID: station.id, in: detailTransition))
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.glass)
        .matchedTransitionSource(id: station.id, in: detailTransition)
    }

    private var navigateButton: some View {
        Button("Navigate with Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond") {
            MapsHandoff.open(station)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.glassProminent)
        .tint(.voltBlue)
    }

    private func updateText(_ field: String, at date: Date?) -> String {
        guard let date else { return "\(field) update time unavailable" }
        return "\(field) updated \(date.formatted(.relative(presentation: .named)))"
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
                Text(station.networkName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.voltBlue)
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
                if let attribution = station.attributionText {
                    Text(attribution).font(.caption).foregroundStyle(.secondary)
                }
                Text(station.access?.title ?? "Access requirements unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if station.connectors.isEmpty {
                    Text("Compatibility unknown")
                        .font(.caption.weight(.semibold))
                }
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
    @Namespace private var alternativeTransition

    private var isFavorite: Bool { store.favoriteStationIDs.contains(station.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeader
                statusCard
                connectorCard
                costEstimateCard
                alternativeChargers
            }
            .padding(20)
        }
        .background(Color.voltBackground)
        .safeAreaInset(edge: .bottom) {
            Button {
                MapsHandoff.open(station)
            } label: {
                Label("Navigate with Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(.voltBlue)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
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
        VoltGlassPanel(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 9) {
                Text(station.networkName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.voltBlue)
                Text(station.name)
                    .font(.largeTitle.weight(.bold))
                Text(station.address)
                    .font(.body)
                    .foregroundStyle(.secondary)
                if store.isDemoMode { DemoNotice() }
                if let attribution = station.attributionText {
                    if let sourceURL = station.sourceURL {
                        Link("Data: \(attribution)", destination: sourceURL)
                            .font(.caption)
                    } else {
                        Text("Data: \(attribution)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(station.access?.title ?? "Access requirements unknown")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if station.connectors.isEmpty {
                    Text("Compatibility unknown · connector details unavailable")
                        .font(.subheadline.weight(.semibold))
                }
            }
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
                            .navigationTransition(.zoom(sourceID: alternative.id, in: alternativeTransition))
                    } label: {
                        StationRow(
                            station: alternative,
                            distance: alternative.distance(from: station.coordinate),
                            isFavorite: store.favoriteStationIDs.contains(alternative.id)
                        )
                        .matchedTransitionSource(id: alternative.id, in: alternativeTransition)
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
            if station.connectors.isEmpty {
                Text("Compatibility unknown. This directory site has no supported connector details; check with the operator before travelling.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(station.connectors, id: \.self) { connector in
                HStack {
                    Label(connector.kind.title, systemImage: connector.kind.systemImage)
                    Spacer()
                    Text(connectorDetail(connector))
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

    private func connectorDetail(_ connector: Connector) -> String {
        let power = connector.powerKW.map { "\($0.formatted(.number.precision(.fractionLength(0)))) kW" } ?? "Power unavailable"
        let count = connector.count.map { "\($0) connectors" } ?? "Count unavailable"
        return "\(power) · \(count)"
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
            .buttonStyle(.glass)
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
    @State private var showingVehicleProfile = false
    @Namespace private var stationTransition

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
                    DemoNotice()
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
        .onChange(of: store.activeVehicleID) { _, _ in
            if !routeCoordinates.isEmpty {
                routeStops = RouteStopMatcher.stops(along: routeCoordinates, compatibleStations: store.compatibleStations)
                selectedStationID = nil
            }
        }
    }

    private var intro: some View {
        VoltGlassPanel(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Plan your drive")
                    .font(.largeTitle.weight(.bold))
                Text("Choose a destination and compare compatible stops across networks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label("VoltWay doesn’t save trip details. Apple MapKit processes your location and destination for routing.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSearch: some View {
        VoltSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Destination")
                    .font(.headline)
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
                .buttonStyle(.glassProminent)
                .tint(.voltBlue)
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
        VoltGlassPanel(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Destination", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Text(destination.name).font(.title3.weight(.semibold))
                Text(destination.address).font(.subheadline).foregroundStyle(.secondary)
                GlassEffectContainer(spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task { await planRoute(to: destination) }
                        } label: {
                            if isPlanning || store.isLoadingStations { ProgressView().frame(maxWidth: .infinity) }
                            else { Label("Find chargers along route", systemImage: "point.topleft.down.to.point.bottomright.curvepath").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.voltBlue)
                        .disabled(isPlanning || store.isLoadingStations || store.profile.connectors.isEmpty)
                        if store.profile.connectors.isEmpty {
                            Button("Set up vehicle connectors") { showingVehicleProfile = true }
                                .font(.subheadline.weight(.semibold))
                                .buttonStyle(.glass)
                        }
                    }
                }
                if store.isLoadingStations {
                    Text("Loading compatible chargers…").font(.caption).foregroundStyle(.secondary)
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
                                .navigationTransition(.zoom(sourceID: stop.station.id, in: stationTransition))
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                StationRow(station: stop.station, distance: nil, isFavorite: store.favoriteStationIDs.contains(stop.station.id))
                                Label("\(distanceText(stop.offRouteMeters)) from route", systemImage: "arrow.turn.up.right")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 10)
                            }
                            .matchedTransitionSource(id: stop.station.id, in: stationTransition)
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
        Map(initialPosition: .region(routeRegion(for: routeCoordinates)), selection: $selectedStationID) {
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
    @Namespace private var stationTransition

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VoltGlassPanel(cornerRadius: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Your saved chargers")
                                    .font(.title2.weight(.bold))
                                Text("Keep useful locations ready for your next drive.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "heart.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.voltBlue)
                                .symbolRenderingMode(.hierarchical)
                                .accessibilityHidden(true)
                        }
                        Text("\(store.favoriteStations.count) available")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 18)
                if store.isDemoMode {
                    DemoNotice()
                        .padding(.bottom, 18)
                }
                if store.favoriteStations.isEmpty {
                    EmptyState(
                        icon: "heart",
                        title: store.favorites.isEmpty ? "No saved chargers" : "Saved sites unavailable",
                        detail: store.favorites.isEmpty ? "Save a charger to find it quickly next time." :
                            "Some saved directory sites aren't in the currently loaded public catalog.",
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    ForEach(store.favoriteStations) { station in
                        NavigationLink {
                            StationDetailView(station: station, store: store)
                                .navigationTransition(.zoom(sourceID: station.id, in: stationTransition))
                        } label: {
                            StationRow(station: station, distance: station.distance(from: store.currentLocation), isFavorite: true)
                                .matchedTransitionSource(id: station.id, in: stationTransition)
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

struct ProfileView: View {
    let store: VoltWayStore
    @State private var showingAddVehicle = false
    @State private var showingPrivateSite = false
    @State private var editingVehicle: VehicleProfile?
    @State private var vehicleToDelete: VehicleProfile?
    @State private var showingDeleteConfirmation = false
    @Namespace private var vehicleTransition

    private var activeVehicle: VehicleProfile? {
        store.vehicles.first { $0.id == store.activeVehicleID }
    }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section { MessageBanner(message: error, isError: true, dismiss: store.clearMessages) }
            }
            if let notice = store.noticeMessage {
                Section { MessageBanner(message: notice, isError: false, dismiss: store.clearMessages) }
            }
            Section {
                profileOverview
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                if store.vehicles.isEmpty {
                    Text("Add a vehicle to see compatible chargers and trip stops.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.vehicles) { vehicle in
                    HStack(spacing: 12) {
                        Button {
                            Task { await store.selectVehicle(vehicle) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: store.activeVehicleID == vehicle.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Color.voltBlue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(vehicle.name).font(.headline)
                                    Text(vehicle.connectors.map(\.title).joined(separator: " + "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(vehicle.name)")
                        .accessibilityAddTraits(store.activeVehicleID == vehicle.id ? .isSelected : [])
                        Button("Edit \(vehicle.name)", systemImage: "pencil") {
                            editingVehicle = vehicle
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .matchedTransitionSource(id: vehicle.id, in: vehicleTransition)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            vehicleToDelete = vehicle
                            showingDeleteConfirmation = true
                        }
                    }
                }
                Button("Add vehicle", systemImage: "plus") { showingAddVehicle = true }
                    .matchedTransitionSource(id: "new-vehicle", in: vehicleTransition)
            } header: {
                Text("Vehicles")
            } footer: {
                Text("Switching vehicles updates Explore, Trip, and your next CarPlay snapshot. Favorites stay with your account.")
            }

            Section("Saved") {
                LabeledContent("Favorite stations", value: store.favorites.count.formatted())
            }

            Section("Catalog coverage") {
                ForEach(CatalogCoverage.networks(in: store.stations)) { summary in
                    let source = summary.hasPartnerFeed ? "partner feed" : summary.hasDirectoryRecords ? "directory" : "owner shared"
                    LabeledContent("\(summary.network) · \(source)", value: "\(summary.sites) sites")
                    if summary.knownChargePoints > 0 {
                        LabeledContent("  Listed charge points", value: summary.knownChargePoints.formatted())
                    }
                    if summary.sitesWithoutChargePointCount > 0 {
                        Text("Charge point count unavailable for \(summary.sitesWithoutChargePointCount) \(summary.sitesWithoutChargePointCount == 1 ? "site" : "sites")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.isDemoMode {
                    Text("\(store.stations.count) real, attributed example sites only · not a nationwide catalog")
                        .foregroundStyle(.secondary)
                } else if let report = store.catalogImportReport {
                    if let synced = store.catalogSyncedAt {
                        LabeledContent("Last successful import", value: synced.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("OCM records fetched", value: report.fetched.formatted())
                    LabeledContent("Directory sites included", value: report.included.formatted())
                    LabeledContent("Private excluded", value: report.private.formatted())
                    LabeledContent("Invalid excluded", value: report.invalid.formatted())
                    LabeledContent("License review excluded", value: report.license.formatted())
                    LabeledContent("Gentari duplicates", value: store.duplicateCount.formatted())
                    if !report.providerIDsNeedingReview.isEmpty {
                        if let providers = report.providers?.filter({ $0.license > 0 }), !providers.isEmpty {
                            ForEach(providers) { provider in
                                Text("License review: \(provider.name) · \(provider.license) records · provider ID \(provider.id)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Unreviewed provider IDs: \(report.providerIDsNeedingReview.map(String.init).joined(separator: ", "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No completed directory import is available yet. Coverage cannot be verified.")
                        .foregroundStyle(.secondary)
                }
                if !store.stations.isEmpty {
                    Text("Only records from the current approved sources are counted here. This is not a count or percentage of all physical chargers in Malaysia.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Coverage gaps") {
                Text("Examples of direct operator feeds not connected yet: Shell Recharge, TNB Electron, JomCharge, chargEV, ChargeSini, DC Handal, and EVPower. This list is not exhaustive. Directory listings may appear above, but do not provide live status or current pricing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Private sites appear only after an owner records permission and shares access with invited accounts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Private sites") {
                let privateCount = store.stations.filter { $0.source == .ownerProvided }.count
                LabeledContent("Sites available to this account", value: privateCount.formatted())
                if store.session == nil {
                    Text("Sign in to add a privately shared charger.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Add private charger", systemImage: "lock.shield") { showingPrivateSite = true }
                    Text("The owner’s permission is required. Only the owner and invited account can see its location.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Label("Location is never persisted", systemImage: "location.slash")
                Label("Session stored in Keychain", systemImage: "key.fill")
                Label("Partner credentials stay on the server", systemImage: "server.rack")
            }

            Section("Charger data") {
                Text("Directory locations may not have current status or prices. Check the network app before travelling.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if store.isDemoMode {
                Section("Environment") {
                    DemoNotice()
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.voltBackground)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddVehicle) {
            NavigationStack { VehicleProfileView(store: store, createsNew: true) }
                .presentationDetents([.medium, .large])
                .navigationTransition(.zoom(sourceID: "new-vehicle", in: vehicleTransition))
        }
        .sheet(item: $editingVehicle) { vehicle in
            NavigationStack { VehicleProfileView(store: store, vehicle: vehicle) }
                .presentationDetents([.medium, .large])
                .navigationTransition(.zoom(sourceID: vehicle.id, in: vehicleTransition))
        }
        .sheet(isPresented: $showingPrivateSite) {
            NavigationStack { PrivateChargerSiteView(store: store) }
                .presentationDetents([.large])
        }
        .confirmationDialog("Delete \(vehicleToDelete?.name ?? "vehicle")?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete vehicle", role: .destructive) {
                if let vehicleToDelete { Task { await store.deleteVehicle(vehicleToDelete) } }
                vehicleToDelete = nil
            }
        }
    }

    private var profileOverview: some View {
        VoltGlassPanel(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "car.side.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.voltBlue)
                        .frame(width: 54, height: 54)
                        .background(Color.voltBlue.opacity(0.12), in: .circle)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(activeVehicle?.name ?? "Your charging profile")
                            .font(.title3.weight(.bold))
                        Text(activeVehicle?.connectors.map(\.title).joined(separator: " + ") ?? "Add a vehicle to filter compatible sites")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if store.vehicles.count > 1 {
                        Menu {
                            ForEach(store.vehicles) { vehicle in
                                Button {
                                    Task { await store.selectVehicle(vehicle) }
                                } label: {
                                    if vehicle.id == store.activeVehicleID {
                                        Label(vehicle.name, systemImage: "checkmark")
                                    } else {
                                        Text(vehicle.name)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Switch active vehicle")
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        profileMetric("Saved", value: store.favorites.count.formatted(), symbol: "heart.fill")
                        profileMetric("Visible sites", value: store.stations.count.formatted(), symbol: "bolt.car.fill")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        profileMetric("Saved", value: store.favorites.count.formatted(), symbol: "heart.fill")
                        profileMetric("Visible sites", value: store.stations.count.formatted(), symbol: "bolt.car.fill")
                    }
                }

                if let email = store.session?.email {
                    Label(email, systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if store.isDemoMode {
                    DemoNotice()
                }
            }
        }
    }

    private func profileMetric(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Color.voltBlue)
                .accessibilityHidden(true)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PrivateChargerSiteView: View {
    let store: VoltWayStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var operatorName = "Private charger"
    @State private var connector = ConnectorKind.ccs2
    @State private var powerKW = ""
    @State private var chargePointCount = ""
    @State private var invitedEmail = ""
    @State private var confirmsPermission = false
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("Site details") {
                TextField("Name", text: $name)
                TextField("Address", text: $address, axis: .vertical)
                TextField("Latitude", text: $latitude)
                    .keyboardType(.decimalPad)
                TextField("Longitude", text: $longitude)
                    .keyboardType(.decimalPad)
                TextField("Operator", text: $operatorName)
                Picker("Connector", selection: $connector) {
                    ForEach(ConnectorKind.allCases) { item in Text(item.title).tag(item) }
                }
                TextField("Power in kW (optional)", text: $powerKW)
                    .keyboardType(.decimalPad)
                TextField("Charge point count (optional)", text: $chargePointCount)
                    .keyboardType(.numberPad)
            }

            Section("Access") {
                TextField("Invite account email (optional)", text: $invitedEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("I have permission from the site owner to share this location", isOn: $confirmsPermission)
                Text("Only you and the invited account can see this charger. Its status and price are always shown as unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = store.errorMessage {
                Section { MessageBanner(message: error, isError: true, dismiss: store.clearMessages) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.voltBackground)
        .navigationTitle("Private charger")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .disabled(isSaving || !confirmsPermission)
            }
        }
    }

    private func save() {
        guard let latitude = Double(latitude), let longitude = Double(longitude),
              powerKW.isEmpty || Double(powerKW) != nil,
              chargePointCount.isEmpty || Int(chargePointCount) != nil else {
            store.showValidationError("Enter coordinates and optional charger values as numbers.")
            return
        }
        let power = Double(powerKW)
        let points = Int(chargePointCount)
        isSaving = true
        Task {
            let saved = await store.addPrivateSite(
                name: name,
                address: address,
                latitude: latitude,
                longitude: longitude,
                operatorName: operatorName,
                connector: connector,
                powerKW: power,
                chargePointCount: points,
                invitedEmail: invitedEmail,
                ownerPermissionGranted: confirmsPermission
            )
            isSaving = false
            if saved { dismiss() }
        }
    }
}

struct VehicleProfileView: View {
    let store: VoltWayStore
    let vehicle: VehicleProfile?
    let createsNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedConnectors: Set<ConnectorKind>
    @State private var minimumPower: String
    @State private var isSaving = false
    @State private var validationMessage: String?

    init(store: VoltWayStore, vehicle: VehicleProfile? = nil, createsNew: Bool = false) {
        self.store = store
        self.vehicle = vehicle
        self.createsNew = createsNew
        let startingProfile = vehicle ?? (createsNew ? nil : store.profile)
        name = startingProfile?.name ?? "My EV"
        selectedConnectors = Set(startingProfile?.connectors ?? [])
        minimumPower = startingProfile?.minimumPowerKW.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? ""
    }

    var body: some View {
        Form {
            if let message = validationMessage ?? store.errorMessage {
                Section { MessageBanner(message: message, isError: true, dismiss: {
                    validationMessage = nil
                    store.clearMessages()
                }) }
            }
            Section("Vehicle name") {
                TextField("My EV", text: $name)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("Vehicle name")
            }

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
                Text("Choose every connector your EV can use. Network listings without current status remain visible.")
            }

            Section("Minimum power") {
                TextField("Optional, for example 50", text: $minimumPower)
                    .keyboardType(.decimalPad)
                Text("Only chargers with reported power at or above this value will appear. Leave blank to include unknown power.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.voltBackground)
        .navigationTitle(createsNew ? "Add vehicle" : "Edit vehicle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(isSaving || selectedConnectors.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        if !normalized.isEmpty && (power == nil || power! <= 0 || !power!.isFinite) {
            validationMessage = "Enter a valid minimum power greater than zero, or leave it blank."
            return
        }
        validationMessage = nil
        isSaving = true
        Task {
            let saved = await store.saveProfile(connectors: selectedConnectors, minimumPowerKW: power,
                                                name: name, vehicleID: vehicle?.id, createsNew: createsNew)
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
                        .buttonStyle(.glass)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
    }
}
