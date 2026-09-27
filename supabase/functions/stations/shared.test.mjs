import assert from "node:assert/strict";
import test from "node:test";
import {
  combineSources,
  filterStations,
  mergeStations,
  normalizeGentari,
  normalizeOpenChargeMap,
  normalizePrivateSite,
  classifyOpenChargeMap,
  normalizeMEVnet,
  combineNationwide,
} from "./shared.ts";

const ocm = (overrides = {}) => ({
  ID: 42,
  DataProvider: { ID: 1, License: "CC BY 4.0" },
  AddressInfo: {
    Title: "City Mall",
    AddressLine1: "Jalan Example",
    Town: "Kuala Lumpur",
    Latitude: 3.14,
    Longitude: 101.68,
    Country: { ISOCode: "MY" },
  },
  OperatorInfo: { Title: "DC Handal" },
  Connections: [
    { ConnectionTypeID: 33, PowerKW: 120, Quantity: 2 },
    { ConnectionTypeID: 25 },
  ],
  StatusType: { IsOperational: true },
  UsageCost: "RM 1.40/kWh",
  ...overrides,
});

test("MEVnet keeps AC/DC counts separate from verified connectors and rejects invalid coordinates", () => {
  const station = normalizeMEVnet({ objectid: 4, location: "City Mall", latitude: 3.14, longitude: 101.68,
    state: "Selangor", status: "Existing", type_ac: 2, type_dc: 1, number_of_existing_ev_charger_s: 3,
    number_of_ev_charger_by_netw_10: 3, data_as: "31-Aug-24", bil: 4, state_code: 10,
    pbt_code: 17, indoor___outdoor: "Indoor" });
  assert.equal(station.id, "mevnet:4");
  assert.deepEqual(station.connectors, []);
  assert.equal(station.operatorName, "Gentari");
  assert.equal(station.chargePointCount, 3);
  assert.equal(station.sourceUpdatedAt, "2024-08-31T00:00:00.000Z");
  assert.equal(station.sourceSequence, 4);
  assert.equal(station.stateCode, 10);
  assert.equal(station.pbtCode, 17);
  assert.equal(station.indoorOutdoor, "Indoor");
  assert.deepEqual(filterStations([station], new Set(["ccs2"]), 0), []);
  assert.equal(normalizeMEVnet({ objectid: 5, location: "Outside", latitude: 20, longitude: 101 }), null);
  const fields = { number_of_ev_charger_by_network: 1 };
  for (let index = 1; index <= 26; index++) {
    fields[index < 10 ? `number_of_ev_charger_by_netwo_${index}` : `number_of_ev_charger_by_netw_${index}`] = 1;
  }
  const allNetworks = normalizeMEVnet({ objectid: 6, location: "Network counts", latitude: 3.14, longitude: 101.68, ...fields });
  assert.equal(Object.keys(allNetworks.networkCounts).length, 27);
});

test("nationwide merge keeps Gentari ID and status, OCM connectors, and MEVnet lifecycle", () => {
  const partner = normalizeGentari({ id: "favorite-id", name: "City Mall", latitude: 3.14, longitude: 101.68,
    connectors: [{ kind: "CCS2", powerKW: 120 }], availability: { status: "available" } });
  const directory = normalizeOpenChargeMap(ocm());
  const planning = normalizeMEVnet({ objectid: 4, location: "City Mall", latitude: 3.14, longitude: 101.68,
    status: "Existing", type_ac: 2, type_dc: 1, bil: 4, state_code: 10, pbt_code: 17,
    indoor___outdoor: "Indoor" });
  const merged = combineNationwide([partner], [directory], [planning]);
  assert.equal(merged.stations.length, 1);
  assert.equal(merged.stations[0].id, "favorite-id");
  assert.equal(merged.stations[0].availability.state, "available");
  assert.equal(merged.stations[0].lifecycle, "existing");
  assert.equal(merged.stations[0].sourceIDs.mevnet, "4");
  assert.equal(merged.stations[0].sourceSequence, 4);
  assert.equal(merged.stations[0].stateCode, 10);
  assert.equal(merged.stations[0].pbtCode, 17);
  assert.equal(merged.stations[0].indoorOutdoor, "Indoor");
  assert.equal(merged.duplicateCount, 2);
  const nearbyDistinct = normalizeMEVnet({ objectid: 5, location: "Another Hub", latitude: 3.14, longitude: 101.68 });
  assert.equal(combineNationwide([partner], null, [nearbyDistinct]).stations.length, 2);
  const secondPartnerHub = normalizeGentari({ id: "second-hub", name: "City Mall", latitude: 3.14, longitude: 101.68,
    connectors: [{ kind: "CCS2", powerKW: 120 }] });
  assert.equal(combineNationwide([partner, secondPartnerHub], null, null).stations.length, 2);
  assert.equal(combineNationwide([partner, secondPartnerHub], [directory], null).stations.length, 3);
  const namedVariant = normalizeMEVnet({ objectid: 6, location: "City Mall EV Charging", latitude: 3.14, longitude: 101.68 });
  assert.equal(combineNationwide([partner], null, [namedVariant]).stations.length, 1);
});

