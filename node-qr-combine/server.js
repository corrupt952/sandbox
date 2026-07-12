const path = require("path");
const http = require("http");
const crypto = require("crypto");
const express = require("express");
const WebSocket = require("ws");

const PORT = process.env.PORT || 3000;
const MAX_PARTICIPANTS = 4;
const ROLE_ORDER = ["TL", "TR", "BL", "BR"];
const ROOM_CODE_LENGTH = 5;
const ROOM_CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const DEFAULT_MODULE_MM = 1.2;
const MIN_MODULE_MM = 0.6;
const MAX_MODULE_MM = 2.5;
const MAX_QR_TEXT_LENGTH = 2048;

/** @type {Map<string, {code: string, hostId: string, qrText: string, moduleMm: number, participants: Map<string, any>}>} */
const rooms = new Map();

function createRoomCode() {
  for (let attempt = 0; attempt < 1000; attempt += 1) {
    let code = "";
    for (let i = 0; i < ROOM_CODE_LENGTH; i += 1) {
      const idx = Math.floor(Math.random() * ROOM_CODE_CHARS.length);
      code += ROOM_CODE_CHARS[idx];
    }

    if (!rooms.has(code)) {
      return code;
    }
  }

  throw new Error("Failed to allocate room code");
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function normalizeRoomCode(input) {
  return String(input || "").trim().toUpperCase();
}

function sendJson(ws, payload) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function sendError(ws, code, message) {
  sendJson(ws, { type: "error", code, message });
}

function nextAvailableRole(room) {
  const used = new Set();
  for (const participant of room.participants.values()) {
    if (participant.role) {
      used.add(participant.role);
    }
  }

  return ROLE_ORDER.find((role) => !used.has(role)) || null;
}

function getRoomPayload(room) {
  const participants = [...room.participants.values()]
    .map((p) => ({
      clientId: p.id,
      role: p.role,
      isHost: p.isHost,
      joinedAt: p.joinedAt,
    }))
    .sort((a, b) => ROLE_ORDER.indexOf(a.role) - ROLE_ORDER.indexOf(b.role));

  return {
    type: "room_state",
    roomCode: room.code,
    hostId: room.hostId,
    qrText: room.qrText,
    moduleMm: room.moduleMm,
    participants,
  };
}

function broadcastRoomState(room) {
  const payload = getRoomPayload(room);
  for (const participant of room.participants.values()) {
    sendJson(participant.ws, payload);
  }
}

function removeSocketFromRoom(ws, { closeRoomOnHostDisconnect = true } = {}) {
  if (!ws.meta || !ws.meta.roomCode || !ws.meta.clientId) {
    return;
  }

  const { roomCode, clientId } = ws.meta;
  ws.meta = { roomCode: null, clientId: null };

  const room = rooms.get(roomCode);
  if (!room) {
    return;
  }

  const participant = room.participants.get(clientId);
  if (!participant) {
    return;
  }

  room.participants.delete(clientId);

  if (participant.isHost && closeRoomOnHostDisconnect) {
    for (const p of room.participants.values()) {
      sendJson(p.ws, {
        type: "room_closed",
        message: "Host disconnected. Room closed.",
      });
      p.ws.meta = { roomCode: null, clientId: null };
    }
    rooms.delete(roomCode);
    return;
  }

  if (room.participants.size === 0) {
    rooms.delete(roomCode);
    return;
  }

  broadcastRoomState(room);
}

function attachParticipantToRoom(ws, room, isHost) {
  const role = nextAvailableRole(room);
  if (!role) {
    return null;
  }

  const participant = {
    id: crypto.randomUUID(),
    ws,
    isHost,
    role,
    joinedAt: Date.now(),
  };

  room.participants.set(participant.id, participant);
  ws.meta = { roomCode: room.code, clientId: participant.id };
  return participant;
}

const app = express();
app.use(express.static(path.join(__dirname, "public")));
app.get("/health", (_req, res) => {
  res.json({ ok: true, rooms: rooms.size });
});

const server = http.createServer(app);
const wss = new WebSocket.Server({ server, path: "/ws" });

wss.on("connection", (ws) => {
  ws.meta = { roomCode: null, clientId: null };

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch (error) {
      sendError(ws, "bad_json", "Invalid JSON payload");
      return;
    }

    if (!msg || typeof msg.type !== "string") {
      sendError(ws, "bad_message", "Missing message type");
      return;
    }

    if (msg.type === "create_room") {
      if (ws.meta.roomCode) {
        sendError(ws, "already_in_room", "This socket already joined a room");
        return;
      }

      let roomCode;
      try {
        roomCode = createRoomCode();
      } catch (error) {
        sendError(ws, "room_create_failed", "Could not create room");
        return;
      }

      const room = {
        code: roomCode,
        hostId: "",
        qrText: "",
        moduleMm: DEFAULT_MODULE_MM,
        participants: new Map(),
      };

      const host = attachParticipantToRoom(ws, room, true);
      if (!host) {
        sendError(ws, "room_create_failed", "Could not assign host role");
        return;
      }

      room.hostId = host.id;
      rooms.set(roomCode, room);

      sendJson(ws, {
        type: "room_created",
        roomCode,
        clientId: host.id,
        role: host.role,
        qrText: room.qrText,
        moduleMm: room.moduleMm,
      });

      broadcastRoomState(room);
      return;
    }

    if (msg.type === "join_room") {
      if (ws.meta.roomCode) {
        sendError(ws, "already_in_room", "This socket already joined a room");
        return;
      }

      const roomCode = normalizeRoomCode(msg.roomCode);
      const room = rooms.get(roomCode);
      if (!room) {
        sendError(ws, "room_not_found", "Room does not exist");
        return;
      }

      if (room.participants.size >= MAX_PARTICIPANTS) {
        sendError(ws, "room_full", "Room already has 4 devices");
        return;
      }

      const participant = attachParticipantToRoom(ws, room, false);
      if (!participant) {
        sendError(ws, "room_full", "No role available");
        return;
      }

      sendJson(ws, {
        type: "room_joined",
        roomCode,
        clientId: participant.id,
        role: participant.role,
        qrText: room.qrText,
        moduleMm: room.moduleMm,
      });

      broadcastRoomState(room);
      return;
    }

    if (msg.type === "update_qr") {
      if (!ws.meta.roomCode || !ws.meta.clientId) {
        sendError(ws, "not_in_room", "Join a room first");
        return;
      }

      const room = rooms.get(ws.meta.roomCode);
      if (!room) {
        sendError(ws, "room_not_found", "Room does not exist");
        return;
      }

      if (ws.meta.clientId !== room.hostId) {
        sendError(ws, "forbidden", "Only host can update QR content");
        return;
      }

      const text = String(msg.text ?? "").slice(0, MAX_QR_TEXT_LENGTH);
      room.qrText = text;
      broadcastRoomState(room);
      return;
    }

    if (msg.type === "update_settings") {
      if (!ws.meta.roomCode || !ws.meta.clientId) {
        sendError(ws, "not_in_room", "Join a room first");
        return;
      }

      const room = rooms.get(ws.meta.roomCode);
      if (!room) {
        sendError(ws, "room_not_found", "Room does not exist");
        return;
      }

      if (ws.meta.clientId !== room.hostId) {
        sendError(ws, "forbidden", "Only host can update settings");
        return;
      }

      const nextModuleMm = Number(msg.moduleMm);
      if (!Number.isFinite(nextModuleMm)) {
        sendError(ws, "bad_settings", "moduleMm must be a number");
        return;
      }

      room.moduleMm = clamp(nextModuleMm, MIN_MODULE_MM, MAX_MODULE_MM);
      broadcastRoomState(room);
      return;
    }

    sendError(ws, "unknown_type", `Unknown message type: ${msg.type}`);
  });

  ws.on("close", () => {
    removeSocketFromRoom(ws, { closeRoomOnHostDisconnect: true });
  });

  ws.on("error", () => {
    removeSocketFromRoom(ws, { closeRoomOnHostDisconnect: true });
  });
});

server.listen(PORT, () => {
  console.log(`QR Combine server running at http://localhost:${PORT}`);
});
