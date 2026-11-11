// Host tests for the app's Steam session core (pocket/launcher/Pocket/PocketSteam.c): the frames it
// sends, read back field by field, and its answers to frames as Steam sends them. The live
// counterpart, against Steam itself, is tests/steam_live.py.
#define _POSIX_C_SOURCE 200809L
#include "../pocket/launcher/Pocket/PocketSteam.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond)                                                                      \
    do {                                                                                 \
        if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } \
    } while (0)

// --- what the session sends -------------------------------------------------------------------
static uint8_t sent[16][8192];
static size_t sent_size[16], sent_count;
static void capture(void *context, const uint8_t *frame, size_t size) {
    (void)context;
    if (sent_count < 16 && size <= sizeof sent[0]) { memcpy(sent[sent_count], frame, size); sent_size[sent_count++] = size; }
}
static uint8_t next_random = 0xa0;
static void fixed_random(void *buffer, size_t size) {   // a counting pattern, so bytes are recognisable
    for (size_t i = 0; i < size; i++) ((uint8_t *)buffer)[i] = next_random++;
}
static int no_gunzip(const uint8_t *data, size_t size, uint8_t *output, size_t output_size) {
    (void)data; (void)size; (void)output; (void)output_size;
    return -1;
}

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
typedef struct { uint32_t message; const uint8_t *header, *body; size_t header_size, body_size; } Frame;
static Frame frame_at(size_t index) {
    Frame f = {0};
    f.message = le32(sent[index]) & 0x7fffffffu;
    CHECK(le32(sent[index]) & 0x80000000u);
    f.header_size = le32(sent[index] + 4);
    f.header = sent[index] + 8;
    f.body = f.header + f.header_size;
    f.body_size = sent_size[index] - 8 - f.header_size;
    return f;
}
static uint64_t number(const uint8_t *data, size_t size, unsigned field) {
    PocketField found;
    return pocket_proto_find(data, size, field, &found) ? found.value : (uint64_t)-1;
}
static int text_is(const uint8_t *data, size_t size, unsigned field, const char *expected) {
    PocketField found;
    return pocket_proto_find(data, size, field, &found) && found.wire == 2 && found.size == strlen(expected) &&
           !memcmp(found.data, expected, found.size);
}

// --- what Steam sends -------------------------------------------------------------------------
static size_t steam_frame(uint8_t *out, uint32_t message, const PocketProto *header, const PocketProto *body) {
    uint32_t words[2] = {message | 0x80000000u, (uint32_t)header->size};
    memcpy(out, words, 8);   // the host is little-endian, as the wire is
    if (header->size) memcpy(out + 8, header->data, header->size);
    if (body->size) memcpy(out + 8 + header->size, body->data, body->size);
    return 8 + header->size + body->size;
}
static int deliver(PocketSteamSession *s, uint32_t message, PocketProto *header, PocketProto *body) {
    uint8_t frame[8192];
    size_t size = steam_frame(frame, message, header, body);
    pocket_proto_free(header);
    pocket_proto_free(body);
    return pocket_steam_receive(s, frame, size);
}

