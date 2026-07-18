// Step 2: ESP-NOW receive test (Atom Lite side)
// Receives packets from Basic V2.7 and shows them via the LED

#include <M5Atom.h>
#include <WiFi.h>
#include <esp_now.h>

// Received data structure (must match the sender's definition)
struct Payload {
    uint8_t value;
};

void onReceive(const uint8_t *mac, const uint8_t *data, int len) {
    Payload p;
    memcpy(&p, data, sizeof(p));

    Serial.printf("Received! from %02X:%02X:%02X:%02X:%02X:%02X  value=%d\n",
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], p.value);

    // Change the LED based on the received value
    switch (p.value) {
        case 1:  M5.dis.drawpix(0, 0x00FF00); break;  // green
        case 2:  M5.dis.drawpix(0, 0xFF0000); break;  // red
        case 3:  M5.dis.drawpix(0, 0x0000FF); break;  // blue
        default: M5.dis.drawpix(0, 0xFFFFFF); break;  // white
    }
}

void setup() {
    M5.begin(true, false, true);
    delay(500);

    // ESP-NOW is more stable with a fixed channel in AP mode
    WiFi.mode(WIFI_AP);
    WiFi.softAP("espnow-test", "password", 1);  // locked to channel 1

    Serial.println("Waiting for ESP-NOW packets...");
    Serial.printf("Atom Lite MAC: %s\n", WiFi.softAPmacAddress().c_str());

    if (esp_now_init() != ESP_OK) {
        Serial.println("ESP-NOW init failed");
        M5.dis.drawpix(0, 0xFF0000);
        return;
    }

    esp_now_register_recv_cb(onReceive);

    // Yellow while waiting
    M5.dis.drawpix(0, 0xFFFF00);
    Serial.println("Ready!");
}

void loop() {
    M5.update();
}
