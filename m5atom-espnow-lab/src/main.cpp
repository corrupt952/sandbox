// Step 3: ESP-NOW send (Basic V2.7 side)
// Cycle through A=Free / B=Busy / C=Away with the buttons and send the status

#include <M5Unified.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include "shared.h"

uint8_t atomMac[] = ATOM_MAC_AP;
uint8_t currentStatus = STATUS_HIMA;

void onSent(const uint8_t *mac, esp_now_send_status_t status) {
    Serial.printf("Send: %s\n",
        status == ESP_NOW_SEND_SUCCESS ? "success" : "failure");
}

void sendStatus(uint8_t status) {
    currentStatus = status;
    Payload p = {status};
    esp_now_send(atomMac, (uint8_t*)&p, sizeof(p));

    // Update the screen
    M5.Display.fillScreen(BLACK);
    M5.Display.setTextSize(3);
    M5.Display.setCursor(0, 80);
    M5.Display.println(STATUS_LABELS[status]);
    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 200);
    M5.Display.println("A:Free  B:Busy  C:Away");

    Serial.printf("Send: %s\n", STATUS_LABELS[status]);
}

void setup() {
    auto cfg = M5.config();
    M5.begin(cfg);
    delay(500);

    // Lock to channel 1
    WiFi.mode(WIFI_STA);
    WiFi.disconnect();
    esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);

    if (esp_now_init() != ESP_OK) {
        Serial.println("ESP-NOW init failed");
        M5.Display.println("ESP-NOW FAIL");
        return;
    }
    esp_now_register_send_cb(onSent);

    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, atomMac, 6);
    peer.channel = ESPNOW_CHANNEL;
    peer.encrypt = false;
    esp_now_add_peer(&peer);

    // Initial display
    M5.Display.fillScreen(BLACK);
    M5.Display.setTextSize(3);
    M5.Display.setCursor(0, 80);
    M5.Display.println(STATUS_LABELS[0]);
    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 200);
    M5.Display.println("A:Free  B:Busy  C:Away");

    // Send the current status on startup
    sendStatus(0);

    Serial.println("Ready!");
}

void loop() {
    M5.update();

    if (M5.BtnA.wasPressed()) sendStatus(0);  // Free
    if (M5.BtnB.wasPressed()) sendStatus(1);  // Busy
    if (M5.BtnC.wasPressed()) sendStatus(2);  // Away
}
