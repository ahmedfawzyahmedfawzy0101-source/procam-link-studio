#include "SRTBridge.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <srt/srt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>

struct ProCamSRTHandle {
    SRTSOCKET socket;
    SRTSOCKET listener;
    time_t connectedAt;
};

static void ProCamSRTCopyError(char* errorBuffer, int32_t errorBufferSize, const char* message) {
    if (!errorBuffer || errorBufferSize <= 0) {
        return;
    }
    const char* source = message ? message : srt_getlasterror_str();
    strncpy(errorBuffer, source, (size_t)errorBufferSize - 1);
    errorBuffer[errorBufferSize - 1] = '\0';
}

static int ProCamSRTApplyOptions(SRTSOCKET socket, const ProCamSRTConfig* config, char* errorBuffer, int32_t errorBufferSize) {
    int yes = 1;
    int no = 0;
    int latency = config->latencyMS;
    int timeout = config->connectTimeoutMS;

    if (srt_setsockflag(socket, SRTO_SENDER, &yes, sizeof yes) == SRT_ERROR ||
        srt_setsockflag(socket, SRTO_SNDSYN, &yes, sizeof yes) == SRT_ERROR ||
        srt_setsockflag(socket, SRTO_RCVSYN, &yes, sizeof yes) == SRT_ERROR ||
        srt_setsockflag(socket, SRTO_LATENCY, &latency, sizeof latency) == SRT_ERROR ||
        srt_setsockflag(socket, SRTO_CONNTIMEO, &timeout, sizeof timeout) == SRT_ERROR) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
        return SRT_ERROR;
    }

    if (config->passphrase && strlen(config->passphrase) > 0) {
        if (srt_setsockflag(socket, SRTO_PASSPHRASE, config->passphrase, (int)strlen(config->passphrase)) == SRT_ERROR) {
            ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
            return SRT_ERROR;
        }
    }

    if (config->streamID && strlen(config->streamID) > 0) {
        if (srt_setsockflag(socket, SRTO_STREAMID, config->streamID, (int)strlen(config->streamID)) == SRT_ERROR) {
            ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
            return SRT_ERROR;
        }
    }

    (void)no;
    return 0;
}

int32_t ProCamSRTStartup(void) {
    return srt_startup();
}

void ProCamSRTCleanup(void) {
    srt_cleanup();
}

ProCamSRTHandle* ProCamSRTConnect(const ProCamSRTConfig* config, char* errorBuffer, int32_t errorBufferSize) {
    if (!config) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, "Missing SRT configuration");
        return NULL;
    }

    SRTSOCKET socket = srt_create_socket();
    if (socket == SRT_INVALID_SOCK) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
        return NULL;
    }

    if (ProCamSRTApplyOptions(socket, config, errorBuffer, errorBufferSize) == SRT_ERROR) {
        srt_close(socket);
        return NULL;
    }

    SRTSOCKET listener = SRT_INVALID_SOCK;
    if (config->mode == 1) {
        struct sockaddr_in bindAddress;
        memset(&bindAddress, 0, sizeof bindAddress);
        bindAddress.sin_family = AF_INET;
        bindAddress.sin_port = htons(config->port);
        bindAddress.sin_addr.s_addr = htonl(INADDR_ANY);

        if (srt_bind(socket, (struct sockaddr*)&bindAddress, sizeof bindAddress) == SRT_ERROR ||
            srt_listen(socket, 1) == SRT_ERROR) {
            ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
            srt_close(socket);
            return NULL;
        }

        listener = socket;
        struct sockaddr_storage peerAddress;
        int peerLength = sizeof peerAddress;
        socket = srt_accept(listener, (struct sockaddr*)&peerAddress, &peerLength);
        if (socket == SRT_INVALID_SOCK) {
            ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
            srt_close(listener);
            return NULL;
        }
    } else {
        struct addrinfo hints;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_DGRAM;

        char portText[16];
        snprintf(portText, sizeof portText, "%u", config->port);
        struct addrinfo* results = NULL;
        int gai = getaddrinfo(config->host, portText, &hints, &results);
        if (gai != 0 || !results) {
            ProCamSRTCopyError(errorBuffer, errorBufferSize, gai_strerror(gai));
            srt_close(socket);
            return NULL;
        }

        int connected = SRT_ERROR;
        for (struct addrinfo* item = results; item != NULL; item = item->ai_next) {
            connected = srt_connect(socket, item->ai_addr, (int)item->ai_addrlen);
            if (connected != SRT_ERROR) {
                break;
            }
        }
        freeaddrinfo(results);

        if (connected == SRT_ERROR) {
            ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
            srt_close(socket);
            return NULL;
        }
    }

    ProCamSRTHandle* handle = (ProCamSRTHandle*)calloc(1, sizeof(ProCamSRTHandle));
    if (!handle) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, "Unable to allocate SRT handle");
        srt_close(socket);
        if (listener != SRT_INVALID_SOCK) {
            srt_close(listener);
        }
        return NULL;
    }

    handle->socket = socket;
    handle->listener = listener;
    handle->connectedAt = time(NULL);
    return handle;
}

int32_t ProCamSRTSend(ProCamSRTHandle* handle, const uint8_t* bytes, int32_t length, char* errorBuffer, int32_t errorBufferSize) {
    if (!handle || handle->socket == SRT_INVALID_SOCK || !bytes || length <= 0) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, "Invalid SRT send request");
        return SRT_ERROR;
    }

    SRT_MSGCTRL control = srt_msgctrl_default;
    int sent = srt_sendmsg2(handle->socket, (const char*)bytes, length, &control);
    if (sent == SRT_ERROR) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
    }
    return sent;
}

int32_t ProCamSRTGetStats(ProCamSRTHandle* handle, ProCamSRTStats* stats, char* errorBuffer, int32_t errorBufferSize) {
    if (!handle || !stats) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, "Invalid SRT stats request");
        return SRT_ERROR;
    }

    SRT_TRACEBSTATS rawStats;
    memset(&rawStats, 0, sizeof rawStats);
    if (srt_bstats(handle->socket, &rawStats, 0) == SRT_ERROR) {
        ProCamSRTCopyError(errorBuffer, errorBufferSize, NULL);
        return SRT_ERROR;
    }

    stats->sendBitrateMbps = rawStats.mbpsSendRate;
    stats->rttMS = rawStats.msRTT;
    stats->packetsSent = rawStats.pktSentTotal;
    stats->packetsLost = rawStats.pktSndLossTotal;
    stats->retransmittedPackets = rawStats.pktRetransTotal;
    stats->sendBufferBytes = rawStats.byteAvailSndBuf;
    stats->uptimeSeconds = difftime(time(NULL), handle->connectedAt);
    stats->packetLossPercent = rawStats.pktSentTotal > 0
        ? ((double)rawStats.pktSndLossTotal / (double)rawStats.pktSentTotal) * 100.0
        : 0.0;
    return 0;
}

void ProCamSRTDisconnect(ProCamSRTHandle* handle) {
    if (!handle) {
        return;
    }
    if (handle->socket != SRT_INVALID_SOCK) {
        srt_close(handle->socket);
    }
    if (handle->listener != SRT_INVALID_SOCK) {
        srt_close(handle->listener);
    }
    free(handle);
}
