// Step 5: Atomic Display Base (HDMI output) sample
// Shows "ON!" centered on a green background while the button is held,
// and "OFF" on a red background when released

#include <M5AtomDisplay.h>

// 1280x720 / 60Hz (default when omitted)
// Lighter resolution: M5AtomDisplay display(640, 360);
M5AtomDisplay display(1280, 720);

static const int BTN_PIN = 39;   // Atom Lite's built-in button (active low)
static bool lastPressed = false;

void drawScreen(bool on) {
    uint32_t bg       = on ? display.color888(  0, 180,  0)   // Green
                           : display.color888(180,   0,  0);  // Red
    const char* label = on ? "ON!" : "OFF";

    display.startWrite();
    display.fillScreen(bg);
    display.setFont(&fonts::Orbitron_Light_32);
    display.setTextSize(4);
    display.setTextColor(display.color888(255, 255, 255));
    // Center-aligned (drawCentreString's x is the horizontal center, y is the text top)
    int32_t th = display.fontHeight();
    display.drawCentreString(label,
                             display.width()  / 2,
                             (display.height() - th) / 2);
    display.endWrite();
}

void setup() {
    pinMode(BTN_PIN, INPUT_PULLUP);

    display.init();
    display.setRotation(1);      // 0=270deg / 1=normal / 2=90deg / 3=180deg
    display.setColorDepth(24);   // 24-bit color

    drawScreen(false);           // "OFF" (red background) at startup
}

void loop() {
    bool pressed = (digitalRead(BTN_PIN) == LOW);
    if (pressed != lastPressed) {
        lastPressed = pressed;
        drawScreen(pressed);
    }
    delay(20);
}
