#include <FastLED.h>

// === Pin definitions ===
#define DATA_PIN         25  // LED panel DIN
#define BUTTON_PIN       39  // Atom Lite button
#define INTERNAL_LED_PIN 27  // Atom Lite internal LED

// === Panel configuration ===
#define NUM_LEDS    512
#define WIDTH       64
#define HEIGHT      8

CRGB leds[NUM_LEDS];
CRGB internalLed[1];

// === Mode ===
enum Mode {
  MODE_SCROLL,   // MENTOR scroll
  MODE_EYES,     // Darting eyes
  MODE_COMPANY,  // STUDIST static display
  MODE_NAME,     // HASEGAWA static display
  MODE_COUNT
};
Mode currentMode = MODE_SCROLL;

// === Button ===
bool lastBtnState = HIGH;
unsigned long lastDebounce = 0;

// === Scroll ===
float scrollOffset = 0;
const char* scrollText = "MENTOR  ";
const char* companyText = "STUDIST";
const char* nameText = "HASEGAWA";

// === Eyes ===
float eyeX = 0, eyeY = 0;
float eyeTargetX = 0, eyeTargetY = 0;
unsigned long lastEyeMove = 0;
unsigned long lastFrame = 0;

// === Font 7x8 (font8x8 by dhepper, public domain, LSB-first) ===
#define FONT_W 7
#define FONT_H 8

static const uint8_t font[][FONT_H] PROGMEM = {
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, //  0: space
  {0x0C,0x1E,0x33,0x33,0x3F,0x33,0x33,0x33}, //  1: A
  {0x3F,0x66,0x66,0x3E,0x66,0x66,0x66,0x3F}, //  2: B
  {0x3C,0x66,0x03,0x03,0x03,0x03,0x66,0x3C}, //  3: C
  {0x1F,0x36,0x66,0x66,0x66,0x66,0x36,0x1F}, //  4: D
  {0x7F,0x46,0x16,0x1E,0x16,0x06,0x46,0x7F}, //  5: E
  {0x7F,0x46,0x16,0x1E,0x16,0x06,0x06,0x0F}, //  6: F
  {0x3C,0x66,0x03,0x03,0x03,0x73,0x66,0x7C}, //  7: G
  {0x33,0x33,0x33,0x3F,0x33,0x33,0x33,0x33}, //  8: H
  {0x1E,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E}, //  9: I
  {0x78,0x30,0x30,0x30,0x30,0x33,0x33,0x1E}, // 10: J
  {0x67,0x66,0x36,0x1E,0x36,0x66,0x66,0x67}, // 11: K
  {0x0F,0x06,0x06,0x06,0x06,0x46,0x66,0x7F}, // 12: L
  {0x63,0x77,0x7F,0x7F,0x6B,0x63,0x63,0x63}, // 13: M
  {0x63,0x67,0x6F,0x7B,0x73,0x63,0x63,0x63}, // 14: N
  {0x1C,0x36,0x63,0x63,0x63,0x63,0x36,0x1C}, // 15: O
  {0x3F,0x66,0x66,0x3E,0x06,0x06,0x06,0x0F}, // 16: P
  {0x1E,0x33,0x33,0x33,0x33,0x3B,0x1E,0x38}, // 17: Q
  {0x3F,0x66,0x66,0x3E,0x36,0x66,0x66,0x67}, // 18: R
  {0x1E,0x33,0x07,0x0E,0x38,0x70,0x33,0x1E}, // 19: S
  {0x3F,0x2D,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E}, // 20: T
  {0x33,0x33,0x33,0x33,0x33,0x33,0x36,0x1C}, // 21: U
  {0x33,0x33,0x33,0x33,0x33,0x36,0x1E,0x0C}, // 22: V
  {0x63,0x63,0x63,0x63,0x6B,0x7F,0x77,0x63}, // 23: W
  {0x63,0x63,0x36,0x1C,0x1C,0x36,0x63,0x63}, // 24: X
  {0x33,0x33,0x33,0x1E,0x0C,0x0C,0x0C,0x1E}, // 25: Y
  {0x7F,0x63,0x30,0x18,0x0C,0x06,0x63,0x7F}, // 26: Z
  {0x18,0x3C,0x3C,0x18,0x18,0x18,0x00,0x18}, // 27: !
  {0x3E,0x63,0x73,0x7B,0x6F,0x67,0x63,0x3E}, // 28: 0
  {0x0C,0x0E,0x0C,0x0C,0x0C,0x0C,0x0C,0x3F}, // 29: 1
  {0x1E,0x33,0x30,0x1C,0x06,0x03,0x33,0x3F}, // 30: 2
  {0x1E,0x33,0x30,0x1C,0x30,0x30,0x33,0x1E}, // 31: 3
  {0x38,0x3C,0x36,0x33,0x7F,0x30,0x30,0x78}, // 32: 4
  {0x3F,0x03,0x1F,0x30,0x30,0x30,0x33,0x1E}, // 33: 5
  {0x1C,0x06,0x03,0x1F,0x33,0x33,0x33,0x1E}, // 34: 6
  {0x3F,0x33,0x30,0x18,0x0C,0x0C,0x0C,0x0C}, // 35: 7
  {0x1E,0x33,0x33,0x1E,0x33,0x33,0x33,0x1E}, // 36: 8
  {0x1E,0x33,0x33,0x3E,0x30,0x30,0x18,0x0E}, // 37: 9
  {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x06}, // 38: ,
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

// === LED Mapping (serpentine wiring support) ===
void setPixel(int x, int y, CRGB color) {
  if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT) return;
  int actualY = (x % 2 == 0) ? y : (HEIGHT - 1 - y);
  leds[x * HEIGHT + actualY] = color;
}

