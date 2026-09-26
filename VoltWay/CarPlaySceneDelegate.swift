import CarPlay
import Foundation
import MapKit
import UIKit

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private weak var interfaceController: CPInterfaceController?
    private let locationService = LocationService()
    private var connectionID = UUID()
    private var currentCoordinate: Coordinate?

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
        let stations: [ChargingStation]
        if let coordinate {
            stations = snapshot.stations.sorted {
                let first = $0.distance(from: coordinate) ?? .greatestFiniteMagnitude
                let second = $1.distance(from: coordinate) ?? .greatestFiniteMagnitude
                return first == second ? $0.name < $1.name : first < second
            }
        } else {
            stations = snapshot.stations
        }

        let title = coordinate == nil ? "Chargers" : "Nearby"
        let nearby = listTemplate(title: title, stations: stations, isDemo: snapshot.isDemo)
        nearby.tabTitle = title
        nearby.tabImage = UIImage(systemName: "bolt.car")

        let favorites = stations.filter { snapshot.favoriteStationIDs.contains($0.id) }
        let saved = listTemplate(title: "Saved", stations: favorites, isDemo: snapshot.isDemo)
        saved.tabTitle = "Saved"
        saved.tabImage = UIImage(systemName: "heart.fill")

        let tabs = CPTabBarTemplate(templates: [nearby, saved])
        interfaceController?.setRootTemplate(tabs, animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        connectionID = UUID()
        currentCoordinate = nil
        NotificationCenter.default.removeObserver(self, name: .voltWayCarPlaySnapshotDidChange, object: nil)
    }

    @objc private func snapshotDidChange() {
        guard interfaceController != nil else { return }
        showLists(from: CarPlaySnapshotStore.load(), near: currentCoordinate)
    }

    private func listTemplate(title: String, stations: [ChargingStation], isDemo: Bool) -> CPListTemplate {
        let items = stations.prefix(12).map { station in
            let prefix = isDemo ? "Demo · " : ""
            let detail = "\(prefix)\(station.networkName) · \(station.availability.displayText()) · \(station.price?.displayText() ?? "Price unavailable")"
            let item = CPListItem(text: station.name, detailText: detail, image: UIImage(systemName: "bolt.fill"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showDetails(for: station, isDemo: isDemo)
                completion()
            }
            return item
        }

        let section: CPListSection
        if items.isEmpty {
            let emptyTitle: String
            switch title {
            case "Saved": emptyTitle = "No saved chargers"
            case "Nearby": emptyTitle = "No nearby chargers"
            default: emptyTitle = "No chargers to show"
            }
            section = CPListSection(items: [CPListItem(text: emptyTitle, detailText: "Open VoltWay on iPhone for details.")])
        } else {
            section = CPListSection(items: items)
        }
        return CPListTemplate(title: title, sections: [section])
    }

    private func showDetails(for station: ChargingStation, isDemo: Bool) {
        var information = [
            CPInformationItem(title: "Network", detail: station.networkName),
            CPInformationItem(title: "Status", detail: station.availability.displayText()),
            CPInformationItem(title: "Price", detail: station.price?.displayText() ?? "Price unavailable"),
            CPInformationItem(title: "Status updated", detail: updateText(station.availability.lastUpdated)),
            CPInformationItem(title: "Price updated", detail: updateText(station.price?.lastUpdated)),
            CPInformationItem(title: "Connectors", detail: station.connectorSummary),
            CPInformationItem(title: "Data source", detail: station.source?.attribution ?? "Unavailable"),
            CPInformationItem(title: "Address", detail: station.address)
        ]
        if isDemo {
            information.insert(CPInformationItem(title: "Demo", detail: "Location example, not live status or price"), at: 0)
        }
        let navigate = CPTextButton(title: "Open Apple Maps", textStyle: .confirm) { _ in
            MapsHandoff.open(station)
        }
        let template = CPInformationTemplate(title: station.name, layout: .leading, items: information, actions: [navigate])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func updateText(_ date: Date?) -> String {
        date?.formatted(.relative(presentation: .named)) ?? "Timestamp unavailable"
    }
}
