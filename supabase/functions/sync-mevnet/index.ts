import { isAccessUnverifiedMEVnet, isPrivateMEVnet, normalizeMEVnet, type JSONObject, type Station } from "../stations/shared.ts";

const layerURL = "https://gisdev.planmalaysia.gov.my/server/rest/services/Hosted/MEVnet_EVCB/FeatureServer/0/query";
const pageSize = 1_000;

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, "Method not allowed");
  const token = Deno.env.get("MEVNET_SYNC_TOKEN");
  if (!token || !equalToken(request.headers.get("x-sync-token"), token)) return reply(401, "Unauthorized");
  if (Deno.env.get("MEVNET_REUSE_APPROVED") !== "true") return reply(503, "MEVnet reuse approval is not configured");
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseURL || !serviceKey) return reply(503, "Catalog sync is not configured");
  try {
    const { stations, report } = await downloadMEVnet();
    const url = new URL(`${supabaseURL}/rest/v1/charger_catalog`);
    url.searchParams.set("on_conflict", "source");
    const saved = await fetch(url, {
      method: "POST",
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify({ source: "mevnet", stations, import_report: report, synced_at: new Date().toISOString() }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!saved.ok) throw new Error("Catalog save failed");
    return new Response(JSON.stringify({ imported: stations.length, report }), { headers: { "Content-Type": "application/json" } });
  } catch {
    // A failed or incomplete download never replaces the last successful snapshot.
    return reply(502, "MEVnet sync failed; previous snapshot retained");
  }
});

export async function downloadMEVnet(): Promise<{ stations: Station[]; report: Record<string, unknown> }> {
  // Fix the source ID set before reading features so edits cannot shift offset pages.
  const idsURL = new URL(layerURL);
  idsURL.search = new URLSearchParams({ f: "json", where: "1=1", returnIdsOnly: "true" }).toString();
  const idsResult = await readJSON(idsURL);
  if (!Array.isArray(idsResult.objectIds) || !idsResult.objectIds.length || idsResult.objectIds.some((id) =>
    typeof id !== "number" || !Number.isSafeInteger(id) || id <= 0
  )) throw new Error("Invalid object IDs");
  const expectedIDs = (idsResult.objectIds as number[]).sort((a, b) => a - b);
  if (new Set(expectedIDs).size !== expectedIDs.length) throw new Error("Duplicate object IDs");
  const expected = expectedIDs.length;
  const stations: Station[] = [];
  const excludedIDs: number[] = [];
  const privateIDs: number[] = [];
  const accessUnverifiedIDs: number[] = [];
  const states: Record<string, { fetched: number; included: number; proposed: number; invalid: number; private: number; accessUnverified: number }> = {};
  const seen = new Set<number>();
  let fetched = 0;
  let previousID = 0;
  let proposed = 0;
  for (let offset = 0; offset < expected; offset += pageSize) {
    const batch = expectedIDs.slice(offset, offset + pageSize);
    // A form body avoids ArcGIS GET URL limits for a full batch of object IDs.
    const parameters = new URLSearchParams({ f: "json", objectIds: batch.join(","), outFields: "*",
      returnGeometry: "false", orderByFields: "objectid ASC" });
    const result = await readJSON(new URL(layerURL), { method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: parameters.toString() });
    if (!Array.isArray(result.features) || (result.exceededTransferLimit !== undefined &&
        typeof result.exceededTransferLimit !== "boolean")) throw new Error("Invalid page");
    const features = result.features;
    if (result.exceededTransferLimit === true || features.length !== batch.length) throw new Error("Incomplete object ID batch");
    const expectedBatch = new Set(batch);
    const featuresByID = new Map<number, JSONObject>();
    for (const feature of features) {
      if (!isObject(feature) || !isObject(feature.attributes)) throw new Error("Invalid feature");
      const id = feature.attributes.objectid;
      if (typeof id !== "number" || !Number.isSafeInteger(id) || !expectedBatch.has(id) || featuresByID.has(id)) {
        throw new Error("Unexpected object ID");
      }
      featuresByID.set(id, feature);
    }
    for (const id of batch) {
      const attributes = featuresByID.get(id)?.attributes;
      if (!isObject(attributes) || id <= previousID || seen.has(id)) throw new Error("Unexpected object ID");
      seen.add(id);
      previousID = id;
      fetched++;
      const state = typeof attributes.state === "string" && attributes.state.trim() ? attributes.state.trim().slice(0, 100) : "State unavailable";
      const tally = states[state] ?? { fetched: 0, included: 0, proposed: 0, invalid: 0, private: 0, accessUnverified: 0 };
      tally.fetched++;
      const privateSite = isPrivateMEVnet(attributes);
      const accessUnverified = !privateSite && isAccessUnverifiedMEVnet(attributes);
      const station = privateSite || accessUnverified ? null : normalizeMEVnet(attributes);
      if (station) {
        stations.push(station);
        tally.included++;
        if (station.lifecycle === "proposed") { proposed++; tally.proposed++; }
      } else if (privateSite) { privateIDs.push(id); tally.private++; }
      else if (accessUnverified) { accessUnverifiedIDs.push(id); tally.accessUnverified++; }
      else { excludedIDs.push(id); tally.invalid++; }
      states[state] = tally;
    }
  }
  if (fetched !== expected || stations.length + excludedIDs.length + privateIDs.length + accessUnverifiedIDs.length !== fetched ||
      Object.values(states).reduce((sum, state) => sum + state.fetched, 0) !== fetched ||
      Object.values(states).some((state) => state.fetched !== state.included + state.invalid + state.private + state.accessUnverified)) throw new Error("Import did not reconcile");
  return { stations, report: { fetched, included: stations.length, existing: stations.filter((station) => station.lifecycle === "existing").length,
    proposed, unknown: stations.filter((station) => station.lifecycle === "unknown").length,
    invalid: excludedIDs.length, private: privateIDs.length, accessUnverified: accessUnverifiedIDs.length,
    excludedIDs: { invalid: excludedIDs, private: privateIDs, accessUnverified: accessUnverifiedIDs }, states } };
}

async function readJSON(url: URL, options: RequestInit = {}): Promise<JSONObject> {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error("MEVnet request failed");
  const value: unknown = await response.json();
  if (!isObject(value) || value.error) throw new Error("MEVnet returned an error");
  return value;
}

function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function equalToken(candidate: string | null, expected: string): boolean {
  if (!candidate || candidate.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < expected.length; index++) difference |= candidate.charCodeAt(index) ^ expected.charCodeAt(index);
  return difference === 0;
}

function reply(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), { status, headers: { "Content-Type": "application/json" } });
}