// === Scroll Text (gap: pixels between characters) ===
void renderScrollWithGap(int gap) {
  int textLen = strlen(scrollText);
  int charSlot = FONT_W + gap;
  int totalCols = textLen * charSlot;
  int offset = ((int)scrollOffset) % totalCols;
  CRGB color(0, 170, 255);

  for (int x = 0; x < WIDTH; x++) {
    int srcCol = ((x + offset) % totalCols + totalCols) % totalCols;
    int charIdx = srcCol / charSlot;
    int charCol = srcCol % charSlot;

    for (int y = 0; y < HEIGHT; y++) {
      bool on = (charCol < FONT_W && y < FONT_H)
                ? getFontPixel(scrollText[charIdx], charCol, y)
                : false;
      setPixel(x, y, on ? color : CRGB::Black);
    }
  }
}

// === Static Text (center-aligned) ===
void renderStatic(const char* text) {
  int textLen = strlen(text);
  int charSlot = FONT_W + 1;
  int textWidth = textLen * charSlot - 1;
  int offsetX = (WIDTH - textWidth) / 2;
  CRGB color(0, 170, 255);

  for (int i = 0; i < textLen; i++) {
    for (int col = 0; col < FONT_W; col++) {
      for (int row = 0; row < FONT_H; row++) {
        if (getFontPixel(text[i], col, row)) {
          setPixel(offsetX + i * charSlot + col, row, color);
        }
      }
    }
  }
}

// === Eyes ===
void updateEyes(float dt) {
  unsigned long now = millis();
  if (now - lastEyeMove > 2000) {
    eyeTargetX = (random(100) - 50) / 50.0f * 0.9f;
    eyeTargetY = (random(100) - 50) / 50.0f * 0.45f;
    lastEyeMove = now;
  }
  eyeX += (eyeTargetX - eyeX) * dt * 7.0f;
  eyeY += (eyeTargetY - eyeY) * dt * 7.0f;
}

void renderEyes() {
  CRGB white(30, 30, 30);
  CRGB pupil(0, 170, 255);

  int centers[][2] = {{16, 3}, {48, 3}};

  for (int e = 0; e < 2; e++) {
    int cx = centers[e][0] + (int)round(eyeX * 5.0f);
    int cy = centers[e][1] + (int)round(eyeY * 1.2f);

    // Eye white (ellipse: semi-major 5, semi-minor 2)
    for (int dr = -2; dr <= 2; dr++) {
      for (int dc = -5; dc <= 5; dc++) {
        if ((float)(dc * dc) / 25.0f + (float)(dr * dr) / 4.0f <= 1.0f) {
          setPixel(cx + dc, cy + dr, white);
        }
      }
    }

    // Pupil (3x3)
    for (int dr = -1; dr <= 1; dr++) {
      for (int dc = -1; dc <= 1; dc++) {
        setPixel(cx + dc, cy + dr, pupil);
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
    scrollOffset = 0;
  }
  lastBtnState = state;
}

void updateInternalLed() {
  switch (currentMode) {
    case MODE_SCROLL:  internalLed[0] = CRGB(0, 0, 255);   break; // blue
    case MODE_EYES:    internalLed[0] = CRGB(0, 255, 0);   break; // green
    case MODE_COMPANY: internalLed[0] = CRGB(255, 0, 255); break; // purple
    case MODE_NAME:    internalLed[0] = CRGB(255, 255, 0); break; // yellow
    default:           internalLed[0] = CRGB::Black;        break;
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

  switch (currentMode) {
    case MODE_SCROLL:
      renderScrollWithGap(1);
      scrollOffset += 15.0f * dt;
      break;
    case MODE_EYES:
      updateEyes(dt);
      renderEyes();
      break;
    case MODE_COMPANY:
      renderStatic(companyText);
      break;
    case MODE_NAME:
      renderStatic(nameText);
      break;
  }

  FastLED.show();
  delay(20);
}
