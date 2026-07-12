# swift-text-adventure

A tiny text adventure engine in a single Swift file, plus a game design
analysis memo. The engine models rooms, items, and an inventory, and runs a
command loop (`look`, `go [direction]`, `take [item]`, `inventory`,
`use [item]`, `exit`) over a three-room demo dungeon (find the key, unlock the
door, escape).

`analysis.md` is a separate exploration of abstract gameplay frameworks
(anomaly detection, entropy management, cryptographic discovery) synthesized
from the engine experiments.

## How to run

```sh
swiftc main.swift -o adventure_game
./adventure_game
```

## Notes

- The compiled binary is not tracked; build it locally with the command above.
