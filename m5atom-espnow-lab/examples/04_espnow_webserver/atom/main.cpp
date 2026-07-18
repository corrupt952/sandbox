// Step 3: ESP-NOW receive + web server + SSE (Atom Lite side)
// Reflects the status from Basic V2.7 to the browser in real time

#include <M5Atom.h>
#include <WiFi.h>
#include <esp_now.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include "shared.h"

// AP settings
const char* AP_SSID = "StatusBoard";
const char* AP_PASS = "12345678";

// LED colors (in STATUS_HIMA / SODAN / RISEKI order)
const uint32_t STATUS_COLORS[] = {0x00FF00, 0xFF8000, 0xFF0000};  // green/orange/red

uint8_t currentStatus = STATUS_HIMA;

AsyncWebServer server(80);
AsyncEventSource events("/events");

// HTML page (updated in real time via SSE)
const char HTML[] PROGMEM = R"(<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Status Board</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      background: #111;
      font-family: sans-serif;
    }
    #status {
      font-size: 20vw;
      font-weight: bold;
      color: white;
      text-align: center;
      transition: all 0.3s ease;
    }
  </style>
</head>
<body>
  <div id="status">...</div>
  <script>
    const labels = ['Free', 'Busy', 'Away'];
    const colors = ['#00cc00', '#ff8800', '#ff2200'];

    const source = new EventSource('/events');
    source.addEventListener('status', function(e) {
      const i = parseInt(e.data);
      const el = document.getElementById('status');
      el.textContent = labels[i];
      el.style.color = colors[i];
      document.body.style.background = colors[i] + '22';
    });

    source.onerror = function() {
      console.log('SSE connection error, reconnecting...');
    };
  </script>
</body>
</html>
)";

// Payload is defined in shared.h

void onReceive(const uint8_t *mac, const uint8_t *data, int len) {
    Payload p;
    memcpy(&p, data, sizeof(p));

    if (p.status >= STATUS_COUNT) return;  // Ignore invalid values
    currentStatus = p.status;

    Serial.printf("Received: status=%d (%s)\n", p.status, STATUS_LABELS[p.status]);

    // Update LED
    M5.dis.drawpix(0, STATUS_COLORS[p.status]);

    // Push to the browser via SSE
    events.send(String(p.status).c_str(), "status", millis());
}

void setup() {
    M5.begin(true, false, true);
    delay(500);

    // Start AP (locked to channel 1)
    WiFi.mode(WIFI_AP);
    WiFi.softAP(AP_SSID, AP_PASS, 1);

    Serial.println("AP started");
    Serial.printf("SSID: %s\n", AP_SSID);
    Serial.printf("IP:   %s\n", WiFi.softAPIP().toString().c_str());
    Serial.printf("MAC:  %s\n", WiFi.softAPmacAddress().c_str());

    // Initialize ESP-NOW
    if (esp_now_init() != ESP_OK) {
        Serial.println("ESP-NOW init failed");
        M5.dis.drawpix(0, 0xFF0000);
        return;
    }
    esp_now_register_recv_cb(onReceive);

    // Set up the web server
    events.onConnect([](AsyncEventSourceClient *client) {
        // Send the current status on connect
        client->send(String(currentStatus).c_str(), "status", millis());
    });
    server.addHandler(&events);

    server.on("/", HTTP_GET, [](AsyncWebServerRequest *req) {
        req->send(200, "text/html", HTML);
    });

    server.begin();
    Serial.println("Web server started");
    Serial.println("Ready!");

    // Green (Free) on startup
    M5.dis.drawpix(0, STATUS_COLORS[0]);
}

void loop() {
    M5.update();
}
