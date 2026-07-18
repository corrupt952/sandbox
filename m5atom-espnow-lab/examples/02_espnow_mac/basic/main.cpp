// Step 1: Check the Basic V2.7's MAC address
// Print the MAC address needed for ESP-NOW pairing to serial and the display

#include <M5Unified.h>
#include <WiFi.h>

void setup() {
    auto cfg = M5.config();
    M5.begin(cfg);
    delay(500);

    WiFi.mode(WIFI_MODE_STA);
    String mac = WiFi.macAddress();

    // Print to serial
    Serial.println("=== Basic V2.7 MAC Address ===");
    Serial.println(mac);
    Serial.println("==============================");

    // Show on the display
    M5.Display.setTextSize(2);
    M5.Display.println("MAC Address:");
    M5.Display.setTextSize(1);
    M5.Display.println(mac);
}

void loop() {
    // Do nothing
}
