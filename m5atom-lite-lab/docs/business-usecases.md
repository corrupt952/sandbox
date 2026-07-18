# M5Stack Atom Lite Business Use Case Research Memo

Research date: 2026-02-27
Research scope: Qiita / Zenn / corporate blogs / GitHub / Home Assistant Community / M5Stack Community

---

## Summary

- **Disruptive cost**: Under ¥4,000 including sensors — 1/10 to 1/100 of commercial systems
- **Agriculture / food**: Proven track record of 1+ years of continuous operation in dusty, pesticide-exposed, high-humidity environments
- **Office**: BLE presence + CO2 sensor combination is the most common
- **Factories**: Retrofitting IoT onto equipment more than 20 years old (no PLC replacement needed)
- **RS485/Modbus**: Can connect directly to existing industrial equipment for data collection

---

## Use cases by industry

### 🌾 Agriculture / farm management

**Greenhouse temperature, humidity, and pressure monitoring**

- Challenge: Commercial sensors are expensive, and checking inside the greenhouse every day is a burden
- Setup: Atom Lite + ENV III (SHT30+QMP6988) -> WiFi -> Ambient cloud
- Cost: About **¥3,050** (Atom Lite ¥1,400 + ENV III ¥1,000 + cable)
- Track record: **1+ years of fault-free operation** in dusty, pesticide-exposed, misty environments
- Development: UIFlow (MicroPython block-based), no-code
- Extension: Can be extended to outdoor farms outside WiFi range using the Atom DTU LoRaWAN Kit
- Source: https://qiita.com/agri1nensei/items/60158862536f238cbc03

---

### 🏭 Manufacturing / factories

#### Anomaly detection + andon (warning light) control

- Challenge: Machines over 20 years old have no alarm function, requiring constant on-site monitoring
- Setup: M5Stack + temperature sensor -> NPN transistor + relay -> patrol lamp (AC100V)
- Note: Atom Lite output is 3.3V DC only -> AC100V equipment is controlled via a relay circuit
- Cost: A few thousand yen (a fraction of the cost of adding a commercial PLC)
- Source: https://www.e-hasegawa.co.jp/ceo-178/

#### Operating rate monitoring (proximity sensor)

- Challenge: Inefficient operating-time tracking via handwritten logs transcribed into Excel
- Setup: Atom Matrix + Omron magnetic proximity sensor GLS (¥1,080) -> LINE notification
- Mechanism: Detects cylinder reciprocation with a magnetic sensor -> automatically tallies timestamped shot counts
- Cost: About **¥4,000**
- Source: https://www.e-hasegawa.co.jp/ceo-184/

#### Automated on-site report creation (i-Reporter integration)

- Challenge: Missing or delayed entries on paper forms when anomalies occur
- Setup: M5Stack + sensor -> custom URL scheme via UIFlow -> i-Reporter app
- Mechanism: Threshold exceeded -> QR code shown on screen -> scanned by tablet -> report created automatically
- Highlight: No-code implementation (UIFlow blocks), no IT department needed
- Applications: Manufacturing, food production, facility management
- Source: https://i-reporter.jp/column/10954/

---

### 🏢 Office / smart office

#### CO2 monitoring (ventilation management, infection control)

- Background: Adoption grew after COVID-19 (from 2020) increased focus on ventilation
- Setup: Atom Lite + CO2 Unit (SCD40, ¥2,200) -> WiFi -> dashboard or notification
- Sensor accuracy: ±(50ppm + 5%), measurement range 400-2000 ppm, plus simultaneous temperature/humidity readings
- Applications: Meeting room occupancy management, ventilation timing alerts
- Source: https://westgate-lab.hatenablog.com/entry/2020/04/01/224511

#### BLE presence detection (occupancy / room presence management)

- Setup: Atom Lite (ESPHome) -> Home Assistant + Bermuda / ESPresence integration
- Mechanism: An Atom Lite is placed in each room as a BLE proxy, and presence is determined from smartphone or BLE tag signals
- Accuracy: Presence determined at room/floor level (seat-level precision is difficult)
- Cost: One Atom Lite (¥1,400) covers one room's worth of sensor coverage
- Source: https://community.home-assistant.io/t/espresence-with-m5atom-all-kinds-m5stack-official-atom-lite-esp32/603361

#### Automatic HVAC / lighting control via IR remote

- Setup: Atom Lite (built-in IR LED) -> WiFi -> Web API -> Alexa / smart home hub
- Highlight: The IRremoteESP8266 library supports air conditioners from major manufacturers
- Applications: Turning off AC in unoccupied meeting rooms, timer-linked power savings
- Source: https://iot-gym.com/how-to-send-ir-signals-by-using-m5atom/

---

### 🚛 Logistics / fleet management

**GPS logger**

- Setup: Atom Lite + GPS Unit -> SD card or WiFi transmission
- Applications: Delivery vehicle position logging, tracking movement of construction equipment and high-value assets
- GitHub: https://github.com/lavrinenkoa/GPSAtom (open source, 4 stars)

---

### 🔌 Industrial equipment / PLC integration

**Data collection via RS485 / Modbus RTU**

- Setup: Atom Lite + Atomic RS485 Base (built-in 12V->5V conversion) -> Modbus RTU
- Highlight: Enables IoT connectivity for PLCs, inverters, and industrial sensors without replacing them
- Track record: Multiple factory-environment implementation reports on the M5Stack Community
- Source: https://community.m5stack.com/topic/2136/atom-switch-modbus

---

### ☁️ Cloud integration

| Platform | Status | Purpose |
|---|---|---|
| Azure IoT Central | Implementation confirmed in 2024 | Centralized sensor data management for large enterprises |
| Ambient | Many implementation examples | Low-cost cloud dashboard |
| SORACOM | Listed as an IoT recipe | Data collection with threshold alerts |
| Home Assistant | Most common case | No-code integration via ESPHome |

---

## Sensor / module compatibility table

| Category | Module | Main business use |
|---|---|---|
| Temperature/humidity/pressure | ENV III (SHT30+QMP6988) | Farms, warehouses, food management |
| CO2 | CO2 Unit (SCD40) | Office ventilation management, infection control |
| Proximity/magnetic | Omron GLS, etc. | Machine operation monitoring |
| RS485 | Atomic RS485 Base | PLC / industrial equipment integration |
| GPS | GPS Unit | Vehicle / asset tracking |
| IR (built-in) | Built-in IR LED | HVAC / lighting control |
| BLE (built-in) | Built-in BLE | Occupancy / presence management |
| LoRaWAN | DTU LoRaWAN Kit | Remote outdoor monitoring (agriculture / fields) |

---

## Areas not found in research (gaps)

- **Medical / healthcare**: No direct case studies found (likely still at the prototype stage due to medical device regulations)
- **Aquaculture (pH / dissolved oxygen)**: Technically feasible, but no confirmed Atom Lite case studies
- **Logistics warehouse inventory counting**: Theoretical implementations using BLE tag tracking exist, but no confirmed reports of production use

---

## Related examples

| Example | Description |
|---|---|
| `examples/01_button_led/` | LED green<->red on button press |
| `examples/04_espnow_webserver/` | Status display via ESP-NOW + WebServer + SSE |
| `examples/05_display_base/` | ON/OFF display on button press via Atomic Display Base (HDMI) |
