import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { parseRelayRoute, parseRelayToken } from "../src/protocol";

const token = "A".repeat(43);
const pairedMarker = "riz-relay:client-paired:v1";

function upgrade(role: "daemon" | "client", candidate = token): Request {
  return new Request("https://relay.test/", {
    headers: {
      upgrade: "websocket",
      "x-riz-relay-role": role,
      "x-riz-relay-token": candidate,
    },
  });
}

async function connect(
  roomName: string,
  role: "daemon" | "client",
  candidate = token,
): Promise<WebSocket> {
  const response = await env.RELAY_ROOMS.getByName(roomName).fetch(
    upgrade(role, candidate),
  );
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  expect(socket).not.toBeNull();
  socket!.accept();
  return socket!;
}

function nextMessage(socket: WebSocket): Promise<MessageEvent> {
  return new Promise((resolve) =>
    socket.addEventListener("message", resolve, { once: true }),
  );
}

async function messageBytes(value: unknown): Promise<Uint8Array> {
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (value instanceof Blob) return new Uint8Array(await value.arrayBuffer());
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new TypeError(`unexpected binary message: ${typeof value}`);
}

describe("relay request validation", () => {
  it("parses only versioned relay routes", () => {
    const deviceId = "device_abcdefghijklmnop";
    expect(parseRelayRoute(`/v1/relay/${deviceId}/client`)).toEqual({
      deviceId,
      role: "client",
    });
    expect(parseRelayRoute("/v1/relay/short/client")).toBeNull();
    expect(parseRelayRoute(`/v2/relay/${deviceId}/client`)).toBeNull();
  });

  it("extracts relay credentials from WebSocket subprotocols", () => {
    expect(parseRelayToken(`riz-relay-v1.${token}`)).toBe(token);
    expect(parseRelayToken(`riz-relay-v1.${token}, extra`)).toBeNull();
    expect(parseRelayToken("riz-relay-v1.short")).toBeNull();
  });
});

describe("RelayRoom", () => {
  it("requires daemon registration before clients", async () => {
    const room = env.RELAY_ROOMS.getByName(crypto.randomUUID());
    const response = await room.fetch(upgrade("client"));
    expect(response.status).toBe(503);
  });

  it("rejects a different relay token", async () => {
    const roomName = crypto.randomUUID();
    await connect(roomName, "daemon");
    const response = await env.RELAY_ROOMS.getByName(roomName).fetch(
      upgrade("client", "B".repeat(43)),
    );
    expect(response.status).toBe(401);
  });

  it("forwards text and binary frames in both directions", async () => {
    const roomName = crypto.randomUUID();
    const daemon = await connect(roomName, "daemon");
    const paired = nextMessage(daemon);
    const client = await connect(roomName, "client");
    expect((await paired).data).toBe(pairedMarker);

    const daemonMessage = nextMessage(daemon);
    client.send("hello");
    expect((await daemonMessage).data).toBe("hello");

    const clientMessage = nextMessage(client);
    daemon.send(new Uint8Array([1, 2, 3]));
    const binary = await messageBytes((await clientMessage).data);
    expect([...binary]).toEqual([1, 2, 3]);

    daemon.close(1000, "done");
    client.close(1000, "done");
  });

  it("keeps simultaneous client channels isolated", async () => {
    const roomName = crypto.randomUUID();
    const daemonA = await connect(roomName, "daemon");
    const daemonB = await connect(roomName, "daemon");
    const pairedA = nextMessage(daemonA);
    const clientA = await connect(roomName, "client");
    expect((await pairedA).data).toBe(pairedMarker);
    const pairedB = nextMessage(daemonB);
    const clientB = await connect(roomName, "client");
    expect((await pairedB).data).toBe(pairedMarker);

    const messageA = nextMessage(daemonA);
    const messageB = nextMessage(daemonB);
    clientA.send("from-a");
    clientB.send("from-b");
    expect((await messageA).data).toBe("from-a");
    expect((await messageB).data).toBe("from-b");

    daemonA.close(1000, "done");
    daemonB.close(1000, "done");
    clientA.close(1000, "done");
    clientB.close(1000, "done");
  });
});
