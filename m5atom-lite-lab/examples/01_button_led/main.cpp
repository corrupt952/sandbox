#include <M5Atom.h>

void setup() {
    M5.begin(true, false, true); // Serial, I2C, Display(LED)
    M5.dis.drawpix(0, 0x00FF00);  // Green
}

void loop() {
    M5.update();
    if (M5.Btn.isPressed()) {
        M5.dis.drawpix(0, 0xFF0000);  // Red while pressed
    } else {
        M5.dis.drawpix(0, 0x00FF00);  // Back to green on release
    }
}
