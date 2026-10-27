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
const parameters = (url, options) => options?.body ? new URLSearchParams(options.body) : new URL(url).searchParams;

test("MEVnet sync requires its server-only token", async () => {
  assert.equal((await handler(request("wrong"))).status, 401);
});

test("complete object ID batches without an optional transfer flag write one atomic snapshot", async () => {
  const original = globalThis.fetch;
  const writes = [];
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) {
      const query = parameters(url, options);
      if (query.has("returnIdsOnly")) return Response.json({ objectIds: [2, 1] });
      assert.equal(options.method, "POST");
      assert.equal(options.headers["Content-Type"], "application/x-www-form-urlencoded");
      assert.equal(query.get("orderByFields"), "objectid ASC");
      assert.equal(query.get("objectIds"), "1,2");
      return Response.json({ features: [feature(2, { status: "Newly Proposed" }),
        feature(1, { number_of_ev_charger_by_netw_10: 2 })] });
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
    { features: [feature(1), feature(3)], exceededTransferLimit: false },
    { features: "bad", exceededTransferLimit: false },
  ]) {
    let writes = 0;
    globalThis.fetch = async (url, options) => {
      if (String(url).includes("FeatureServer")) return parameters(url, options).has("returnIdsOnly")
        ? Response.json({ objectIds: [1, 2] }) : Response.json(page);
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
    if (String(url).includes("FeatureServer")) return parameters(url, options).has("returnIdsOnly")
      ? Response.json({ objectIds: [1, 2] })
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
    if (String(url).includes("FeatureServer")) return parameters(url, options).has("returnIdsOnly")
      ? Response.json({ objectIds: [1, 2, 3] })
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

test("1,000-record boundary fetches fixed object ID batches and reconciles all records", async () => {
  const original = globalThis.fetch;
  const batches = [];
  let snapshot;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) {
      const query = parameters(url, options);
      if (query.has("returnIdsOnly")) return Response.json({ objectIds: Array.from({ length: 1001 }, (_, index) => index + 1) });
      const ids = query.get("objectIds").split(",").map(Number);
      batches.push(ids);
      return ids[0] === 1
        ? Response.json({ features: Array.from({ length: 1000 }, (_, index) => feature(index + 1)), exceededTransferLimit: false })
        : Response.json({ features: [feature(1001)], exceededTransferLimit: false });
    }
    snapshot = JSON.parse(options.body);
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 200);
    assert.deepEqual(batches.map((batch) => [batch[0], batch.length]), [[1, 1000], [1001, 1]]);
    assert.equal(snapshot.stations.length, 1001);
    assert.equal(snapshot.import_report.fetched, 1001);
  } finally { globalThis.fetch = original; }
});

test("a source change between object ID batches cannot publish a shifted catalog", async () => {
  const original = globalThis.fetch;
  let writes = 0;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) {
      const query = parameters(url, options);
      if (query.has("returnIdsOnly")) return Response.json({ objectIds: Array.from({ length: 1001 }, (_, index) => index + 1) });
      return query.get("objectIds").startsWith("1,")
        ? Response.json({ features: Array.from({ length: 1000 }, (_, index) => feature(index + 1)) })
        : Response.json({ features: [feature(1002)] });
    }
    writes++;
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 502);
    assert.equal(writes, 0);
  } finally { globalThis.fetch = original; }
});

test("a nonempty source whose sites are now all private clears the old snapshot", async () => {
  const original = globalThis.fetch;
  let snapshot;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("FeatureServer")) return parameters(url, options).has("returnIdsOnly")
      ? Response.json({ objectIds: [1] })
      : Response.json({ features: [feature(1, { category: "Private depot" })] });
    snapshot = JSON.parse(options.body);
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await handler(request())).status, 200);
    assert.deepEqual(snapshot.stations, []);
    assert.equal(snapshot.import_report.fetched, 1);
    assert.deepEqual(snapshot.import_report.excludedIDs.private, [1]);
  } finally { globalThis.fetch = original; }
});

test("an empty or duplicate object ID list never replaces the snapshot", async () => {
  const original = globalThis.fetch;
  try {
    for (const objectIds of [[], [1, 1]]) {
      let writes = 0;
      globalThis.fetch = async (url) => {
        if (String(url).includes("FeatureServer")) return Response.json({ objectIds });
        writes++;
        return new Response(null, { status: 201 });
      };
      assert.equal((await handler(request())).status, 502);
      assert.equal(writes, 0);
    }
  } finally {
    globalThis.fetch = original;
  }
});
