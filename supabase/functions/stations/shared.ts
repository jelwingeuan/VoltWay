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
  source: "gentari" | "openChargeMap" | "ownerProvided" | "mevnet";
  sourceAttribution?: string;
  sourceAttributions?: string[];
  sourceIDs?: Record<string, string>;
  sourceUpdatedAt?: string | null;
  state?: string | null;
  sourceSequence?: number | null;
  stateCode?: number | null;
  pbtCode?: number | null;
  pbt?: string | null;
  indoorOutdoor?: string | null;
  lifecycle?: "existing" | "proposed" | "unknown";
  acCount?: number | null;
  dcCount?: number | null;
  proposedChargePointCount?: number | null;
  indoorCount?: number | null;
  outdoorCount?: number | null;
  category?: string | null;
  networkCounts?: Record<string, number>;
  access?: "public" | "limited" | "unknown" | "private";
  chargePointCount?: number | null;
};

// These licenses are explicitly permitted for redistribution with the attribution below.
// Unknown or ambiguous provider terms remain excluded and appear in the import report.
const approvedLicenses = new Map([
  ["cc0", "CC0"],
  ["cc-0", "CC0"],
  ["licensed under cc0 by data sharing agreement", "CC0"],
  ["cc by 4.0", "CC BY 4.0"],
  ["licensed under creative commons attribution 4.0 international (cc by 4.0)", "CC BY 4.0"],
]);
const providerFallbacks = new Map([
  [1, "Open Charge Map · CC BY 4.0"],
  [41, "ChargeSini via Open Charge Map · CC0"],
]);

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
    sourceAttribution: "Gentari partner feed",
    sourceAttributions: ["Gentari partner feed"],
    sourceIDs: { gentari: id },
    chargePointCount: positiveInteger(raw.number_of_points ?? raw.charge_point_count),
  };
}

export function normalizeOpenChargeMap(raw: JSONObject): Station | null {
  return classifyOpenChargeMap(raw).station;
}

const mevnetNetworks = ["1Utama", "ABB", "BMW", "Charge N Go", "chargEV", "ChargeSini", "ETCM", "Evwave", "Exicom", "Flexi Parking", "Gentari", "GoCar", "Go To-U", "JomCharge", "Kineta", "MINI", "Nichicon", "ParkEasy", "PEKEMA", "Pestech", "Plugit", "Schneider", "Shell Recharge", "Sunway", "TNB Electron", "Zap", "Others"];

