# node-qr-combine

Prototype for combining QR codes split across up to 4 devices into one room.
A host creates a room and sets the QR payload; up to 3 more devices join with
a room code and each gets assigned a quadrant (`TL`/`TR`/`BL`/`BR`). Room
state (participants, QR text, module size) is broadcast to everyone over a
WebSocket as it changes.

## Stack

- Node.js + Express (static file serving, `/health`)
- `ws` for the WebSocket room protocol (`/ws`)

## How to run

```sh
npm install
npm start
# open http://localhost:3000
```

## Notes

- In-memory only; state resets on restart. `MAX_PARTICIPANTS` is 4, one per
  quadrant role.
