# ESP-NOW Advanced Feature Notes

Research date: 2026-02-27
Sources surveyed: Espressif official docs / GitHub / Qiita / Zenn / ESP32 Forum

---

## Summary

- ESP-NOW isn't just for communication — it can also support **RSSI-based proximity detection, tx-power control, and RTT-based quality monitoring**
- RSSI-based distance estimation is **good enough for zone classification (near/medium/far)** but not cm-level precision
- RTT (5-8 ms) **isn't usable for distance estimation**, but it's useful for detecting changes in radio quality
- Reducing tx power (`esp_wifi_set_max_tx_power`) lets you **artificially design entry/exit zones**
- ESP-NOW is best suited for **low-latency, low-power** LAN use cases; if you need wide-area coverage or high throughput, use ESP-Mesh-Lite instead

---

## 1. Distance estimation and proximity detection via RSSI

### Differences in the recv callback across IDF versions

The ESP-NOW receive callback signature changed going from IDF 4.x to 5.x.

| Framework | Callback signature | RSSI available |
|---|---|---|
| Arduino ESP32 2.x (IDF 4.x) | `(const uint8_t *mac, const uint8_t *data, int len)` | No |
| Arduino ESP32 3.x (IDF 5.x) | `(const esp_now_recv_info_t *info, const uint8_t *data, int len)` | **Yes** |

With Arduino ESP32 3.x (the latest version currently installed via PlatformIO), you can get the RSSI from the `rx_ctrl->rssi` field of `esp_now_recv_info_t`.