export function normalizeMEVnet(raw: JSONObject): Station | null {
  const id = positiveInteger(raw.objectid);
  const latitude = number(raw.latitude);
  const longitude = number(raw.longitude);
  const name = text(raw.location);
  if (!id || !name || name.length > 160 || !validCoordinate(latitude, longitude) || latitude < 0.8 || latitude > 7.5 || longitude! < 99 || longitude! > 120.5) return null;
  const networkCounts: Record<string, number> = {};
  mevnetNetworks.forEach((network, index) => {
    const key = index === 0 ? "number_of_ev_charger_by_network" : `number_of_ev_charger_by_netwo_${index}`;
    const actualKey = index >= 10 ? `number_of_ev_charger_by_netw_${index}` : key;
    const count = nonnegativeInteger(raw[actualKey]);
    if (count !== null) networkCounts[network] = count;
  });
  const activeNetworks = Object.entries(networkCounts).filter(([network, count]) => count > 0 && network !== "Others").map(([network]) => network);
  const status = text(raw.status)?.toLowerCase() ?? "";
  const lifecycle = status.includes("propos") ? "proposed" : status.includes("exist") ? "existing" : "unknown";
  const sourceUpdatedAt = mevnetDate(raw.data_as);
  return {
    id: `mevnet:${id}`, name,
    address: [text(raw.pbt)?.slice(0, 100), text(raw.state)?.slice(0, 100)].filter(Boolean).join(", ") || "Address unavailable",
    coordinate: { latitude, longitude: longitude! },
    operatorName: activeNetworks.length === 1 ? activeNetworks[0] : activeNetworks.length > 1 ? "Multiple networks" : "Network unavailable",
    connectors: [],
    availability: { state: "unknown", availableConnectors: null, totalConnectors: null, lastUpdated: null },
    price: null, source: "mevnet", sourceAttribution: "PLANMalaysia MEVnet · planning catalog",
    sourceAttributions: ["PLANMalaysia MEVnet · planning catalog"], sourceIDs: { mevnet: String(id) }, sourceUpdatedAt,
    state: text(raw.state)?.slice(0, 100) ?? null,
    sourceSequence: positiveInteger(raw.bil), stateCode: nonnegativeInteger(raw.state_code),
    pbtCode: nonnegativeInteger(raw.pbt_code), pbt: text(raw.pbt)?.slice(0, 100) ?? null,
    indoorOutdoor: text(raw.indoor___outdoor)?.slice(0, 100) ?? null, lifecycle,
    acCount: nonnegativeInteger(raw.type_ac), dcCount: nonnegativeInteger(raw.type_dc),
    proposedChargePointCount: nonnegativeInteger(raw.number_of_proposed_ev_charger__),
    indoorCount: nonnegativeInteger(raw.indoor), outdoorCount: nonnegativeInteger(raw.outdoor),
    category: text(raw.category),
    chargePointCount: nonnegativeInteger(raw.number_of_existing_ev_charger_s), networkCounts,
    access: "unknown",
  };
}

export function isPrivateMEVnet(raw: JSONObject): boolean {
  return [raw.category, raw.access, raw.usage_type].some((value) =>
    typeof value === "string" && /\bprivate\b|\bstaff.only\b|\brestricted\b/i.test(value));
}

export function isAccessUnverifiedMEVnet(raw: JSONObject): boolean {
  const category = text(raw.category)?.toLowerCase();
  return category !== null && ["residential", "residences", "strata", "office", "university"].includes(category);
}

export function normalizePrivateSite(raw: JSONObject): Station | null {
  const supplied = isObject(raw.station) ? raw.station : null;
  const coordinate = supplied && isObject(supplied.coordinate) ? supplied.coordinate : null;
  const latitude = number(coordinate?.latitude);
  const longitude = number(coordinate?.longitude);
  const id = text(raw.id);
  const name = text(supplied?.name);
  if (!id || !name || name.length > 100 || !validCoordinate(latitude, longitude) ||
      latitude < 0.8 || latitude > 7.5 || longitude! < 99 || longitude! > 120.5) return null;
  const suppliedConnectors = Array.isArray(supplied?.connectors) ? supplied.connectors.filter(isObject) : [];
  const connectors = suppliedConnectors.flatMap((connector) => {
    const kind = normalizeConnector(text(connector.kind));
    if (!kind) return [];
    return [{
      kind,
      powerKW: positive(number(connector.powerKW)),
      count: positiveInteger(connector.count),
    }];
  });
  if (!connectors.length) return null;
  return {
    id: `private:${id}`,
    name,
    address: text(supplied?.address)?.slice(0, 240) ?? "Address unavailable",
    coordinate: { latitude, longitude: longitude! },
    operatorName: text(supplied?.operatorName)?.slice(0, 100) ?? "Private charger",
    connectors,
    availability: { state: "unknown", availableConnectors: null, totalConnectors: null, lastUpdated: null },
    price: null,
    source: "ownerProvided",
    sourceAttribution: "Owner supplied · shared by invitation",
    access: "private",
    chargePointCount: positiveInteger(supplied?.chargePointCount),
  };
}

