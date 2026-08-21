# The read path

The receive half of this experiment is built and running; the half that lets an agent read its own mailbox is not. This is the design that came out of a red/blue review and the identity research, written down before it is built so the reasoning survives.

Nothing here is implemented yet.

## What it has to do

An agent asks for its own mail and gets it. No agent can read another's. A human operator can enrol a new agent without editing code.

## Authentication: a per-agent keypair, not a Google token per request

The obvious design — the agent presents a Google ID token on every request and the Worker verifies it — puts Google in the hot path for no benefit and leaves the agent holding a refresh token, a bearer secret whose holder simply *is* the agent.

Instead: each agent generates its own Ed25519 or ES256 keypair and registers the **public** key. The private key is generated agent-side and never transits. Each request carries a signature over it — RFC 9421 HTTP message signatures, as Cloudflare's own Web Bot Auth does, or a short-lived `private_key_jwt` assertion. The Worker verifies the signature.

This is proof of possession rather than a bearer credential, so a captured request is not a reusable credential and the one-hour ID-token replay window disappears. Rotation is an edit to a key list. Revocation is deleting one public key. Neither needs a human.

Google's role, if there is one, is enrolment: run the consent flow once, check `sub`, `email`, `hd` and `email_verified`, record `sub → public key`, discard the Google tokens. Google becomes evidence about who this agent is, gathered once, rather than a live credential. Enrolment does not have to be Google-backed at all — an operator registering a public key by hand is the same binding with a different witness.

## Authorization: a binding table, and nothing else

`hd` is not a boundary here. It carries the Workspace organization's *primary* domain, so an agent on a secondary domain presents the primary one, and checking it either rejects legitimate agents or admits every human in the tenant. Its only real use is that service-account tokens lack it entirely.

So the boundary is an explicit table of `{address, aliases, public key, sub}`, and it is configuration. Not trust-on-first-use: whoever logged in first would claim the mailbox, including for an address that already has mail in it. A request for an address with no binding is a 404, never an invitation to create one.

Both a signature check and an address-resolves-to-this-key check must pass. Neither alone.

## Address handling

One `normalizeAddress`, shared by the receive path and this one, or the key a message is stored under can diverge from the key a caller is authorized for. It already exists in `email-worker/src/address.ts`: ASCII gate before case folding, no plus-tag or dot stripping, exactly one `@`.

If subaddressing is ever enabled on the zone, `user+detail@` starts matching the `user@` rule with the `+detail` preserved in `message.to`, and a strict binding table will reject legitimate mail. Enabling subaddressing and keying mailboxes strictly are one decision, not two.

## Before it holds anything real

The mailbox is an unauthenticated write channel open to the internet: anyone who knows the address puts content in it. If an agent reads its own inbox and acts on it, that is prompt injection with a delivery mechanism.

- Message content goes to a model as clearly delimited untrusted data, never concatenated into a system prompt, with the delimiter escaped in the content.
- Feed the text part. HTML must be sanitised — hidden text is the standard vehicle — and zero-width and bidirectional control codepoints stripped.
- Cap bytes per message and messages per turn. An unbounded inbox read is a context-flooding technique as much as a cost problem.
- Authentication verdicts reach the model as the structured `spf` / `dkim` / `dmarc` columns, never as a header for it to interpret.
- Acting on a message requires the sender to be on an allowlist and to have passed DMARC, enforced in code before the model call. Everything else is readable and non-actionable.
- No turn that ingested inbox content may perform an outbound or state-changing action without human confirmation, and URLs found in messages are never auto-fetched. A URL fetch is a general exfiltration channel and would reintroduce exactly the send path this deployment exists without.
- Stored mail is never served as renderable HTML from this origin.

## Surface

`workers_dev` is off, so there is no public hostname today. Whatever hosts the read path needs an identity check of its own; an operator console belongs behind Cloudflare Access, which is the single trust boundary Cloudflare's own reference implementation uses.

The Worker's verification is the authorization decision and cannot be delegated to Access — Access knows whether a principal may reach the Worker, not whether it may read an address.

## Open

Whether an operator console drives Email Routing rules through the API so that one enrolment creates the address, the rule and the key binding together. The API supports full CRUD on routing rules, so the two-list problem is solvable; it is not solved.