test("a proposed planning row cannot hide a live charger at the same named site", () => {
  const partner = normalizeGentari({ id: "live-site", name: "City Mall", latitude: 3.14, longitude: 101.68,
    connectors: [{ kind: "CCS2", powerKW: 120 }], availability: { status: "available", last_updated: "2026-09-28T00:00:00Z" } });
  const planned = normalizeMEVnet({ objectid: 7, location: "City Mall", latitude: 3.14, longitude: 101.68,
    status: "Newly Proposed" });
  const result = combineNationwide([partner], null, [planned]);
  assert.deepEqual(result.stations.map((station) => station.id), ["live-site", "mevnet:7"]);
  assert.equal(result.stations[0].lifecycle, undefined);
  assert.equal(result.stations[0].availability.state, "available");
  assert.equal(result.stations[1].availability.state, "unknown");
});

test("OCM imports contributor locations but never directory status or price", () => {
  const station = normalizeOpenChargeMap(ocm());
  assert.equal(station.id, "ocm:42");
  assert.equal(station.operatorName, "DC Handal");
  assert.equal(station.source, "openChargeMap");
  assert.equal(station.availability.state, "unknown");
  assert.equal(station.availability.lastUpdated, null);
  assert.equal(station.price, null);
  assert.deepEqual(station.connectors[1], { kind: "type2", powerKW: null, count: null });
});

test("OCM explains exclusions and keeps unknown connectors in the directory", () => {
  assert.equal(normalizeOpenChargeMap(ocm({ DataProvider: { ID: 9, License: "Unknown" } })), null);
  assert.equal(normalizeOpenChargeMap(ocm({ AddressInfo: { ...ocm().AddressInfo, Country: { ISOCode: "SG" } } })), null);
  assert.equal(normalizeOpenChargeMap(ocm({ AddressInfo: { ...ocm().AddressInfo, Latitude: 40 } })), null);
  assert.deepEqual(normalizeOpenChargeMap(ocm({ Connections: [{ ConnectionTypeID: 1 }] }))?.connectors, []);
  assert.equal(classifyOpenChargeMap(ocm({ DataProviderID: 9, DataProvider: undefined })).excluded, "license");
  assert.equal(classifyOpenChargeMap(ocm({ UsageType: { Title: "Private - For Staff Only", IsPublicAccess: false } })).excluded, "private");
  assert.equal(classifyOpenChargeMap(ocm({ UsageTypeID: 3, UsageType: undefined })).excluded, "private");
  assert.equal(classifyOpenChargeMap(ocm({ DataProviderID: 9, DataProvider: undefined, UsageTypeID: 2 })).excluded, "private");
  assert.equal(classifyOpenChargeMap(ocm({ AddressInfo: { ...ocm().AddressInfo, Latitude: 40 } })).excluded, "invalid");
});

test("reviewed CC0 terms include additional providers with their own attribution", () => {
  const station = normalizeOpenChargeMap(ocm({
    DataProvider: { ID: 46, Title: "Voltspot", License: "CC-0", IsOpenDataLicensed: true },
    UsageType: { ID: 7, Title: "Public - Notice Required" },
  }));
  assert.equal(station.sourceAttribution, "Voltspot via Open Charge Map · CC0");
  assert.equal(station.access, "limited");
  assert.equal(classifyOpenChargeMap(ocm({
    DataProvider: { ID: 47, Title: "Unknown terms", License: "custom license", IsOpenDataLicensed: true },
  })).excluded, "license");
  assert.equal(classifyOpenChargeMap(ocm({
    DataProvider: { ID: 46, Title: "Voltspot", License: "CC-0", IsOpenDataLicensed: false },
  })).excluded, "license");
});

