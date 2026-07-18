// ESP-NOW pairing - Node side (Atom Lite)
// On boot: red LED (unpaired) / green LED (paired)
// Short button press (unpaired): broadcast PAIR_REQUEST -> blue blink
// Short button press (paired): send PING to the Hub
// Short button press (waiting during buzzer-quiz): send BUZZ -> orange LED
// Long press 3s (paired): reset pairing

#include <M5Atom.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <Preferences.h>
#include "../pairing.h"

static const uint8_t BROADCAST_MAC[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

// State
enum NodeState { STATE_UNPAIRED, STATE_PAIRING, STATE_PAIRED, STATE_HAYAOSHI };
static NodeState nodeState = STATE_UNPAIRED;

// Hub's MAC address (saved after pairing)
static uint8_t hubMac[6] = {};
static bool hubMacValid = false;

// Pairing start time (for timeout)
static unsigned long pairingStartTime = 0;
static const unsigned long PAIRING_TIMEOUT_MS = 10000;

// Flags set in callbacks and consumed by the main loop
static volatile bool flagPairConfirmed = false;
static volatile bool flagPingReceived  = false;
static volatile bool flagPongReceived  = false;
static volatile bool flagHayaoshiStart = false;
static volatile bool flagHayaoshiReset = false;
static volatile bool flagRandomPick    = false;
static uint8_t pendingHubMac[6] = {};
static uint8_t pongSrc[6]       = {};

// Long-press control
static bool longPressTriggered = false;

// LED flash timer (0 means inactive)
static unsigned long ledRestoreAt = 0;

// Buzzer-quiz control
static unsigned long hayaoshiStartTime = 0;
static bool hayaoshiBuzzed = false;

static Preferences prefs;

// ────────────────────────────────────────────────
// Utilities
// ────────────────────────────────────────────────

static void setLED(uint32_t color) {
    M5.dis.drawpix(0, color);
}

static void registerPeer(const uint8_t *mac) {
    if (esp_now_is_peer_exist(mac)) return;
    esp_now_peer_info_t p = {};
    memcpy(p.peer_addr, mac, 6);
    p.channel = PAIRING_CHANNEL;
    p.encrypt = false;
    esp_now_add_peer(&p);
}

static void saveToNVS() {
    prefs.putBytes("hub_mac", hubMac, 6);
    prefs.putBool("paired", true);
}

static void clearNVS() {
    prefs.clear();
}

// ────────────────────────────────────────────────
// ESP-NOW callbacks
// ────────────────────────────────────────────────

static void onReceive(const uint8_t *mac, const uint8_t *data, int len) {
    if (len < (int)sizeof(PairingMsg)) return;
    PairingMsg msg;
    memcpy(&msg, data, sizeof(msg));

    switch (msg.type) {
        case MSG_PAIR_CONFIRM:
            if (nodeState == STATE_PAIRING) {
                memcpy(pendingHubMac, mac, 6);
                flagPairConfirmed = true;
            }
            break;
        case MSG_PING:
            memcpy(pongSrc, mac, 6);
            flagPingReceived = true;
            break;
        case MSG_PONG:
            flagPongReceived = true;
            break;
        case MSG_HAYAOSHI_START:
            flagHayaoshiStart = true;
            break;
        case MSG_HAYAOSHI_RESET:
            flagHayaoshiReset = true;
            break;
        case MSG_RANDOM_PICK:
            flagRandomPick = true;
            break;
        default:
            break;
    }
}

// ────────────────────────────────────────────────
// Setup
// ────────────────────────────────────────────────

void setup() {
    M5.begin(true, false, true);
    delay(100);

    prefs.begin("pairing", false);

    // Restore pairing info from NVS
    if (prefs.getBool("paired", false)) {
        prefs.getBytes("hub_mac", hubMac, 6);
        hubMacValid = true;
        nodeState = STATE_PAIRED;
    }

    // Initialize WiFi + ESP-NOW
    WiFi.mode(WIFI_STA);
    WiFi.disconnect();
    esp_wifi_set_channel(PAIRING_CHANNEL, WIFI_SECOND_CHAN_NONE);

    if (esp_now_init() != ESP_OK) {
        Serial.println("ESP-NOW init failed");
        setLED(0xFF0000);
        return;
    }
    esp_now_register_recv_cb(onReceive);

    // Register the broadcast peer (used to send PAIR_REQUEST)
    registerPeer(BROADCAST_MAC);

    // If already paired, also register the Hub peer
    if (hubMacValid) {
        registerPeer(hubMac);
        setLED(0x00FF00);  // green
        Serial.println("Already paired. LED: green");
    } else {
        setLED(0xFF0000);  // red
        Serial.println("Not paired. LED: red");
    }
}

// ────────────────────────────────────────────────
// Main loop
// ────────────────────────────────────────────────

void loop() {
    M5.update();

    // ── Handle callback flags ──────────────────

    if (flagPairConfirmed) {
        flagPairConfirmed = false;
        memcpy(hubMac, pendingHubMac, 6);
        hubMacValid = true;
        nodeState = STATE_PAIRED;
        registerPeer(hubMac);
        saveToNVS();
        setLED(0x00FF00);  // green
        Serial.println("Pairing confirmed! LED: green");
    }

    if (flagPingReceived) {
        flagPingReceived = false;
        // Send PONG back to the Hub
        if (hubMacValid) {
            PairingMsg msg = {MSG_PONG};
            esp_now_send(hubMac, (uint8_t*)&msg, sizeof(msg));
        }
        setLED(0xFFFFFF);  // white (feedback)
        ledRestoreAt = millis() + 1000;
        Serial.println("PING received -> PONG sent.");
    }

    if (flagPongReceived) {
        flagPongReceived = false;
        setLED(0xFFFFFF);  // white (feedback)
        ledRestoreAt = millis() + 1000;
        Serial.println("PONG received.");
    }

    if (flagHayaoshiStart) {
        flagHayaoshiStart = false;
        if (nodeState == STATE_PAIRED) {
            nodeState = STATE_HAYAOSHI;
            hayaoshiBuzzed = false;
            hayaoshiStartTime = millis();
            Serial.println("Hayaoshi started!");
        }
    }

    if (flagHayaoshiReset) {
        flagHayaoshiReset = false;
        if (nodeState == STATE_HAYAOSHI) {
            nodeState = STATE_PAIRED;
            hayaoshiBuzzed = false;
            ledRestoreAt = 0;
            setLED(0x00FF00);  // green
            Serial.println("Hayaoshi reset.");
        }
    }

    if (flagRandomPick) {
        flagRandomPick = false;
        setLED(0xFF00FF);  // magenta (random pick)
        ledRestoreAt = millis() + 3000;
        Serial.println("Random pick! LED: magenta 3s");
    }

    // Check whether the LED flash has ended
    if (ledRestoreAt > 0 && millis() >= ledRestoreAt) {
        ledRestoreAt = 0;
        if (nodeState == STATE_PAIRED) {
            setLED(0x00FF00);  // green
        } else if (nodeState == STATE_UNPAIRED) {
            setLED(0xFF0000);  // red
        }
        // STATE_HAYAOSHI is updated by the blink loop on the next frame
    }

    // ── Handle buttons (short press / long press) ──

    // Long press (3s): reset pairing
    if (M5.Btn.pressedFor(3000) && nodeState == STATE_PAIRED) {
        longPressTriggered = true;
        esp_now_del_peer(hubMac);
        memset(hubMac, 0, 6);
        hubMacValid = false;
        nodeState = STATE_UNPAIRED;
        clearNVS();
        setLED(0xFF0000);  // red
        Serial.println("Pairing reset. LED: red");
    }

    // Short press (detected on release, ignored after a long press)
    if (M5.Btn.wasReleased()) {
        if (!longPressTriggered) {
            if (nodeState == STATE_UNPAIRED) {
                // Send a pairing request
                nodeState = STATE_PAIRING;
                pairingStartTime = millis();
                PairingMsg msg = {MSG_PAIR_REQUEST};
                esp_now_send(BROADCAST_MAC, (uint8_t*)&msg, sizeof(msg));
                Serial.println("PAIR_REQUEST sent.");
            } else if (nodeState == STATE_PAIRED) {
                // Send PING to the Hub (manual connectivity check)
                PairingMsg msg = {MSG_PING};
                esp_now_send(hubMac, (uint8_t*)&msg, sizeof(msg));
                Serial.println("PING sent to hub.");
            } else if (nodeState == STATE_HAYAOSHI) {
                // Buzz-in button
                if (!hayaoshiBuzzed && hubMacValid) {
                    PairingMsg msg = {MSG_HAYAOSHI_BUZZ};
                    esp_now_send(hubMac, (uint8_t*)&msg, sizeof(msg));
                    hayaoshiBuzzed = true;
                    setLED(0xFF8000);  // orange (already buzzed)
                    ledRestoreAt = 0;  // clear the blink timer
                    Serial.println("BUZZ sent!");
                }
            }
        }
        longPressTriggered = false;
    }

    // ── LED blink & timeout while pairing ──

    if (nodeState == STATE_PAIRING) {
        unsigned long elapsed = millis() - pairingStartTime;
        if (elapsed > PAIRING_TIMEOUT_MS) {
            nodeState = STATE_UNPAIRED;
            setLED(0xFF0000);  // red
            Serial.println("Pairing timeout.");
        } else {
            // Blue blink (500ms cycle)
            setLED((elapsed % 500 < 250) ? 0x0000FF : 0x000000);
        }
    }

    // ── Yellow LED blink while waiting for buzzer-quiz ──

    if (nodeState == STATE_HAYAOSHI && !hayaoshiBuzzed) {
        unsigned long elapsed = millis() - hayaoshiStartTime;
        setLED((elapsed % 300 < 150) ? 0xFFFF00 : 0x000000);
    }

    delay(20);
}
