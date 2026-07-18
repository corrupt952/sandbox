# m5atom-lite-lab

A PlatformIO basics experiment repository for the M5Stack Atom Lite / Basic V2.7.
It covers only minimal samples for button input and display output.

ESP-NOW communication samples live in [m5atom-espnow-lab](../m5atom-espnow-lab/),
and FastLED-based LED matrix display samples live in
[m5atom-led-matrix-lab](../m5atom-led-matrix-lab/) — split out into separate repos
(originally a single repo called `atom-lite-test`).

## Environment setup

`flake.nix` provides Python 3 / `uv`. Enter it via `direnv allow` or `nix develop`,
or just use the system Python directly.

```bash
uv venv
uv pip install -r requirements.txt
```

## Usage

```bash
# Copy the sample you want to try into src/
cp examples/01_button_led/main.cpp src/main.cpp

# Build & upload
.venv/bin/pio run -t upload

# Serial monitor (exit: Ctrl+C)
.venv/bin/pio device monitor
```

`05_display_base` uses its own dedicated `atom_display` env (which references
`examples/05_display_base/` directly via `build_src_filter`), so copying it to
`src/main.cpp` is not needed.

```bash
.venv/bin/pio run -e atom_display -t upload
```

## Directory layout

```
examples/
├── 01_button_led/   # LED green<->red on button press
└── 05_display_base/ # Atomic Display Base (HDMI output), uses a dedicated env

src/
└── main.cpp         # Build target (copy from examples/ to use)

docs/
└── business-usecases.md  # Research memo on M5Stack Atom Lite business use cases
```

## Target devices

| Device | board | Purpose |
|---|---|---|
| Atom Lite | `m5stack-atom` | `atom` env (01_button_led) |
| Atom Lite + Atomic Display Base | `m5stack-atom` | `atom_display` env (05_display_base, HDMI output) |
