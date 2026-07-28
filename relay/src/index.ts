import { DurableObject } from "cloudflare:workers";
import {
  parseRelayRoute,
  parseRelayToken,
  RELAY_PROTOCOL_PREFIX,
  type RelayRole,
} from "./protocol";

const MAX_FRAME_BYTES = 26 * 1024 * 1024;
const CLIENT_PAIRED_MARKER = "riz-relay:client-paired:v1";

interface SocketAttachment {
  role: RelayRole;
  id: string;
  peerId: string | null;
}

function text(message: string, status: number): Response {
  return new Response(message, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/") {
      return Response.json({ service: "riz-relay", status: "ok" });
    }

    const route = parseRelayRoute(url.pathname);
    if (route === null) return text("not found", 404);
    if (request.method !== "GET") return text("method not allowed", 405);
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return text("websocket upgrade required", 426);
    }

    const relayToken = parseRelayToken(
      request.headers.get("sec-websocket-protocol"),
    );
    if (relayToken === null) return text("invalid relay protocol", 401);

    const headers = new Headers(request.headers);
    headers.set("x-riz-relay-role", route.role);
    headers.set("x-riz-relay-token", relayToken);
    const room = env.RELAY_ROOMS.getByName(route.deviceId);
    return room.fetch(new Request(request, { headers }));
  },
} satisfies ExportedHandler<Env>;

export class RelayRoom extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return text("websocket upgrade required", 426);
    }

    const role = request.headers.get("x-riz-relay-role");
    const relayToken = request.headers.get("x-riz-relay-token");
    if ((role !== "daemon" && role !== "client") || relayToken === null) {
      return text("invalid relay credentials", 401);
    }

    const candidateHash = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(relayToken),
    );
    const storedHash = await this.ctx.storage.get<ArrayBuffer>(
      "relayTokenHash",
    );
    if (storedHash === undefined) {
      if (role !== "daemon") return text("daemon has not registered", 503);
      await this.ctx.storage.put("relayTokenHash", candidateHash);
    } else if (!crypto.subtle.timingSafeEqual(storedHash, candidateHash)) {
      return text("invalid relay credentials", 401);
    }

    let peer: WebSocket | undefined;
    if (role === "client") {
      peer = this.ctx
        .getWebSockets("daemon")
        .find((socket) => this.attachment(socket).peerId === null);
      if (peer === undefined) return text("daemon is offline or busy", 503);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const id = crypto.randomUUID();
    server.serializeAttachment({
      role,
      id,
      peerId: peer === undefined ? null : this.attachment(peer).id,
    } satisfies SocketAttachment);
    if (peer !== undefined) {
      const peerAttachment = this.attachment(peer);
      peer.serializeAttachment({
        ...peerAttachment,
        peerId: id,
      } satisfies SocketAttachment);
      peer.send(CLIENT_PAIRED_MARKER);
    }
    this.ctx.acceptWebSocket(server, [role]);
    return new Response(null, {
      status: 101,
      webSocket: client,
      headers: {
        "sec-websocket-protocol": `${RELAY_PROTOCOL_PREFIX}${relayToken}`,
      },
    });
  }

  webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): void {
    const size =
      typeof message === "string"
        ? new TextEncoder().encode(message).byteLength
        : message.byteLength;
    if (size > MAX_FRAME_BYTES) {
      socket.close(1009, "frame too large");
      return;
    }

    const attachment = this.attachment(socket);
    const target = this.findSocket(attachment.peerId);
    if (target === undefined) {
      socket.close(1012, "relay peer disconnected");
      return;
    }
    try {
      target.send(message);
    } catch {
      target.close(1011, "relay send failed");
      socket.close(1011, "relay send failed");
    }
  }

  webSocketClose(
    socket: WebSocket,
    code: number,
    reason: string,
    _wasClean: boolean,
  ): void {
    const attachment = this.attachment(socket);
    const peer = this.findSocket(attachment.peerId);
    if (peer !== undefined) {
      peer.close(1012, `${attachment.role} disconnected`);
    }
    void code;
    void reason;
  }

  webSocketError(socket: WebSocket): void {
    const attachment = this.attachment(socket);
    const peer = this.findSocket(attachment.peerId);
    if (peer !== undefined) {
      peer.close(1012, `${attachment.role} connection failed`);
    }
    socket.close(1011, "relay socket error");
  }

  private attachment(socket: WebSocket): SocketAttachment {
    return socket.deserializeAttachment() as SocketAttachment;
  }

  private findSocket(id: string | null): WebSocket | undefined {
    if (id === null) return undefined;
    return this.ctx
      .getWebSockets()
      .find((socket) => this.attachment(socket).id === id);
  }
}
