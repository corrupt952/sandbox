# m5atom-led-matrix-lab

An experiment repository for WS2812B LED matrix displays using M5Stack Atom Lite + FastLED.
It covers three hardware configurations: an LED panel (8x32), an LED Hat (scrolling text / eyes display),
and an LED Badge (32x16, two panels stacked vertically).

Basic button/display operations live in [m5atom-lite-lab](../m5atom-lite-lab/), and
ESP-NOW communication work is split out into [m5atom-espnow-lab](../m5atom-espnow-lab/)
(these were originally a single repository called `atom-lite-test`).

## Environment setup

`flake.nix` provides Python 3 / `uv`. Enter it via `direnv allow` or `nix develop`,
or just use the system Python directly.

```bash
uv venv
uv pip install -r requirements.txt
```

## Usage

Each example has its own dedicated env (referencing the corresponding `examples/` subdirectory
directly via `build_src_filter`), so there's no need to copy anything into `src/main.cpp`.

```bash
.venv/bin/pio run -e led_panel -t upload   # 8x32 panel (G25 connection)
.venv/bin/pio run -e led_hat   -t upload   # LED Hat
.venv/bin/pio run -e led_badge -t upload   # 32x16 badge (two panels stacked vertically)

.venv/bin/pio device monitor
```

If you want to preview the display patterns without real hardware, just open the HTML files
under `simulators/` directly in a browser (no build step, single file).

## Directory layout

```
examples/
├── 07_led_panel/  # 8x32 WS2812B panel
├── 08_led_hat/    # SCROLL TEXT / EYES mode switching
└── 09_led_badge/  # 32x16, two panels stacked vertically, 3x7 slim font

simulators/
├── led-badge-simulator.html  # Browser simulator for the Badge display
├── led-hat-simulator.html    # Browser simulator for the Hat display
└── minigames.html            # Browser prototype of mini-games for the Badge (32x16)
```

## Target devices

| Device | board | Recommended library |
|---|---|---|
| Atom Lite | `m5stack-atom` | FastLED |
