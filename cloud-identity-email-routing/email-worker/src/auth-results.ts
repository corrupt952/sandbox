export interface AuthVerdicts {
  authserv_id: string | null;
  spf: string | null;
  dkim: string | null;
  dmarc: string | null;
  forged_instances: number;
}

const NONE: AuthVerdicts = {
  authserv_id: null,
  spf: null,
  dkim: null,
  dmarc: null,
  forged_instances: 0,
};

/**
 * A sender can put its own Authentication-Results header in the message, and
 * Headers.get() would hand back every instance joined together. Only the
 * instance our own ingest stamped is evidence, identified by its authserv-id;
 * every other instance is attacker-supplied data and is counted, not merged.
 *
 * `headers` must preserve duplicates, so it comes from the MIME parser rather
 * than from the Headers object.
 */
export function readAuthResults(
  headers: { key: string; value: string }[],
  expectedAuthservId: string,
): AuthVerdicts {
  const instances = headers
    .filter((h) => h.key.toLowerCase() === "authentication-results")
    .map((h) => h.value);
  if (instances.length === 0) return NONE;

  const expected = expectedAuthservId.toLowerCase();
  const ours = instances.find((v) => segments(v)[0]?.trim().split(/\s+/, 1)[0].toLowerCase() === expected);
  if (ours === undefined) {
    return { ...NONE, forged_instances: instances.length };
  }

  const resinfo = segments(ours).slice(1);
  return {
    authserv_id: expected,
    spf: verdict(resinfo, "spf"),
    dkim: verdict(resinfo, "dkim"),
    dmarc: verdict(resinfo, "dmarc"),
    forged_instances: instances.length - 1,
  };
}

/**
 * Splits on the `;` separators that are structure, ignoring the ones inside
 * parenthesised comments — real headers put free text like
 * "(no SPF records found for postmaster@…)" next to a result.
 */
function segments(value: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let current = "";
  for (const ch of value) {
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);

    if (ch === ";" && depth === 0) {
      out.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  out.push(current);
  return out;
}

/**
 * One method can appear more than once with different property types — an
 * observed header carried spf=none for the HELO check and spf=pass for
 * MAIL FROM. The MAIL FROM result is the one that says anything about the
 * sending domain, so prefer the segment naming it and fall back to the last.
 */
function verdict(resinfo: string[], method: string): string | null {
  const pattern = new RegExp(`(?:^|\\s)${method}\\s*=\\s*([A-Za-z]+)(?![A-Za-z=])`, "i");

  let fallback: string | null = null;
  for (const segment of resinfo) {
    const bare = segment.replace(/\([^()]*\)/g, " ");
    const match = bare.match(pattern);
    if (!match) continue;
    if (method === "spf" && /smtp\.mailfrom\s*=/i.test(bare)) return match[1].toLowerCase();
    fallback = match[1].toLowerCase();
  }
  return fallback;
}
