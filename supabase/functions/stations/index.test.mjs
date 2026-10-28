import assert from "node:assert/strict";
import test from "node:test";

let handler;
const environment = {
  SUPABASE_URL: "https://voltway.test",
  SUPABASE_ANON_KEY: "public-anon-key",
  SUPABASE_SERVICE_ROLE_KEY: "private-service-key",
};
globalThis.Deno = {
  serve: (callback) => { handler = callback; },
  env: { get: (key) => environment[key] },
};
await import("./index.ts");

const request = (query = "") => new Request(`https://voltway.test/functions/v1/stations${query}`, {
  headers: { Authorization: "Bearer signed-in-user" },
});

test("Authenticated search serves cached open data when Gentari is unavailable", async () => {
  const originalFetch = globalThis.fetch;
  const upstream = [];
  globalThis.fetch = async (url) => {
    upstream.push(String(url));
    if (String(url).includes("/auth/v1/user")) return Response.json({ id: "user-1" });
    if (String(url).includes("/private_charger_sites")) return Response.json([]);
    if (String(url).includes("source=eq.mevnet")) return Response.json([]);
    return Response.json([{
      stations: [{
        id: "ocm:42", name: "City Mall", address: "Kuala Lumpur", operatorName: "DC Handal",
        coordinate: { latitude: 3.14, longitude: 101.68 },
        connectors: [{ kind: "ccs2", powerKW: 120, count: 2 }],
        availability: { state: "unknown", availableConnectors: null, totalConnectors: null, lastUpdated: null },
        price: null, source: "openChargeMap",
      }],
      synced_at: new Date().toISOString(),
      import_report: {},
    }]);
  };
  try {
    const response = await handler(request("?connectors=ccs2&minimumPowerKW=50"));
    const data = await response.json();
    assert.equal(response.status, 200);
    assert.deepEqual(data.stations.map((station) => station.id), ["ocm:42"]);
    assert.equal(data.warnings.length, 2);
    assert.equal(data.catalogImportReport, null);
    assert.deepEqual(data.duplicateIDs, []);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(upstream.length, 3);
    assert.ok(upstream.every((url) => !url.includes("source=eq.mevnet")));
    assert.ok(upstream.every((url) => !url.includes("latitude") && !url.includes("longitude")));
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("A malformed or entirely unrecognizable Gentari feed warns and uses the catalog", async () => {
  const originalFetch = globalThis.fetch;
  environment.GENTARI_API_URL = "https://gentari.test/stations";
  environment.GENTARI_API_TOKEN = "partner-token";
  try {
    for (const payload of [{ error: "feed changed" }, [
      { id: "site-1", name: "Site without coordinates or connectors" },
    ]]) {
      globalThis.fetch = async (url) => {
        if (String(url).includes("/auth/v1/user")) return Response.json({ id: "user-1" });
        if (String(url).includes("gentari.test")) return Response.json(payload);
        if (String(url).includes("/private_charger_sites")) return Response.json([]);
        return Response.json([{ stations: [{
          id: "ocm:42", name: "Catalog site", address: "Kuala Lumpur", operatorName: "Operator",
          coordinate: { latitude: 3.14, longitude: 101.68 }, connectors: [],
          availability: { state: "unknown", availableConnectors: null, totalConnectors: null, lastUpdated: null },
          price: null, source: "openChargeMap",
        }], synced_at: new Date().toISOString() }]);
      };
      const response = await handler(request());
      const data = await response.json();
      assert.equal(response.status, 200);
      assert.deepEqual(data.stations.map((station) => station.id), ["ocm:42"]);
      assert.ok(data.warnings.some((warning) => warning.includes("Gentari live feed unavailable")));
    }
  } finally {
    delete environment.GENTARI_API_URL;
    delete environment.GENTARI_API_TOKEN;
    globalThis.fetch = originalFetch;
  }
});

test("An explicitly empty Gentari station list is valid source data", async () => {
  const originalFetch = globalThis.fetch;
  environment.GENTARI_API_URL = "https://gentari.test/stations";
  environment.GENTARI_API_TOKEN = "partner-token";
  globalThis.fetch = async (url) => {
    if (String(url).includes("/auth/v1/user")) return Response.json({ id: "user-1" });
    if (String(url).includes("gentari.test")) return Response.json({ stations: [] });
    if (String(url).includes("/private_charger_sites")) return Response.json([]);
    return new Response("Unavailable", { status: 503 });
  };
  try {
    const response = await handler(request());
    const data = await response.json();
    assert.equal(response.status, 200);
    assert.deepEqual(data.stations, []);
    assert.ok(data.warnings.every((warning) => !warning.includes("Gentari live feed unavailable")));
  } finally {
    delete environment.GENTARI_API_URL;
    delete environment.GENTARI_API_TOKEN;
    globalThis.fetch = originalFetch;
  }
});

test("Private station reads use the signed-in JWT so database RLS can filter invitees", async () => {
  const originalFetch = globalThis.fetch;
  let privateRequest;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("/auth/v1/user")) return Response.json({ id: "user-1" });
    if (String(url).includes("/private_charger_sites")) {
      privateRequest = { url: String(url), headers: options.headers };
      return Response.json([{
        id: "site-1",
        station: {
          id: "forged", name: "Shared depot", address: "Kuala Lumpur",
          coordinate: { latitude: 3.14, longitude: 101.68 }, operatorName: "Workplace",
          connectors: [{ kind: "type2", powerKW: 22, count: 1 }],
          availability: { state: "available", availableConnectors: 1, totalConnectors: 1 },
          price: { amountMYR: 0, unit: "kWh" }, access: "public", source: "openChargeMap",
        },
      }]);
    }
    return new Response("Unavailable", { status: 503 });
  };
  try {
    const response = await handler(request());
    const data = await response.json();
    assert.equal(response.status, 200);
    assert.equal(privateRequest.headers.Authorization, "Bearer signed-in-user");
    assert.equal(privateRequest.headers.apikey, "public-anon-key");
    assert.deepEqual(new URL(privateRequest.url).searchParams.getAll("select"), ["id,station"]);
    assert.equal(data.stations[0].id, "private:site-1");
    assert.equal(data.stations[0].access, "private");
    assert.equal(data.stations[0].availability.state, "unknown");
    assert.equal(data.stations[0].price, null);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
  } finally { globalThis.fetch = originalFetch; }
});

test("MEVnet snapshots are served only while reuse approval is active", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(String(url));
    if (String(url).includes("/auth/v1/user")) return Response.json({ id: "user-1" });
    if (String(url).includes("/private_charger_sites")) return Response.json([]);
    if (String(url).includes("source=eq.open_charge_map")) return Response.json([]);
    if (String(url).includes("source=eq.mevnet")) return Response.json([{
      stations: [{ id: "mevnet:1", name: "Planning site", address: "Selangor", operatorName: "Network unavailable",
        coordinate: { latitude: 3.14, longitude: 101.68 }, connectors: [],
        availability: { state: "unknown", availableConnectors: null, totalConnectors: null, lastUpdated: null },
        price: null, source: "mevnet" }],
      synced_at: new Date().toISOString(), import_report: { fetched: 1, included: 1 },
    }]);
    return new Response("Unavailable", { status: 503 });
  };
  try {
    environment.MEVNET_REUSE_APPROVED = "true";
    const approved = await handler(request());
    assert.equal(approved.status, 200);
    assert.deepEqual((await approved.json()).stations.map((station) => station.id), ["mevnet:1"]);
    assert.ok(requests.some((url) => url.includes("source=eq.mevnet")));

    requests.length = 0;
    delete environment.MEVNET_REUSE_APPROVED;
    const revoked = await handler(request());
    assert.equal(revoked.status, 502);
    assert.equal(revoked.headers.get("Cache-Control"), "no-store");
    assert.ok(requests.every((url) => !url.includes("source=eq.mevnet")));
  } finally {
    delete environment.MEVNET_REUSE_APPROVED;
    globalThis.fetch = originalFetch;
  }
});

test("a validated zero-eligible catalog is available without resurrecting prior sites", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url).includes("/auth/v1/user")) return Response.json({ id: "user-1" });
    if (String(url).includes("/private_charger_sites")) return Response.json([]);
    if (String(url).includes("source=eq.open_charge_map")) return Response.json([{
      stations: [], synced_at: new Date().toISOString(),
      import_report: { fetched: 2, included: 0, private: 1, invalid: 0, license: 1 },
    }]);
    return new Response("Unavailable", { status: 503 });
  };
  try {
    const result = await handler(request());
    const data = await result.json();
    assert.equal(result.status, 200);
    assert.deepEqual(data.stations, []);
    assert.equal(data.catalogImportReport.included, 0);
  } finally { globalThis.fetch = originalFetch; }
});

test("Missing both sources is an error, not a fabricated demo result", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => String(url).includes("/auth/v1/user")
    ? Response.json({ id: "user-1" })
    : new Response("Unavailable", { status: 503 });
  try {
    const response = await handler(request());
    assert.equal(response.status, 502);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
