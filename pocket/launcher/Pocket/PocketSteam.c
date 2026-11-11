// Steam's client protocol for Brighter Pocket (PocketSteam.h). Message numbers and fields are
// Steam's own (SteamKit2's emsg.steamd and SteamDatabase's Protobufs name them); the auth ticket
// is laid out as the Steam client lays it out, as SteamKit2's SteamAuthTicket reproduces it.
#define _POSIX_C_SOURCE 200809L   // clock_gettime under -std=c11
#include "PocketSteam.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

// CRC-32 (IEEE, as zlib's crc32): Steam names a registered ticket by it.
static uint32_t crc32_of(const uint8_t *data, size_t size) {
    uint32_t crc = 0xffffffffu;
    for (size_t i = 0; i < size; i++) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
    }
    return ~crc;
}

enum {   // EMsg
    MSG_MULTI = 1,
    MSG_SERVICE_METHOD_RESPONSE = 147,
    MSG_SERVICE_METHOD_CALL = 151,
    MSG_HEARTBEAT = 703,
    MSG_LOG_OFF = 706,
    MSG_LOGON_RESPONSE = 751,
    MSG_LOGGED_OFF = 757,
    MSG_ACCOUNT_INFO = 768,
    MSG_GAME_CONNECT_TOKENS = 779,
    MSG_OWNERSHIP_TICKET = 857,
    MSG_OWNERSHIP_TICKET_RESPONSE = 858,
    MSG_GAMES_PLAYED = 5410,
    MSG_AUTH_LIST = 5432,
    MSG_LOGON = 5514,
    MSG_AUTH_LIST_ACK = 5575,
    MSG_SERVICE_METHOD_CALL_NO_ACCOUNT = 9804,
    MSG_HELLO = 9805,
    PROTOBUF_FLAG = 0x80000000u,
};
enum {
    PROTOCOL_VERSION = 65581,
    MAX_TOKENS = 32,
    MAX_TICKETS = 16,
    MAX_REPLIES = 8,
    MAX_DEPTH = 4,                 // nested multi messages
    MAX_INFLATED = 16 << 20,
    TICKET_TYPE_WEB_API = 5,       // SteamKit2's TicketType.WebApiTicket
};
static const uint64_t STEAM_ID_UNKNOWN_INDIVIDUAL = 0x0110000100000000ull;   // public universe, before logon

typedef struct {
    uint32_t app_id, crc;
    uint8_t *ticket, *secret;
    size_t ticket_size, secret_size;
    int acknowledged;
} Ticket;

struct PocketSteamSession {
    PocketSteamSend send;
    void *context;
    PocketSteamRandom random;
    PocketSteamGunzip gunzip;
    PocketSteamStatus status;
    int result, heartbeat_seconds;
    uint64_t steam_id, next_job;
    int32_t session_id;
    char persona[129];
    uint8_t *tokens[MAX_TOKENS];
    size_t token_sizes[MAX_TOKENS], token_count, max_tokens;
    uint32_t ownership_app;
    int ownership_answered, ownership_result;
    uint8_t *ownership_ticket;
    size_t ownership_size;
    Ticket tickets[MAX_TICKETS];
    size_t ticket_count;
    uint32_t sequence;
    struct { uint64_t job; int result; uint8_t *body; size_t size; } replies[MAX_REPLIES];
    size_t reply_count;
    uint8_t *taken;   // the body the last pocket_steam_reply handed out
};

