# m5atom-espnow-lab

A repository of ESP-NOW communication experiments between an M5Stack Atom Lite and a Basic V2.7.
It collects a set of samples that progress step by step — MAC address check → minimal send/receive →
web server integration → dynamic pairing — along with findings from research (RSSI proximity detection,
tx-power control, etc.).

Basic button/display operations live in [m5atom-lite-lab](../m5atom-lite-lab/), and the FastLED-based
LED matrix display code lives in [m5atom-led-matrix-lab](../m5atom-led-matrix-lab/) — both were split out
of what was originally a single repository called `atom-lite-test`.

## Environment setup

`flake.nix` provides Python 3 / `uv`. Enter via `direnv allow` or `nix develop`, or just use the
system Python directly.

```bash
uv venv
uv pip install -r requirements.txt
```

## Usage

```bash
# Copy the sample you want to try into src/ (flash the atom and basic sides separately)
cp examples/03_espnow_basic/atom/main.cpp src/main.cpp
.venv/bin/pio run -e atom -t upload

cp examples/03_espnow_basic/basic/main.cpp src/main.cpp
.venv/bin/pio run -e basic -t upload

.venv/bin/pio device monitor
```

`06_espnow_pairing` uses dedicated envs (`pairing_hub` / `pairing_node`) whose `build_src_filter`
points directly at `examples/06_espnow_pairing/{hub,node}/`, so no copy into `src/main.cpp` is needed.

```bash
.venv/bin/pio run -e pairing_hub -t upload   # Basic V2.7
.venv/bin/pio run -e pairing_node -t upload  # Atom Lite
```

`src/main.cpp` currently carries over a work-in-progress implementation of `shared.h`'s status
notification pattern (Free / Busy / Away). It's expected to be overwritten when trying another sample.

## Directory structure

```
examples/
├── 02_espnow_mac/         # MAC address check for both atom and basic sides
├── 03_espnow_basic/       # Minimal ESP-NOW send/receive
├── 04_espnow_webserver/   # ESP-NOW + web server integration
└── 06_espnow_pairing/     # Dynamic pairing (hub/node), uses dedicated envs
    └── pairing.h          # Shared pairing protocol definitions

include/
└── shared.h        # Channel/MAC/status definitions used by the 02-04 series

src/
└── main.cpp        # Build target (copy from examples/ to use; not needed for the pairing series, which uses dedicated envs)

docs/
└── espnow-advanced.md  # Research notes on RSSI proximity detection, tx-power control, and RTT quality monitoring
```

## Target devices

| Device | board | Recommended library |
|---|---|---|
| Atom Lite | `m5stack-atom` | M5Atom + FastLED |
| Basic V2.7 | `m5stack-core-esp32` | M5Unified |

To switch devices, switch envs like `.venv/bin/pio run -e atom` / `-e basic`.
