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
  } finally {
    globalThis.fetch = originalFetch;
  }
});
