import { combineSources, filterStations, normalizeGentari, stationArray, type Station } from "./shared.ts";

const jsonHeaders = { "Content-Type": "application/json" };

Deno.serve(async (request) => {
  if (request.method !== "GET") return response({ error: "Method not allowed" }, 405);

  const authorization = request.headers.get("Authorization");
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!authorization || !supabaseURL || !supabaseAnonKey) return response({ error: "Unauthorized" }, 401);

  try {
    const userResponse = await fetch(`${supabaseURL}/auth/v1/user`, {
      headers: { Authorization: authorization, apikey: supabaseAnonKey },
    });
    if (!userResponse.ok) return response({ error: "Unauthorized" }, 401);
  } catch {
    return response({ error: "Authentication is unavailable" }, 503);
  }

  const requested = new URL(request.url).searchParams;
  const requestedConnectors = (requested.get("connectors") ?? "").split(",").filter(Boolean);
  const minimumPower = Number(requested.get("minimumPowerKW") ?? "0");
  if (requestedConnectors.some((value) => !["type2", "ccs2", "chademo"].includes(value)) ||
      !Number.isFinite(minimumPower) || minimumPower < 0) {
    return response({ error: "Invalid charger filters" }, 400);
  }

  const [gentari, catalog] = await Promise.all([fetchGentari(), readCatalog(supabaseURL)]);
  const combined = combineSources(gentari, catalog?.stations ?? null);
  if (!combined) return response({ error: "Charger sources are unavailable" }, 502);
  const warnings = combined.warnings;
  if (catalog && Date.now() - new Date(catalog.syncedAt).getTime() > 48 * 60 * 60 * 1000) {
    warnings.push("Open Charge Map catalog has not synced recently; locations may be outdated.");
  }
  const stations = filterStations(combined.stations, new Set(requestedConnectors), minimumPower);
  return new Response(JSON.stringify({ stations, warnings, catalogSyncedAt: catalog?.syncedAt ?? null }), {
    status: 200,
    headers: { ...jsonHeaders, "Cache-Control": "private, max-age=30" },
  });
});

async function fetchGentari(): Promise<Station[] | null> {
  const partnerURL = Deno.env.get("GENTARI_API_URL");
  const partnerToken = Deno.env.get("GENTARI_API_TOKEN");
  if (!partnerURL || !partnerToken) return null;
  try {
    const partnerResponse = await fetch(partnerURL, {
      headers: { Authorization: `Bearer ${partnerToken}`, Accept: "application/json" },
      signal: AbortSignal.timeout(15_000),
    });
    if (!partnerResponse.ok) return null;
    return stationArray(await partnerResponse.json())
      .map(normalizeGentari)
      .filter((station): station is Station => station !== null);
  } catch {
    return null;
  }
}

async function readCatalog(supabaseURL: string): Promise<{ stations: Station[]; syncedAt: string } | null> {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceKey) return null;
  try {
    const url = new URL(`${supabaseURL}/rest/v1/charger_catalog`);
    url.searchParams.set("source", "eq.open_charge_map");
    url.searchParams.set("select", "stations,synced_at");
    const catalogResponse = await fetch(url, {
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
      signal: AbortSignal.timeout(10_000),
    });
    if (!catalogResponse.ok) return null;
    const rows = await catalogResponse.json();
    const row = Array.isArray(rows) ? rows[0] : null;
    if (!row || !Array.isArray(row.stations) || !row.stations.length || typeof row.synced_at !== "string") return null;
    return { stations: row.stations, syncedAt: row.synced_at };
  } catch {
    return null;
  }
}

function response(payload: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(payload), { status, headers: jsonHeaders });
}
