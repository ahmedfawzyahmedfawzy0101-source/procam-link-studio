#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProCamSRTHandle ProCamSRTHandle;

typedef struct ProCamSRTConfig {
    int32_t mode;
    const char* host;
    uint16_t port;
    int32_t latencyMS;
    const char* passphrase;
    const char* streamID;
    int32_t connectTimeoutMS;
} ProCamSRTConfig;

typedef struct ProCamSRTStats {
    double sendBitrateMbps;
    double rttMS;
    double packetLossPercent;
    int64_t packetsSent;
    int64_t packetsLost;
    int64_t retransmittedPackets;
    int64_t sendBufferBytes;
    double uptimeSeconds;
} ProCamSRTStats;

int32_t ProCamSRTStartup(void);
void ProCamSRTCleanup(void);
ProCamSRTHandle* ProCamSRTConnect(const ProCamSRTConfig* config, char* errorBuffer, int32_t errorBufferSize);
int32_t ProCamSRTSend(ProCamSRTHandle* handle, const uint8_t* bytes, int32_t length, char* errorBuffer, int32_t errorBufferSize);
int32_t ProCamSRTGetStats(ProCamSRTHandle* handle, ProCamSRTStats* stats, char* errorBuffer, int32_t errorBufferSize);
void ProCamSRTDisconnect(ProCamSRTHandle* handle);

#ifdef __cplusplus
}
#endif