// --- protobuf ---------------------------------------------------------------------------------
static void reserve(PocketProto *p, size_t more) {
    if (p->failed || p->size + more <= p->capacity) return;
    size_t capacity = p->capacity ? p->capacity : 64;
    while (capacity < p->size + more) capacity *= 2;
    uint8_t *grown = realloc(p->data, capacity);
    if (!grown) { p->failed = 1; return; }
    p->data = grown;
    p->capacity = capacity;
}
static void append(PocketProto *p, const void *data, size_t size) {
    reserve(p, size);
    if (p->failed || !size) return;
    memcpy(p->data + p->size, data, size);
    p->size += size;
}
static void varint(PocketProto *p, uint64_t value) {
    uint8_t bytes[10];
    size_t n = 0;
    do { bytes[n++] = (uint8_t)((value & 127) | (value > 127 ? 128 : 0)); value >>= 7; } while (value);
    append(p, bytes, n);
}
static void little(PocketProto *p, uint64_t value, size_t size) {
    uint8_t bytes[8];
    for (size_t i = 0; i < size; i++) bytes[i] = (uint8_t)(value >> (8 * i));
    append(p, bytes, size);
}
void pocket_proto_free(PocketProto *p) { free(p->data); memset(p, 0, sizeof *p); }
void pocket_proto_uint(PocketProto *p, unsigned field, uint64_t value) { varint(p, (uint64_t)field << 3); varint(p, value); }
void pocket_proto_fixed64(PocketProto *p, unsigned field, uint64_t value) { varint(p, ((uint64_t)field << 3) | 1); little(p, value, 8); }
void pocket_proto_bytes(PocketProto *p, unsigned field, const void *data, size_t size) {
    varint(p, ((uint64_t)field << 3) | 2);
    varint(p, size);
    append(p, data, size);
}
void pocket_proto_string(PocketProto *p, unsigned field, const char *text) { pocket_proto_bytes(p, field, text, strlen(text)); }
void pocket_proto_message(PocketProto *p, unsigned field, const PocketProto *message) {
    if (message->failed) p->failed = 1;
    pocket_proto_bytes(p, field, message->data, message->size);
}

static int read_varint(const uint8_t **position, const uint8_t *end, uint64_t *value) {
    *value = 0;
    for (unsigned shift = 0; shift < 70; shift += 7) {
        if (*position >= end) return 0;
        uint8_t byte = *(*position)++;
        if (shift == 63 && (byte & 0xfe)) return 0;
        *value |= (uint64_t)(byte & 127) << shift;
        if (!(byte & 128)) return 1;
    }
    return 0;
}
static uint64_t read_little(const uint8_t *data, size_t size) {
    uint64_t value = 0;
    for (size_t i = 0; i < size; i++) value |= (uint64_t)data[i] << (8 * i);
    return value;
}
int pocket_proto_next(const uint8_t **position, const uint8_t *end, PocketField *field) {
    if (*position >= end) return 0;
    uint64_t tag;
    if (!read_varint(position, end, &tag) || !(tag >> 3) || (tag >> 3) > 0x1fffffff) return -1;
    memset(field, 0, sizeof *field);
    field->field = (unsigned)(tag >> 3);
    field->wire = (unsigned)(tag & 7);
    size_t left;
    switch (field->wire) {
    case 0:
        return read_varint(position, end, &field->value) ? 1 : -1;
    case 1:
    case 5:
        left = (size_t)(end - *position);
        if (left < (field->wire == 1 ? 8u : 4u)) return -1;
        field->value = read_little(*position, field->wire == 1 ? 8 : 4);
        *position += field->wire == 1 ? 8 : 4;
        return 1;
    case 2:
        if (!read_varint(position, end, &field->value) || field->value > (uint64_t)(end - *position)) return -1;
        field->data = *position;
        field->size = (size_t)field->value;
        *position += field->size;
        return 1;
    default:
        return -1;
    }
}
int pocket_proto_find(const uint8_t *data, size_t size, unsigned number, PocketField *found) {
    const uint8_t *position = data, *end = data + size;
    PocketField field;
    int present = 0, step;
    while ((step = pocket_proto_next(&position, end, &field)) == 1)
        if (field.field == number) { *found = field; present = 1; }
    return step < 0 ? 0 : present;
}
// Every field of a message parses (the whole message is well formed).
static int well_formed(const uint8_t *data, size_t size) {
    const uint8_t *position = data, *end = data + size;
    PocketField field;
    int step;
    while ((step = pocket_proto_next(&position, end, &field)) == 1) {}
    return step == 0;
}
static uint64_t number_of(const uint8_t *data, size_t size, unsigned number, uint64_t fallback) {
    PocketField field;
    return pocket_proto_find(data, size, number, &field) && field.wire != 2 ? field.value : fallback;
}

