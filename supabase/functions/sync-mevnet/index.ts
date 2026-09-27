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
    if (!stations.length) throw new Error("Empty catalog");
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
  const countURL = new URL(layerURL);
  countURL.search = new URLSearchParams({ f: "json", where: "1=1", returnCountOnly: "true" }).toString();
  const countResult = await readJSON(countURL);
  if (!Number.isSafeInteger(countResult.count) || (countResult.count as number) <= 0) throw new Error("Invalid count");
  const expected = countResult.count as number;
  const stations: Station[] = [];
  const excludedIDs: number[] = [];
  const privateIDs: number[] = [];
  const accessUnverifiedIDs: number[] = [];
  const states: Record<string, { fetched: number; included: number; proposed: number; invalid: number; private: number; accessUnverified: number }> = {};
  const seen = new Set<number>();
  let fetched = 0;
  let previousID = 0;
  let proposed = 0;
  for (let offset = 0; offset < expected + pageSize; offset += pageSize) {
    const url = new URL(layerURL);
    url.search = new URLSearchParams({ f: "json", where: "1=1", outFields: "*", returnGeometry: "false",
      orderByFields: "objectid ASC", resultOffset: String(offset), resultRecordCount: String(pageSize) }).toString();
    const result = await readJSON(url);
    if (!Array.isArray(result.features) || typeof result.exceededTransferLimit !== "boolean") throw new Error("Invalid page");
    const features = result.features;
    if (features.length === 0) {
      if (fetched !== expected) throw new Error("Incomplete page sequence");
      break;
    }
    for (const feature of features) {
      if (!isObject(feature) || !isObject(feature.attributes)) throw new Error("Invalid feature");
      const attributes = feature.attributes;
      const id = attributes.objectid;
      if (typeof id !== "number" || !Number.isSafeInteger(id) || id <= previousID || seen.has(id)) throw new Error("Nonadvancing page");
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
    if (fetched > expected) throw new Error("Count changed during import");
    if (!result.exceededTransferLimit) {
      if (fetched !== expected) throw new Error("Incomplete final page");
      break;
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

async function readJSON(url: URL): Promise<JSONObject> {
  const response = await fetch(url, { signal: AbortSignal.timeout(20_000) });
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
