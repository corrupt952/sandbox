const ADDRESS_CHARS = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~@-]+$/;
const MAX_ADDRESS_BYTES = 254;

/**
 * Returns a canonical key, or null if the input is not an address this system
 * will accept. Both the receive path and any read path must call this, or the
 * key a message is stored under can diverge from the key a caller is authorized
 * for.
 */
export function normalizeAddress(input: unknown): string | null {
  if (typeof input !== "string") return null;

  let value = input.trim();
  if (value.startsWith("<") && value.endsWith(">")) value = value.slice(1, -1).trim();
  if (value.length === 0 || value.length > MAX_ADDRESS_BYTES) return null;

  // Charset gate before case folding, not after: toLowerCase() is Unicode-aware,
  // so codepoints like U+0130 fold onto ASCII letters and two different inputs
  // become one key.
  if (!ADDRESS_CHARS.test(value)) return null;

  const at = value.indexOf("@");
  if (at <= 0 || at !== value.lastIndexOf("@")) return null;

  const domain = value.slice(at + 1);
  if (domain.length === 0 || !domain.includes(".")) return null;

  // No plus-tag or dot stripping: those collapse distinct addresses onto one key.
  return value.toLowerCase();
}