// --- frames -------------------------------------------------------------------------------------
static void send_message(PocketSteamSession *s, uint32_t message, const PocketProto *body, uint64_t job,
                         const char *method) {
    PocketProto header = {0}, frame = {0};
    pocket_proto_fixed64(&header, 1, s->steam_id ? s->steam_id : STEAM_ID_UNKNOWN_INDIVIDUAL);
    pocket_proto_uint(&header, 2, (uint64_t)(int64_t)s->session_id);
    if (job) pocket_proto_fixed64(&header, 10, job);
    if (method) pocket_proto_string(&header, 12, method);
    little(&frame, message | PROTOBUF_FLAG, 4);
    little(&frame, header.size, 4);
    append(&frame, header.data, header.size);
    if (body) append(&frame, body->data, body->size);
    if (!frame.failed && !header.failed && !(body && body->failed)) s->send(s->context, frame.data, frame.size);
    pocket_proto_free(&header);
    pocket_proto_free(&frame);
}

PocketSteamSession *pocket_steam_create(PocketSteamSend send, void *context, PocketSteamRandom random,
                                        PocketSteamGunzip gunzip) {
    PocketSteamSession *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->send = send;
    s->context = context;
    s->random = random;
    s->gunzip = gunzip;
    s->max_tokens = 10;
    s->heartbeat_seconds = 9;
    random(&s->next_job, sizeof s->next_job);
    s->next_job &= 0x00ffffffffffffffull;   // room to count up
    return s;
}

static void forget_tickets(PocketSteamSession *s) {
    for (size_t i = 0; i < s->ticket_count; i++) { free(s->tickets[i].ticket); free(s->tickets[i].secret); }
    s->ticket_count = 0;
}
void pocket_steam_destroy(PocketSteamSession *s) {
    if (!s) return;
    for (size_t i = 0; i < s->token_count; i++) free(s->tokens[i]);
    for (size_t i = 0; i < s->reply_count; i++) free(s->replies[i].body);
    forget_tickets(s);
    free(s->ownership_ticket);
    free(s->taken);
    free(s);
}

void pocket_steam_hello(PocketSteamSession *s) {
    PocketProto body = {0};
    pocket_proto_uint(&body, 1, PROTOCOL_VERSION);
    send_message(s, MSG_HELLO, &body, 0, NULL);
    pocket_proto_free(&body);
    if (s->status == POCKET_STEAM_DISCONNECTED) s->status = POCKET_STEAM_CONNECTED;
}

// CMsgClientLogon, as Tolkara's Steam Cloud client sends it: the protocol, a random login ID
// (Steam ends an older session with the same one), and the refresh token as the access token.
void pocket_steam_logon(PocketSteamSession *s, const char *account, const char *refresh_token,
                        const char *machine_name) {
    uint32_t login_id;
    s->random(&login_id, sizeof login_id);
    PocketProto address = {0}, body = {0};
    varint(&address, (1 << 3) | 5);   // CMsgIPAddress.v4, fixed32
    little(&address, login_id, 4);
    pocket_proto_uint(&body, 1, PROTOCOL_VERSION);
    pocket_proto_uint(&body, 2, login_id);
    pocket_proto_uint(&body, 5, 1771);         // client_package_version
    pocket_proto_string(&body, 6, "english");
    pocket_proto_uint(&body, 7, 20);           // client_os_type
    pocket_proto_uint(&body, 8, 1);            // should_remember_password
    pocket_proto_message(&body, 11, &address); // obfuscated_private_ip
    pocket_proto_string(&body, 50, account);
    pocket_proto_string(&body, 96, machine_name);
    pocket_proto_uint(&body, 102, 1);          // supports_rate_limit_response
    pocket_proto_string(&body, 108, refresh_token);
    s->steam_id = 0;
    s->session_id = 0;
    send_message(s, MSG_LOGON, &body, 0, NULL);
    pocket_proto_free(&address);
    pocket_proto_free(&body);
    s->status = POCKET_STEAM_LOGGING_ON;
}

