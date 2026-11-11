// Between the app's Steam session (pocket/launcher/Pocket, signed in by the launcher before the
// game starts) and the Steam library the game calls (Steam.c). The app exports
// PocketSteamBridgeGet; the library finds it with dlsym when Steam starts, and answers offline
// when it is absent (no session: the player chose to play offline, or a host test).
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { POCKET_STEAM_BRIDGE_VERSION = 1, POCKET_STEAM_BRIDGE_TICKET_SIZE = 2560 };

// A web API ticket, or why there is none (an EResult: 1 OK, 3 no connection, ...). Called once,
// on a thread of the session's.
typedef void (*PocketSteamTicketDone)(void *context, int result, const uint8_t *ticket, uint32_t size,
                                      uint32_t crc);

typedef struct {
    uint32_t version;
    // 1 with the signed-in account's Steam ID and persona name, or 0 if none is signed in.
    int (*account)(uint64_t *steam_id, char *name, size_t name_size);
    // A web API ticket for the running game and the service named by identity.
    void (*web_ticket)(const char *identity, PocketSteamTicketDone done, void *context);
    // The game is done with the ticket with this CRC.
    void (*cancel_ticket)(uint32_t crc);
} PocketSteamBridge;

typedef const PocketSteamBridge *(*PocketSteamBridgeGetter)(void);
#define POCKET_STEAM_BRIDGE_SYMBOL "PocketSteamBridgeGet"

#ifdef __cplusplus
}
#endif
