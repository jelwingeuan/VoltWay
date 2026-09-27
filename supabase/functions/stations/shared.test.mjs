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
