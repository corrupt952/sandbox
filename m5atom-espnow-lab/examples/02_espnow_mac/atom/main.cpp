// Step 1: Check the Atom Lite's MAC address
// Print the MAC address needed for ESP-NOW pairing over serial

#include <M5Atom.h>
#include <WiFi.h>

void setup() {
    M5.begin(true, false, true);
    delay(500);

    // Get and print the MAC address
    WiFi.mode(WIFI_MODE_STA);
    String mac = WiFi.macAddress();

    Serial.println("=== Atom Lite MAC Address ===");
    Serial.println(mac);
    Serial.println("=============================");
    Serial.println("Write this MAC address into the Basic V2.7 side code");

    // Light the LED blue to show readiness
    M5.dis.drawpix(0, 0x0000FF);
}

void loop() {
    // Do nothing
}
