import assert from "node:assert/strict";
import test from "node:test";

let handler;
globalThis.Deno = {
  serve: (callback) => { handler = callback; },
  env: {
    get: (key) => ({
      OCM_SYNC_TOKEN: "private-sync-token",
      OPEN_CHARGE_MAP_API_KEY: "private-ocm-key",
      SUPABASE_URL: "https://voltway.test",
      SUPABASE_SERVICE_ROLE_KEY: "private-service-key",
    })[key],
  },
};
await import("./index.ts");

const request = (token = "private-sync-token") => new Request("https://voltway.test/functions/v1/sync-ocm", {
  method: "POST",
  headers: { "x-sync-token": token },
});

test("Sync rejects callers without its server-only token", async () => {
  const result = await handler(request("wrong-token"));
  assert.equal(result.status, 401);
});

test("A failed download makes no catalog write", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, options) => {
    requests.push({ url: String(url), method: options?.method ?? "GET" });
    return new Response("Unavailable", { status: 503 });
  };
  try {
    const result = await handler(request());
    assert.equal(result.status, 502);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].method, "GET");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("A complete import writes one atomic catalog snapshot", async () => {
  const originalFetch = globalThis.fetch;
  const writes = [];
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("openchargemap.io")) {
      assert.equal(options.headers["X-API-Key"], "private-ocm-key");
      assert.equal(new URL(url).searchParams.has("opendata"), false);
      if (Number(new URL(url).searchParams.get("greaterthanid")) > 0) return Response.json([]);
      return Response.json([{
        ID: 42,
        DataProviderID: 1,
        AddressInfo: { Title: "City Mall", CountryID: 137, Latitude: 3.14, Longitude: 101.68 },
        Connections: [{ ConnectionTypeID: 33, PowerKW: 120, Quantity: 2 }],
        StatusType: { IsOperational: true },
        UsageCost: "RM 1.40/kWh",
      }]);
    }
    writes.push(JSON.parse(options.body));
    return new Response(null, { status: 201 });
  };
  try {
    const result = await handler(request());
    assert.equal(result.status, 200);
    assert.equal(writes.length, 1);
    assert.equal(writes[0].stations[0].id, "ocm:42");
    assert.equal(writes[0].stations[0].price, null);
    assert.equal(writes[0].stations[0].availability.state, "unknown");
    assert.deepEqual(writes[0].import_report, {
      fetched: 1, included: 1, private: 0, invalid: 0, license: 0, providerIDsNeedingReview: [],
      excludedIDs: { private: [], invalid: [], license: [] },
      providers: [{ id: 1, name: "Provider 1", fetched: 1, included: 1, private: 0, invalid: 0, license: 0 }],
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("An incomplete page sequence never replaces the last snapshot", async () => {
  const originalFetch = globalThis.fetch;
  let writes = 0;
  let pages = 0;
  globalThis.fetch = async (url) => {
    if (String(url).includes("openchargemap.io")) {
      pages++;
      if (pages === 1) return Response.json(Array.from({ length: 1_000 }, (_, index) => ({
        ID: index + 1,
        DataProviderID: 1,
        AddressInfo: { Title: `Site ${index + 1}`, CountryID: 137, Latitude: 3.14, Longitude: 101.68 },
        Connections: [],
      })));
      return new Response("Source unavailable", { status: 503 });
    }
    writes++;
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 502);
    assert.equal(pages, 2);
    assert.equal(writes, 0);
  } finally { globalThis.fetch = originalFetch; }
});

test("Short pages keep advancing until an empty page confirms completion", async () => {
  const originalFetch = globalThis.fetch;
  const cursors = [];
  let written;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("openchargemap.io")) {
      const cursor = Number(new URL(url).searchParams.get("greaterthanid"));
      cursors.push(cursor);
      if (cursor >= 2) return Response.json([]);
      const id = cursor + 1;
      return Response.json([{ ID: id, DataProviderID: 1,
        AddressInfo: { Title: `Site ${id}`, CountryID: 137, Latitude: 3.14, Longitude: 101.68 }, Connections: [] }]);
    }
    written = JSON.parse(options.body);
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 200);
    assert.deepEqual(cursors, [0, 1, 2]);
    assert.deepEqual(written.stations.map((station) => station.id), ["ocm:1", "ocm:2"]);
  } finally { globalThis.fetch = originalFetch; }
});

test("Import accounts for every fetched record without silently losing unknown connectors", async () => {
  const originalFetch = globalThis.fetch;
  let written;
  const base = {
    ID: 1, DataProviderID: 1,
    AddressInfo: { Title: "Site", CountryID: 137, Latitude: 3.14, Longitude: 101.68 },
    Connections: [],
  };
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("openchargemap.io")) {
      if (Number(new URL(url).searchParams.get("greaterthanid")) > 0) return Response.json([]);
      return Response.json([
      base,
      { ...base, ID: 2, DataProviderID: 9 },
      { ...base, ID: 3, UsageType: { Title: "Private - For Staff Only", IsPublicAccess: false } },
      { ...base, ID: 4, AddressInfo: { ...base.AddressInfo, Latitude: 40 } },
      ]);
    }
    written = JSON.parse(options.body);
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 200);
    assert.deepEqual(written.stations.map((item) => item.id), ["ocm:1"]);
    assert.deepEqual(written.import_report, {
      fetched: 4, included: 1, private: 1, invalid: 1, license: 1, providerIDsNeedingReview: [9],
      excludedIDs: { private: [3], invalid: [4], license: [2] },
      providers: [
        { id: 1, name: "Provider 1", fetched: 3, included: 1, private: 1, invalid: 1, license: 0 },
        { id: 9, name: "Provider 9", fetched: 1, included: 0, private: 0, invalid: 0, license: 1 },
      ],
    });
  } finally { globalThis.fetch = originalFetch; }
});
