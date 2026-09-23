type JSONObject = Record<string, unknown>;

const jsonHeaders = { "Content-Type": "application/json" };

Deno.serve(async (request) => {
  if (request.method !== "GET") return response({ error: "Method not allowed" }, 405);

  const authorization = request.headers.get("Authorization");
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!authorization || !supabaseURL || !supabaseAnonKey) return response({ error: "Unauthorized" }, 401);

  const userResponse = await fetch(`${supabaseURL}/auth/v1/user`, {
    headers: { Authorization: authorization, apikey: supabaseAnonKey },
  });
  if (!userResponse.ok) return response({ error: "Unauthorized" }, 401);

  const partnerURL = Deno.env.get("GENTARI_API_URL");
  const partnerToken = Deno.env.get("GENTARI_API_TOKEN");
  if (!partnerURL || !partnerToken) return response({ error: "Partner feed is not configured" }, 503);

  try {
    const partnerResponse = await fetch(partnerURL, {
      headers: { Authorization: `Bearer ${partnerToken}`, Accept: "application/json" },
    });
    if (!partnerResponse.ok) return response({ error: "Partner feed is unavailable" }, 502);

    const payload = await partnerResponse.json();
    const requested = new URL(request.url).searchParams;
    const connectors = new Set((requested.get("connectors") ?? "").split(",").filter(Boolean));
    const minimumPower = Number(requested.get("minimumPowerKW") ?? "0");

    const stations = stationArray(payload)
      .map(normalizeStation)
      .filter((station): station is JSONObject => station !== null)
      .filter((station) => {
        const stationConnectors = station.connectors as JSONObject[];
        return stationConnectors.some((connector) => {
          const kind = connector.kind as string;
          const power = connector.powerKW as number;
          return (!connectors.size || connectors.has(kind)) && power >= minimumPower;
        });
      });

    return new Response(JSON.stringify({ stations }), {
      status: 200,
      headers: { ...jsonHeaders, "Cache-Control": "private, max-age=30" },
    });
  } catch {
    return response({ error: "Partner feed is unavailable" }, 502);
  }
});

function stationArray(payload: unknown): JSONObject[] {
  if (Array.isArray(payload)) return payload.filter(isObject);
  if (!isObject(payload)) return [];
  for (const key of ["stations", "locations", "data"]) {
    const value = payload[key];
    if (Array.isArray(value)) return value.filter(isObject);
  }
  return [];
}

function normalizeStation(raw: JSONObject): JSONObject | null {
  const id = text(raw.id ?? raw.station_id ?? raw.location_id);
  const name = text(raw.name ?? raw.station_name);
  const latitude = number(raw.latitude ?? raw.lat);
  const longitude = number(raw.longitude ?? raw.lng ?? raw.lon);
  if (!id || !name || latitude === null || longitude === null) return null;

  const connectorPayload = Array.isArray(raw.connectors) ? raw.connectors.filter(isObject) : [];
  const connectors = connectorPayload.map((connector) => ({
    kind: normalizeConnector(text(connector.kind ?? connector.standard ?? connector.type)),
    powerKW: number(connector.power_kw ?? connector.powerKW ?? connector.max_power_kw) ?? 0,
    count: number(connector.count ?? connector.quantity) ?? 1,
  })).filter((connector) => connector.kind && connector.powerKW > 0);
  if (!connectors.length) return null;

  const availability = isObject(raw.availability) ? raw.availability : raw;
  const pricePayload = isObject(raw.price) ? raw.price : null;
  const amount = pricePayload ? number(pricePayload.amount_myr ?? pricePayload.amount) : null;
  const unit = pricePayload ? normalizePriceUnit(text(pricePayload.unit)) : null;

  return {
    id,
    name,
    address: text(raw.address ?? raw.formatted_address) ?? "Address unavailable",
    coordinate: { latitude, longitude },
    operatorName: text(raw.operator_name ?? raw.operator) ?? "Gentari",
    connectors,
    availability: {
      state: normalizeStatus(text(availability.status ?? availability.state)),
      availableConnectors: number(availability.available_connectors ?? availability.available),
      totalConnectors: number(availability.total_connectors ?? availability.total),
      lastUpdated: isoDate(availability.last_updated ?? availability.updated_at),
    },
    price: amount !== null && amount >= 0 && unit ? {
      amountMYR: amount,
      unit,
      lastUpdated: isoDate(pricePayload?.last_updated ?? pricePayload?.updated_at),
    } : null,
  };
}

function normalizeConnector(value: string | null): string | null {
  const normalized = value?.toLowerCase().replaceAll(/[^a-z0-9]/g, "");
  if (normalized?.includes("ccs2") || normalized?.includes("combo2")) return "ccs2";
  if (normalized?.includes("chademo")) return "chademo";
  if (normalized?.includes("type2")) return "type2";
  return null;
}

function normalizeStatus(value: string | null): string {
  switch (value?.toLowerCase()) {
    case "available": case "free": return "available";
    case "occupied": case "charging": case "in_use": return "occupied";
    case "offline": case "out_of_service": case "faulted": return "offline";
    default: return "unknown";
  }
}

function normalizePriceUnit(value: string | null): string | null {
  const normalized = value?.toLowerCase();
  if (normalized === "kwh" || normalized === "per_kwh") return "kWh";
  if (normalized === "minute" || normalized === "per_minute" || normalized === "min") return "minute";
  if (normalized === "session" || normalized === "per_session") return "session";
  return null;
}

function isoDate(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? null : date.toISOString();
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function number(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(parsed) ? parsed : null;
}

function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function response(payload: JSONObject, status: number): Response {
  return new Response(JSON.stringify(payload), { status, headers: jsonHeaders });
}