export function classifyOpenChargeMap(raw: JSONObject): {
  station: Station | null; excluded: "license" | "private" | "invalid" | null; providerID: number | null;
} {
  const provider = isObject(raw.DataProvider) ? raw.DataProvider : null;
  const providerID = number(provider?.ID ?? raw.DataProviderID);
  const usage = isObject(raw.UsageType) ? raw.UsageType : null;
  const usageID = number(raw.UsageTypeID ?? usage?.ID);
  const usageTitle = text(usage?.Title)?.toLowerCase() ?? "";
  if ([2, 3, 6].includes(usageID ?? -1) || usageTitle.startsWith("private") || usageTitle.startsWith("privately owned")) {
    return { station: null, excluded: "private", providerID };
  }
  const license = text(provider?.License)?.toLowerCase().replaceAll(/\s+/g, " ");
  const approvedLicense = license ? approvedLicenses.get(license) : null;
  const knownProvider = providerID === 1 || providerID === 41;
  const attribution = provider && approvedLicense && provider.IsOpenDataLicensed !== false &&
    (provider.IsOpenDataLicensed === true || knownProvider) && provider.IsApprovedImport !== false
    ? (providerID === 1 && approvedLicense === "CC BY 4.0") || (providerID === 41 && approvedLicense === "CC0")
      ? providerFallbacks.get(providerID)
      : `${text(provider.Title) ?? `Provider ${providerID ?? "unknown"}`} via Open Charge Map · ${approvedLicense}`
    : !provider && providerID !== null ? providerFallbacks.get(providerID) : null;
  if (!attribution) return { station: null, excluded: "license", providerID };
  const id = positiveInteger(raw.ID);
  const address = isObject(raw.AddressInfo) ? raw.AddressInfo : null;
  const country = isObject(address?.Country) ? address.Country : null;
  const countryCode = text(country?.ISOCode);
  const countryID = number(address?.CountryID);
  const latitude = number(address?.Latitude);
  const longitude = number(address?.Longitude);
  if (!id || !validCoordinate(latitude, longitude) || (countryCode !== null && countryCode !== "MY") ||
      (countryID !== null && countryID !== 137) ||
      latitude < 0.8 || latitude > 7.5 || longitude! < 99 || longitude! > 120.5) {
    return { station: null, excluded: "invalid", providerID };
  }
  const name = text(address?.Title);
  if (!name) return { station: null, excluded: "invalid", providerID };

  const connections = Array.isArray(raw.Connections) ? raw.Connections.filter(isObject) : [];
  const connectors = connections.flatMap((connection) => {
    const type = isObject(connection.ConnectionType) ? connection.ConnectionType : null;
    const kind = ocmConnector(number(connection.ConnectionTypeID ?? type?.ID));
    if (!kind) return [];
    return [{ kind, powerKW: positive(number(connection.PowerKW)), count: positiveInteger(connection.Quantity) }];
  });
  const operator = isObject(raw.OperatorInfo) ? raw.OperatorInfo : null;
  const addressParts = [address?.AddressLine1, address?.Town, address?.StateOrProvince]
    .map(text).filter((part): part is string => part !== null);
  const access = usageID === 4 || usageID === 7 || usageTitle.includes("membership") || usageTitle.includes("notice required")
    ? "limited" : [1, 5].includes(usageID ?? -1) || usageTitle === "public" || usageTitle.includes("pay at location")
    ? "public" : "unknown";
  return { station: {
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
    sourceAttribution: attribution,
    sourceAttributions: [attribution],
    sourceIDs: { openChargeMap: `ocm:${id}` },
    access,
    chargePointCount: positiveInteger(raw.NumberOfPoints),
  }, excluded: null, providerID };
}

export function mergeStations(gentari: Station[], openChargeMap: Station[]): Station[] {
  return mergeWithDuplicateIDs(gentari, openChargeMap).stations;
}

