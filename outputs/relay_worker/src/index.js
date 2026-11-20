import { DurableObject } from "cloudflare:workers";

const TTL = 60_000;
const CODE = /^[A-Z2-9]{12}$/;
const token = () => crypto.randomUUID() + crypto.randomUUID();
const reply = (value, status = 200) => Response.json(value, { status, headers: { "Cache-Control": "no-store" } });

function validThrow(args) {
  if (!args || typeof args !== "object" || Array.isArray(args)) return false;
  for (const key of ["x", "y", "offsetX", "offsetY", "offsetZ", "direction", "mult", "target_height"])
    if (!Number.isInteger(args[key]) || Math.abs(args[key]) > 100000) return false;
  return [-1, 0, 1].includes(args.direction) && [2, 3].includes(args.mult)
    && Number.isFinite(args.target_x) && Math.abs(args.target_x) <= 100000
    && Number.isFinite(args.target_y) && Math.abs(args.target_y) <= 100000;
}

async function readSmallJson(request) {
  const reader = request.body?.getReader();
  if (!reader) throw new Error("empty_body");
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > 16_384) {
      await reader.cancel();
      throw new Error("body_too_large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

export class Room extends DurableObject {
  _send(ws, value) {
    try { ws.send(JSON.stringify(value)); } catch { /* connection already closed */ }
  }

  _broadcast(value, except = null) {
    for (const ws of this.ctx.getWebSockets()) if (ws !== except) this._send(ws, value);
  }

  _closeRole(role, reason) {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.deserializeAttachment()?.role === role) ws.close(1000, reason);
    }
  }

  async create(lock) {
    const old = await this.ctx.storage.get("room");
    if (old && old.expires > Date.now()) return { error: "room_exists" };
    for (const ws of this.ctx.getWebSockets()) ws.close(1000, "room_recreated");
    const hostToken = token();
    await this.ctx.storage.put("room", { lock, hostToken, guestToken: null, expires: Date.now() + TTL });
    await this.ctx.storage.setAlarm(Date.now() + TTL + 1_000);
    return { host_token: hostToken };
  }

  async join(lock) {
    const room = await this.ctx.storage.get("room");
    if (!room || room.expires <= Date.now()) return { error: "room_expired" };
    if (room.guestToken) return { error: "room_full" };
    if (JSON.stringify(room.lock) !== JSON.stringify(lock)) return { error: "config_mismatch" };
    room.guestToken = token();
    room.expires = Date.now() + TTL;
    await this.ctx.storage.put("room", room);
    await this.ctx.storage.setAlarm(room.expires + 1_000);
    return { guest_token: room.guestToken };
  }

  async status(authToken) {
    const room = await this.ctx.storage.get("room");
    if (!room || room.expires <= Date.now()) return { error: "room_expired" };
    const isHost = authToken === room.hostToken;
    if (!isHost && authToken !== room.guestToken) return { error: "unauthorized" };
    room.expires = Date.now() + TTL;
    await this.ctx.storage.put("room", room);
    await this.ctx.storage.setAlarm(room.expires + 1_000);
    return { connected: Boolean(room.guestToken), role: isHost ? "host" : "guest" };
  }

  async leave(authToken) {
    const room = await this.ctx.storage.get("room");
    if (!room) return { ok: true };
    if (authToken === room.hostToken) {
      await this.ctx.storage.delete("room");
      for (const ws of this.ctx.getWebSockets()) ws.close(1000, "room_closed");
    }
    else if (authToken === room.guestToken) {
      room.guestToken = null;
      await this.ctx.storage.put("room", room);
      this._closeRole("guest", "guest_left");
      this._broadcast({ type: "peer_left", role: "guest" });
    } else return { error: "unauthorized" };
    return { ok: true };
  }

  async alarm() {
    const room = await this.ctx.storage.get("room");
    if (room && room.expires <= Date.now()) {
      await this.ctx.storage.delete("room");
      for (const ws of this.ctx.getWebSockets()) ws.close(1000, "room_expired");
    }
    else if (room) await this.ctx.storage.setAlarm(room.expires + 1_000);
  }

  async fetch(request) {
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return reply({ error: "upgrade_required" }, 426);
    }
    const url = new URL(request.url);
    const authToken = url.searchParams.get("token");
    const room = await this.ctx.storage.get("room");
    if (!room || room.expires <= Date.now()) return reply({ error: "room_expired" }, 404);
    const role = authToken === room.hostToken ? "host" : authToken === room.guestToken ? "guest" : null;
    if (!role || !authToken) return reply({ error: "unauthorized" }, 403);
    this._closeRole(role, "reconnected");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ role, lastAt: 0 });
    this._send(server, { type: "ready", role });
    this._broadcast({ type: "peer_joined", role }, server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (typeof message !== "string" || message.length > 4096) { ws.close(1008, "invalid_message"); return; }
    let value;
    try { value = JSON.parse(message); } catch { ws.close(1008, "invalid_json"); return; }
    const attachment = ws.deserializeAttachment();
    if (!attachment?.role) { ws.close(1008, "no_session"); return; }
    if (value?.type === "chat") {
      // In-match chat: either role may speak, the room forwards to the other side.
      const text = typeof value.text === "string" ? value.text.trim() : "";
      if (!text || text.length > 120 || /[\u0000-\u0008\u000b-\u001f]/.test(text)) {
        ws.close(1008, "invalid_chat");
        return;
      }
      this._broadcast({ type: "chat", role: attachment.role, text }, ws);
      return;
    }
    if (value?.type === "round") {
      if (attachment.role !== "host" || !Number.isInteger(value.id) || value.id < 1
          || !["start", "end"].includes(value.phase)
          || (value.phase === "end" && !["host", "guest"].includes(value.winner))) {
        ws.close(1008, "invalid_round"); return;
      }
      this._broadcast({ type: "round", id: value.id, phase: value.phase,
        winner: value.phase === "end" ? value.winner : null }, ws);
      return;
    }
    if (value?.type === "hit_request") {
      if (attachment.role !== "guest" || !Number.isInteger(value.id) || value.id < 1
          || !Number.isInteger(value.skill) || value.skill < 1 || value.skill > 1000000
          || !Number.isInteger(value.stage) || value.stage < 0 || value.stage > 20
          || !Number.isInteger(value.action) || value.action < 0 || value.action > 1000000000
          || !Number.isFinite(value.x) || !Number.isFinite(value.y)
          || Math.abs(value.x) > 100000 || Math.abs(value.y) > 100000
          || !Number.isFinite(value.height) || value.height < 0 || value.height > 1000
          || typeof value.facing_left !== "boolean"
          || (value.id >= 1000000 && value.stage === 2 && !validThrow(value.throw_args))) {
        ws.close(1008, "invalid_hit_request"); return;
      }
      for (const peer of this.ctx.getWebSockets()) {
        if (peer.deserializeAttachment()?.role === "host") {
          this._send(peer, { type: "hit_request", id: value.id,
            skill: value.skill, stage: value.stage, action: value.action,
            x: value.x, y: value.y, height: value.height,
            facing_left: value.facing_left,
            throw_args: value.id >= 1000000 && value.stage === 2 ? value.throw_args : {} });
        }
      }
      return;
    }
    if (value?.type === "combat") {
      if (attachment.role !== "host" || !Number.isInteger(value.id) || value.id < 1
          || !["host", "guest"].includes(value.target)
          || !(["none", "hurt", "float", "down"].includes(value.reaction)
               || (value.reaction && typeof value.reaction === "object"
                   && !Array.isArray(value.reaction)
                   && JSON.stringify(value.reaction).length <= 1024))
          || !Number.isInteger(value.hp_host) || value.hp_host < 0 || value.hp_host > 500000
          || !Number.isInteger(value.hp_guest) || value.hp_guest < 0 || value.hp_guest > 500000
          || !Number.isFinite(value.attacker_x) || Math.abs(value.attacker_x) > 100000
          || !Number.isFinite(value.attacker_y) || Math.abs(value.attacker_y) > 100000
          || !Number.isInteger(value.attacker_height) || value.attacker_height < 0 || value.attacker_height > 1000
          || ![-1, 1].includes(value.impulse)
          || typeof value.knockdown !== "boolean"
          || !Number.isInteger(value.power) || Math.abs(value.power) > 100000
          || !Number.isInteger(value.power_x) || Math.abs(value.power_x) > 100000
          || !Number.isInteger(value.freeze) || value.freeze < 0 || value.freeze > 10000
          || !Number.isInteger(value.damage) || value.damage < 0 || value.damage > 10000000) {
        ws.close(1008, "invalid_combat"); return;
      }
      this._broadcast({ type: "combat", id: value.id, target: value.target,
        reaction: value.reaction, hp_host: value.hp_host, hp_guest: value.hp_guest,
        attacker_x: value.attacker_x, attacker_y: value.attacker_y,
        attacker_height: value.attacker_height,
        impulse: value.impulse, knockdown: value.knockdown, power: value.power,
        power_x: value.power_x, freeze: value.freeze, damage: value.damage }, ws);
      return;
    }
    if (!value || value.type !== "state" || !Number.isInteger(value.seq) || value.seq < 0
        || !Number.isInteger(value.map) || value.map < 0 || value.map > 10000
        || !Number.isFinite(value.x) || !Number.isFinite(value.y)
        || Math.abs(value.x) > 100000 || Math.abs(value.y) > 100000
        || (value.height !== undefined && (!Number.isFinite(value.height) || value.height < 0 || value.height > 1000))
        || (value.ready !== undefined && typeof value.ready !== "boolean")
        || (value.defeat_ready !== undefined && typeof value.defeat_ready !== "boolean")
        || (value.hp_self !== undefined && (!Number.isInteger(value.hp_self) || value.hp_self < 0 || value.hp_self > 500000))
        || (value.hp_peer !== undefined && (!Number.isInteger(value.hp_peer) || value.hp_peer < 0 || value.hp_peer > 500000))
        || (value.mp_self !== undefined && (!Number.isInteger(value.mp_self) || value.mp_self < 0 || value.mp_self > 10000000))
        || typeof value.facing_left !== "boolean" || !Number.isInteger(value.motion)
        || value.motion < 0 || value.motion > 10000
        || (value.skill !== undefined && (!Number.isInteger(value.skill) || value.skill < 0 || value.skill > 1000000))
        || (value.action !== undefined && (!Number.isInteger(value.action) || value.action < 0 || value.action > 1000000000))
        || (value.action_frame !== undefined && (!Number.isInteger(value.action_frame) || value.action_frame < 0 || value.action_frame > 1000))
        || (value.reaction_frame !== undefined && (!Number.isInteger(value.reaction_frame) || value.reaction_frame < 0 || value.reaction_frame > 1000))
        || (value.reaction_state !== undefined && !["", "stiff", "hurt", "float", "lie", "get_up"].includes(value.reaction_state))
        || (value.grab_binding !== undefined && (!value.grab_binding || typeof value.grab_binding !== "object"
          || Array.isArray(value.grab_binding) || Object.keys(value.grab_binding).some(k => !["x", "y", "z"].includes(k))
          || Object.values(value.grab_binding).some(n => !Number.isFinite(n) || Math.abs(n) > 1000)))
        || (value.caught_pose !== undefined && (!value.caught_pose || typeof value.caught_pose !== "object"
          || Array.isArray(value.caught_pose) || (Object.keys(value.caught_pose).length !== 0
            && (!Number.isInteger(value.caught_pose.motion) || value.caught_pose.motion < 0 || value.caught_pose.motion > 10000
              || !Number.isInteger(value.caught_pose.frame) || value.caught_pose.frame < -1 || value.caught_pose.frame > 1000
              || typeof value.caught_pose.invert !== "boolean"
              || typeof value.caught_pose.facing_left !== "boolean"
              || !Number.isFinite(value.caught_pose.x) || Math.abs(value.caught_pose.x) > 100000
              || !Number.isFinite(value.caught_pose.y) || Math.abs(value.caught_pose.y) > 100000
              || !Number.isFinite(value.caught_pose.height) || value.caught_pose.height < 0 || value.caught_pose.height > 1000))))
        || (value.statuses !== undefined && (!Array.isArray(value.statuses) || value.statuses.length > 32
            || value.statuses.some(id => typeof id !== "string" || !/^\d{1,12}$/.test(id))))
        || (value.stage !== undefined && (!Number.isInteger(value.stage) || value.stage < 0 || value.stage > 10))) {
      ws.close(1008, "invalid_state"); return;
    }
    const now = Date.now();
    if (now - attachment.lastAt < 45) return; // Keep a room below 20 updates/s/player.
    ws.serializeAttachment({ role: attachment.role, lastAt: now });
    const avatar = value.avatar;
    const safeAvatar = avatar && typeof avatar === "object" && !Array.isArray(avatar)
      ? { name: String(avatar.name ?? "").slice(0, 30), level: Number.isInteger(avatar.level) ? avatar.level : 1,
          career: Number.isInteger(avatar.career) ? avatar.career : 0,
          career_wear_level: Number.isInteger(avatar.career_wear_level) ? avatar.career_wear_level : 1,
          has_join: avatar.has_join === true, sublime: avatar.sublime === true,
          equipment: Array.isArray(avatar.equipment) ? avatar.equipment.slice(0, 16).map(n => Number.isInteger(n) ? n : 0) : [],
          appearance: avatar.appearance && typeof avatar.appearance === "object" && !Array.isArray(avatar.appearance) ? avatar.appearance : {},
          combat_attrs: Object.fromEntries(["2001", "2002", "2003", "2004", "2007", "2008", "2009", "2010", "2011", "2012", "2013", "2015", "2016", "2017", "2018", "2019", "2020"]
            .map(k => [k, Number.isInteger(avatar.combat_attrs?.[k]) && avatar.combat_attrs[k] >= 0 && avatar.combat_attrs[k] <= 10000000 ? avatar.combat_attrs[k] : 0])) }
      : null;
    for (const peer of this.ctx.getWebSockets()) {
      if (peer === ws || peer.deserializeAttachment()?.role === attachment.role) continue;
      this._send(peer, { type: "state", role: attachment.role, seq: value.seq, map: value.map,
                         x: value.x, y: value.y, height: value.height ?? 0, ready: value.ready === true,
                         defeat_ready: value.defeat_ready === true,
                         hp_self: value.hp_self ?? 500000, hp_peer: value.hp_peer ?? 500000,
                         mp_self: value.mp_self ?? 0,
                         facing_left: value.facing_left,
                         motion: value.motion, skill: value.skill ?? 0, stage: value.stage ?? 0,
                         action: value.action ?? 0, action_frame: value.action_frame ?? 0,
                         reaction_state: value.reaction_state ?? "", reaction_frame: value.reaction_frame ?? 0,
                         statuses: value.statuses ?? [], caught_pose: value.caught_pose ?? {},
                         grab_binding: value.grab_binding ?? {}, avatar: safeAvatar });
    }
  }

  async webSocketClose(ws) {
    const role = ws.deserializeAttachment()?.role;
    if (role) this._broadcast({ type: "peer_left", role }, ws);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/game") {
      const code = url.searchParams.get("code");
      if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return reply({ error: "upgrade_required" }, 426);
      }
      if (!code || !CODE.test(code)) return reply({ error: "invalid_code" }, 400);
      return env.ROOMS.getByName(code).fetch(request);
    }
    if (request.method !== "POST") return reply({ error: "method_not_allowed" }, 405);
    let body;
    try { body = await readSmallJson(request); }
    catch { return reply({ error: "invalid_json" }, 400); }
    if (!body || typeof body !== "object" || Array.isArray(body)) return reply({ error: "invalid_body" }, 400);
    const path = url.pathname;
    if (!["/create", "/join", "/status", "/leave"].includes(path)) return reply({ error: "not_found" }, 404);
    let code = body.code;
    if (path === "/create") {
      code = Array.from(crypto.getRandomValues(new Uint8Array(12)), n => "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[n % 32]).join("");
      if (!body.lock || typeof body.lock !== "object") return reply({ error: "missing_lock" }, 400);
    }
    if (typeof code !== "string" || !CODE.test(code)) return reply({ error: "invalid_code" }, 400);
    const stub = env.ROOMS.getByName(code);
    let result;
    if (path === "/create") result = await stub.create(body.lock);
    else if (path === "/join") result = await stub.join(body.lock);
    else if (path === "/status") result = await stub.status(body.token);
    else result = await stub.leave(body.token);
    return reply({ code, ...result }, result.error ? 400 : 200);
  },
};
