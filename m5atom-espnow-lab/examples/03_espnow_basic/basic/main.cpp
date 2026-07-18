// Step 2: ESP-NOW send test (Basic V2.7 side)
// Pressing buttons A/B/C sends a value to the Atom Lite

#include <M5Unified.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>

// Atom Lite's MAC address (AP-mode MAC)
uint8_t atomMac[] = {0x14, 0x08, 0x08, 0x54, 0xE8, 0x45};  // AP-mode MAC

// Sent data structure (must match the receiver's definition)
struct Payload {
    uint8_t value;
};

void onSent(const uint8_t *mac, esp_now_send_status_t status) {
    Serial.printf("Send result: %s\n",
        status == ESP_NOW_SEND_SUCCESS ? "success" : "failure");
}

void sendValue(uint8_t val) {
    Payload p = {val};
    esp_err_t result = esp_now_send(atomMac, (uint8_t*)&p, sizeof(p));
    if (result != ESP_OK) {
        Serial.println("esp_now_send error");
    }
}

void setup() {
    auto cfg = M5.config();
    M5.begin(cfg);
    delay(500);

    // Match the same channel 1 as the Atom Lite
    WiFi.mode(WIFI_STA);
    WiFi.disconnect();
    esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);

    Serial.println("ESP-NOW sender started");

    if (esp_now_init() != ESP_OK) {
        Serial.println("ESP-NOW init failed");
        M5.Display.println("ESP-NOW FAIL");
        return;
    }

    esp_now_register_send_cb(onSent);

    // Register the Atom Lite as a peer
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, atomMac, 6);
    peer.channel = 1;
    peer.encrypt = false;
    if (esp_now_add_peer(&peer) != ESP_OK) {
        Serial.println("Peer registration failed");
        M5.Display.println("PEER FAIL");
        return;
    }

    M5.Display.setTextSize(2);
    M5.Display.println("ESP-NOW Ready!");
    M5.Display.setTextSize(1);
    M5.Display.println("");
    M5.Display.println("A: value=1 (green)");
    M5.Display.println("B: value=2 (red)");
    M5.Display.println("C: value=3 (blue)");

    Serial.println("Ready! Press A/B/C buttons to send");
}

void loop() {
    M5.update();

    if (M5.BtnA.wasPressed()) {
        Serial.println("A pressed -> sending value=1");
        sendValue(1);
    }
    if (M5.BtnB.wasPressed()) {
        Serial.println("B pressed -> sending value=2");
        sendValue(2);
    }
    if (M5.BtnC.wasPressed()) {
        Serial.println("C pressed -> sending value=3");
        sendValue(3);
    }
}
