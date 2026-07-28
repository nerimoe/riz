export const RELAY_PROTOCOL_PREFIX = "riz-relay-v1.";

const DEVICE_ID_PATTERN = /^[A-Za-z0-9_-]{22,128}$/;

export type RelayRole = "daemon" | "client";

export interface RelayRoute {
  deviceId: string;
  role: RelayRole;
}

export function parseRelayRoute(pathname: string): RelayRoute | null {
  const match = /^\/v1\/relay\/([^/]+)\/(daemon|client)$/.exec(pathname);
  if (!match || !DEVICE_ID_PATTERN.test(match[1])) return null;
  return { deviceId: match[1], role: match[2] as RelayRole };
}

export function parseRelayToken(header: string | null): string | null {
  if (header === null) return null;
  const protocols = header.split(",").map((value) => value.trim());
  if (protocols.length !== 1) return null;
  const token = protocols[0].startsWith(RELAY_PROTOCOL_PREFIX)
    ? protocols[0].slice(RELAY_PROTOCOL_PREFIX.length)
    : undefined;
  return token !== undefined && /^[A-Za-z0-9_-]{32,256}$/.test(token)
    ? token
    : null;
}
