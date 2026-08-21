// Secrets do not appear in the generated types, because they are not in the
// committed configuration. Declared here so the code that reads them is checked.
interface Env {
  ALLOWED_RECIPIENTS?: string;
}