// An independent CRC-32 (bytewise table), checked against the standard vector.
static uint32_t reference_crc(const uint8_t *data, size_t size) {
    static uint32_t table[256];
    if (!table[1])
        for (uint32_t n = 0; n < 256; n++) {
            uint32_t c = n;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xedb88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
    uint32_t crc = 0xffffffffu;
    for (size_t i = 0; i < size; i++) crc = table[(crc ^ data[i]) & 0xff] ^ (crc >> 8);
    return crc ^ 0xffffffffu;
}

int main(void) {
    CHECK(reference_crc((const uint8_t *)"123456789", 9) == 0xcbf43926u);
    PocketSteamSession *s = pocket_steam_create(capture, NULL, fixed_random, no_gunzip);
    CHECK(pocket_steam_status(s, NULL) == POCKET_STEAM_DISCONNECTED);

    // Hello, then a service call with no account: EMsg 9804, the method in the header, a job.
    pocket_steam_hello(s);
    Frame hello = frame_at(0);
    CHECK(hello.message == 9805 && number(hello.body, hello.body_size, 1) == 65581);
    const uint8_t rsa_request[] = {0x0a, 0x03, 'j', 'o', 'e'};
    uint64_t job = pocket_steam_call(s, "Authentication.GetPasswordRSAPublicKey#1", rsa_request, sizeof rsa_request);
    Frame call = frame_at(1);
    CHECK(call.message == 9804);
    CHECK(number(call.header, call.header_size, 10) == job);
    CHECK(text_is(call.header, call.header_size, 12, "Authentication.GetPasswordRSAPublicKey#1"));
    CHECK(call.body_size == sizeof rsa_request && !memcmp(call.body, rsa_request, sizeof rsa_request));

    // Its reply is found by job, once; another job's is not.
    PocketProto header = {0}, body = {0};
    pocket_proto_uint(&header, 13, 1);
    pocket_proto_fixed64(&header, 11, job);
    pocket_proto_string(&body, 1, "c0ffee");
    CHECK(deliver(s, 147, &header, &body) == 0);
    int result = 0;
    const uint8_t *reply;
    size_t reply_size;
    CHECK(!pocket_steam_reply(s, job + 1, &result, &reply, &reply_size));
    CHECK(pocket_steam_reply(s, job, &result, &reply, &reply_size) && result == 1);
    CHECK(text_is(reply, reply_size, 1, "c0ffee"));
    CHECK(!pocket_steam_reply(s, job, &result, &reply, &reply_size));

    // Logon: the refresh token as the access token, the account and the machine name.
    pocket_steam_logon(s, "joe", "refresh.token", "Brighter Pocket");
    Frame logon = frame_at(2);
    CHECK(logon.message == 5514 && pocket_steam_status(s, NULL) == POCKET_STEAM_LOGGING_ON);
    CHECK(number(logon.header, logon.header_size, 1) == 0x0110000100000000ull);
    CHECK(text_is(logon.body, logon.body_size, 50, "joe"));
    CHECK(text_is(logon.body, logon.body_size, 108, "refresh.token"));
    CHECK(text_is(logon.body, logon.body_size, 96, "Brighter Pocket"));

    // A refused logon says why; an accepted one gives the account and its session.
    pocket_proto_uint(&body, 1, 5);   // InvalidPassword
    CHECK(deliver(s, 751, &header, &body) == 0);
    CHECK(pocket_steam_status(s, &result) == POCKET_STEAM_REFUSED && result == 5 && !pocket_steam_steam_id(s));
    pocket_steam_logon(s, "joe", "refresh.token", "Brighter Pocket");
    pocket_proto_fixed64(&header, 1, 76561197960287930ull);
    pocket_proto_uint(&header, 2, 1234);
    pocket_proto_uint(&body, 1, 1);
    pocket_proto_uint(&body, 3, 20);
    CHECK(deliver(s, 751, &header, &body) == 0);
    CHECK(pocket_steam_status(s, &result) == POCKET_STEAM_ONLINE && result == 1);
    CHECK(pocket_steam_steam_id(s) == 76561197960287930ull && pocket_steam_heartbeat_seconds(s) == 20);

    // Account info and game connect tokens, packed in one uncompressed multi message.
    PocketProto info = {0}, info_header = {0}, tokens = {0}, tokens_header = {0}, multi = {0};
    pocket_proto_string(&info, 1, "Joe");
    const char *const names[] = {"token-0", "token-1", "token-2"};
    for (int i = 0; i < 3; i++) pocket_proto_string(&tokens, 2, names[i]);
    pocket_proto_uint(&tokens, 1, 2);   // keep two: the oldest goes
    uint8_t inner[1024];
    size_t inner_size = steam_frame(inner, 768, &info_header, &info);
    uint32_t length = (uint32_t)inner_size;
    uint8_t joined[2048];
    memcpy(joined, &length, 4);
    memcpy(joined + 4, inner, inner_size);
    size_t joined_size = 4 + inner_size;
    inner_size = steam_frame(inner, 779, &tokens_header, &tokens);
    length = (uint32_t)inner_size;
    memcpy(joined + joined_size, &length, 4);
    memcpy(joined + joined_size + 4, inner, inner_size);
    joined_size += 4 + inner_size;
    pocket_proto_bytes(&multi, 2, joined, joined_size);
    CHECK(deliver(s, 1, &header, &multi) == 0);
    pocket_proto_free(&info); pocket_proto_free(&tokens);
    CHECK(!strcmp(pocket_steam_persona_name(s), "Joe"));
    CHECK(pocket_steam_connect_tokens(s) == 2);

    // A compressed multi needs the platform's gunzip; one that cannot be unpacked is an error.
    pocket_proto_uint(&multi, 1, 64);
    pocket_proto_bytes(&multi, 2, "not gzip", 8);
    CHECK(deliver(s, 1, &header, &multi) == -1);

    // No ticket before the ownership ticket comes.
    uint8_t ticket[POCKET_STEAM_WEB_TICKET_SIZE];
    uint32_t crc = 0;
    CHECK(pocket_steam_web_ticket(s, 2791440, "game", ticket, &crc) == -1);
    sent_count = 0;
    pocket_steam_request_ownership(s, 2791440);
    Frame ownership = frame_at(0);
    CHECK(ownership.message == 857 && number(ownership.body, ownership.body_size, 1) == 2791440);
    CHECK(!pocket_steam_ownership(s, 2791440, &result));
    const uint8_t app_ticket[] = {'A', 'P', 'P', 'T', 'I', 'C', 'K', 'E', 'T'};
    pocket_proto_uint(&body, 1, 1);
    pocket_proto_uint(&body, 2, 2791440);
    pocket_proto_bytes(&body, 3, app_ticket, sizeof app_ticket);
    CHECK(deliver(s, 858, &header, &body) == 0);
    CHECK(pocket_steam_ownership(s, 2791440, &result) && result == 1);

    // The web API ticket, as SteamKit2 lays it out: the session part from the oldest kept token
    // ("token-1"), the ownership ticket after its size, filler to 2,560 bytes.
    sent_count = 0;
    next_random = 0x40;
    CHECK(pocket_steam_web_ticket(s, 2791440, "game", ticket, &crc) == 0);
    CHECK(le32(ticket) == 7 && !memcmp(ticket + 4, "token-1", 7));
    const uint8_t *part = ticket + 11;
    CHECK(le32(part) == 24 && le32(part + 4) == 1 && le32(part + 8) == 5);
    CHECK(part[12] == 0x40 && part[19] == 0x47);   // the two addresses: random
    CHECK(le32(part + 24) == 1);                   // the first ticket's sequence
    size_t session_size = 11 + 28;
    CHECK(crc == reference_crc(ticket, session_size));
    CHECK(le32(ticket + session_size) == sizeof app_ticket);
    CHECK(!memcmp(ticket + session_size + 4, app_ticket, sizeof app_ticket));
    CHECK(ticket[session_size + 4 + sizeof app_ticket] == 0x48);   // the filler follows the randoms
    CHECK(pocket_steam_connect_tokens(s) == 1);

    // Registered with Steam in CMsgClientAuthList: the session part, its CRC, "str:game\0".
    Frame list = frame_at(0);
    CHECK(list.message == 5432 && number(list.body, list.body_size, 1) == 1);   // tokens_left
    CHECK(number(list.body, list.body_size, 5) == 2791440);                    // app_ids
    PocketField entry;
    CHECK(pocket_proto_find(list.body, list.body_size, 4, &entry) && entry.wire == 2);
    CHECK(number(entry.data, entry.size, 4) == 2791440 && number(entry.data, entry.size, 6) == crc);
    PocketField registered, secret;
    CHECK(pocket_proto_find(entry.data, entry.size, 7, &registered) && registered.size == session_size &&
          !memcmp(registered.data, ticket, session_size));
    CHECK(pocket_proto_find(entry.data, entry.size, 8, &secret) && secret.size == 9 && !memcmp(secret.data, "str:game", 9));

    // Steam's ack names the CRCs it holds.
    CHECK(!pocket_steam_ticket_acknowledged(s, crc));
    pocket_proto_uint(&body, 1, crc + 1);
    pocket_proto_uint(&body, 1, crc);
    CHECK(deliver(s, 5575, &header, &body) == 0);
    CHECK(pocket_steam_ticket_acknowledged(s, crc));

    // Online, service calls go as the account (EMsg 151); playing names the game.
    sent_count = 0;
    pocket_steam_call(s, "Player.GetGameBadgeLevels#1", NULL, 0);
    pocket_steam_games_played(s, 2791440);
    CHECK(frame_at(0).message == 151 && number(frame_at(0).header, frame_at(0).header_size, 1) == 76561197960287930ull);
    Frame played = frame_at(1);
    PocketField game;
    CHECK(played.message == 5410 && pocket_proto_find(played.body, played.body_size, 1, &game) &&
          number(game.data, game.size, 2) == 2791440);

    // Cancelling sends the list again without the ticket.
    sent_count = 0;
    pocket_steam_cancel_ticket(s, crc);
    Frame emptied = frame_at(0);
    CHECK(emptied.message == 5432 && !pocket_proto_find(emptied.body, emptied.body_size, 4, &entry));
    CHECK(!pocket_steam_ticket_acknowledged(s, crc));

    // Steam ending the session; a truncated frame; a frame that is not protobuf (ignored).
    pocket_proto_uint(&body, 1, 6);   // LoggedInElsewhere
    CHECK(deliver(s, 757, &header, &body) == 0);
    CHECK(pocket_steam_status(s, &result) == POCKET_STEAM_LOGGED_OFF && result == 6 && !pocket_steam_steam_id(s));
    const uint8_t truncated[] = {0xef, 0x02, 0x00, 0x80, 0xff, 0x00, 0x00, 0x00};
    CHECK(pocket_steam_receive(s, truncated, sizeof truncated) == -1);
    const uint8_t legacy[] = {0x01, 0x00, 0x00, 0x00, 0x24, 0x02};
    CHECK(pocket_steam_receive(s, legacy, sizeof legacy) == 0);

    pocket_proto_free(&header);
    pocket_steam_destroy(s);
    if (failures) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    puts("steam session: all checks passed");
    return 0;
}
