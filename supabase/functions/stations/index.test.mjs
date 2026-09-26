import assert from "node:assert/strict";
import test from "node:test";

let handler;
globalThis.Deno = {
  serve: (callback) => { handler = callback; },
  env: {
    get: (key) => ({
      SUPABASE_URL: "https://voltway.test",
      SUPABASE_ANON_KEY: "public-anon-key",
      SUPABASE_SERVICE_ROLE_KEY: "private-service-key",
    })[key],
  },
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
    return Response.json([{
      stations: [{
        id: "ocm:42", name: "City Mall", address: "Kuala Lumpur", operatorName: "DC Handal",
        coordinate: { latitude: 3.14, longitude: 101.68 },
        connectors: [{ kind: "ccs2", powerKW: 120, count: 2 }],
        availability: { state: "unknown", availableConnectors: null, totalConnectors: null, lastUpdated: null },
        price: null, source: "openChargeMap",
      }],
      synced_at: new Date().toISOString(),
    }]);
  };
  try {
    const response = await handler(request("?connectors=ccs2&minimumPowerKW=50"));
    const data = await response.json();
    assert.equal(response.status, 200);
    assert.deepEqual(data.stations.map((station) => station.id), ["ocm:42"]);
    assert.equal(data.warnings.length, 1);
    assert.equal(upstream.length, 2);
    assert.ok(upstream.every((url) => !url.includes("latitude") && !url.includes("longitude")));
  } finally {
    globalThis.fetch = originalFetch;
  }
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
