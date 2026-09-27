import assert from "node:assert/strict";
import test from "node:test";

let handler;
globalThis.Deno = {
  serve: (callback) => { handler = callback; },
  env: { get: (key) => ({ MEVNET_SYNC_TOKEN: "sync-secret", SUPABASE_URL: "https://voltway.test",
    SUPABASE_SERVICE_ROLE_KEY: "service-secret", MEVNET_REUSE_APPROVED: "true" })[key] },
};
await import("./index.ts");

const request = (token = "sync-secret") => new Request("https://voltway.test/functions/v1/sync-mevnet", {
  method: "POST", headers: { "x-sync-token": token },
});
const feature = (objectid, overrides = {}) => ({ attributes: { objectid, location: `Site ${objectid}`,
  latitude: 3.14, longitude: 101.68, state: "Selangor", status: "Existing", type_ac: 2, type_dc: 1,
  data_as: "31-Aug-24", ...overrides } });

test("MEVnet sync requires its server-only token", async () => {
  assert.equal((await handler(request("wrong"))).status, 401);
});

test("complete deterministic pages write one atomic snapshot with planning-only facts", async () => {
  const original = globalThis.fetch;
  const writes = [];
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) {
      const query = new URL(url).searchParams;
      if (query.has("returnCountOnly")) return Response.json({ count: 2 });
      assert.equal(query.get("orderByFields"), "objectid ASC");
      return Response.json({ features: [feature(1, { number_of_ev_charger_by_netw_10: 2 }),
        feature(2, { status: "Newly Proposed" })], exceededTransferLimit: false });
    }
    writes.push(JSON.parse(options.body));
    return new Response(null, { status: 201 });
  };
  try {
    const result = await handler(request());
    assert.equal(result.status, 200);
    assert.equal(writes.length, 1);
    assert.equal(writes[0].source, "mevnet");
    assert.equal(writes[0].stations[0].operatorName, "Gentari");
    assert.deepEqual(writes[0].stations[0].connectors, []);
    assert.equal(writes[0].stations[0].price, null);
    assert.equal(writes[0].stations[0].availability.state, "unknown");
    assert.equal(writes[0].stations[1].lifecycle, "proposed");
    assert.equal(writes[0].import_report.fetched, 2);
    assert.equal(writes[0].import_report.proposed, 1);
  } finally { globalThis.fetch = original; }
});

test("incomplete, repeated, or malformed pages never replace the prior snapshot", async () => {
  const original = globalThis.fetch;
  for (const page of [
    { features: [feature(1)], exceededTransferLimit: false },
    { features: [feature(1), feature(1)], exceededTransferLimit: false },
    { features: "bad", exceededTransferLimit: false },
  ]) {
    let writes = 0;
    globalThis.fetch = async (url) => {
      if (String(url).includes("FeatureServer")) return new URL(url).searchParams.has("returnCountOnly")
        ? Response.json({ count: 2 }) : Response.json(page);
      writes++;
      return new Response(null, { status: 201 });
    };
    assert.equal((await handler(request())).status, 502);
    assert.equal(writes, 0);
  }
  globalThis.fetch = original;
});

test("explicitly private records are counted and not published", async () => {
  const original = globalThis.fetch;
  let snapshot;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) return new URL(url).searchParams.has("returnCountOnly")
      ? Response.json({ count: 2 })
      : Response.json({ features: [feature(1), feature(2, { category: "Private depot" })], exceededTransferLimit: false });
    snapshot = JSON.parse(options.body);
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 200);
    assert.deepEqual(snapshot.stations.map((station) => station.id), ["mevnet:1"]);
    assert.deepEqual(snapshot.import_report.excludedIDs.private, [2]);
    assert.equal(snapshot.import_report.states.Selangor.private, 1);
  } finally { globalThis.fetch = original; }
});

test("residential and campus sites without access permission are accounted for but not published", async () => {
  const original = globalThis.fetch;
  let snapshot;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) return new URL(url).searchParams.has("returnCountOnly")
      ? Response.json({ count: 3 })
      : Response.json({ features: [feature(1), feature(2, { category: "Residential" }),
        feature(3, { category: "University" })], exceededTransferLimit: false });
    snapshot = JSON.parse(options.body);
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 200);
    assert.deepEqual(snapshot.stations.map((station) => station.id), ["mevnet:1"]);
    assert.deepEqual(snapshot.import_report.excludedIDs.accessUnverified, [2, 3]);
    assert.equal(snapshot.import_report.states.Selangor.accessUnverified, 2);
  } finally { globalThis.fetch = original; }
});

test("1,000-record boundary advances by offset and reconciles all pages", async () => {
  const original = globalThis.fetch;
  const offsets = [];
  let snapshot;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) {
      const query = new URL(url).searchParams;
      if (query.has("returnCountOnly")) return Response.json({ count: 1001 });
      offsets.push(Number(query.get("resultOffset")));
      return Number(query.get("resultOffset")) === 0
        ? Response.json({ features: Array.from({ length: 1000 }, (_, index) => feature(index + 1)), exceededTransferLimit: true })
        : Response.json({ features: [feature(1001)], exceededTransferLimit: false });
    }
    snapshot = JSON.parse(options.body);
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 200);
    assert.deepEqual(offsets, [0, 1000]);
    assert.equal(snapshot.stations.length, 1001);
    assert.equal(snapshot.import_report.fetched, 1001);
  } finally { globalThis.fetch = original; }
});
