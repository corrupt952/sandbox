import PostalMime from "postal-mime";
import { normalizeAddress } from "./address";
import { readAuthResults } from "./auth-results";
import { Mailbox } from "./mailbox";

export { Mailbox };

const SUBJECT_LIMIT = 2000;
const REJECT_REASON = "Message rejected";

export default {
  async email(message, env, ctx): Promise<void> {
    // Permanent failures call setReject: they fail identically on every retry,
    // so throwing would produce a retry storm ending in a bounce that tells the
    // sender the address exists. Transient failures below are left to throw so
    // Cloudflare redelivers.
    const reject = (reason: string) => {
      // The reason string reaches the sender, so it stays generic; the specific
      // one is logged instead.
      message.setReject(REJECT_REASON);
      console.log(
        JSON.stringify({
          event: "rejected",
          reason,
          envelopeTo: message.to,
          envelopeFrom: message.from,
          rawSize: message.rawSize,
        }),
      );
    };

    if (message.rawSize > Number(env.MAX_MESSAGE_BYTES)) {
      reject("over_size_cap");
      return;
    }

    const key = normalizeAddress(message.to);
    if (key === null) {
      reject("unnormalizable_recipient");
      return;
    }
    if (!allowedRecipients(env).has(key)) {
      reject("recipient_not_configured");
      return;
    }

    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());

    let parsed;
    try {
      parsed = await new PostalMime().parse(raw);
    } catch {
      reject("unparseable_mime");
      return;
    }

    const auth = readAuthResults(parsed.headers ?? [], env.AUTHSERV_ID);
    const id = crypto.randomUUID();
    const rawKey = `raw/${key}/${id}`;

    // R2 first, so a failure here leaves no row pointing at a missing object.
    // The reverse ordering can strand an object, which is harmless and sweepable.
    await env.RAW.put(rawKey, raw, {
      httpMetadata: { contentType: "message/rfc822" },
    });

    const stub = env.MAILBOX.get(env.MAILBOX.idFromName(key));
    await stub.store({
      id,
      received_at: new Date().toISOString(), // Not the Date header, which the sender controls.
      envelope_from: message.from,
      envelope_to: key,
      header_from: parsed.from?.address ?? null,
      // Recorded as context only. Routing and keying come from the envelope,
      // because these headers name whatever the sender wants them to.
      header_to: parsed.to?.map((t) => t.address).filter(Boolean).join(", ") || null,
      subject: parsed.subject?.slice(0, SUBJECT_LIMIT) ?? null,
      message_id: parsed.messageId ?? null,
      authserv_id: auth.authserv_id,
      spf: auth.spf,
      dkim: auth.dkim,
      dmarc: auth.dmarc,
      forged_auth_headers: auth.forged_instances,
      raw_size: message.rawSize,
      raw_key: rawKey,
    });

    console.log(
      JSON.stringify({
        event: "stored",
        rawKey,
        envelopeTo: key,
        envelopeFrom: message.from,
        headerFrom: parsed.from?.address ?? null,
        rawSize: message.rawSize,
        spf: auth.spf,
        dkim: auth.dkim,
        dmarc: auth.dmarc,
        forgedAuthHeaders: auth.forged_instances,
        mailboxCount: await stub.count(),
      }),
    );
  },
} satisfies ExportedHandler<Env>;

/**
 * Email Routing's literal rules already bound which addresses arrive, with
 * catch-all disabled. This repeats that as a closed set inside the Worker so
 * enabling catch-all cannot silently widen what gets stored.
 */
function allowedRecipients(env: Env): Set<string> {
  const configured = (env.ALLOWED_RECIPIENTS ?? "")
    .split(",")
    .map((entry) => normalizeAddress(entry))
    .filter((entry): entry is string => entry !== null);
  return new Set(configured);
}