void pocket_steam_logoff(PocketSteamSession *s) { send_message(s, MSG_LOG_OFF, NULL, 0, NULL); }
void pocket_steam_heartbeat(PocketSteamSession *s) { send_message(s, MSG_HEARTBEAT, NULL, 0, NULL); }

PocketSteamStatus pocket_steam_status(const PocketSteamSession *s, int *result) {
    if (result) *result = s->result;
    return s->status;
}
uint64_t pocket_steam_steam_id(const PocketSteamSession *s) { return s->status == POCKET_STEAM_ONLINE ? s->steam_id : 0; }
const char *pocket_steam_persona_name(const PocketSteamSession *s) { return s->persona; }
int pocket_steam_heartbeat_seconds(const PocketSteamSession *s) { return s->heartbeat_seconds; }
size_t pocket_steam_connect_tokens(const PocketSteamSession *s) { return s->token_count; }

// --- receiving ------------------------------------------------------------------------------------
static uint8_t *copy(const uint8_t *data, size_t size) {
    uint8_t *out = malloc(size ? size : 1);
    if (out && size) memcpy(out, data, size);
    return out;
}

static void receive_tokens(PocketSteamSession *s, const uint8_t *body, size_t size) {
    const uint8_t *position = body, *end = body + size;
    PocketField field;
    s->max_tokens = (size_t)number_of(body, size, 1, 10);
    if (s->max_tokens > MAX_TOKENS) s->max_tokens = MAX_TOKENS;
    while (pocket_proto_next(&position, end, &field) == 1) {
        if (field.field != 2 || field.wire != 2) continue;
        if (s->token_count == MAX_TOKENS) {   // keep the newest
            free(s->tokens[0]);
            memmove(s->tokens, s->tokens + 1, (MAX_TOKENS - 1) * sizeof *s->tokens);
            memmove(s->token_sizes, s->token_sizes + 1, (MAX_TOKENS - 1) * sizeof *s->token_sizes);
            s->token_count--;
        }
        uint8_t *token = copy(field.data, field.size);
        if (!token) continue;
        s->tokens[s->token_count] = token;
        s->token_sizes[s->token_count++] = field.size;
    }
    while (s->token_count > s->max_tokens) {   // Steam says how many to keep: drop the oldest
        free(s->tokens[0]);
        memmove(s->tokens, s->tokens + 1, (s->token_count - 1) * sizeof *s->tokens);
        memmove(s->token_sizes, s->token_sizes + 1, (s->token_count - 1) * sizeof *s->token_sizes);
        s->token_count--;
    }
}

static void receive_reply(PocketSteamSession *s, uint64_t job, int result, const uint8_t *body, size_t size) {
    if (s->reply_count == MAX_REPLIES) {   // drop the oldest unclaimed reply
        free(s->replies[0].body);
        memmove(s->replies, s->replies + 1, (MAX_REPLIES - 1) * sizeof *s->replies);
        s->reply_count--;
    }
    uint8_t *kept = copy(body, size);
    if (!kept) return;
    s->replies[s->reply_count].job = job;
    s->replies[s->reply_count].result = result;
    s->replies[s->reply_count].body = kept;
    s->replies[s->reply_count++].size = size;
}

static int receive_frame(PocketSteamSession *s, const uint8_t *frame, size_t size, int depth);

