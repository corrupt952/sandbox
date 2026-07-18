// ESP-NOW pairing - Hub side (Basic V2.7)
// Menu operation: A:up  B:select  C:down
//
// Normal screen: paired node list + 5-item menu
//   PING All    ... connectivity check to all nodes
//   Pairing Mode... wait for pairing (B to exit)
//   Clear All   ... delete all pairings (with confirmation)
//   Hayaoshi    ... buzzer-quiz game (only online nodes participate)
//   Random Pick ... random pick (only among online nodes)
//
// Pairing confirmation: B:accept / A or C:cancel

#include <M5Unified.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <Preferences.h>
#include "../pairing.h"

static const uint8_t BROADCAST_MAC[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

// Paired devices
static uint8_t pairedMacs[MAX_PAIRED_NODES][6];
static int     pairedCount = 0;

// State
enum HubState {
    STATE_NORMAL,
    STATE_PAIRING_WAIT,
    STATE_PAIRING_CONFIRM,
    STATE_CLEAR_CONFIRM,
    STATE_ONLINE_CHECK,       // online check before a game
    STATE_HAYAOSHI_WAITING,   // waiting during buzzer-quiz
    STATE_HAYAOSHI_RESULT,    // showing buzzer-quiz result
    STATE_RANDOM_RESULT       // showing random pick result
};
static HubState hubState = STATE_NORMAL;

// Menu
enum MenuItem { MENU_PING = 0, MENU_PAIRING, MENU_CLEAR_ALL, MENU_HAYAOSHI, MENU_RANDOM_PICK, MENU_COUNT };
static int menuCursor = 0;
static const char* MENU_LABELS[] = { "PING All", "Pairing Mode", "Clear All", "Hayaoshi", "Random Pick" };

// Flags set in callbacks and consumed by the main loop
static volatile bool flagPairRequest  = false;
static volatile bool flagPongReceived = false;
static volatile bool flagNodePing     = false;
static uint8_t pendingNodeMac[6] = {};
static uint8_t lastPongMac[6]    = {};
static uint8_t nodePingSrc[6]    = {};

// Online check
static bool nodeOnline[MAX_PAIRED_NODES] = {};
static unsigned long onlineCheckStartTime = 0;
static const unsigned long ONLINE_CHECK_MS = 2000;
static int pendingGameMode = -1;

// Buzzer quiz (hayaoshi)
static volatile bool flagHayaoshiBuzz  = false;
static uint8_t hayaoshiBuzzerMac[6]    = {};
static unsigned long hayaoshiStartTime = 0;
static const unsigned long HAYAOSHI_TIMEOUT_MS = 30000;

// Random pick
static uint8_t randomPickedMac[6] = {};

static Preferences prefs;

// ────────────────────────────────────────────────
// Utilities
// ────────────────────────────────────────────────

static String macToStr(const uint8_t *mac) {
    char buf[18];
    snprintf(buf, sizeof(buf), "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    return String(buf);
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
    prefs.putInt("count", pairedCount);
    char key[8];
    for (int i = 0; i < pairedCount; i++) {
        snprintf(key, sizeof(key), "mac%d", i);
        prefs.putBytes(key, pairedMacs[i], 6);
    }
}

static void loadFromNVS() {
    pairedCount = prefs.getInt("count", 0);
    char key[8];
    for (int i = 0; i < pairedCount; i++) {
        snprintf(key, sizeof(key), "mac%d", i);
        prefs.getBytes(key, pairedMacs[i], 6);
    }
}

static void clearAllPairings() {
    for (int i = 0; i < pairedCount; i++) {
        if (esp_now_is_peer_exist(pairedMacs[i])) {
            esp_now_del_peer(pairedMacs[i]);
        }
    }
    pairedCount = 0;
    prefs.clear();
}

static int getOnlineCount() {
    int cnt = 0;
    for (int i = 0; i < pairedCount; i++) {
        if (nodeOnline[i]) cnt++;
    }
    return cnt;
}

// ────────────────────────────────────────────────
// Screen drawing
// ────────────────────────────────────────────────

static void drawNormalScreen() {
    M5.Display.fillScreen(BLACK);
    M5.Display.setTextColor(WHITE, BLACK);

    // Header
    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 0);
    M5.Display.println("ESP-NOW Hub");

    M5.Display.setTextSize(1);
    M5.Display.printf("Paired: %d / %d nodes\n\n", pairedCount, MAX_PAIRED_NODES);

    // Node list (up to 5 entries)
    int showMax = min(pairedCount, 5);
    for (int i = 0; i < showMax; i++) {
        M5.Display.printf(" #%d %s\n", i, macToStr(pairedMacs[i]).c_str());
    }
    if (pairedCount > 5) {
        M5.Display.printf(" ...(%d more)\n", pairedCount - 5);
    }

    // Menu (highlight the cursor row)
    M5.Display.setCursor(0, 148);
    for (int i = 0; i < MENU_COUNT; i++) {
        if (i == menuCursor) {
            M5.Display.setTextColor(BLACK, CYAN);
            M5.Display.printf("> %-18s\n", MENU_LABELS[i]);
            M5.Display.setTextColor(WHITE, BLACK);
        } else {
            M5.Display.printf("  %-18s\n", MENU_LABELS[i]);
        }
    }

    // Button guide
    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, BLACK);
    M5.Display.print("A:UP  B:OK  C:DOWN");
    M5.Display.setTextColor(WHITE, BLACK);
}