> Source: [ESP-IDF Programming Guide v5.5.3 - ESP-NOW](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/network/esp_now.html), [GitHub Issue #7992](https://github.com/espressif/arduino-esp32/issues/7992) (closed 2025-01-16)

```cpp
// Getting RSSI under IDF 5.x / Arduino ESP32 3.x (using esp_now.h directly)
#include <esp_now.h>

static void onReceive(const esp_now_recv_info_t *info,
                      const uint8_t *data, int len) {
    int8_t rssi = info->rx_ctrl->rssi;
    // rssi is a negative value (e.g. -45, -72, etc.)
}

// Registration stays the same
esp_now_register_recv_cb(onReceive);
```

> **Note**: The code currently in this repository (node/main.cpp, hub/main.cpp) still uses the old signature.
> Using `esp_now_recv_info_t` requires updating the callback signature.

---

### Distance calculation formula

Converting RSSI to distance uses the **log-distance path loss model**.

```
d = 10 ^ ((TxPower - RSSI) / (10 × n))
```

| Parameter | Description | Typical value |
|---|---|---|
| `TxPower` | RSSI at 1 m (calibration value) | -50 to -60 dBm (ESP32) |
| `RSSI` | Received signal strength | Negative value |
| `n` | Propagation environment parameter | Outdoor 2.0 / Indoor 2.7-4.0 |

```cpp
float rssiToDistance(int8_t rssi, int8_t txPower = -55, float n = 2.7f) {
    return powf(10.0f, (txPower - rssi) / (10.0f * n));
}
```

> Source: [Estimating distance to a beacon from RSSI and TxPower - Qiita](https://qiita.com/shu223/items/7c4e87c47eca65724305)

---

### Practical accuracy and caveats

- **Good enough for zone classification (near/medium/far)**: error of roughly ±1-3 m
- **Not cm-level precision**: walls, bodies, and multipath fading cause ±30-40% deviation
- **Smoothing with a Kalman filter** significantly reduces noise
- BLE measurements also report large device-to-device variance; ESP-NOW shows a similar tendency

```cpp
// Simple zone classification (calibration required)
const char* rssiToZone(int8_t rssi) {
    if (rssi > -50) return "NEAR";    // ~1m
    if (rssi > -65) return "MEDIUM";  // 1-5m
    return "FAR";                     // 5m+
}
```

---

## 2. RTT (round-trip time) measurement

### Measured values

| Condition | RTT |
|---|---|
| Typical (ESP32 <-> ESP32) | **5,400-7,500 μs (5-8 ms)** |
| With AMPDU TX/RX disabled | ~689 μs (best case) |
| Measured on ESP8266 | 7-11 ms (for reference) |

> Source: [ESP32 Forum: ESPNOW Slower than expected RTT](https://www.esp32.com/viewtopic.php?t=9965), [GitHub: ESP32_ESPIDF_ESPNOW](https://github.com/leonyuhanov/ESP32_ESPIDF_ESPNOW)

---

### Why RTT is unsuitable for distance estimation

At the speed of light (3×10⁸ m/s), 1 ms corresponds to 300 km.
Since ESP32's processing delay alone is already 5-8 ms, **the physical distance component is buried in the error and not practically usable**.

---

### Using it to monitor radio quality

A more realistic use is: "we can't tell the distance, but we can tell when quality **changes**."

```cpp
// Record millis() when sending PING, then take the diff when PONG is received
uint32_t pingSentAt = 0;

// Sending PING
pingSentAt = millis();
PairingMsg msg = {MSG_PING};
esp_now_send(targetMac, (uint8_t*)&msg, sizeof(msg));

// In the PONG receive callback
uint32_t rtt = millis() - pingSentAt;
// A sudden increase in rtt -> radio quality is degrading
```

---

## 3. Tx power control

### API

```cpp
#include <esp_wifi.h>

// Unit is 0.25 dBm (value = dBm × 4)
// 80 → 20 dBm (max)
// 20 → 5 dBm
//  4 → 1 dBm
esp_wifi_set_max_tx_power(20);  // Set to 5 dBm
```

> Source: [ESP Wireless Transmission Power Configuration - ESP-Techpedia](https://docs.espressif.com/projects/esp-techpedia/en/latest/esp-friends/advanced-development/performance/modify-tx-power.html)

---

### dBm vs approximate range

| Setting | Actual dBm | Approx. indoor range | Use case |
|---|---|---|---|
| 80 | 20 dBm | ~50 m (max) | Wide-area pairing |
| 40 | 10 dBm | ~20 m | Normal |
| 20 | 5 dBm | ~5 m | Proximity zone design |
| 8  | 2 dBm | ~2 m | Entry/exit detection |

> Actual range varies significantly with antenna, obstacles, and interference. On-device calibration is required.

---

### Implementation pattern for zone design

Lowering the Hub's tx power creates an area where "you must be close to the Hub to pair."

```cpp
// Inside setup()
WiFi.mode(WIFI_STA);
WiFi.disconnect();
esp_wifi_set_channel(PAIRING_CHANNEL, WIFI_SECOND_CHAN_NONE);
esp_wifi_set_max_tx_power(20);  // 5 dBm -> reaches only about 3-5m
```

---

## 4. Liveness monitoring / online node detection

Combining the existing PING All + PONG mechanism with timeout detection is enough to build liveness monitoring.

```cpp
// Record the last PONG received time per node
uint32_t lastSeen[MAX_PAIRED_NODES] = {};

// On PONG received
for (int i = 0; i < pairedCount; i++) {
    if (memcmp(pairedMacs[i], mac, 6) == 0) {
        lastSeen[i] = millis();
    }
}

// Periodic check (inside loop())
uint32_t now = millis();
for (int i = 0; i < pairedCount; i++) {
    bool online = (now - lastSeen[i]) < 30000;  // within 30 seconds
    // -> reflect on the LCD or in logs
}
```

---

## 5. ESP-NOW vs other protocols

| | **ESP-NOW** | **ESP-Mesh-Lite** | **ESP-BLE-Mesh** | **ZigBee** |
|---|---|---|---|---|
| Latency | **< 10 ms** | < 100 ms | 50-100 ms | 10-16 ms |
| Throughput | < 0.5 Mbps | **20 Mbps** | < 1 Kbps | 16.9 Kbps |
| Range | 150-300 m | < 100 m | 50 m (per node) | **300 m** |
| Power consumption | **Low** | Higher | Low | Low |
| Max peer count | 20 | Many | Many | Many |
| Multi-hop | Manual implementation | **Automatic** | Automatic | Automatic |
| Primary use | Low-latency LAN control | High-bandwidth IoT | Smart home | Sensor networks |

> Source: [ESP-Techpedia: Comparison of Different Mesh Solutions](https://docs.espressif.com/projects/esp-techpedia/en/latest/esp-friends/solution-introduction/mesh/mesh-comparison.html)

**Selection guidelines:**
- Prioritize response speed (game controllers, remotes, custom keyboards) -> **ESP-NOW**
- Wide-area sensor networks -> **ZigBee / Thread**
- Large-volume data transfer -> **ESP-Mesh-Lite**
- Smart-home standard compatibility -> **ESP-BLE-Mesh / Matter**

---

## 6. Other supplementary features

### Time synchronization (simplified PTP)

A simple implementation is possible where the Hub obtains the time via NTP and broadcasts it to all nodes.
Accuracy is NTP accuracy + ESP-NOW latency (~5ms).

```cpp
// Hub: add a timestamp to the payload
struct TimeMsg {
    uint8_t  type;       // new MSG_TIME_SYNC = 0x20
    uint32_t timestamp;  // Unix time (seconds)
    uint32_t millis_us;  // ms for correction
};
```

> Source: [ESP32 Forum: ESP-NOW time synchronization](https://www.esp32.com/viewtopic.php?t=18644)

---

### Multi-hop relaying (manual implementation)

ESP-NOW itself has no multi-hop support, but it can be simulated with a **relay node** pattern.

```
Hub ─ ESP-NOW ─► Relay Node ─ ESP-NOW ─► Far Node
```

The relay node simply re-sends the received packet via `esp_now_send()`.
However, this **doubles the latency** (typically 10-16 ms), and you need to watch out for loops involving the same packet.

---

### LONG RANGE mode (up to 1 km)

Enabling LR (Long Range) mode via `esp_wifi_set_protocol()` theoretically extends the range to
up to 1 km with a clear line of sight (normal mode is 200-300 m).
However, this **significantly reduces throughput**, and both the Hub and Node need their settings updated.

```cpp
esp_wifi_set_protocol(WIFI_IF_STA,
    WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G |
    WIFI_PROTOCOL_11N | WIFI_PROTOCOL_LR);
```

> Source: [XIAOGYAN Talkie article - Qiita](https://qiita.com/pokibon/items/f8b4164c8c2484c28483)

---

## Related example

| Example | Description |
|---|---|
| `examples/06_espnow_pairing/` | A pairing system implementing RSSI retrieval, liveness monitoring, and PING/PONG |

---

## Things worth trying next

1. **Add RSSI-based proximity detection**: update the callback to use `esp_now_recv_info_t` and show each node's RSSI on the Hub's screen
2. **Liveness monitoring**: show "⚠ offline" for nodes with no response for 30 seconds
3. **Tx-power zones**: lower the tx power only during pairing mode, requiring you to be right next to the Hub to pair