// CMsgMulti: frames packed together, gzipped when size_unzipped is set.
static int receive_multi(PocketSteamSession *s, const uint8_t *body, size_t size, int depth) {
    PocketField payload;
    if (depth >= MAX_DEPTH || !pocket_proto_find(body, size, 2, &payload) || payload.wire != 2) return -1;
    uint64_t inflated_size = number_of(body, size, 1, 0);
    uint8_t *inflated = NULL;
    const uint8_t *data = payload.data;
    size_t data_size = payload.size;
    if (inflated_size) {
        if (inflated_size > MAX_INFLATED || !(inflated = malloc((size_t)inflated_size))) return -1;
        if (s->gunzip(payload.data, payload.size, inflated, (size_t)inflated_size) != 0) { free(inflated); return -1; }
        data = inflated;
        data_size = (size_t)inflated_size;
    }
    int failed = 0;
    for (size_t offset = 0; offset < data_size && !failed;) {
        if (data_size - offset < 4) { failed = 1; break; }
        uint32_t length = (uint32_t)read_little(data + offset, 4);
        offset += 4;
        if (length > data_size - offset) { failed = 1; break; }
        failed = receive_frame(s, data + offset, length, depth + 1) < 0;
        offset += length;
    }
    free(inflated);
    return failed ? -1 : 0;
}

static int receive_frame(PocketSteamSession *s, const uint8_t *frame, size_t size, int depth) {
    if (size < 4) return -1;
    uint32_t message = (uint32_t)read_little(frame, 4);
    if (!(message & PROTOBUF_FLAG)) return 0;   // the older, non-protobuf messages: none this needs
    message &= ~PROTOBUF_FLAG;
    if (size < 8) return -1;
    uint32_t header_size = (uint32_t)read_little(frame + 4, 4);
    if (header_size > size - 8) return -1;
    const uint8_t *header = frame + 8, *body = header + header_size;
    size_t body_size = size - 8 - header_size;
    if (!well_formed(header, header_size) || !well_formed(body, body_size)) return -1;
    PocketField field;

    switch (message) {
    case MSG_MULTI:
        return receive_multi(s, body, body_size, depth);
    case MSG_LOGON_RESPONSE:
        s->result = (int)number_of(body, body_size, 1, 2);
        if (s->result == POCKET_STEAM_RESULT_OK) {
            s->steam_id = number_of(header, header_size, 1, 0);
            s->session_id = (int32_t)number_of(header, header_size, 2, 0);
            int seconds = (int)number_of(body, body_size, 3, 0);
            if (seconds > 0) s->heartbeat_seconds = seconds;
            s->status = POCKET_STEAM_ONLINE;
        } else {
            s->status = POCKET_STEAM_REFUSED;
        }
        return 0;
    case MSG_LOGGED_OFF:
        s->result = (int)number_of(body, body_size, 1, 2);
        s->status = POCKET_STEAM_LOGGED_OFF;
        return 0;
    case MSG_ACCOUNT_INFO:
        if (pocket_proto_find(body, body_size, 1, &field) && field.wire == 2) {
            size_t n = field.size < sizeof s->persona - 1 ? field.size : sizeof s->persona - 1;
            memcpy(s->persona, field.data, n);
            s->persona[n] = 0;
        }
        return 0;
    case MSG_GAME_CONNECT_TOKENS:
        receive_tokens(s, body, body_size);
        return 0;
    case MSG_OWNERSHIP_TICKET_RESPONSE:
        if ((uint32_t)number_of(body, body_size, 2, 0) != s->ownership_app) return 0;
        s->ownership_answered = 1;
        s->ownership_result = (int)number_of(body, body_size, 1, 2);
        free(s->ownership_ticket);
        s->ownership_ticket = NULL;
        s->ownership_size = 0;
        if (s->ownership_result == POCKET_STEAM_RESULT_OK && pocket_proto_find(body, body_size, 3, &field) &&
            field.wire == 2 && field.size && (s->ownership_ticket = copy(field.data, field.size)))
            s->ownership_size = field.size;
        return 0;
    case MSG_AUTH_LIST_ACK: {
        const uint8_t *position = body, *end = body + body_size;
        while (pocket_proto_next(&position, end, &field) == 1)
            if (field.field == 1 && field.wire == 0)
                for (size_t i = 0; i < s->ticket_count; i++)
                    if (s->tickets[i].crc == (uint32_t)field.value) s->tickets[i].acknowledged = 1;
        return 0;
    }
    case MSG_SERVICE_METHOD_RESPONSE:
        receive_reply(s, number_of(header, header_size, 11, 0), (int)number_of(header, header_size, 13, 2), body,
                      body_size);
        return 0;
    default:
        return 0;
    }
}

