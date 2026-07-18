#pragma once
#include <stdint.h>

// ESP-NOW channel (must match between Hub and Node)
#define PAIRING_CHANNEL  1

// Maximum number of nodes the Hub can keep paired
#define MAX_PAIRED_NODES 10

// Message types
#define MSG_PAIR_REQUEST  0x01  // Node -> broadcast: pairing request
#define MSG_PAIR_CONFIRM  0x02  // Hub  -> Node:      pairing accepted
#define MSG_PING          0x10  // either direction: connectivity check request
#define MSG_PONG          0x11  // either direction: connectivity check response
#define MSG_HAYAOSHI_START 0x20  // Hub -> broadcast: buzzer-quiz start signal
#define MSG_HAYAOSHI_BUZZ  0x21  // Node -> Hub:      buzzer-quiz buzz-in button press
#define MSG_HAYAOSHI_RESET 0x22  // Hub -> broadcast: buzzer-quiz reset / timeout
#define MSG_RANDOM_PICK    0x30  // Hub -> Node:      random pick

// Payload sent/received over ESP-NOW
// The source MAC can be obtained from the receive callback's mac argument, so it's not needed here
struct PairingMsg {
    uint8_t type;  // one of MSG_*
};
