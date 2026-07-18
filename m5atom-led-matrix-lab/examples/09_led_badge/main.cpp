#include <FastLED.h>

// === Pin definitions ===
#define DATA_PIN         25
#define BUTTON_PIN       39
#define INTERNAL_LED_PIN 27

// === Panel configuration (32x16, 2 panels vertical) ===
// [8x32 B] (top, rotated 180deg, LEDs 256-511)
// [8x32 A] (bottom, normal, LEDs 0-255)
#define NUM_LEDS    512
#define WIDTH       32
#define HEIGHT      16

CRGB leds[NUM_LEDS];
CRGB internalLed[1];

// === Mode ===
enum Mode {
  MODE_NAME,      // 2-line: HASEGAWA + STUDIST
  MODE_EYES,      // eyes
  MODE_COMPANY,   // STUDIST centered
  MODE_EQUALIZER, // equalizer
  MODE_MATRIX,    // matrix rain
  MODE_COUNT
};
Mode currentMode = MODE_NAME;

// === Button ===
bool lastBtnState = HIGH;
unsigned long lastDebounce = 0;

const char* companyText = "STUDIST";
const char* nameText = "HASEGAWA";

// === Matrix ===
float matrixY[WIDTH];
float matrixSpeed[WIDTH];
bool matrixInit = false;

// === Eyes ===
float eyeX = 0, eyeY = 0;
float eyeTargetX = 0, eyeTargetY = 0;
unsigned long lastEyeMove = 0;
unsigned long lastFrame = 0;

// === Font 3x7 (slim) ===
#define FONT_W 3
#define FONT_H 7

// LSB-first: bit0=col0(left), bit1=col1, bit2=col2(right)
static const uint8_t font[][FONT_H] PROGMEM = {
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00}, //  0: space
  {0x02,0x05,0x05,0x07,0x05,0x05,0x00}, //  1: A
  {0x03,0x05,0x03,0x05,0x05,0x03,0x00}, //  2: B
  {0x06,0x01,0x01,0x01,0x01,0x06,0x00}, //  3: C
  {0x03,0x05,0x05,0x05,0x05,0x03,0x00}, //  4: D
  {0x07,0x01,0x03,0x01,0x01,0x07,0x00}, //  5: E
  {0x07,0x01,0x03,0x01,0x01,0x01,0x00}, //  6: F
  {0x06,0x01,0x01,0x05,0x05,0x06,0x00}, //  7: G
  {0x05,0x05,0x07,0x05,0x05,0x05,0x00}, //  8: H
  {0x07,0x02,0x02,0x02,0x02,0x07,0x00}, //  9: I
  {0x06,0x04,0x04,0x04,0x05,0x02,0x00}, // 10: J
  {0x05,0x05,0x03,0x05,0x05,0x05,0x00}, // 11: K
  {0x01,0x01,0x01,0x01,0x01,0x07,0x00}, // 12: L
  {0x05,0x07,0x07,0x05,0x05,0x05,0x00}, // 13: M
  {0x05,0x07,0x05,0x05,0x05,0x05,0x00}, // 14: N
  {0x02,0x05,0x05,0x05,0x05,0x02,0x00}, // 15: O
  {0x03,0x05,0x03,0x01,0x01,0x01,0x00}, // 16: P
  {0x02,0x05,0x05,0x05,0x03,0x06,0x00}, // 17: Q
  {0x03,0x05,0x03,0x05,0x05,0x05,0x00}, // 18: R
  {0x06,0x01,0x02,0x04,0x04,0x03,0x00}, // 19: S
  {0x07,0x02,0x02,0x02,0x02,0x02,0x00}, // 20: T
  {0x05,0x05,0x05,0x05,0x05,0x02,0x00}, // 21: U
  {0x05,0x05,0x05,0x05,0x05,0x02,0x00}, // 22: V
  {0x05,0x05,0x05,0x07,0x07,0x05,0x00}, // 23: W
  {0x05,0x05,0x02,0x02,0x05,0x05,0x00}, // 24: X
  {0x05,0x05,0x02,0x02,0x02,0x02,0x00}, // 25: Y
  {0x07,0x04,0x02,0x02,0x01,0x07,0x00}, // 26: Z
  {0x02,0x02,0x02,0x02,0x00,0x02,0x00}, // 27: !
  {0x02,0x05,0x05,0x05,0x05,0x02,0x00}, // 28: 0
  {0x02,0x03,0x02,0x02,0x02,0x07,0x00}, // 29: 1
  {0x03,0x04,0x02,0x02,0x01,0x07,0x00}, // 30: 2
  {0x03,0x04,0x02,0x04,0x04,0x03,0x00}, // 31: 3
  {0x05,0x05,0x07,0x04,0x04,0x04,0x00}, // 32: 4
  {0x07,0x01,0x03,0x04,0x04,0x03,0x00}, // 33: 5
  {0x06,0x01,0x03,0x05,0x05,0x02,0x00}, // 34: 6
  {0x07,0x04,0x04,0x02,0x02,0x02,0x00}, // 35: 7
  {0x02,0x05,0x02,0x05,0x05,0x02,0x00}, // 36: 8
  {0x02,0x05,0x05,0x06,0x04,0x03,0x00}, // 37: 9
  {0x00,0x00,0x00,0x00,0x00,0x02,0x01}, // 38: ,
};