int pocket_steam_receive(PocketSteamSession *s, const uint8_t *frame, size_t size) {
    return receive_frame(s, frame, size, 0);
}

// --- service calls ---------------------------------------------------------------------------
uint64_t pocket_steam_call(PocketSteamSession *s, const char *method, const uint8_t *body, size_t size) {
    PocketProto message = {0};
    append(&message, body, size);
    uint64_t job = ++s->next_job;
    send_message(s, s->status == POCKET_STEAM_ONLINE ? MSG_SERVICE_METHOD_CALL : MSG_SERVICE_METHOD_CALL_NO_ACCOUNT,
                 &message, job, method);
    pocket_proto_free(&message);
    return job;
}

int pocket_steam_reply(PocketSteamSession *s, uint64_t job, int *result, const uint8_t **body, size_t *size) {
    for (size_t i = 0; i < s->reply_count; i++) {
        if (s->replies[i].job != job) continue;
        free(s->taken);
        s->taken = s->replies[i].body;
        if (result) *result = s->replies[i].result;
        if (body) *body = s->taken;
        if (size) *size = s->replies[i].size;
        memmove(s->replies + i, s->replies + i + 1, (s->reply_count - i - 1) * sizeof *s->replies);
        s->reply_count--;
        return 1;
    }
    return 0;
}

// --- ownership and tickets ------------------------------------------------------------------------
void pocket_steam_request_ownership(PocketSteamSession *s, uint32_t app_id) {
    PocketProto body = {0};
    pocket_proto_uint(&body, 1, app_id);
    s->ownership_app = app_id;
    s->ownership_answered = 0;
    send_message(s, MSG_OWNERSHIP_TICKET, &body, ++s->next_job, NULL);
    pocket_proto_free(&body);
}

int pocket_steam_ownership(const PocketSteamSession *s, uint32_t app_id, int *result) {
    if (s->ownership_app != app_id || !s->ownership_answered) return 0;
    if (result) *result = s->ownership_result;
    return 1;
}

void pocket_steam_games_played(PocketSteamSession *s, uint32_t app_id) {
    PocketProto game = {0}, body = {0};
    if (app_id) {
        pocket_proto_fixed64(&game, 2, app_id);   // game_id
        pocket_proto_message(&body, 1, &game);
    }
    send_message(s, MSG_GAMES_PLAYED, &body, 0, NULL);
    pocket_proto_free(&game);
    pocket_proto_free(&body);
}

// CMsgClientAuthList: every ticket still held, as the Steam client sends the whole list each time.
static void send_auth_list(PocketSteamSession *s) {
    PocketProto body = {0};
    pocket_proto_uint(&body, 1, s->token_count);   // tokens_left
    for (size_t i = 0; i < s->ticket_count; i++) {
        const Ticket *t = &s->tickets[i];
        PocketProto entry = {0};
        pocket_proto_fixed64(&entry, 4, t->app_id);   // gameid
        pocket_proto_uint(&entry, 6, t->crc);
        pocket_proto_bytes(&entry, 7, t->ticket, t->ticket_size);
        if (t->secret) pocket_proto_bytes(&entry, 8, t->secret, t->secret_size);   // server_secret
        pocket_proto_message(&body, 4, &entry);
        pocket_proto_free(&entry);
    }
    for (size_t i = 0; i < s->ticket_count; i++) {   // app_ids, each once
        size_t first = 0;
        while (s->tickets[first].app_id != s->tickets[i].app_id) first++;
        if (first == i) pocket_proto_uint(&body, 5, s->tickets[i].app_id);
    }
    send_message(s, MSG_AUTH_LIST, &body, ++s->next_job, NULL);
    pocket_proto_free(&body);
}

