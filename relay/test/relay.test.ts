import {
  env,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { parseRelayRoute, parseRelayToken } from "../src/protocol";

const token = "A".repeat(43);
const pairedMarker = "riz-relay:client-paired:v1";
const daemonHeartbeat = "riz-relay:daemon-heartbeat:v1";
const daemonHeartbeatAck = "riz-relay:daemon-heartbeat-ack:v1";

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

  it("acknowledges idle daemon heartbeats without consuming a client slot", async () => {
    const roomName = crypto.randomUUID();
    const daemon = await connect(roomName, "daemon");
    const acknowledged = nextMessage(daemon);
    daemon.send(daemonHeartbeat);
    expect((await acknowledged).data).toBe(daemonHeartbeatAck);

    const paired = nextMessage(daemon);
    const client = await connect(roomName, "client");
    expect((await paired).data).toBe(pairedMarker);
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

  it("reclaims clients that never send their authentication frame", async () => {
    const roomName = crypto.randomUUID();
    const room = env.RELAY_ROOMS.getByName(roomName);
    const daemon = await connect(roomName, "daemon");
    const paired = nextMessage(daemon);
    const client = await connect(roomName, "client");
    expect((await paired).data).toBe(pairedMarker);

    await runInDurableObject(room, (_instance, state) => {
      const socket = state.getWebSockets("client")[0];
      const attachment = socket.deserializeAttachment() as Record<
        string,
        unknown
      >;
      socket.serializeAttachment({ ...attachment, connectedAt: 0 });
    });

    const clientClosed = new Promise<CloseEvent>((resolve) =>
      client.addEventListener("close", resolve, { once: true }),
    );
    const daemonClosed = new Promise<CloseEvent>((resolve) =>
      daemon.addEventListener("close", resolve, { once: true }),
    );
    expect(await runDurableObjectAlarm(room)).toBe(true);
    expect((await clientClosed).code).toBe(1008);
    expect((await daemonClosed).code).toBe(1012);
  });

  it("reclaims authenticated clients that stop sending heartbeats", async () => {
    const roomName = crypto.randomUUID();
    const room = env.RELAY_ROOMS.getByName(roomName);
    const daemon = await connect(roomName, "daemon");
    const paired = nextMessage(daemon);
    const client = await connect(roomName, "client");
    expect((await paired).data).toBe(pairedMarker);

    const forwarded = nextMessage(daemon);
    client.send("auth frame");
    expect((await forwarded).data).toBe("auth frame");
    await runInDurableObject(room, (_instance, state) => {
      const socket = state.getWebSockets("client")[0];
      const attachment = socket.deserializeAttachment() as Record<
        string,
        unknown
      >;
      socket.serializeAttachment({ ...attachment, lastSeenAt: 0 });
    });

    const clientClosed = new Promise<CloseEvent>((resolve) =>
      client.addEventListener("close", resolve, { once: true }),
    );
    const daemonClosed = new Promise<CloseEvent>((resolve) =>
      daemon.addEventListener("close", resolve, { once: true }),
    );
    expect(await runDurableObjectAlarm(room)).toBe(true);
    expect((await clientClosed).code).toBe(1001);
    expect((await daemonClosed).code).toBe(1012);
  });

  it("keeps authenticated clients with recent heartbeat activity", async () => {
    const roomName = crypto.randomUUID();
    const room = env.RELAY_ROOMS.getByName(roomName);
    const daemon = await connect(roomName, "daemon");
    const paired = nextMessage(daemon);
    const client = await connect(roomName, "client");
    expect((await paired).data).toBe(pairedMarker);

    const forwarded = nextMessage(daemon);
    client.send("heartbeat");
    expect((await forwarded).data).toBe("heartbeat");
    expect(await runDurableObjectAlarm(room)).toBe(true);
    await runInDurableObject(room, (_instance, state) => {
      expect(state.getWebSockets("client")).toHaveLength(1);
      expect(state.getWebSockets("daemon")).toHaveLength(1);
    });

    daemon.close(1000, "done");
    client.close(1000, "done");
  });

  it("reclaims daemon sockets whose client peer no longer exists", async () => {
    const roomName = crypto.randomUUID();
    const room = env.RELAY_ROOMS.getByName(roomName);
    const daemon = await connect(roomName, "daemon");
    await runInDurableObject(room, (_instance, state) => {
      const socket = state.getWebSockets("daemon")[0];
      const attachment = socket.deserializeAttachment() as Record<
        string,
        unknown
      >;
      socket.serializeAttachment({ ...attachment, peerId: "missing-client" });
    });

    const daemonClosed = new Promise<CloseEvent>((resolve) =>
      daemon.addEventListener("close", resolve, { once: true }),
    );
    const unavailable = await room.fetch(upgrade("client"));
    expect(unavailable.status).toBe(503);
    expect((await daemonClosed).code).toBe(1012);

    const replacement = await connect(roomName, "daemon");
    const paired = nextMessage(replacement);
    const client = await connect(roomName, "client");
    expect((await paired).data).toBe(pairedMarker);
    replacement.close(1000, "done");
    client.close(1000, "done");
  });
});
