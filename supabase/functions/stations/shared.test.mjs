import assert from "node:assert/strict";
import test from "node:test";
import {
  combineSources,
  filterStations,
  mergeStations,
  normalizeGentari,
  normalizeOpenChargeMap,
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

test("OCM rejects other providers, invalid country, and unsupported connectors", () => {
  assert.equal(normalizeOpenChargeMap(ocm({ DataProvider: { ID: 9, License: "Unknown" } })), null);
  assert.equal(normalizeOpenChargeMap(ocm({ AddressInfo: { ...ocm().AddressInfo, Country: { ISOCode: "SG" } } })), null);
  assert.equal(normalizeOpenChargeMap(ocm({ AddressInfo: { ...ocm().AddressInfo, Latitude: 40 } })), null);
  assert.equal(normalizeOpenChargeMap(ocm({ Connections: [{ ConnectionTypeID: 1 }] })), null);
});

test("OCM also accepts Malaysia's numeric country ID in compact records", () => {
  const record = ocm({
    DataProvider: undefined,
    DataProviderID: 1,
    AddressInfo: { ...ocm().AddressInfo, Country: undefined, CountryID: 137 },
  });
  assert.equal(normalizeOpenChargeMap(record)?.id, "ocm:42");
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
});

test("Minimum power excludes unknown power without inventing a value", () => {
  const station = normalizeOpenChargeMap(ocm());
  assert.deepEqual(filterStations([station], new Set(["type2"]), 0).map((item) => item.id), ["ocm:42"]);
  assert.deepEqual(filterStations([station], new Set(["type2"]), 50), []);
  assert.deepEqual(filterStations([station], new Set(["ccs2"]), 50).map((item) => item.id), ["ocm:42"]);
});

test("A failed feed keeps the available feed and marks coverage partial", () => {
  const directory = normalizeOpenChargeMap(ocm());
  const partial = combineSources(null, [directory]);
  assert.deepEqual(partial.stations.map((item) => item.id), ["ocm:42"]);
  assert.deepEqual(partial.warnings, ["Gentari live feed unavailable; showing open-data locations only."]);
  const failed = combineSources(null, null);
  assert.equal(failed, null);
});