static void drawPairingWaitScreen() {
    M5.Display.fillScreen(NAVY);
    M5.Display.setTextColor(WHITE, NAVY);

    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 40);
    M5.Display.println(">> PAIRING MODE");

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 90);
    M5.Display.println("Waiting for node...");
    M5.Display.println("");
    M5.Display.println("Press button on Atom Lite");

    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, NAVY);
    M5.Display.print("B:Exit");
    M5.Display.setTextColor(WHITE, NAVY);
}

static void drawPairingConfirmScreen(const uint8_t *mac) {
    M5.Display.fillScreen(NAVY);
    M5.Display.setTextColor(WHITE, NAVY);

    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 40);
    M5.Display.println(">> PAIRING MODE");

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 90);
    M5.Display.println("New node found!");
    M5.Display.println("");
    M5.Display.setTextSize(2);
    M5.Display.println(macToStr(mac));

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, NAVY);
    M5.Display.print("B:Accept   A/C:Cancel");
    M5.Display.setTextColor(WHITE, NAVY);
}

static void drawClearConfirmScreen() {
    M5.Display.fillScreen(MAROON);
    M5.Display.setTextColor(WHITE, MAROON);

    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 40);
    M5.Display.println("!! CONFIRM !!");

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 100);
    M5.Display.println("Delete all paired nodes?");
    M5.Display.printf("(%d nodes will be removed)\n", pairedCount);

    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, MAROON);
    M5.Display.print("B:Yes   A/C:No");
    M5.Display.setTextColor(WHITE, MAROON);
}

static void drawOnlineCheckScreen() {
    M5.Display.fillScreen(DARKCYAN);
    M5.Display.setTextColor(WHITE, DARKCYAN);

    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 40);
    M5.Display.println(">> CHECKING...");

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 90);
    M5.Display.println("Pinging all nodes...");
    M5.Display.printf("Waiting %d ms for PONG\n", (int)ONLINE_CHECK_MS);

    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, DARKCYAN);
    M5.Display.print("B:Cancel");
    M5.Display.setTextColor(WHITE, DARKCYAN);
}

static void drawHayaoshiWaitingScreen(int onlineCnt) {
    M5.Display.fillScreen(OLIVE);
    M5.Display.setTextColor(WHITE, OLIVE);

    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 40);
    M5.Display.println(">> HAYAOSHI");

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 90);
    M5.Display.printf("Online: %d nodes\n", onlineCnt);
    M5.Display.println("");
    M5.Display.println("Press button on Atom Lite!");

    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, OLIVE);
    M5.Display.print("B:Cancel");
    M5.Display.setTextColor(WHITE, OLIVE);
}

