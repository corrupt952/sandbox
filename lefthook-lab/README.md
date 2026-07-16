# lefthook-lab

Hands-on verification of [lefthook](https://lefthook.dev) and [hk](https://hk.jdx.dev)
as Git hooks managers — checking whether their basic guarantees actually hold up
in practice, not just on paper.

## Setup

`flake.nix` provides a devShell with `lefthook` and `hk` (via nixpkgs unstable —
`hk` isn't packaged on stable nixpkgs branches yet). Enter it with `nix develop`
or `direnv allow`.

Verification itself happens in a disposable `testbed/` directory: a real,
separately `git init`'d repo (gitignored from this repo — see `.gitignore`)
so hook installation and commit-blocking behavior can be exercised against an
actual `.git`, without polluting this repo's own history.

## Finding: `core.hooksPath` conflicts can push installation toward global state

If a global `core.hooksPath` is already configured on the machine (e.g. by
another hooks setup), `lefthook install` refuses to run by default and prints
two suggested fixes:

- `lefthook install --reset-hooks-path` — unsets `core.hooksPath` globally
- `lefthook install --force` — installs into whatever `core.hooksPath` currently
  resolves to, **which is the global hooks directory if no local override
  exists**

Both of the tool's own suggested remedies mutate global state in that
situation. Confirmed by reading `ensureHooksPathUnset` in
[`internal/command/install.go`](https://github.com/evilmartians/lefthook/blob/master/internal/command/install.go):
the only code path that calls `git config --global --unset-all core.hooksPath`
is the `--reset-hooks-path` branch; plain `--force` skips that, but resolves
its write target to whichever path (local or global) is currently configured —
global, if nothing local is set.

The way to install scoped strictly to one repo, touching nothing global:

```sh
git config --local core.hooksPath .git/hooks   # explicit local override first
lefthook install --force                        # now resolves to the local path
```

lefthook still logs a warning here (it compares the local value against the
default hooks path as a string, and a relative `.git/hooks` won't match the
absolute default it computes internally — a minor quirk, not a functional
issue), but no `git config` mutation happens in this branch of the code at all.

## Verified so far

- **Basic blocking behavior**: a `pre-commit` config blocking `.DS_Store` and
  `*BurstDebugInformation_DoNotShip` actually stops `git commit` (confirmed via
  exit code and absence of a new commit), using the scoped install method above.

## Not yet verified

- Performance (staged/unstaged/full-repo timing)
- Known-bug reproductions from upstream issue trackers
- Monorepo ergonomics (multiple project roots, shared hook distribution)
- Supply-chain surface of npm/cargo-based installs