static uint32_t milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint32_t)((uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000);
}

int pocket_steam_web_ticket(PocketSteamSession *s, uint32_t app_id, const char *identity,
                            uint8_t ticket[POCKET_STEAM_WEB_TICKET_SIZE], uint32_t *crc) {
    if (!s->token_count || !s->ownership_ticket || s->ownership_app != app_id) return -1;
    if (s->ticket_count == MAX_TICKETS) {   // the oldest goes, as a game would have cancelled it
        free(s->tickets[0].ticket);
        free(s->tickets[0].secret);
        memmove(s->tickets, s->tickets + 1, (MAX_TICKETS - 1) * sizeof *s->tickets);
        s->ticket_count--;
    }
    // The session part: [token size][game connect token][24][1][type][8 random][time][sequence].
    uint8_t *token = s->tokens[0];
    size_t token_size = s->token_sizes[0];
    memmove(s->tokens, s->tokens + 1, (s->token_count - 1) * sizeof *s->tokens);
    memmove(s->token_sizes, s->token_sizes + 1, (s->token_count - 1) * sizeof *s->token_sizes);
    s->token_count--;
    PocketProto session = {0};
    uint8_t addresses[8];
    s->random(addresses, sizeof addresses);
    little(&session, token_size, 4);
    append(&session, token, token_size);
    free(token);
    little(&session, 24, 4);
    little(&session, 1, 4);
    little(&session, TICKET_TYPE_WEB_API, 4);
    append(&session, addresses, sizeof addresses);
    little(&session, milliseconds(), 4);
    little(&session, ++s->sequence, 4);
    if (session.failed) { pocket_proto_free(&session); return -1; }

    size_t whole = session.size + 4 + s->ownership_size;
    if (whole > POCKET_STEAM_WEB_TICKET_SIZE) { pocket_proto_free(&session); return -1; }
    Ticket *t = &s->tickets[s->ticket_count];
    memset(t, 0, sizeof *t);
    t->app_id = app_id;
    t->crc = crc32_of(session.data, session.size);
    t->ticket = session.data;
    t->ticket_size = session.size;
    if (identity && *identity) {   // Steam's form: "str:" + identity + NUL
        size_t n = strlen(identity);
        if ((t->secret = malloc(n + 5))) {
            memcpy(t->secret, "str:", 4);
            memcpy(t->secret + 4, identity, n + 1);
            t->secret_size = n + 5;
        }
    }
    s->ticket_count++;
    send_auth_list(s);

    // What the game gets: the session part, the ownership ticket after its size, then filler
    // to the full 2,560 bytes, as Steam hands out a web API ticket.
    memcpy(ticket, session.data, session.size);
    for (int i = 0; i < 4; i++) ticket[session.size + i] = (uint8_t)(s->ownership_size >> (8 * i));
    memcpy(ticket + session.size + 4, s->ownership_ticket, s->ownership_size);
    s->random(ticket + whole, POCKET_STEAM_WEB_TICKET_SIZE - whole);
    if (crc) *crc = t->crc;
    return 0;
}

int pocket_steam_ticket_acknowledged(const PocketSteamSession *s, uint32_t crc) {
    for (size_t i = 0; i < s->ticket_count; i++)
        if (s->tickets[i].crc == crc) return s->tickets[i].acknowledged;
    return 0;
}

void pocket_steam_cancel_ticket(PocketSteamSession *s, uint32_t crc) {
    for (size_t i = 0; i < s->ticket_count; i++) {
        if (s->tickets[i].crc != crc) continue;
        free(s->tickets[i].ticket);
        free(s->tickets[i].secret);
        memmove(s->tickets + i, s->tickets + i + 1, (s->ticket_count - i - 1) * sizeof *s->tickets);
        s->ticket_count--;
        send_auth_list(s);
        return;
    }
}

void pocket_steam_register_tickets(PocketSteamSession *s) {
    if (s->ticket_count) send_auth_list(s);
}
