import { normalizeOpenChargeMap, type JSONObject, type Station } from "../stations/shared.ts";

const pageSize = 1_000;
const maxPages = 20;

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, "Method not allowed");
  const syncToken = Deno.env.get("OCM_SYNC_TOKEN");
  if (!syncToken || !matchesToken(request.headers.get("x-sync-token"), syncToken)) return reply(401, "Unauthorized");

  const apiKey = Deno.env.get("OPEN_CHARGE_MAP_API_KEY");
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!apiKey || !supabaseURL || !serviceKey) return reply(503, "Catalog sync is not configured");

  try {
    const stations = await downloadMalaysia(apiKey);
    if (!stations.length) return reply(502, "Catalog sync returned no usable locations");
    const url = new URL(`${supabaseURL}/rest/v1/charger_catalog`);
    url.searchParams.set("on_conflict", "source");
    const saved = await fetch(url, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=minimal",
      },
      body: JSON.stringify({ source: "open_charge_map", stations, synced_at: new Date().toISOString() }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!saved.ok) return reply(502, "Catalog could not be saved");
    return new Response(JSON.stringify({ imported: stations.length }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch {
    // Keep the previous successful snapshot unchanged on any incomplete import.
    return reply(502, "Catalog sync failed");
  }
});

async function downloadMalaysia(apiKey: string): Promise<Station[]> {
  const stations: Station[] = [];
  let afterID = 0;
  for (let page = 0; page < maxPages; page++) {
    const url = new URL("https://api.openchargemap.io/v3/poi/");
    url.searchParams.set("output", "json");
    url.searchParams.set("countrycode", "MY");
    url.searchParams.set("opendata", "true");
    url.searchParams.set("compact", "false");
    url.searchParams.set("verbose", "true");
    url.searchParams.set("sortby", "id_asc");
    url.searchParams.set("greaterthanid", String(afterID));
    url.searchParams.set("maxresults", String(pageSize));
    const response = await fetch(url, {
      headers: { "X-API-Key": apiKey, "User-Agent": "VoltWay-Malaysia-Catalog/1.0" },
      signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error("Open Charge Map request failed");
    const records: unknown = await response.json();
    if (!Array.isArray(records) || records.some((record) =>
      !isObject(record) || typeof record.ID !== "number" || !Number.isSafeInteger(record.ID)
    )) {
      throw new Error("Open Charge Map returned invalid data");
    }
    if (records.length === 0) return stations;
    const nextID = records[records.length - 1].ID as number;
    if (nextID <= afterID) throw new Error("Open Charge Map pagination did not advance");
    stations.push(...records.map(normalizeOpenChargeMap).filter((station): station is Station => station !== null));
    if (records.length < pageSize) return stations;
    afterID = nextID;
  }
  throw new Error("Open Charge Map result exceeds the import limit");
}

function matchesToken(candidate: string | null, expected: string): boolean {
  if (!candidate || candidate.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < expected.length; index++) difference |= candidate.charCodeAt(index) ^ expected.charCodeAt(index);
  return difference === 0;
}

function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function reply(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), { status, headers: { "Content-Type": "application/json" } });
}