static void drawHayaoshiResultScreen(const uint8_t *mac) {
    M5.Display.fillScreen(DARKGREEN);
    M5.Display.setTextColor(WHITE, DARKGREEN);

    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 40);
    M5.Display.println("!! BUZZED !!");

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 90);
    M5.Display.println("Winner:");
    M5.Display.println("");
    M5.Display.setTextSize(2);
    M5.Display.println(macToStr(mac));

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, DARKGREEN);
    M5.Display.print("B:Reset");
    M5.Display.setTextColor(WHITE, DARKGREEN);
}

static void drawRandomResultScreen(const uint8_t *mac) {
    M5.Display.fillScreen(PURPLE);
    M5.Display.setTextColor(WHITE, PURPLE);

    M5.Display.setTextSize(2);
    M5.Display.setCursor(0, 40);
    M5.Display.println(">> RANDOM PICK");

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 90);
    M5.Display.println("Selected node:");
    M5.Display.println("");
    M5.Display.setTextSize(2);
    M5.Display.println(macToStr(mac));

    M5.Display.setTextSize(1);
    M5.Display.setCursor(0, 228);
    M5.Display.setTextColor(YELLOW, PURPLE);
    M5.Display.print("B:OK");
    M5.Display.setTextColor(WHITE, PURPLE);
}

// Shows a status message between the menu and button guide on the normal screen
static void showMessage(const String &msg) {
    M5.Display.fillRect(0, 212, 320, 12, BLACK);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(CYAN, BLACK);
    M5.Display.setCursor(0, 212);
    M5.Display.print(msg);
    M5.Display.setTextColor(WHITE, BLACK);
}

// ────────────────────────────────────────────────
// ESP-NOW callbacks
// ────────────────────────────────────────────────

static void onReceive(const uint8_t *mac, const uint8_t *data, int len) {
    if (len < (int)sizeof(PairingMsg)) return;
    PairingMsg msg;
    memcpy(&msg, data, sizeof(msg));

    switch (msg.type) {
        case MSG_PAIR_REQUEST:
            if (hubState == STATE_PAIRING_WAIT) {
                for (int i = 0; i < pairedCount; i++) {
                    if (memcmp(pairedMacs[i], mac, 6) == 0) return;
                }
                memcpy(pendingNodeMac, mac, 6);
                flagPairRequest = true;
            }
            break;
        case MSG_PONG:
            if (hubState == STATE_ONLINE_CHECK) {
                // During the online check: mark the matching node as online
                for (int i = 0; i < pairedCount; i++) {
                    if (memcmp(pairedMacs[i], mac, 6) == 0) {
                        nodeOnline[i] = true;
                        break;
                    }
                }
            } else {
                memcpy(lastPongMac, mac, 6);
                flagPongReceived = true;
            }
            break;
        case MSG_PING:
            memcpy(nodePingSrc, mac, 6);
            flagNodePing = true;
            break;
        case MSG_HAYAOSHI_BUZZ:
            // Only accept the first BUZZ
            if (hubState == STATE_HAYAOSHI_WAITING && !flagHayaoshiBuzz) {
                memcpy(hayaoshiBuzzerMac, mac, 6);
                flagHayaoshiBuzz = true;
            }
            break;
        default:
            break;
    }
}

// ────────────────────────────────────────────────
// Setup
// ────────────────────────────────────────────────

void setup() {
    auto cfg = M5.config();
    M5.begin(cfg);
    delay(500);

    prefs.begin("pairing", false);
    loadFromNVS();

    WiFi.mode(WIFI_STA);
    WiFi.disconnect();
    esp_wifi_set_channel(PAIRING_CHANNEL, WIFI_SECOND_CHAN_NONE);

    if (esp_now_init() != ESP_OK) {
        M5.Display.println("ESP-NOW init failed");
        return;
    }
    esp_now_register_recv_cb(onReceive);

    registerPeer(BROADCAST_MAC);
    for (int i = 0; i < pairedCount; i++) {
        registerPeer(pairedMacs[i]);
    }

    drawNormalScreen();
    Serial.printf("Hub ready. Paired: %d\n", pairedCount);
}

// ────────────────────────────────────────────────
// Main loop
// ────────────────────────────────────────────────

