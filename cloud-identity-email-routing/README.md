# cloud-identity-email-routing

Giving an autonomous agent its own identity — one that signs into third-party services and shows up under its own name in audit logs — without giving it a mailbox, and without paying for a seat. Google Cloud Identity Free supplies the identity, Cloudflare Email Routing supplies inbound mail, and an Email Worker reads what arrives. Nothing in the arrangement can send.

The interesting part turned out not to be the Worker. It was that the obvious blocker — a business domain whose MX already belongs to Google Workspace — is not a blocker at all, and that most of what the vendor prose says about the Worker runtime is wrong.

## Finding: the apex MX conflict dissolves into a Workspace domain setting

Email Routing "is a zone-level feature that applies to the apex domain by default", and its "DNS records are configured on the root domain" — MX on `@`, SPF on `@`, DKIM on `cf2024-1._domainkey` ([Domain configuration](https://developers.cloudflare.com/email-service/configuration/domains/)). A domain already running Workspace mail has that apex MX spoken for, and one hostname cannot meaningfully share its MX between two providers.

The Cloudflare-shaped answer is subdomains, which are supported — "You can extend either service to subdomains of the same zone, such as `mail.example.com`", up to 30 domains per zone ([Subdomains](https://developers.cloudflare.com/email-service/configuration/subdomains/)) — but the documented way in starts at "Select the apex domain, then open **Settings**", a page that exists only once the zone is onboarded, and onboarding is what writes Cloudflare's records onto the root. Apex routing records can be unlocked and replaced afterward, though the docs frame that as a migration aid rather than a supported way to keep another provider there permanently.

None of that is necessary. A Workspace tenant holds more than one domain, and a **secondary domain** gives its users their own accounts and their own primary addresses. Activating one does not require handing its MX to Google: **Skip Google MX setup** exists to "activate the domain even if you are routing its email through a mail server that's not hosted by Google", and it applies to secondary domains and domain aliases ([Skipping Google Workspace MX record setup](https://knowledge.workspace.google.com/admin/gmail/advanced/skipping-google-workspace-mx-record-setup)). A Cloud Identity Free user has no Gmail to route in the first place, so pointing that MX at Cloudflare costs nothing.

So the agent lives on a second registered domain, added to the existing tenant as a secondary domain, apex MX pointing at Email Routing. The business domain is never touched and no subdomain is involved.

## Finding: a user alias domain cannot carry an agent identity

The other domain type on the same dialog is a dead end, and not for cosmetic reasons. "Users cannot authenticate using alias domain addresses; they need to use their primary email address" ([Limitations with multiple domains](https://knowledge.workspace.google.com/admin/domains/limitations-with-multiple-domains)) — an alias address cannot sign in anywhere, which is the entire job. An alias domain also creates no separate account, so there is no distinct principal to attribute audit-log entries to, and it mints an address on the new domain for every existing user, all of them pointing at a domain whose MX now belongs to Cloudflare.

The two types do not convert into one another. Changing type means deleting the domain and re-adding it, after clearing any groups and user aliases on it.

## Finding: Google calls a mailbox-less address verified

A Cloud Identity Free user has no Gmail, no recovery address, and no way to receive anything at its own address. Google issues it an ID token anyway, and that token says the address is verified:

```json
{
  "iss": "https://accounts.google.com",
  "hd": "example.com",
  "sub": "1040228666623431…",
  "email": "agent@example.com",
  "email_verified": true
}
```

The consent flow completes with no extra identity check — no phone, no recovery address, nothing that would need a mailbox to satisfy. Verification here rests on the tenant owning the domain, not on anything being delivered. Any third-party service that trusts `email_verified` should therefore accept such an account without sending a confirmation mail at all; the ones that demand a received message are the ones declining to trust the claim.

Figma and Notion both behave that way: signing up with Google went straight through on the strength of the claim, with no confirmation mail sent and nothing to receive. So "can this identity sign up for things" is a question about each service's trust in `email_verified`, not about the identity — and the services that ask for a received message are the exception to be counted, not the rule to design around.

`sub` is the stable identifier and the right key for anything per-agent. An address can be renamed; `sub` cannot.

Reproducing this needs no OAuth client of your own, because the gcloud CLI is already one:

```sh
docker run -ti --name gcloud-probe \
  gcr.io/google.com/cloudsdktool/google-cloud-cli:stable \
  gcloud auth login --no-launch-browser

docker run --rm --volumes-from gcloud-probe \
  gcr.io/google.com/cloudsdktool/google-cloud-cli:stable \
  bash -c 'gcloud auth print-identity-token | cut -d. -f2 | base64 -d'
```

`--no-launch-browser` prints a URL to open on the host and takes a pasted code back; it was deprecated in favour of `--no-browser`, which is worse here because it wants gcloud installed on the browser machine too. Credentials stay in the named container's volume, so `docker rm gcloud-probe` disposes of them and the host's own gcloud config is never touched.

The `aud` on a token obtained this way is gcloud's own client ID, so it will not open anything that checks `aud` against its own client — which is the behaviour you want, since otherwise any token from anyone's gcloud login would be accepted.

## Finding: an account per agent is the fallback, not the default

Proving that a mailbox-less Google identity can sign up for third-party services answers "can it", and the more useful question turned out to be "should it". Mostly it should not. Where a product has a purpose-built bot mechanism, that mechanism beats a user account on all three axes at once.

**Cost.** Every purpose-built mechanism surveyed is free; a user account is a seat wherever seats are billed. Fifty agents in Figma Professional is fifty full seats. Fifty machine users in a GitHub org is fifty licences.

**Terms.** GitHub caps free machine accounts at one per person and forbids accounts registered by automated means. Discord prohibits automating a user account outright — a self-bot is a termination risk, so there the pattern is not merely expensive but disallowed. Figma ties each account to the individual it was issued to. Technically workable and contractually permitted are different questions, and this is the axis where a growing fleet of agent accounts eventually attracts attention.

**Audit separation, which is the thing the pattern was supposed to buy.** A GitHub App appears in the audit log as its own actor; a Linear agent appears as itself; a Salesforce integration user carries its own id through field history. The bot mechanism gives the same separation the user account was wanted for, for free and without the terms problem.

Linear and GitHub Apps are the two implementations worth copying, for different reasons. Linear treats a bot as a participant — assignable, mentionable, revocable in a click, explicitly not billable — which is what you would design if agents do work rather than post notifications. GitHub Apps win on credentials: a private-key-signed JWT exchanged for an installation token that lives one hour and rotates itself, against static long-lived strings nearly everywhere else.

So a dedicated account earns its place only where no bot concept exists, or where it sits behind a tier you are not on. Figma below Organization is exactly that, which makes it the one service where a dedicated account is the honest answer and also the one where it costs a seat.

None of this diminishes the mailbox. Whichever mechanism a service offers, the agent still needs an address.

## Finding: a machine can name itself, but only a person can vouch for it

An agent that must hold a *Workspace user* identity cannot avoid both a one-time human consent and a stored long-lived credential, and this is structural rather than a gap someone will close. Every alternative fails one of the three requirements: domain-wide delegation removes the consent but lets one service account impersonate every user in the domain — Google's own documentation states that scopes cannot restrict which users are impersonated — and workload identity federation removes the stored secret but yields a workload or service-account token, never a token carrying a Workspace user's `sub`.

Google's own [Agent Identity](https://docs.cloud.google.com/iam/docs/agent-identity-overview) settles the argument by conceding it. It is the most advanced attested agent identity shipping anywhere — a SPIFFE ID, auto-provisioned X.509 certificates valid 24 hours, tokens cryptographically bound to the certificate, no long-lived keys possible — and for third-party or user data it still opens a consent dialog and still keeps a refresh token, merely in a vault the agent cannot read. Attestation proves where code runs. It cannot prove a person agreed to something.

The line every ecosystem draws is the same one. Web Bot Auth's keypairs, Cloudflare Access service tokens, and the MCP authorization spec's draft `client_credentials` extension all authenticate a *client* with no human involved. None of them produces a principal a third-party relying party will accept as a user. A machine naming itself is automatable; a machine being vouched for as a person is not.

Surveying the identity vendors says the same thing twice over. They have converged on asymmetric keypairs — `private_key_jwt` and certificate- or attestation-bound tokens — and none of them has removed the human from enrolment. Okta's agents authenticate with `private_key_jwt` and then exchange that for a cross-domain grant carrying an `act` actor chain, which is the standards-track version of "this agent, acting for that person". The one shipped counter-example is Microsoft's Entra Agent ID, where an agent is a specialised service principal that can be *paired with a user account* — the combination Google's model refuses — but it is tenant-local and proprietary, so the agent is a sign-in principal only inside that tenant.

Which means the keypair design here is on the industry's line rather than beside it, and the one-time consent is where everyone else puts it too.

Which means the consent is in the right place, and the mistake is using it more than once. Run it once per agent, verify `sub`, `email`, `hd` and `email_verified`, record `sub → the agent's public key`, then throw the Google tokens away. Give each agent an Ed25519 or ES256 keypair and have it sign each request — RFC 9421 message signatures, or a `private_key_jwt` assertion. Google becomes an enrolment proof rather than a live credential, a captured request stops being a reusable credential, rotation is an edit to a key list, and revocation is deleting one public key. None of that needs a human, and the one thing that does happens once.

If a refresh token is kept anyway, the rules worth knowing: it dies after six months unused, which is what kills a dormant agent; there is a limit of 100 live refresh tokens per account per client id; and the seven-day expiry for apps in Testing applies only to the external user type and exempts requests whose scopes are a subset of name, email, and profile — which is exactly the scope set an identity-only design asks for.

## Finding: Agent Identity is not a sign-in identity

Google shipping something called Agent Identity in 2026 invites the assumption that it replaces a Cloud Identity Free user for this. It does not, and cannot be configured to.

Its identifier is `principal://TRUST_DOMAIN/resources/…`, not an email address and not an OIDC `sub` a relying party could consume. Its tokens are certificate-bound and guarded by a Google-managed Context-Aware Access policy so that they "can only be used from their intended, trusted runtime environment"; presented anywhere else they return 401 ([agent identity on Agent Runtime](https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity)). That non-portability is the security property, and it is exactly what makes the credential useless as a sign-in assertion. It is also issued only to agents deployed on Agent Runtime, so an agent living anywhere else has none to hold. Google files it under [identities for workloads](https://docs.cloud.google.com/iam/docs/workload-identities), on the other side of the line from identities for users.

So the two solve different problems and neither can be made to do the other's job. A Cloud Identity Free user is a person-shaped principal the consumer identity ecosystem already accepts, costs nothing per agent up to the free cap, and appears in the Workspace audit log. Agent Identity gives a process an attested, non-exportable credential for reaching Google Cloud APIs, and drags in the metered runtime it only exists inside. Holding both is coherent — Google's own stack does exactly that — but only for an agent that runs on Agent Runtime and actually calls Google Cloud APIs.

## Finding: the free tier includes the audit log

Attribution is the point of giving each agent its own identity, so it matters that Cloud Identity Free carries the log events that make attribution real: Admin, User, **OAuth**, SAML and Groups log events are all in the free edition, and Premium adds only device log events and automatic export to BigQuery ([Cloud Identity editions](https://docs.cloud.google.com/identity/docs/editions)). The OAuth entry is the one to care about — it records which third-party applications an account authorised, attributed to that account.

## Finding: `hd` cannot fence off a secondary-domain agent

The obvious way to scope a Google ID token to your tenant is to check `hd`, and for an agent on a secondary domain it does not work. `hd` carries the domain of the user's Workspace organization — the **primary** domain — not the domain the user's own address sits on. An agent at `agent@agents.example` inside a tenant whose primary domain is `example.com` presents `hd: example.com`.

So checking `hd` against the agent's own domain rejects legitimate tokens, and relaxing it to the primary domain admits every human employee in the organization. Either way `hd` provides no isolation between the agent and the rest of the tenant, and the entire boundary comes to rest on binding a specific address to a specific `sub`. That binding has to be configuration, not something recorded on first sight — whoever logs in first would otherwise claim the mailbox.

`hd` still earns its check for one thing: service-account ID tokens are issued by `accounts.google.com` too, with an `aud` the caller chooses, and they carry no `hd` at all. Verifying `iss` and `aud` alone therefore admits anyone with any Google service account.

## Finding: a 25 MiB message does not fit in a 2 MB row

Email Routing accepts inbound messages up to 25 MiB. A Durable Object's SQLite has a "Maximum string, BLOB or table row size" of 2 MB ([Durable Objects limits](https://developers.cloudflare.com/durable-objects/platform/limits/)). Storing a parsed message — text, html, and headers — as one row therefore has a hole in it more than ten times wider than the row it writes into.

Combined with letting the handler throw, that turns into a retry loop: the insert fails, the exception propagates, Cloudflare redelivers, it fails again. Anyone who knows the address can trigger it with one oversized message. The fix is to put the raw message in R2 and keep only metadata and the object key in the row, which is what the reference implementation does for attachments and costs nothing at this volume — R2's free tier is 10 GB-month with 1M class A and 10M class B operations.

## Finding: not having a rule rejects better than rejecting does

Cloudflare does not document what its MX replies for an address with no routing rule when catch-all is off. Measured, it is clean and correct:

```
550 5.1.1 Address does not exist.
```

The Worker never runs. Compare that with what the Worker itself can say — `setReject(reason)` takes only a string and the code is Cloudflare's to choose, which turns out to be:

```
555 5.7.1 Message rejected.
```

`5.7.1` is "delivery not authorized, message refused" and fits. `555` does not: RFC 5321 defines it as "MAIL FROM/RCPT TO parameters not recognized or not implemented", which is not what happened and not what a human reading the bounce needs to know. There is no way to ask for `550`.

So the better expression of "no such address here" is the absence of a routing rule, not a rule that routes to a Worker which rejects. That demotes the Worker's allowlist from primary mechanism to safety net — worth keeping for the address whose rule outlived its mailbox, and for the day someone enables catch-all, but not the thing doing the work.

Rejecting rather than silently accepting is also the right posture, and the cost is honest: anyone can walk a wordlist against the MX and learn which addresses exist. Cloudflare's MX offers no tarpit or rate-limit knob to soften that. Gmail and Microsoft 365 expose their customers to exactly the same enumeration, and for a domain with a handful of addresses the marginal loss is small.

One live trap sits next to this. Subaddressing is off by default, and with it on, "if you send an email to `user+detail@example.com` it will be matched by the `user@example.com` routing rule" while "the `+detail` part is preserved in `message.to`" ([routing rules and addresses](https://developers.cloudflare.com/email-service/configuration/email-routing-addresses/)). An allowlist comparing `message.to` literally — which is the correct behaviour, since collapsing `+` tags merges distinct addresses onto one key — would then reject legitimate mail. Enabling subaddressing and keying mailboxes strictly are choices that have to be made together.

## Finding: `canBeForwarded` does not exist

Prose documentation describes a `canBeForwarded` property for deciding whether an incoming message passed authentication. No such property exists. The real surface of `ForwardableEmailMessage` in the types wrangler 4.124 generates is `from`, `to`, `raw`, `headers`, `rawSize`, `setReject`, `forward`, `reply` — read out of the generated `worker-configuration.d.ts`, which is authoritative in a way the prose is not.

What survives instead is the `Authentication-Results` header Cloudflare stamps on the message. A real delivery from Gmail arrives carrying the full verdict:

```
mx.cloudflare.net; dkim=pass header.d=…gappssmtp.com header.s=… ;
dmarc=none header.from=… policy.dmarc=none;
spf=none (no SPF records found for postmaster@mail-qv1-xf2a.google.com) smtp.helo=…;
spf=pass (domain of … designates 2607:f8b0:4864:20::f2a as permitted sender) smtp.mailfrom=…;
arc=pass
```

Reading that header is the only way a Worker learns whether SPF or DKIM passed. Note the two `spf=` entries: the HELO check fails and the MAIL FROM check passes, so a naive substring match on `spf=` reads the wrong one.

It gets worse than merely ambiguous. A sender can put their own `Authentication-Results` header in the message claiming whatever they like, and `Headers.get()` returns every instance of a header joined together, so what comes back is your infrastructure's verdict concatenated with the attacker's. Only the instance your own ingest added is evidence, identified by its `authserv-id` — pin that value from a known-good message on your own deployment and discard the rest. Storing the header verbatim is fine as raw material; parsing it by searching for `pass` is not.

## Finding: Email Routing cannot send, but the Worker can

"Email Routing is receive-only" is true of Email Routing and misleading about the system. What can send is the Worker: a `send_email` binding reaches verified destination addresses in the same account even on the free plan with only Email Routing configured ([Configure send bindings](https://developers.cloudflare.com/email-service/configuration/send-bindings/)). Reaching an arbitrary third party is what needs a sending domain onboarded and Workers Paid.

So "no send path" is a property of the deployment, not of the platform, and it cannot be demonstrated by sending and watching it fail: reaching the sending API means granting `email_sending:write`, and enabling Email Sending to test it would build the very route the arrangement is supposed to lack. Absence is shown by construction instead. `wrangler types` generates the environment from the config, and the whole of it is one line:

```ts
interface __BaseEnv_Env {
	MAILBOX: DurableObjectNamespace<import("./src/index").Mailbox>;
}
```

There is nothing to call. The binding list `wrangler deploy` prints says the same thing at runtime, and the operating token cannot enumerate Email Sending at all — `Unauthorized [code: 2036]` — because that scope was never granted.

## Finding: `wrangler dev --remote` is gone for Durable Objects

Reaching a deployed Durable Object through a local port no longer works: "`wrangler dev --remote` is no longer supported for Durable Objects." It starts, prints `Ready on http://localhost:…`, warns that "SQLite in Durable Objects is only supported in local mode", and then throws on the first request. Production state is reachable only through the deployed Worker.

## Finding: `wrangler login` asks for 28 permissions

The default OAuth flow requests everything — Account & Billing, DNS & Zones, AI, App Security, 21 Developer Platform scopes. Deploying an Email Worker and pointing a routing rule at it needs five:

```sh
wrangler login --scopes \
  workers_scripts:write workers_tail:read email_routing:write account:read zone:read
```

`zone:read` is not optional despite nothing writing DNS records directly: without it wrangler cannot turn a domain name into a zone, and every `email routing` subcommand fails with "Could not find zone". Left out is `user:read`, whose absence only breaks `wrangler email routing list` — the per-domain commands work without it.

## Setup

```sh
mise install
pnpm install
pnpm --filter email-worker exec wrangler types
```

`mise.toml` pins node and pnpm for everything below it; `email-worker/` is the only package in the workspace so far, and `cloud-identity/` holds the Admin console half, which is console work with nothing to run.

The third command regenerates `email-worker/worker-configuration.d.ts`, which is not committed. It is half a megabyte of Cloudflare's own workerd declarations, it is derived from `wrangler.jsonc` plus whichever runtime version is pinned, and it changes on its own schedule — so it is a build input here rather than source. Type-checking fails until it has been generated once.

## The Email Worker

`email-worker/` stores the raw message in R2 and the metadata in a Durable Object keyed by recipient, one SQLite database each. It never calls `message.forward()` and declares no `send_email` binding, so nothing passes through a destination mailbox and nothing can leave.

The mailbox key comes from `message.to`, the envelope recipient, and from nothing else. `To`, `Cc` and `Delivered-To` are recorded as context but never influence where a message lands — they name whatever the sender wants them to. Both the receive path and any future read path run the address through one `normalizeAddress`, which gates to ASCII *before* case folding, because `toLowerCase()` is Unicode-aware and several codepoints fold onto ASCII letters; fold first and two different inputs become one key. Plus-tags and dots are left alone, so `agent+x@` is a different address, not the same one.

Deliverable addresses are a closed set held in a secret, checked in the Worker on top of the literal Email Routing rules. Anything else gets `setReject`, which is a permanent SMTP error the sender sees as a bounce. That split matters: permanent failures — over the size cap, unparseable, recipient not configured — must reject, because they fail identically on every retry and throwing would produce a retry storm. Transient failures still throw, so Cloudflare redelivers.

`Authentication-Results` is parsed at store time into explicit `spf` / `dkim` / `dmarc` columns. Only the instance carrying our own `authserv-id` counts; a sender can add its own header claiming everything passed, and the count of those is stored too. Within our instance, `spf` takes the `smtp.mailfrom` result rather than the HELO one.

The shape comes from [`cloudflare/agentic-inbox`](https://github.com/cloudflare/agentic-inbox), Cloudflare's own reference for agent mailboxes on Email Routing — MIME parsing with `postal-mime`, per-address isolation via `idFromName`, letting the handler throw. Left behind: threading, folders, the AI agent, the web UI, and its `send_email` binding. Diverged from deliberately: it keys mailboxes off the parsed `To` header rather than the envelope.

There is no HTTP endpoint for reading a mailbox back, and `workers_dev` is off so there is no public hostname either. What the Worker read is visible in `wrangler tail` as mail arrives. A read path belongs behind an identity check, not behind obscurity.

### Delivering mail locally

`wrangler dev` exposes a `/cdn-cgi/handler/email` endpoint that triggers the `email()` handler, with no domain, account, or DNS record involved.

```sh
cd email-worker
./deliver-local.sh                             # fixtures/plain.eml
./deliver-local.sh fixtures/unauthenticated.eml
```

`fixtures/plain.eml` carries an `Authentication-Results` header and stores it verbatim; `fixtures/unauthenticated.eml` has none and stores `null`. Local delivery bypasses whatever Cloudflare does to a message before the handler runs, so it exercises the handler and nothing else.

### Standing up a live address

```sh
pnpm --filter email-worker exec wrangler deploy

pnpm exec wrangler email routing settings "$ZONE"    # expect: unconfigured
pnpm exec wrangler email routing dns get "$ZONE"     # review before writing anything
pnpm exec wrangler email routing enable "$ZONE"      # writes apex MX, SPF, DKIM

pnpm exec wrangler email routing rules create "$ZONE" \
  --name "agent to worker" \
  --match-type literal --match-field to --match-value "$AGENT" \
  --action-type worker --action-value "$WORKER"

pnpm exec wrangler tail "$WORKER"
```

`enable` writes three MX records (`route1`–`route3.mx.cloudflare.net`), SPF, and DKIM onto the apex, so run `dns get` first and confirm nothing there is worth keeping. The catch-all rule defaults to disabled with action `drop`, which is what this wants: only the named address reaches the Worker.

## Reading the mailbox

Not built. An agent asking for its own mail — and getting only its own — is designed but unimplemented; [`docs/read-path.md`](docs/read-path.md) holds the design and the reasoning behind it, including why the agent signs each request with its own keypair rather than presenting a Google token, and what has to be true before an inbox that anyone on the internet can write to is fed to a model.

## Out of scope

Self-hosting an IdP, GitHub Apps, and identity on any other service.
