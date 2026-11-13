// Steam's client protocol, as much of it as Brighter Pocket needs to stand in for the Steam
// client on a phone: sign in (with a remembered refresh token, or through Steam's
// authentication service), Brighter Shores' ownership ticket, and web API auth tickets built
// and registered with Steam as the Steam client builds and registers them (SteamKit2's
// SteamAuthTicket is the public reference). It owns no socket: the caller carries frames to
// and from a Steam connection manager over a WebSocket and calls in from one thread at a time.
// Plain C, so the host tests and the live check run it unchanged (tests/steam_session_test.c,
// tests/steam_live.py).
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    POCKET_STEAM_WEB_TICKET_SIZE = 2560,   // GetTicketForWebApiResponse_t's m_rgubTicket
    POCKET_STEAM_RESULT_OK = 1,            // EResult
};

typedef enum {
    POCKET_STEAM_DISCONNECTED,   // nothing sent yet
    POCKET_STEAM_CONNECTED,      // hello sent: service calls without an account work
    POCKET_STEAM_LOGGING_ON,
    POCKET_STEAM_ONLINE,         // logged on
    POCKET_STEAM_REFUSED,        // the logon was refused (pocket_steam_status's result says why)
    POCKET_STEAM_LOGGED_OFF,     // Steam ended the session
} PocketSteamStatus;

typedef struct PocketSteamSession PocketSteamSession;
// Hands one frame to the WebSocket; called from within the session's own calls.
typedef void (*PocketSteamSend)(void *context, const uint8_t *frame, size_t size);
// Fills a buffer with random bytes (the platform's, so the host test can fix them).
typedef void (*PocketSteamRandom)(void *buffer, size_t size);
// Gunzips data that must come out exactly output_size bytes: 0, or -1 (the platform's zlib).
typedef int (*PocketSteamGunzip)(const uint8_t *data, size_t size, uint8_t *output, size_t output_size);

PocketSteamSession *pocket_steam_create(PocketSteamSend send, void *context, PocketSteamRandom random,
                                        PocketSteamGunzip gunzip);
void pocket_steam_destroy(PocketSteamSession *session);

// The first frame on a new connection.
void pocket_steam_hello(PocketSteamSession *session);
// Log on with an account name and a refresh token from the authentication service.
void pocket_steam_logon(PocketSteamSession *session, const char *account, const char *refresh_token,
                        const char *machine_name);
void pocket_steam_logoff(PocketSteamSession *session);
// Every heartbeat interval while online.
void pocket_steam_heartbeat(PocketSteamSession *session);
// One frame from the connection: 0, or -1 if it cannot be read (the connection is then unusable).
int pocket_steam_receive(PocketSteamSession *session, const uint8_t *frame, size_t size);

PocketSteamStatus pocket_steam_status(const PocketSteamSession *session, int *result);
uint64_t pocket_steam_steam_id(const PocketSteamSession *session);       // 0 until online
const char *pocket_steam_persona_name(const PocketSteamSession *session); // "" until Steam sends it
int pocket_steam_heartbeat_seconds(const PocketSteamSession *session);
size_t pocket_steam_connect_tokens(const PocketSteamSession *session);   // game connect tokens held
// 1 while a game runs on another session of the account (Steam's playing session state), with
// that game's app ID (0 if Steam did not name it).
int pocket_steam_playing_elsewhere(const PocketSteamSession *session, uint32_t *app_id);

// A unified service method ("Authentication.GetPasswordRSAPublicKey#1"), before or after logon.
// Returns the job its reply will carry.
uint64_t pocket_steam_call(PocketSteamSession *session, const char *method, const uint8_t *body, size_t size);
// Any other request that Steam answers with a job (EMsg message, a protobuf body: the content
// system's product info, depot keys). Its replies come through pocket_steam_reply like a call's,
// matched by their jobid_target; one request may have several (product info in parts). The result
// is the reply header's eresult, or OK when it has none.
uint64_t pocket_steam_request(PocketSteamSession *session, uint32_t message, const uint8_t *body, size_t size);
// The reply to a call: 1 with its result and body (the session's until the next call to
// pocket_steam_call or pocket_steam_reply), or 0 if it has not come.
int pocket_steam_reply(PocketSteamSession *session, uint64_t job, int *result, const uint8_t **body, size_t *size);

// Ask for the app's ownership ticket; 1 once answered, with Steam's result.
void pocket_steam_request_ownership(PocketSteamSession *session, uint32_t app_id);
int pocket_steam_ownership(const PocketSteamSession *session, uint32_t app_id, int *result);
// Tell Steam the app is running, as the Steam client does when a game starts (0 for none).
void pocket_steam_games_played(PocketSteamSession *session, uint32_t app_id);
// A web API ticket for the app and the identity of the service that will check it: built from
// a game connect token and the ownership ticket, registered with Steam, and written to
// ticket (POCKET_STEAM_WEB_TICKET_SIZE bytes). 0 with its CRC, or -1 if a token or the
// ownership ticket is missing.
int pocket_steam_web_ticket(PocketSteamSession *session, uint32_t app_id, const char *identity,
                            uint8_t ticket[POCKET_STEAM_WEB_TICKET_SIZE], uint32_t *crc);
// 1 once Steam has acknowledged the ticket with this CRC.
int pocket_steam_ticket_acknowledged(const PocketSteamSession *session, uint32_t crc);
// Withdraw a ticket from Steam (the game is done with it).
void pocket_steam_cancel_ticket(PocketSteamSession *session, uint32_t crc);
// Send Steam the tickets still held again (on a new connection after the old one dropped).
void pocket_steam_register_tickets(PocketSteamSession *session);

// --- the authentication service's messages (Authentication.*#1) -------------------------------
// A small protobuf writer and reader for them, shared with the session's own messages.
typedef struct {
    uint8_t *data;
    size_t size, capacity;
    int failed;
} PocketProto;
void pocket_proto_free(PocketProto *proto);
void pocket_proto_uint(PocketProto *proto, unsigned field, uint64_t value);
void pocket_proto_fixed64(PocketProto *proto, unsigned field, uint64_t value);
void pocket_proto_bytes(PocketProto *proto, unsigned field, const void *data, size_t size);
void pocket_proto_string(PocketProto *proto, unsigned field, const char *text);
void pocket_proto_message(PocketProto *proto, unsigned field, const PocketProto *message);

typedef struct {
    unsigned field, wire;      // wire 0 varint, 1 fixed64, 2 bytes, 5 fixed32
    uint64_t value;            // varint and fixed values
    const uint8_t *data;       // bytes
    size_t size;
} PocketField;
// The next field after *position; 1, 0 at the end, -1 if malformed.
int pocket_proto_next(const uint8_t **position, const uint8_t *end, PocketField *field);
// The last field with this number (protobuf's rule for a non-repeated field); 1 if present.
int pocket_proto_find(const uint8_t *data, size_t size, unsigned field, PocketField *found);

#ifdef __cplusplus
}
#endif
