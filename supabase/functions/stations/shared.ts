export type JSONObject = Record<string, unknown>;

export type Station = {
  id: string;
  name: string;
  address: string;
  coordinate: { latitude: number; longitude: number };
  operatorName: string;
  connectors: { kind: string; powerKW: number | null; count: number | null }[];
  availability: {
    state: string;
    availableConnectors: number | null;
    totalConnectors: number | null;
    lastUpdated: string | null;
  };
  price: { amountMYR: number; unit: string; lastUpdated: string | null } | null;
  source: "gentari" | "openChargeMap";
};

export function stationArray(payload: unknown): JSONObject[] {
  if (Array.isArray(payload)) return payload.filter(isObject);
  if (!isObject(payload)) return [];
  for (const key of ["stations", "locations", "data"]) {
    const value = payload[key];
    if (Array.isArray(value)) return value.filter(isObject);
  }
  return [];
}

export function normalizeGentari(raw: JSONObject): Station | null {
  const id = text(raw.id ?? raw.station_id ?? raw.location_id);
  const name = text(raw.name ?? raw.station_name);
  const latitude = number(raw.latitude ?? raw.lat);
  const longitude = number(raw.longitude ?? raw.lng ?? raw.lon);
  if (!id || !name || !validCoordinate(latitude, longitude)) return null;

  const connectorPayload = Array.isArray(raw.connectors) ? raw.connectors.filter(isObject) : [];
  const connectors = connectorPayload.flatMap((connector) => {
    const kind = normalizeConnector(text(connector.kind ?? connector.standard ?? connector.type));
    const powerKW = positive(number(connector.power_kw ?? connector.powerKW ?? connector.max_power_kw));
    if (!kind) return [];
    return [{ kind, powerKW, count: positiveInteger(connector.count ?? connector.quantity) }];
  });
  if (!connectors.length) return null;

  const availability = isObject(raw.availability) ? raw.availability : raw;
  const pricePayload = isObject(raw.price) ? raw.price : null;
  const amount = pricePayload ? number(pricePayload.amount_myr ?? pricePayload.amount) : null;
  const unit = pricePayload ? normalizePriceUnit(text(pricePayload.unit)) : null;

  return {
    id,
    name,
    address: text(raw.address ?? raw.formatted_address) ?? "Address unavailable",
    coordinate: { latitude, longitude: longitude! },
    operatorName: text(raw.operator_name ?? raw.operator) ?? "Gentari",
    connectors,
    availability: {
      state: normalizeStatus(text(availability.status ?? availability.state)),
      availableConnectors: nonnegativeInteger(availability.available_connectors ?? availability.available),
      totalConnectors: nonnegativeInteger(availability.total_connectors ?? availability.total),
      lastUpdated: isoDate(availability.last_updated ?? availability.updated_at),
    },
    price: amount !== null && amount >= 0 && unit ? {
      amountMYR: amount,
      unit,
      lastUpdated: isoDate(pricePayload?.last_updated ?? pricePayload?.updated_at),
    } : null,
    source: "gentari",
  };
}

