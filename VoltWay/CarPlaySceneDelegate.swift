import CarPlay
import Foundation
import MapKit
import UIKit

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private enum ListKind: Equatable { case chargers, saved }

    private weak var interfaceController: CPInterfaceController?
    private let locationService = LocationService()
    private var connectionID = UUID()
    private var currentCoordinate: Coordinate?
    private var chargerStations: [ChargingStation] = []
    private var savedStations: [ChargingStation] = []
    private var chargerRows: [(ChargingStation, CPListItem)] = []
    private var savedRows: [(ChargingStation, CPListItem)] = []
    private var chargerTemplate: CPListTemplate?
    private var savedTemplate: CPListTemplate?
    private var detailTemplate: CPInformationTemplate?
    private var detailStationID: String?
    private var chargerPageStart = 0
    private var savedPageStart = 0
    private var isDemo = false
    private var listTitle = "Chargers"
    private var freshnessTimer: Timer?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        connectionID = UUID()
        currentCoordinate = nil
        NotificationCenter.default.addObserver(self, selector: #selector(snapshotDidChange), name: .voltWayCarPlaySnapshotDidChange, object: nil)
        let activeConnection = connectionID
        let snapshot = CarPlaySnapshotStore.load()
        showLists(from: snapshot, near: nil)

        guard locationService.isAuthorized else { return }
        Task {
            guard let coordinate = try? await locationService.requestLocation(),
                  activeConnection == connectionID,
                  self.interfaceController != nil else { return }
            currentCoordinate = coordinate
            showLists(from: CarPlaySnapshotStore.load(), near: coordinate)
        }
    }

    private func showLists(from snapshot: CarPlaySnapshot, near coordinate: Coordinate?) {
        freshnessTimer?.invalidate()
        detailTemplate = nil
        detailStationID = nil
        chargerPageStart = 0
        savedPageStart = 0
        isDemo = snapshot.isDemo

        if let coordinate {
            chargerStations = snapshot.stations.sorted {
                let first = $0.distance(from: coordinate) ?? .greatestFiniteMagnitude
                let second = $1.distance(from: coordinate) ?? .greatestFiniteMagnitude
                return first == second ? $0.name < $1.name : first < second
            }
        } else {
            chargerStations = snapshot.stations
        }

        listTitle = coordinate == nil ? "Chargers" : "Nearby"
        savedStations = chargerStations.filter { snapshot.favoriteStationIDs.contains($0.id) }
        let now = Date.now
        let nearby = CPListTemplate(title: listTitle, sections: [listSection(for: .chargers, at: now)])
        nearby.tabTitle = listTitle
        nearby.tabImage = UIImage(systemName: "bolt.car")

        let saved = CPListTemplate(title: "Saved", sections: [listSection(for: .saved, at: now)])
        saved.tabTitle = "Saved"
        saved.tabImage = UIImage(systemName: "heart.fill")
        chargerTemplate = nearby
        savedTemplate = saved

        let tabs = CPTabBarTemplate(templates: [nearby, saved])
        interfaceController?.setRootTemplate(tabs, animated: false, completion: nil)
        scheduleFreshnessRefresh(after: now)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        connectionID = UUID()
        currentCoordinate = nil
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        chargerTemplate = nil
        savedTemplate = nil
        detailTemplate = nil
        detailStationID = nil
        chargerStations = []
        savedStations = []
        chargerRows = []
        savedRows = []
        NotificationCenter.default.removeObserver(self, name: .voltWayCarPlaySnapshotDidChange, object: nil)
    }

    @objc private func snapshotDidChange() {
        guard interfaceController != nil else { return }
        showLists(from: CarPlaySnapshotStore.load(), near: currentCoordinate)
    }

    private func listSection(for kind: ListKind, at date: Date) -> CPListSection {
        let stations = kind == .chargers ? chargerStations : savedStations
        let start = kind == .chargers ? chargerPageStart : savedPageStart
        let page = CarPlayPresentation.page(totalCount: stations.count, startingAt: start,
                                             maximumItemCount: CPListTemplate.maximumItemCount)
        let rows = page.range.map { index in
            let station = stations[index]
            let item = CPListItem(text: station.name, detailText: detailText(for: station, at: date),
                                  image: UIImage(systemName: "bolt.fill"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showDetails(for: station)
                completion()
            }
            return (station, item)
        }
        if kind == .chargers { chargerRows = rows } else { savedRows = rows }

        var items = rows.map { $0.1 }
        if let nextStart = page.nextStart {
            let more = CPListItem(
                text: nextStart == 0 ? "Back to first" : "More chargers",
                detailText: "\(page.range.upperBound) of \(stations.count) sites"
            )
            more.accessoryType = .disclosureIndicator
            more.handler = { [weak self] _, completion in
                self?.showPage(nextStart, for: kind)
                completion()
            }
            items.append(more)
        } else if page.hasUnreachableItems {
            let countText = kind == .saved ? "\(stations.count) saved chargers" : "\(stations.count) chargers"
            items = [CPListItem(text: "Open VoltWay on iPhone", detailText: countText)]
        }

        if items.isEmpty {
            let emptyTitle: String
            switch kind {
            case .saved: emptyTitle = "No saved chargers"
            case .chargers: emptyTitle = listTitle == "Nearby" ? "No nearby chargers" : "No chargers to show"
            }
            items = [CPListItem(text: emptyTitle, detailText: "Open VoltWay on iPhone for details.")]
        }
        return CPListSection(items: items)
    }

    private func showPage(_ start: Int, for kind: ListKind) {
        guard interfaceController != nil else { return }
        if kind == .chargers {
            chargerPageStart = start
            chargerTemplate?.updateSections([listSection(for: .chargers, at: .now)])
        } else {
            savedPageStart = start
            savedTemplate?.updateSections([listSection(for: .saved, at: .now)])
        }
        scheduleFreshnessRefresh(after: .now)
    }

    private func detailText(for station: ChargingStation, at date: Date) -> String {
        let prefix = isDemo ? "Demo · " : ""
        return "\(prefix)\(station.networkName) · \(station.availability.displayText(at: date)) · \(station.price?.displayText(at: date) ?? "Price unavailable")"
    }

    private func informationItems(for station: ChargingStation, at date: Date) -> [CPInformationItem] {
        var information = [
            CPInformationItem(title: "Network", detail: station.networkName),
            CPInformationItem(title: "Status", detail: station.availability.displayText(at: date)),
            CPInformationItem(title: "Price", detail: station.price?.displayText(at: date) ?? "Price unavailable"),
            CPInformationItem(title: "Status updated", detail: updateText(station.availability.lastUpdated)),
            CPInformationItem(title: "Price updated", detail: updateText(station.price?.lastUpdated)),
            CPInformationItem(title: "Connectors", detail: station.connectorSummary),
            CPInformationItem(title: "Access", detail: station.access?.title ?? "Requirements unknown"),
            CPInformationItem(title: "Data source", detail: station.attributionText ?? "Unavailable"),
            CPInformationItem(title: "Address", detail: station.address)
        ]
        if isDemo {
            information.insert(CPInformationItem(title: "Demo", detail: "Location example, not live status or price"), at: 0)
        } else {
            information.insert(CPInformationItem(title: "Site", detail: station.lifecycle?.title ?? "Lifecycle unverified"), at: 7)
        }
        return information
    }

    private func showDetails(for station: ChargingStation) {
        guard interfaceController != nil else { return }
        let information = informationItems(for: station, at: .now)
        let navigate = CPTextButton(title: "Open Apple Maps", textStyle: .confirm) { _ in
            MapsHandoff.open(station)
        }
        let template = CPInformationTemplate(title: station.name, layout: .leading, items: information, actions: [navigate])
        detailTemplate = template
        detailStationID = station.id
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        scheduleFreshnessRefresh(after: .now)
    }

    @objc private func refreshExpiredFacts() {
        guard interfaceController != nil else { return }
        let now = Date.now
        for (station, item) in chargerRows { item.setDetailText(detailText(for: station, at: now)) }
        for (station, item) in savedRows { item.setDetailText(detailText(for: station, at: now)) }
        if let detailStationID,
           let station = chargerStations.first(where: { $0.id == detailStationID }) {
            detailTemplate?.items = informationItems(for: station, at: now)
        }
        scheduleFreshnessRefresh(after: now)
    }

    private func scheduleFreshnessRefresh(after date: Date) {
        freshnessTimer?.invalidate()
        guard interfaceController != nil else {
            freshnessTimer = nil
            return
        }
        let visibleStations = chargerRows.map { $0.0 } + savedRows.map { $0.0 }
        guard let next = CarPlayPresentation.nextFreshnessUpdate(in: visibleStations, after: date) else {
            freshnessTimer = nil
            return
        }
        let timer = Timer(fireAt: next, interval: 0, target: self,
                          selector: #selector(refreshExpiredFacts), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        freshnessTimer = timer
    }

    private func updateText(_ date: Date?) -> String {
        date?.formatted(.relative(presentation: .named)) ?? "Timestamp unavailable"
    }
}
