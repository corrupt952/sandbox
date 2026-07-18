#include <FastLED.h>

#define DATA_PIN  25   // Atom Lite G25
#define NUM_LEDS  512
#define WIDTH     64
#define HEIGHT    8

CRGB leds[NUM_LEDS];
uint8_t hueOffset = 0;

void setup() {
  FastLED.addLeds<WS2812B, DATA_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(10);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, 2500);
}

void loop() {
  for (int x = 0; x < WIDTH; x++) {
    uint8_t hue = hueOffset + x * 8;
    uint8_t brightness = sin8(hueOffset * 2 + x * 16);
    for (int y = 0; y < HEIGHT; y++) {
      int i = x * HEIGHT + y;
      leds[i] = CHSV(hue, 255, brightness);
    }
  }
  FastLED.show();
  hueOffset++;
  delay(20);
}