function mergeWithDuplicateIDs(gentari: Station[], openChargeMap: Station[]): { stations: Station[]; duplicateIDs: string[] } {
  // ponytail: exact-name/100 m matching avoids false merges; add a shared site ID if a partner feed supplies one.
  const duplicateIDs: string[] = [];
  const distinctDirectory = openChargeMap.filter((openStation) => {
    const duplicate = gentari.some((partnerStation) =>
    partnerStation.id === openStation.id ||
    (sameName(openStation.name, partnerStation.name) && distanceMeters(openStation.coordinate, partnerStation.coordinate) <= 100)
    );
    if (duplicate) duplicateIDs.push(openStation.id);
    return !duplicate;
  });
  return { stations: [...gentari, ...distinctDirectory], duplicateIDs };
}

export function combineSources(gentari: Station[] | null, openChargeMap: Station[] | null): {
  stations: Station[];
  warnings: string[];
  duplicateCount: number;
  duplicateIDs: string[];
} | null {
  if (gentari === null && openChargeMap === null) return null;
  const warnings: string[] = [];
  if (gentari === null) warnings.push("Gentari live feed unavailable; showing open-data locations only.");
  if (openChargeMap === null) warnings.push("Open Charge Map catalog unavailable; showing Gentari locations only.");
  const { stations, duplicateIDs } = mergeWithDuplicateIDs(gentari ?? [], openChargeMap ?? []);
  return { stations, warnings, duplicateCount: duplicateIDs.length, duplicateIDs };
}

export function combineNationwide(gentari: Station[] | null, openChargeMap: Station[] | null, mevnet: Station[] | null): {
  stations: Station[]; warnings: string[]; duplicateCount: number; duplicateIDs: string[];
} | null {
  if (gentari === null && openChargeMap === null && mevnet === null) return null;
  const warnings: string[] = [];
  if (gentari === null) warnings.push("Gentari live feed unavailable; partner status and pricing may be absent.");
  if (openChargeMap === null) warnings.push("Open Charge Map directory unavailable; connector and access details may be absent.");
  if (mevnet === null) warnings.push("PLANMalaysia MEVnet baseline unavailable; nationwide catalog coverage is partial.");
  const stations: Station[] = [];
  const duplicateIDs: string[] = [];
  const byName = new Map<string, number[]>();
  const bySourceID = new Map<string, number>();
  for (const incoming of [...(gentari ?? []), ...(openChargeMap ?? []), ...(mevnet ?? [])]) {
    const ids = incoming.sourceIDs ?? { [incoming.source]: incoming.id };
    const sharedIndex = Object.entries(ids).map(([source, id]) => bySourceID.get(`${source}:${id}`)).find((index) => index !== undefined);
    const nameMatches = (byName.get(siteName(incoming.name)) ?? []).filter((candidate) => sameSite(stations[candidate], incoming));
    // Ambiguous co-located hubs stay separate unless an exact cross-source ID resolves them.
    const index = sharedIndex ?? (nameMatches.length === 1 ? nameMatches[0] : -1);
    if (index < 0) {
      const nextIndex = stations.length;
      stations.push(incoming);
      byName.set(siteName(incoming.name), [...(byName.get(siteName(incoming.name)) ?? []), nextIndex]);
      Object.entries(ids).forEach(([source, id]) => bySourceID.set(`${source}:${id}`, nextIndex));
      continue;
    }
    const existing = stations[index];
    duplicateIDs.push(incoming.id);
    const sourceIDs = { ...(existing.sourceIDs ?? { [existing.source]: existing.id }), ...(incoming.sourceIDs ?? { [incoming.source]: incoming.id }) };
    const sourceAttributions = [...new Set([...(existing.sourceAttributions ?? [existing.sourceAttribution ?? existing.source]),
      ...(incoming.sourceAttributions ?? [incoming.sourceAttribution ?? incoming.source])])];
    // Source order is Gentari, OCM, MEVnet. Preserve the first stable ID and all trusted enriched facts.
    stations[index] = { ...existing, sourceIDs, sourceAttributions,
      sourceAttribution: sourceAttributions.join(" · "),
      connectors: existing.connectors.length ? existing.connectors : incoming.connectors,
      address: existing.address !== "Address unavailable" ? existing.address : incoming.address,
      state: incoming.source === "mevnet" ? incoming.state : existing.state,
      sourceSequence: incoming.source === "mevnet" ? incoming.sourceSequence : existing.sourceSequence,
      stateCode: incoming.source === "mevnet" ? incoming.stateCode : existing.stateCode,
      pbtCode: incoming.source === "mevnet" ? incoming.pbtCode : existing.pbtCode,
      pbt: incoming.source === "mevnet" ? incoming.pbt : existing.pbt,
      indoorOutdoor: incoming.source === "mevnet" ? incoming.indoorOutdoor : existing.indoorOutdoor,
      lifecycle: incoming.source === "mevnet" ? incoming.lifecycle : existing.lifecycle,
      acCount: incoming.source === "mevnet" ? incoming.acCount : existing.acCount,
      dcCount: incoming.source === "mevnet" ? incoming.dcCount : existing.dcCount,
      proposedChargePointCount: incoming.source === "mevnet" ? incoming.proposedChargePointCount : existing.proposedChargePointCount,
      indoorCount: incoming.source === "mevnet" ? incoming.indoorCount : existing.indoorCount,
      outdoorCount: incoming.source === "mevnet" ? incoming.outdoorCount : existing.outdoorCount,
      category: incoming.source === "mevnet" ? incoming.category : existing.category,
      networkCounts: incoming.source === "mevnet" ? incoming.networkCounts : existing.networkCounts,
      chargePointCount: incoming.source === "mevnet" && incoming.chargePointCount !== null ? incoming.chargePointCount : existing.chargePointCount,
      sourceUpdatedAt: incoming.source === "mevnet" ? incoming.sourceUpdatedAt : existing.sourceUpdatedAt,
      access: existing.access === "unknown" ? incoming.access : existing.access,
    };
    if (!(byName.get(siteName(incoming.name)) ?? []).includes(index)) {
      byName.set(siteName(incoming.name), [...(byName.get(siteName(incoming.name)) ?? []), index]);
    }
    Object.entries(sourceIDs).forEach(([source, id]) => bySourceID.set(`${source}:${id}`, index));
  }
  return { stations, warnings, duplicateCount: duplicateIDs.length, duplicateIDs };
}

