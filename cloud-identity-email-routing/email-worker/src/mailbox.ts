import { DurableObject } from "cloudflare:workers";

// The index signature is what sql.exec<T> requires of a row type.
export interface StoredMessage extends Record<string, SqlStorageValue> {
  id: string;
  received_at: string;
  envelope_from: string;
  envelope_to: string;
  header_from: string | null;
  header_to: string | null;
  subject: string | null;
  message_id: string | null;
  authserv_id: string | null;
  spf: string | null;
  dkim: string | null;
  dmarc: string | null;
  forged_auth_headers: number;
  raw_size: number;
  raw_key: string;
}

export class Mailbox extends DurableObject {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);

    // The first schema stored bodies inline. Those rows cannot be carried
    // forward — their raw messages were never written to R2, so there is
    // nothing for a migrated row to point at. Dropping is only acceptable
    // because everything under it was probe mail.
    const legacy = this.ctx.storage.sql
      .exec<{ n: number }>(`SELECT COUNT(*) AS n FROM pragma_table_info('messages') WHERE name = 'html'`)
      .toArray()[0];
    if (legacy && legacy.n > 0) this.ctx.storage.sql.exec(`DROP TABLE messages`);

    // No message bodies here. A row caps at 2 MB and inbound mail runs to
    // 25 MiB, so the body lives in R2 and this holds the key to it.
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        received_at TEXT NOT NULL,
        envelope_from TEXT NOT NULL,
        envelope_to TEXT NOT NULL,
        header_from TEXT,
        header_to TEXT,
        subject TEXT,
        message_id TEXT,
        authserv_id TEXT,
        spf TEXT,
        dkim TEXT,
        dmarc TEXT,
        forged_auth_headers INTEGER NOT NULL DEFAULT 0,
        raw_size INTEGER NOT NULL,
        raw_key TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS messages_received_at ON messages (received_at DESC);
    `);
  }

  store(message: StoredMessage): void {
    this.ctx.storage.sql.exec(
      `INSERT INTO messages (
         id, received_at, envelope_from, envelope_to, header_from, header_to,
         subject, message_id, authserv_id, spf, dkim, dmarc,
         forged_auth_headers, raw_size, raw_key
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      message.id,
      message.received_at,
      message.envelope_from,
      message.envelope_to,
      message.header_from,
      message.header_to,
      message.subject,
      message.message_id,
      message.authserv_id,
      message.spf,
      message.dkim,
      message.dmarc,
      message.forged_auth_headers,
      message.raw_size,
      message.raw_key,
    );
  }

  list(limit = 50): StoredMessage[] {
    return this.ctx.storage.sql
      .exec<StoredMessage>(
        `SELECT * FROM messages ORDER BY received_at DESC LIMIT ?`,
        limit,
      )
      .toArray();
  }

  get(id: string): StoredMessage | null {
    return (
      this.ctx.storage.sql
        .exec<StoredMessage>(`SELECT * FROM messages WHERE id = ?`, id)
        .toArray()[0] ?? null
    );
  }

  count(): number {
    return (
      this.ctx.storage.sql
        .exec<{ n: number }>(`SELECT COUNT(*) AS n FROM messages`)
        .toArray()[0]?.n ?? 0
    );
  }
}