void loop() {
    M5.update();

    // ── Handle callback flags ──────────────────

    if (flagPairRequest && hubState == STATE_PAIRING_WAIT) {
        flagPairRequest = false;
        hubState = STATE_PAIRING_CONFIRM;
        drawPairingConfirmScreen(pendingNodeMac);
    }

    if (flagPongReceived) {
        flagPongReceived = false;
        String s = "PONG: " + macToStr(lastPongMac);
        if (hubState == STATE_NORMAL) showMessage(s);
        Serial.println(s);
    }

    if (flagNodePing) {
        flagNodePing = false;
        registerPeer(nodePingSrc);
        PairingMsg pongMsg = {MSG_PONG};
        esp_now_send(nodePingSrc, (uint8_t*)&pongMsg, sizeof(pongMsg));
        String s = "PING from: " + macToStr(nodePingSrc);
        if (hubState == STATE_NORMAL) showMessage(s);
        Serial.println(s);
    }

    if (flagHayaoshiBuzz) {
        flagHayaoshiBuzz = false;
        hubState = STATE_HAYAOSHI_RESULT;
        drawHayaoshiResultScreen(hayaoshiBuzzerMac);
        Serial.printf("Hayaoshi winner: %s\n", macToStr(hayaoshiBuzzerMac).c_str());
    }

    // ── Handle buttons ──────────────────────────

    if (hubState == STATE_NORMAL) {
        if (M5.BtnA.wasPressed()) {
            menuCursor = (menuCursor - 1 + MENU_COUNT) % MENU_COUNT;
            drawNormalScreen();
        }
        if (M5.BtnC.wasPressed()) {
            menuCursor = (menuCursor + 1) % MENU_COUNT;
            drawNormalScreen();
        }
        if (M5.BtnB.wasPressed()) {
            if (menuCursor == MENU_PING) {
                PairingMsg pingMsg = {MSG_PING};
                esp_now_send(BROADCAST_MAC, (uint8_t*)&pingMsg, sizeof(pingMsg));
                showMessage("PING sent to all nodes...");
                Serial.println("PING broadcast sent.");
            } else if (menuCursor == MENU_PAIRING) {
                hubState = STATE_PAIRING_WAIT;
                drawPairingWaitScreen();
            } else if (menuCursor == MENU_CLEAR_ALL) {
                if (pairedCount > 0) {
                    hubState = STATE_CLEAR_CONFIRM;
                    drawClearConfirmScreen();
                } else {
                    showMessage("No nodes to clear.");
                }
            } else if (menuCursor == MENU_HAYAOSHI || menuCursor == MENU_RANDOM_PICK) {
                if (pairedCount == 0) {
                    showMessage("No paired nodes.");
                } else {
                    // Enter the online-check phase
                    memset(nodeOnline, 0, sizeof(nodeOnline));
                    PairingMsg pingMsg = {MSG_PING};
                    esp_now_send(BROADCAST_MAC, (uint8_t*)&pingMsg, sizeof(pingMsg));
                    hubState = STATE_ONLINE_CHECK;
                    onlineCheckStartTime = millis();
                    pendingGameMode = menuCursor;
                    drawOnlineCheckScreen();
                    Serial.println("Online check started.");
                }
            }
        }

    } else if (hubState == STATE_PAIRING_WAIT) {
        if (M5.BtnB.wasPressed()) {
            hubState = STATE_NORMAL;
            drawNormalScreen();
        }

    } else if (hubState == STATE_PAIRING_CONFIRM) {
        if (M5.BtnB.wasPressed()) {
            if (pairedCount < MAX_PAIRED_NODES) {
                registerPeer(pendingNodeMac);
                PairingMsg confirmMsg = {MSG_PAIR_CONFIRM};
                esp_now_send(pendingNodeMac, (uint8_t*)&confirmMsg, sizeof(confirmMsg));
                memcpy(pairedMacs[pairedCount], pendingNodeMac, 6);
                pairedCount++;
                saveToNVS();
                Serial.printf("Paired! Total: %d\n", pairedCount);
            }
            hubState = STATE_NORMAL;
            drawNormalScreen();
        }
        if (M5.BtnA.wasPressed() || M5.BtnC.wasPressed()) {
            hubState = STATE_PAIRING_WAIT;
            drawPairingWaitScreen();
        }

    } else if (hubState == STATE_CLEAR_CONFIRM) {
        if (M5.BtnB.wasPressed()) {
            clearAllPairings();
            hubState = STATE_NORMAL;
            drawNormalScreen();
            Serial.println("All pairings cleared.");
        }
        if (M5.BtnA.wasPressed() || M5.BtnC.wasPressed()) {
            hubState = STATE_NORMAL;
            drawNormalScreen();
        }

    } else if (hubState == STATE_ONLINE_CHECK) {
        // Start the game after the timeout
        if (millis() - onlineCheckStartTime > ONLINE_CHECK_MS) {
            int cnt = getOnlineCount();
            Serial.printf("Online check done. Online: %d / %d\n", cnt, pairedCount);

            if (cnt == 0) {
                hubState = STATE_NORMAL;
                drawNormalScreen();
                showMessage("No online nodes.");
            } else if (pendingGameMode == MENU_HAYAOSHI) {
                PairingMsg startMsg = {MSG_HAYAOSHI_START};
                esp_now_send(BROADCAST_MAC, (uint8_t*)&startMsg, sizeof(startMsg));
                hubState = STATE_HAYAOSHI_WAITING;
                hayaoshiStartTime = millis();
                drawHayaoshiWaitingScreen(cnt);
                Serial.printf("Hayaoshi started. Online: %d\n", cnt);
            } else if (pendingGameMode == MENU_RANDOM_PICK) {
                // Collect indices of online nodes and pick one at random
                int indices[MAX_PAIRED_NODES];
                int idxCnt = 0;
                for (int i = 0; i < pairedCount; i++) {
                    if (nodeOnline[i]) indices[idxCnt++] = i;
                }
                int picked = indices[random(idxCnt)];
                memcpy(randomPickedMac, pairedMacs[picked], 6);
                PairingMsg pickMsg = {MSG_RANDOM_PICK};
                esp_now_send(randomPickedMac, (uint8_t*)&pickMsg, sizeof(pickMsg));
                hubState = STATE_RANDOM_RESULT;
                drawRandomResultScreen(randomPickedMac);
                Serial.printf("Random pick: %s\n", macToStr(randomPickedMac).c_str());
            }
        }
        // B: cancel
        if (M5.BtnB.wasPressed()) {
            hubState = STATE_NORMAL;
            drawNormalScreen();
        }

    } else if (hubState == STATE_HAYAOSHI_WAITING) {
        // Timeout (30 seconds)
        if (millis() - hayaoshiStartTime > HAYAOSHI_TIMEOUT_MS) {
            PairingMsg resetMsg = {MSG_HAYAOSHI_RESET};
            esp_now_send(BROADCAST_MAC, (uint8_t*)&resetMsg, sizeof(resetMsg));
            hubState = STATE_NORMAL;
            drawNormalScreen();
            showMessage("Hayaoshi: timeout.");
            Serial.println("Hayaoshi timeout.");
        }
        if (M5.BtnB.wasPressed()) {
            PairingMsg resetMsg = {MSG_HAYAOSHI_RESET};
            esp_now_send(BROADCAST_MAC, (uint8_t*)&resetMsg, sizeof(resetMsg));
            hubState = STATE_NORMAL;
            drawNormalScreen();
        }

    } else if (hubState == STATE_HAYAOSHI_RESULT) {
        if (M5.BtnB.wasPressed()) {
            PairingMsg resetMsg = {MSG_HAYAOSHI_RESET};
            esp_now_send(BROADCAST_MAC, (uint8_t*)&resetMsg, sizeof(resetMsg));
            hubState = STATE_NORMAL;
            drawNormalScreen();
        }

    } else if (hubState == STATE_RANDOM_RESULT) {
        if (M5.BtnB.wasPressed()) {
            hubState = STATE_NORMAL;
            drawNormalScreen();
        }
    }

    delay(20);
}
