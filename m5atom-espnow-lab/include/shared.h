#pragma once

// ESP-NOW channel (must match on both sender and receiver)
#define ESPNOW_CHANNEL 1

// Device MAC addresses
// Note: Atom Lite uses the AP-mode MAC (STA + 1)
#define ATOM_MAC_AP  {0x14, 0x08, 0x08, 0x54, 0xE8, 0x45}
#define BASIC_MAC    {0x84, 0x1F, 0xE8, 0x83, 0x45, 0xB4}

// Status definitions
#define STATUS_HIMA      0  // Free
#define STATUS_SODAN     1  // Busy
#define STATUS_RISEKI    2  // Away
#define STATUS_COUNT     3

static const char* STATUS_LABELS[] = {"Free", "Busy", "Away"};

// ESP-NOW send/receive data structure
struct Payload {
    uint8_t status;  // STATUS_HIMA / STATUS_SODAN / STATUS_RISEKI
};