int charToIndex(char c) {
  if (c >= 'A' && c <= 'Z') return 1 + (c - 'A');
  if (c >= 'a' && c <= 'z') return 1 + (c - 'a');
  if (c == '!') return 27;
  if (c >= '0' && c <= '9') return 28 + (c - '0');
  if (c == ',') return 38;
  return 0;
}

bool getFontPixel(char c, int col, int row) {
  if (col < 0 || col >= FONT_W || row < 0 || row >= FONT_H) return false;
  uint8_t rowData = pgm_read_byte(&font[charToIndex(c)][row]);
  return (rowData >> col) & 1;
}

// === LED Mapping (2 panels vertical, Panel B rotated 180deg) ===
// Panel A: bottom (rows 8-15), normal, LEDs 0-255
// Panel B: top (rows 0-7), rotated 180deg, LEDs 256-511
void setPixel(int x, int y, CRGB color) {
  if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT) return;

  int ledIndex;
  if (y >= 8) {
    // Panel A (bottom, normal)
    int col = x;
    int row = y - 8;
    int actualRow = (col % 2 == 0) ? row : (7 - row);
    ledIndex = col * 8 + actualRow;
  } else {
    // Panel B (top, rotated 180deg)
    int col = 31 - x;
    int row = 7 - y;
    int actualRow = (col % 2 == 0) ? row : (7 - row);
    ledIndex = 256 + col * 8 + actualRow;
  }

  leds[ledIndex] = color;
}

// === Static Text (centered on line) ===
void renderStaticLine(const char* text, int yOffset, CRGB color) {
  int textLen = strlen(text);
  int charSlot = FONT_W + 1;
  int textWidth = textLen * charSlot - 1;
  int offsetX = (WIDTH - textWidth) / 2;

  for (int i = 0; i < textLen; i++) {
    for (int col = 0; col < FONT_W; col++) {
      for (int row = 0; row < FONT_H; row++) {
        if (getFontPixel(text[i], col, row)) {
          setPixel(offsetX + i * charSlot + col, yOffset + row, color);
        }
      }
    }
  }
}

// === Equalizer (sin wave based, like HTML sim) ===
void renderEqualizer(float t) {
  for (int x = 0; x < WIDTH; x++) {
    float h = (sin(t * 3.0f + x * 0.8f) * 0.5f + 0.5f) * HEIGHT *
              (0.5f + 0.5f * sin(t * 1.7f + x * 0.3f));
    int barH = (int)h;
    for (int y = HEIGHT - 1; y >= HEIGHT - barH && y >= 0; y--) {
      float ratio = (float)(HEIGHT - y) / HEIGHT;
      uint8_t r = (ratio > 0.5f) ? 255 : (uint8_t)(ratio * 2.0f * 255);
      uint8_t g = (ratio < 0.7f) ? 255 : (uint8_t)((1.0f - ratio) * 3.3f * 255);
      setPixel(x, y, CRGB(r, g, 0));
    }
  }
}

// === Matrix Rain ===
void initMatrix() {
  for (int x = 0; x < WIDTH; x++) {
    matrixY[x] = -(float)random(HEIGHT * 100) / 100.0f;
    matrixSpeed[x] = 4.0f + (float)random(800) / 100.0f;
  }
  matrixInit = true;
}