function sameSite(lhs: Station, rhs: Station): boolean {
  if (lhs.id === rhs.id) return true;
  if (Object.entries(lhs.sourceIDs ?? {}).some(([source, id]) => rhs.sourceIDs?.[source] === id)) return true;
  if (lhs.lifecycle === "proposed" || rhs.lifecycle === "proposed") return false;
  if (lhs.source === rhs.source) return false;
  if (distanceMeters(lhs.coordinate, rhs.coordinate) > 120) return false;
  // Equal site names are required when no shared source ID exists: nearby mall hubs can be distinct.
  return sameName(lhs.name, rhs.name);
}

export function filterStations(stations: Station[], connectors: Set<string>, minimumPower: number): Station[] {
  return stations.filter((station) => (!connectors.size && minimumPower <= 0) || station.connectors.some((connector) =>
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
  const first = siteName(lhs);
  return first.length > 0 && first === siteName(rhs);
}

function siteName(value: string): string {
  const tokens = value.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  const meaningful = tokens.filter((token) => !["ev", "charging", "charger", "chargers", "station", "site", "evcb"].includes(token));
  return (meaningful.length ? meaningful : tokens).join("");
}

function mevnetDate(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const match = /^(\d{1,2})-([A-Za-z]{3})-(\d{2}|\d{4})$/.exec(value);
  if (!match) return null;
  const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  const month = months.indexOf(match[2].toLowerCase());
  const year = match[3].length === 2 ? 2000 + Number(match[3]) : Number(match[3]);
  if (month < 0 || year < 2000) return null;
  const date = new Date(Date.UTC(year, month, Number(match[1])));
  return date.getUTCMonth() === month && date.getUTCDate() === Number(match[1]) ? date.toISOString() : null;
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
