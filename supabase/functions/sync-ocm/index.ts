import { classifyOpenChargeMap, type JSONObject, type Station } from "../stations/shared.ts";

const pageSize = 1_000;
const maxPages = 100;

type ImportReport = {
  fetched: number; included: number; private: number; invalid: number; license: number;
  providerIDsNeedingReview: number[];
  excludedIDs: { private: number[]; invalid: number[]; license: number[] };
  providers: { id: number; name: string; fetched: number; included: number; private: number; invalid: number; license: number }[];
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, "Method not allowed");
  const syncToken = Deno.env.get("OCM_SYNC_TOKEN");
  if (!syncToken || !matchesToken(request.headers.get("x-sync-token"), syncToken)) return reply(401, "Unauthorized");

  const apiKey = Deno.env.get("OPEN_CHARGE_MAP_API_KEY");
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!apiKey || !supabaseURL || !serviceKey) return reply(503, "Catalog sync is not configured");

  try {
    const { stations, report } = await downloadMalaysia(apiKey);
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
      body: JSON.stringify({ source: "open_charge_map", stations, import_report: report, synced_at: new Date().toISOString() }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!saved.ok) return reply(502, "Catalog could not be saved");
    return new Response(JSON.stringify({ imported: stations.length, report }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch {
    // Keep the previous successful snapshot unchanged on any incomplete import.
    return reply(502, "Catalog sync failed");
  }
});

async function downloadMalaysia(apiKey: string): Promise<{ stations: Station[]; report: ImportReport }> {
  const stations: Station[] = [];
  const report: ImportReport = { fetched: 0, included: 0, private: 0, invalid: 0, license: 0,
    providerIDsNeedingReview: [], excludedIDs: { private: [], invalid: [], license: [] }, providers: [] };
  const providers = new Map<number, ImportReport["providers"][number]>();
  const unreviewed = new Set<number>();
  let afterID = 0;
  for (let page = 0; page < maxPages; page++) {
    const url = new URL("https://api.openchargemap.io/v3/poi/");
    url.searchParams.set("output", "json");
    url.searchParams.set("countrycode", "MY");
    // Request all Malaysian records so restricted licenses are counted, never silently omitted by the API.
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
    if (records.length === 0) return reconciledImport(stations, report);
    const nextID = records[records.length - 1].ID as number;
    if (nextID <= afterID || records.some((record, index) =>
      (record.ID as number) <= (index === 0 ? afterID : records[index - 1].ID as number)
    )) throw new Error("Open Charge Map pagination did not advance");
    for (const record of records) {
      report.fetched++;
      const result = classifyOpenChargeMap(record);
      const provider = isObject(record.DataProvider) ? record.DataProvider : null;
      const providerID = result.providerID ?? 0;
      const providerReport = providers.get(providerID) ?? {
        id: providerID,
        name: text(provider?.Title) ?? (providerID ? `Provider ${providerID}` : "Provider unavailable"),
        fetched: 0, included: 0, private: 0, invalid: 0, license: 0,
      };
      providerReport.fetched++;
      if (result.station) providerReport.included++;
      else if (result.excluded) providerReport[result.excluded]++;
      providers.set(providerID, providerReport);
      if (result.station) { stations.push(result.station); report.included++; }
      else if (result.excluded) {
        report[result.excluded]++;
        report.excludedIDs[result.excluded].push(record.ID as number);
      }
      if (result.excluded === "license" && result.providerID !== null) unreviewed.add(result.providerID);
    }
    report.providerIDsNeedingReview = [...unreviewed].sort((a, b) => a - b);
    report.providers = [...providers.values()].sort((a, b) => a.name.localeCompare(b.name));
    // A short page is not proof of completion: keep paging until the API confirms an empty page.
    afterID = nextID;
  }
  throw new Error("Open Charge Map result exceeds the import limit");
}

function reconciledImport(stations: Station[], report: ImportReport): { stations: Station[]; report: ImportReport } {
  const providerTotals = report.providers.reduce((totals, provider) => ({
    fetched: totals.fetched + provider.fetched,
    included: totals.included + provider.included,
    private: totals.private + provider.private,
    invalid: totals.invalid + provider.invalid,
    license: totals.license + provider.license,
  }), { fetched: 0, included: 0, private: 0, invalid: 0, license: 0 });
  if (report.fetched !== report.included + report.private + report.invalid + report.license ||
      providerTotals.fetched !== report.fetched || providerTotals.included !== report.included ||
      providerTotals.private !== report.private || providerTotals.invalid !== report.invalid ||
      providerTotals.license !== report.license ||
      new Set(stations.map((station) => station.id)).size !== stations.length ||
      report.private !== report.excludedIDs.private.length ||
      report.invalid !== report.excludedIDs.invalid.length ||
      report.license !== report.excludedIDs.license.length) {
    throw new Error("Open Charge Map import did not reconcile");
  }
  return { stations, report };
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

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function reply(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), { status, headers: { "Content-Type": "application/json" } });
}