test("reviewed ChargeSini CC0 records retain distinct attribution and restricted access", () => {
  const station = normalizeOpenChargeMap(ocm({
    DataProvider: { ID: 41, License: "CC0" },
    UsageType: { Title: "Public - Membership Required", IsPublicAccess: true },
  }));
  assert.equal(station.id, "ocm:42");
  assert.equal(station.sourceAttribution, "ChargeSini via Open Charge Map · CC0");
  assert.equal(station.access, "limited");
  assert.equal(station.price, null);
});

test("OCM also accepts Malaysia's numeric country ID in compact records", () => {
  const record = ocm({
    DataProvider: undefined,
    DataProviderID: 1,
    AddressInfo: { ...ocm().AddressInfo, Country: undefined, CountryID: 137 },
  });
  assert.equal(normalizeOpenChargeMap(record)?.id, "ocm:42");
  assert.equal(normalizeOpenChargeMap(ocm({
    AddressInfo: { ...ocm().AddressInfo, Country: undefined, CountryID: undefined },
  }))?.id, "ocm:42");
});

test("Source summaries keep sites separate from known charge points", () => {
  const station = normalizeOpenChargeMap(ocm({ NumberOfPoints: 5 }));
  assert.equal(station.chargePointCount, 5);
  assert.equal(normalizeOpenChargeMap(ocm()).chargePointCount, null);
});

test("Owner-shared records are private and discard supplied live status and price", () => {
  const station = normalizePrivateSite({
    id: "private-site-id",
    station: {
      id: "attacker-selected-id", name: "Depot charger", address: "Kuala Lumpur",
      coordinate: { latitude: 3.14, longitude: 101.68 }, operatorName: "Depot",
      connectors: [{ kind: "ccs2", powerKW: 120, count: 2 }],
      availability: { state: "available", availableConnectors: 2, totalConnectors: 2 },
      price: { amountMYR: 1.2, unit: "kWh" }, access: "public", source: "openChargeMap",
    },
  });
  assert.equal(station.id, "private:private-site-id");
  assert.equal(station.source, "ownerProvided");
  assert.equal(station.access, "private");
  assert.equal(station.availability.state, "unknown");
  assert.equal(station.price, null);
  assert.equal(station.sourceAttribution, "Owner supplied · shared by invitation");
  assert.equal(normalizePrivateSite({ id: "outside", station: {
    name: "Bad coordinate", coordinate: { latitude: 40, longitude: 101 }, connectors: [{ kind: "ccs2" }],
  } }), null);
});

test("Gentari IDs stay unchanged and clear same-site duplicates prefer Gentari", () => {
  const gentari = normalizeGentari({
    id: "existing-favorite", name: "City Mall", latitude: 3.1401, longitude: 101.6801,
    connectors: [{ kind: "CCS2", powerKW: 120, count: 2 }],
    availability: { status: "available", available: 1, last_updated: "2026-09-26T12:00:00Z" },
  });
  const other = normalizeOpenChargeMap(ocm({ ID: 43, AddressInfo: { ...ocm().AddressInfo, Title: "Another Mall", Latitude: 3.2 } }));
  assert.equal(gentari.id, "existing-favorite");
  assert.deepEqual(mergeStations([gentari], [normalizeOpenChargeMap(ocm()), other]).map((item) => item.id), ["existing-favorite", "ocm:43"]);
  assert.deepEqual(combineSources([gentari], [normalizeOpenChargeMap(ocm()), other]).duplicateIDs, ["ocm:42"]);
});

test("Minimum power excludes unknown power without inventing a value", () => {
  const station = normalizeOpenChargeMap(ocm());
  assert.deepEqual(filterStations([station], new Set(["type2"]), 0).map((item) => item.id), ["ocm:42"]);
  assert.deepEqual(filterStations([station], new Set(["type2"]), 50), []);
  assert.deepEqual(filterStations([station], new Set(["ccs2"]), 50).map((item) => item.id), ["ocm:42"]);
});

test("Unfiltered catalog keeps unknown-connector sites for All sites", () => {
  const station = normalizeOpenChargeMap(ocm({ Connections: [] }));
  assert.deepEqual(filterStations([station], new Set(), 0).map((item) => item.id), ["ocm:42"]);
  assert.deepEqual(filterStations([station], new Set(["ccs2"]), 0), []);
});

test("A failed feed keeps the available feed and marks coverage partial", () => {
  const directory = normalizeOpenChargeMap(ocm());
  const partial = combineSources(null, [directory]);
  assert.deepEqual(partial.stations.map((item) => item.id), ["ocm:42"]);
  assert.deepEqual(partial.warnings, ["Gentari live feed unavailable; showing open-data locations only."]);
  const failed = combineSources(null, null);
  assert.equal(failed, null);
});