export function normalizeOpenChargeMap(raw: JSONObject): Station | null {
  const provider = isObject(raw.DataProvider) ? raw.DataProvider : null;
  // ponytail: only contributor data has a known compatible license; review provider IDs before widening this gate.
  if (number(provider?.ID ?? raw.DataProviderID) !== 1) return null;
  const id = positiveInteger(raw.ID);
  const address = isObject(raw.AddressInfo) ? raw.AddressInfo : null;
  const country = isObject(address?.Country) ? address.Country : null;
  const countryCode = text(country?.ISOCode);
  const latitude = number(address?.Latitude);
  const longitude = number(address?.Longitude);
  if (!id || !validCoordinate(latitude, longitude) || (countryCode ? countryCode !== "MY" : number(address?.CountryID) !== 137) ||
      latitude < 0.8 || latitude > 7.5 || longitude! < 99 || longitude! > 120.5) return null;
  const name = text(address?.Title);
  if (!name) return null;

  const connections = Array.isArray(raw.Connections) ? raw.Connections.filter(isObject) : [];
  const connectors = connections.flatMap((connection) => {
    const type = isObject(connection.ConnectionType) ? connection.ConnectionType : null;
    const kind = ocmConnector(number(connection.ConnectionTypeID ?? type?.ID));
    if (!kind) return [];
    return [{ kind, powerKW: positive(number(connection.PowerKW)), count: positiveInteger(connection.Quantity) }];
  });
  if (!connectors.length) return null;

  const operator = isObject(raw.OperatorInfo) ? raw.OperatorInfo : null;
  const addressParts = [address?.AddressLine1, address?.Town, address?.StateOrProvince]
    .map(text).filter((part): part is string => part !== null);
  return {
    id: `ocm:${id}`,
    name,
    address: addressParts.join(", ") || "Address unavailable",
    coordinate: { latitude, longitude: longitude! },
    operatorName: text(operator?.Title) ?? "Operator unavailable",
    connectors,
    // OCM operational flags and free-text usage cost are directory data, not live availability or current tariffs.
    availability: { state: "unknown", availableConnectors: null, totalConnectors: null, lastUpdated: null },
    price: null,
    source: "openChargeMap",
  };
}

export function mergeStations(gentari: Station[], openChargeMap: Station[]): Station[] {
  // ponytail: exact-name/100 m matching avoids false merges; add a shared site ID if a partner feed supplies one.
  return [...gentari, ...openChargeMap.filter((openStation) => !gentari.some((partnerStation) =>
    partnerStation.id === openStation.id ||
    (sameName(openStation.name, partnerStation.name) && distanceMeters(openStation.coordinate, partnerStation.coordinate) <= 100)
  ))];
}

export function combineSources(gentari: Station[] | null, openChargeMap: Station[] | null): {
  stations: Station[];
  warnings: string[];
} | null {
  if (gentari === null && openChargeMap === null) return null;
  const warnings: string[] = [];
  if (gentari === null) warnings.push("Gentari live feed unavailable; showing open-data locations only.");
  if (openChargeMap === null) warnings.push("Open Charge Map catalog unavailable; showing Gentari locations only.");
  return { stations: mergeStations(gentari ?? [], openChargeMap ?? []), warnings };
}

export function filterStations(stations: Station[], connectors: Set<string>, minimumPower: number): Station[] {
  return stations.filter((station) => station.connectors.some((connector) =>
    (!connectors.size || connectors.has(connector.kind)) &&
    (minimumPower <= 0 || (connector.powerKW !== null && connector.powerKW >= minimumPower))
  ));
}

function ocmConnector(id: number | null): string | null {
  if (id === 33) return "ccs2";
  if (id === 25 || id === 1036) return "type2";
  if (id === 2) return "chademo";
  return null;
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

function sameName(lhs: string, rhs: string): boolean {
  const normalized = (value: string) => value.toLowerCase().replaceAll(/[^a-z0-9]/g, "");
  const first = normalized(lhs);
  return first.length > 0 && first === normalized(rhs);
}

function distanceMeters(lhs: Station["coordinate"], rhs: Station["coordinate"]): number {
  const radians = Math.PI / 180;
  const x = (lhs.longitude - rhs.longitude) * radians * Math.cos((lhs.latitude + rhs.latitude) / 2 * radians);
  const y = (lhs.latitude - rhs.latitude) * radians;
  return Math.hypot(x, y) * 6_371_000;
}

function validCoordinate(latitude: number | null, longitude: number | null): latitude is number {
  return latitude !== null && longitude !== null && latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;
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

function positive(value: number | null): number | null {
  return value !== null && value > 0 ? value : null;
}

function positiveInteger(value: unknown): number | null {
  const parsed = number(value);
  return parsed !== null && Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function nonnegativeInteger(value: unknown): number | null {
  const parsed = number(value);
  return parsed !== null && Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null;
}

function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