void renderMatrix(float dt) {
  if (!matrixInit) initMatrix();

  for (int x = 0; x < WIDTH; x++) {
    matrixY[x] += matrixSpeed[x] * dt;
    if (matrixY[x] > HEIGHT + 6) {
      matrixY[x] = -(float)random(600) / 100.0f;
      matrixSpeed[x] = 4.0f + (float)random(800) / 100.0f;
    }
    int head = (int)matrixY[x];
    for (int i = 0; i < 6; i++) {
      int y = head - i;
      if (y >= 0 && y < HEIGHT) {
        float v = 1.0f - i * 0.2f;
        if (v > 0) setPixel(x, y, CRGB(0, (uint8_t)(v * 255), 0));
      }
    }
  }
}

// === Eyes (bigger for 32x16) ===
void updateEyes(float dt) {
  unsigned long now = millis();
  if (now - lastEyeMove > 2000) {
    eyeTargetX = (random(100) - 50) / 50.0f * 0.8f;
    eyeTargetY = (random(100) - 50) / 50.0f * 0.5f;
    lastEyeMove = now;
  }
  eyeX += (eyeTargetX - eyeX) * dt * 7.0f;
  eyeY += (eyeTargetY - eyeY) * dt * 7.0f;
}

void renderEyes() {
  CRGB white(30, 30, 30);
  CRGB pupil(0, 170, 255);

  int centers[][2] = {{9, 8}, {23, 8}};

  for (int e = 0; e < 2; e++) {
    int cx = centers[e][0] + (int)round(eyeX * 3.0f);
    int cy = centers[e][1] + (int)round(eyeY * 2.0f);

    // Eye white (ellipse: semi-major 6 horizontal, semi-minor 4 vertical)
    for (int dr = -4; dr <= 4; dr++) {
      for (int dc = -6; dc <= 6; dc++) {
        if ((float)(dc * dc) / 36.0f + (float)(dr * dr) / 16.0f <= 1.0f) {
          setPixel(cx + dc, cy + dr, white);
        }
      }
    }

    // Pupil (circle r~2)
    for (int dr = -2; dr <= 2; dr++) {
      for (int dc = -2; dc <= 2; dc++) {
        if (dc * dc + dr * dr <= 5) {
          setPixel(cx + dc, cy + dr, pupil);
        }
      }
    }
  }
}

// === Button ===
void handleButton() {
  bool state = digitalRead(BUTTON_PIN);
  if (state == LOW && lastBtnState == HIGH && (millis() - lastDebounce > 200)) {
    currentMode = (Mode)((currentMode + 1) % MODE_COUNT);
    lastDebounce = millis();
  }
  lastBtnState = state;
}

void updateInternalLed() {
  switch (currentMode) {
    case MODE_NAME:      internalLed[0] = CRGB(255, 255, 0); break;
    case MODE_EYES:      internalLed[0] = CRGB(0, 255, 0);   break;
    case MODE_COMPANY:   internalLed[0] = CRGB(255, 0, 255); break;
    case MODE_EQUALIZER: internalLed[0] = CRGB(255, 0, 0);   break;
    case MODE_MATRIX:    internalLed[0] = CRGB(0, 128, 0);   break;
    default:             internalLed[0] = CRGB::Black;        break;
  }
}

// === Setup & Loop ===
void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT);

  FastLED.addLeds<WS2812B, DATA_PIN, GRB>(leds, NUM_LEDS);
  FastLED.addLeds<WS2812B, INTERNAL_LED_PIN, GRB>(internalLed, 1);
  FastLED.setBrightness(10);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, 2500);

  randomSeed(analogRead(0));
  lastFrame = millis();
  updateInternalLed();
}

void loop() {
  unsigned long now = millis();
  float dt = (now - lastFrame) / 1000.0f;
  lastFrame = now;

  handleButton();
  updateInternalLed();

  fill_solid(leds, NUM_LEDS, CRGB::Black);

  CRGB color(0, 170, 255);

  switch (currentMode) {
    case MODE_NAME:
      renderStaticLine(nameText, 1, color);
      renderStaticLine(companyText, 9, color);
      break;
    case MODE_EYES:
      updateEyes(dt);
      renderEyes();
      break;
    case MODE_COMPANY:
      renderStaticLine(companyText, (HEIGHT - FONT_H) / 2, color);
      break;
    case MODE_EQUALIZER: {
      float t = millis() / 1000.0f;
      renderEqualizer(t);
      break;
    }
    case MODE_MATRIX:
      renderMatrix(dt);
      break;
  }

  FastLED.show();
  delay(20);
}
