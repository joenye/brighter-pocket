// libsteam_api for a device with no Steam client.
//
// The macOS client links @loader_path/libsteam_api.dylib, Valve's library, which
// talks to a running Steam client. There is none on iOS, and the client exits at
// start when SteamAPI_Init fails ("Failed to init Steam"). This adapter takes the
// library's place (the staged client leaves Valve's file out). The app signs in to
// Steam itself before the game starts (pocket/launcher/Pocket) and lends this library
// its session through PocketSteamBridge.h: the account's Steam ID and persona name,
// and web API tickets built and registered with Steam as the Steam client makes them.
// Without a session (the player chose to play offline) it answers as Steam does when
// running but offline: initialisation succeeds, nobody is logged on, and a request
// for a ticket fails with "no connection". It opens no connection itself.
//
// The client imports eight flat functions and asks for four interfaces
// (docs/client-analysis.md). Each interface is a C++ object: a pointer to a table
// of virtual functions, called with the object in x0, so plain C functions in a
// table are what the client's calls reach. Every slot of each interface version is
// filled; the ones the client is not known to call log once and answer zero (or
// an empty string where the method returns one).
#include "Steam.h"
#include "PocketSteamBridge.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

void AKLogC(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#define LOG(...) AKLogC("[steam] " __VA_ARGS__)

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool initialized;
static atomic_uintptr_t init_count;   // what SteamInternal_ContextInit compares with
static time_t started;

// --- callbacks -------------------------------------------------------------------------
// CCallbackBase: the table of Run(void *), Run(void *, bool, SteamAPICall_t),
// GetCallbackSizeBytes(); then the flags byte and the callback number.
typedef struct {
    void (*const *vtable)(void *self, void *param);
    uint8_t flags;
    int32_t callback;
} CallbackBase;
enum { CALLBACK_REGISTERED = 1, MAX_CALLBACKS = 64, MAX_PENDING = 16 };
static CallbackBase *registered[MAX_CALLBACKS];

typedef struct {
    int32_t callback;
    uint32_t size;
    union { SteamTicketForWebApiResponse ticket; uint8_t bytes[sizeof(SteamTicketForWebApiResponse)]; } payload;
} Pending;
static Pending pending[MAX_PENDING];
static unsigned pending_count;
static uint32_t next_ticket = 1;

// --- the app's session ---------------------------------------------------------------------
static _Atomic(const PocketSteamBridge *) bridge;
static char persona[129] = "Player";
enum { MAX_ISSUED = 16 };
static struct { uint32_t handle, crc; } issued[MAX_ISSUED];   // tickets handed out, for cancelling
static unsigned issued_count;

static const PocketSteamBridge *session(void) {
    const PocketSteamBridge *b = atomic_load(&bridge);
    return b && b->account(NULL, NULL, 0) ? b : NULL;
}
static void find_session(void) {
    PocketSteamBridgeGetter get = (PocketSteamBridgeGetter)dlsym(RTLD_DEFAULT, POCKET_STEAM_BRIDGE_SYMBOL);
    const PocketSteamBridge *b = get ? get() : NULL;
    atomic_store(&bridge, b && b->version == POCKET_STEAM_BRIDGE_VERSION ? b : NULL);
}

static void post(int32_t callback, const void *payload, uint32_t size) {
    pthread_mutex_lock(&lock);
    if (pending_count < MAX_PENDING && size <= sizeof pending[0].payload) {
        Pending *p = &pending[pending_count++];
        p->callback = callback;
        p->size = size;
        memcpy(p->payload.bytes, payload, size);
    } else {
        LOG("callback %d dropped: queue full\n", callback);
    }
    pthread_mutex_unlock(&lock);
}

void SteamAPI_RegisterCallback(void *object, int callback) {
    CallbackBase *base = object;
    pthread_mutex_lock(&lock);
    base->flags |= CALLBACK_REGISTERED;
    base->callback = callback;
    size_t i = 0;
    while (i < MAX_CALLBACKS && registered[i] && registered[i] != base) i++;
    if (i < MAX_CALLBACKS) registered[i] = base;
    else LOG("cannot register callback %d: %d already registered\n", callback, MAX_CALLBACKS);
    pthread_mutex_unlock(&lock);
}

void SteamAPI_UnregisterCallback(void *object) {
    CallbackBase *base = object;
    pthread_mutex_lock(&lock);
    for (size_t i = 0; i < MAX_CALLBACKS; i++)
        if (registered[i] == base) registered[i] = NULL;
    base->flags &= (uint8_t)~CALLBACK_REGISTERED;
    pthread_mutex_unlock(&lock);
}

// Results posted since the last call reach every callback registered for them, on
// the caller's thread, as with Steam. A callback may register or post again.
void SteamAPI_RunCallbacks(void) {
    for (;;) {
        pthread_mutex_lock(&lock);
        if (!pending_count) { pthread_mutex_unlock(&lock); return; }
        Pending item = pending[0];
        memmove(pending, pending + 1, (pending_count - 1) * sizeof *pending);
        pending_count--;
        CallbackBase *targets[MAX_CALLBACKS];
        size_t count = 0;
        for (size_t i = 0; i < MAX_CALLBACKS; i++)
            if (registered[i] && registered[i]->callback == item.callback) targets[count++] = registered[i];
        pthread_mutex_unlock(&lock);
        for (size_t i = 0; i < count; i++) targets[i]->vtable[0](targets[i], item.payload.bytes);
    }
}

// --- the interfaces --------------------------------------------------------------------
typedef struct { const void *const *vtable; const char *version; } Interface;

static const char *persona_name(void) {
    const PocketSteamBridge *b = session();
    if (b) {
        pthread_mutex_lock(&lock);
        b->account(NULL, persona, sizeof persona);
        pthread_mutex_unlock(&lock);
    }
    return persona;
}
enum { User_INDEX, Friends_INDEX, Utils_INDEX, Apps_INDEX, INTERFACE_COUNT, MAX_SLOTS = 96 };
static void unexpected(int which, const char *version, int slot) {
    static uint8_t seen[INTERFACE_COUNT][MAX_SLOTS];
    if (slot < MAX_SLOTS && !__atomic_exchange_n(&seen[which][slot], 1, __ATOMIC_RELAXED))
        LOG("%s slot %d called: answered with zero\n", version, slot);
}
// One function per unused slot, so the log names the slot the client reached.
#define ZERO(iface, n) static uint64_t iface##_##n(void *self) { (void)self; unexpected(iface##_INDEX, iface##_VERSION, n); return 0; }
#define EMPTY(iface, n) static const char *iface##_##n(void *self) { (void)self; unexpected(iface##_INDEX, iface##_VERSION, n); return ""; }

// ISteamUser, "SteamUser023".
#define User_VERSION STEAM_USER_VERSION
static int32_t User_GetHSteamUser(void *self) { (void)self; return atomic_load(&initialized) ? 1 : 0; }
static bool User_BLoggedOn(void *self) { (void)self; return session() != NULL; }
static uint64_t User_GetSteamID(void *self) {   // k_steamIDNil when nobody is logged on
    (void)self;
    uint64_t id = 0;
    const PocketSteamBridge *b = session();
    if (b) b->account(&id, NULL, 0);
    return id;
}
// Steam answers with a handle at once and the ticket later, by callback.
static void ticket_done(void *context, int result, const uint8_t *ticket, uint32_t size, uint32_t crc) {
    uint32_t handle = (uint32_t)(uintptr_t)context;
    SteamTicketForWebApiResponse response = {.ticket = handle, .result = result, .size = 0};
    if (result == STEAM_RESULT_OK && ticket && size <= STEAM_TICKET_MAX) {
        memcpy(response.bytes, ticket, size);
        response.size = (int32_t)size;
        pthread_mutex_lock(&lock);
        if (issued_count == MAX_ISSUED) {   // the oldest goes; the game would have cancelled it
            memmove(issued, issued + 1, (MAX_ISSUED - 1) * sizeof *issued);
            issued_count--;
        }
        issued[issued_count].handle = handle;
        issued[issued_count++].crc = crc;
        pthread_mutex_unlock(&lock);
    }
    LOG("web API ticket %u: %s (%d bytes)\n", handle, result == STEAM_RESULT_OK ? "ready" : "failed", response.size);
    post(STEAM_CALLBACK_TICKET_FOR_WEB_API, &response, sizeof response);
}
static uint32_t User_GetAuthTicketForWebApi(void *self, const char *identity) {
    (void)self;
    pthread_mutex_lock(&lock);
    uint32_t handle = next_ticket++;
    pthread_mutex_unlock(&lock);
    const PocketSteamBridge *b = session();
    LOG("GetAuthTicketForWebApi(%s) -> %u%s\n", identity ? identity : "", handle,
        b ? "" : "; offline, the ticket will fail");
    if (b) {
        b->web_ticket(identity ? identity : "", ticket_done, (void *)(uintptr_t)handle);
    } else {
        SteamTicketForWebApiResponse response = {.ticket = handle, .result = STEAM_RESULT_NO_CONNECTION, .size = 0};
        post(STEAM_CALLBACK_TICKET_FOR_WEB_API, &response, sizeof response);
    }
    return handle;
}
static uint32_t User_GetAuthSessionTicket(void *self, void *ticket, int max, uint32_t *size, const void *identity) {
    (void)self; (void)ticket; (void)max; (void)identity;
    if (size) *size = 0;
    LOG("GetAuthSessionTicket: not served, no ticket\n");
    return 0;   // k_HAuthTicketInvalid
}
static void User_CancelAuthTicket(void *self, uint32_t ticket) {
    (void)self;
    uint32_t crc = 0;
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < pending_count; i++)
        if (pending[i].callback == STEAM_CALLBACK_TICKET_FOR_WEB_API && pending[i].payload.ticket.ticket == ticket) {
            memmove(pending + i, pending + i + 1, (pending_count - i - 1) * sizeof *pending);
            pending_count--;
            break;
        }
    for (unsigned i = 0; i < issued_count; i++)
        if (issued[i].handle == ticket) {
            crc = issued[i].crc;
            memmove(issued + i, issued + i + 1, (issued_count - i - 1) * sizeof *issued);
            issued_count--;
            break;
        }
    pthread_mutex_unlock(&lock);
    const PocketSteamBridge *b = atomic_load(&bridge);
    if (crc && b) b->cancel_ticket(crc);
}
static int32_t User_GetPlayerSteamLevel(void *self) { (void)self; return 0; }
ZERO(User, 3) ZERO(User, 4) ZERO(User, 5) ZERO(User, 6) ZERO(User, 7) ZERO(User, 8) ZERO(User, 9) ZERO(User, 10)
ZERO(User, 11) ZERO(User, 12) ZERO(User, 15) ZERO(User, 16) ZERO(User, 18) ZERO(User, 19) ZERO(User, 20)
ZERO(User, 21) ZERO(User, 22) ZERO(User, 23) ZERO(User, 25) ZERO(User, 26) ZERO(User, 27) ZERO(User, 28)
ZERO(User, 29) ZERO(User, 30) ZERO(User, 31) ZERO(User, 32)
static const void *const user_vtable[STEAM_USER_SLOTS] = {
    User_GetHSteamUser, User_BLoggedOn, User_GetSteamID, User_3, User_4, User_5, User_6, User_7, User_8, User_9,
    User_10, User_11, User_12, User_GetAuthSessionTicket, User_GetAuthTicketForWebApi, User_15, User_16,
    User_CancelAuthTicket, User_18, User_19, User_20, User_21, User_22, User_23, User_GetPlayerSteamLevel, User_25,
    User_26, User_27, User_28, User_29, User_30, User_31, User_32,
};

// ISteamFriends, "SteamFriends017".
#define Friends_VERSION STEAM_FRIENDS_VERSION
static const char *Friends_GetPersonaName(void *self) { (void)self; return persona_name(); }
static int32_t Friends_GetPersonaState(void *self) { (void)self; return session() ? 1 : 0; }   // online, or offline
static int32_t Friends_GetFriendCount(void *self, int flags) { (void)self; (void)flags; return 0; }
ZERO(Friends, 1) ZERO(Friends, 4) ZERO(Friends, 5) ZERO(Friends, 6) EMPTY(Friends, 7) ZERO(Friends, 8)
EMPTY(Friends, 9) ZERO(Friends, 10) EMPTY(Friends, 11) ZERO(Friends, 12) ZERO(Friends, 13) EMPTY(Friends, 14)
ZERO(Friends, 15) ZERO(Friends, 16) ZERO(Friends, 17) ZERO(Friends, 18) ZERO(Friends, 19) EMPTY(Friends, 20)
EMPTY(Friends, 21) ZERO(Friends, 22) ZERO(Friends, 23) ZERO(Friends, 24) ZERO(Friends, 25) ZERO(Friends, 26)
ZERO(Friends, 27) ZERO(Friends, 28) ZERO(Friends, 29) ZERO(Friends, 30) ZERO(Friends, 31) ZERO(Friends, 32)
ZERO(Friends, 33) ZERO(Friends, 34) ZERO(Friends, 35) ZERO(Friends, 36) ZERO(Friends, 37) ZERO(Friends, 38)
ZERO(Friends, 39) ZERO(Friends, 40) ZERO(Friends, 41) ZERO(Friends, 42) ZERO(Friends, 43) ZERO(Friends, 44)
EMPTY(Friends, 45) ZERO(Friends, 46) EMPTY(Friends, 47) ZERO(Friends, 48) ZERO(Friends, 49) ZERO(Friends, 50)
ZERO(Friends, 51) ZERO(Friends, 52) ZERO(Friends, 53) ZERO(Friends, 54) ZERO(Friends, 55) ZERO(Friends, 56)
ZERO(Friends, 57) ZERO(Friends, 58) ZERO(Friends, 59) ZERO(Friends, 60) ZERO(Friends, 61) ZERO(Friends, 62)
ZERO(Friends, 63) ZERO(Friends, 64) ZERO(Friends, 65) ZERO(Friends, 66) ZERO(Friends, 67) ZERO(Friends, 68)
ZERO(Friends, 69) ZERO(Friends, 70) ZERO(Friends, 71) ZERO(Friends, 72) ZERO(Friends, 73) ZERO(Friends, 74)
ZERO(Friends, 75) ZERO(Friends, 76) ZERO(Friends, 77) EMPTY(Friends, 78) ZERO(Friends, 79)
static const void *const friends_vtable[STEAM_FRIENDS_SLOTS] = {
    Friends_GetPersonaName, Friends_1, Friends_GetPersonaState, Friends_GetFriendCount, Friends_4, Friends_5,
    Friends_6, Friends_7, Friends_8, Friends_9, Friends_10, Friends_11, Friends_12, Friends_13, Friends_14,
    Friends_15, Friends_16, Friends_17, Friends_18, Friends_19, Friends_20, Friends_21, Friends_22, Friends_23,
    Friends_24, Friends_25, Friends_26, Friends_27, Friends_28, Friends_29, Friends_30, Friends_31, Friends_32,
    Friends_33, Friends_34, Friends_35, Friends_36, Friends_37, Friends_38, Friends_39, Friends_40, Friends_41,
    Friends_42, Friends_43, Friends_44, Friends_45, Friends_46, Friends_47, Friends_48, Friends_49, Friends_50,
    Friends_51, Friends_52, Friends_53, Friends_54, Friends_55, Friends_56, Friends_57, Friends_58, Friends_59,
    Friends_60, Friends_61, Friends_62, Friends_63, Friends_64, Friends_65, Friends_66, Friends_67, Friends_68,
    Friends_69, Friends_70, Friends_71, Friends_72, Friends_73, Friends_74, Friends_75, Friends_76, Friends_77,
    Friends_78, Friends_79,
};

// ISteamUtils, "SteamUtils010".
#define Utils_VERSION STEAM_UTILS_VERSION
static uint32_t Utils_GetSecondsSinceAppActive(void *self) { (void)self; return (uint32_t)(time(NULL) - started); }
static uint32_t Utils_GetSecondsSinceComputerActive(void *self) { (void)self; return 0; }
static int32_t Utils_GetConnectedUniverse(void *self) { (void)self; return 1; }   // k_EUniversePublic
static uint32_t Utils_GetServerRealTime(void *self) { (void)self; return (uint32_t)time(NULL); }
static const char *Utils_GetIPCountry(void *self) { (void)self; return ""; }
static uint8_t Utils_GetCurrentBatteryPower(void *self) { (void)self; return 255; }   // on mains
static uint32_t Utils_GetAppID(void *self) { (void)self; return STEAM_APP_ID; }
static bool Utils_IsOverlayEnabled(void *self) { (void)self; return false; }
static bool Utils_BOverlayNeedsPresent(void *self) { (void)self; return false; }
static const char *Utils_GetSteamUILanguage(void *self) { (void)self; return "english"; }
static bool Utils_IsSteamRunningInVR(void *self) { (void)self; return false; }
static bool Utils_IsSteamInBigPictureMode(void *self) { (void)self; return false; }
static bool Utils_IsSteamRunningOnSteamDeck(void *self) { (void)self; return false; }
ZERO(Utils, 5) ZERO(Utils, 6) ZERO(Utils, 7) ZERO(Utils, 10) ZERO(Utils, 11) ZERO(Utils, 12)
ZERO(Utils, 13) ZERO(Utils, 14) ZERO(Utils, 15) ZERO(Utils, 16) ZERO(Utils, 19) ZERO(Utils, 20) ZERO(Utils, 21)
ZERO(Utils, 22) ZERO(Utils, 25) ZERO(Utils, 27) ZERO(Utils, 28) ZERO(Utils, 29) ZERO(Utils, 30) ZERO(Utils, 31)
ZERO(Utils, 32) ZERO(Utils, 33) ZERO(Utils, 35) ZERO(Utils, 36) ZERO(Utils, 37) ZERO(Utils, 38)
static const void *const utils_vtable[STEAM_UTILS_SLOTS] = {
    Utils_GetSecondsSinceAppActive, Utils_GetSecondsSinceComputerActive, Utils_GetConnectedUniverse,
    Utils_GetServerRealTime, Utils_GetIPCountry, Utils_5, Utils_6, Utils_7, Utils_GetCurrentBatteryPower,
    Utils_GetAppID, Utils_10, Utils_11, Utils_12, Utils_13, Utils_14, Utils_15, Utils_16, Utils_IsOverlayEnabled,
    Utils_BOverlayNeedsPresent, Utils_19, Utils_20, Utils_21, Utils_22, Utils_GetSteamUILanguage,
    Utils_IsSteamRunningInVR, Utils_25, Utils_IsSteamInBigPictureMode, Utils_27, Utils_28, Utils_29, Utils_30,
    Utils_31, Utils_32, Utils_33, Utils_IsSteamRunningOnSteamDeck, Utils_35, Utils_36, Utils_37, Utils_38,
};

// ISteamApps, "STEAMAPPS_INTERFACE_VERSION008".
#define Apps_VERSION STEAM_APPS_VERSION
static bool Apps_BIsSubscribed(void *self) { (void)self; return true; }
static bool Apps_No(void *self) { (void)self; return false; }
static const char *Apps_GetCurrentGameLanguage(void *self) { (void)self; return "english"; }
static const char *Apps_GetAvailableGameLanguages(void *self) { (void)self; return "english"; }
static bool Apps_BIsSubscribedApp(void *self, uint32_t app) { (void)self; return app == STEAM_APP_ID; }
static bool Apps_GetCurrentBetaName(void *self, char *name, int size) {
    (void)self;
    if (name && size > 0) name[0] = 0;
    return false;   // the default branch
}
// The client asks this when its files look wrong. There is no Steam to repair
// them here: the log says so, and the device copy must be staged again.
static bool Apps_MarkContentCorrupt(void *self, bool missing_only) {
    (void)self;
    LOG("MarkContentCorrupt(missing files only: %d): stage the client again (tools/stage_client.py)\n", missing_only);
    return false;
}
static int32_t Apps_GetAppBuildId(void *self) { (void)self; return 0; }
static const char *Apps_GetLaunchQueryParam(void *self, const char *key) { (void)self; (void)key; return ""; }
ZERO(Apps, 7) ZERO(Apps, 8) ZERO(Apps, 10) ZERO(Apps, 11) ZERO(Apps, 12) ZERO(Apps, 13) ZERO(Apps, 14)
ZERO(Apps, 17) ZERO(Apps, 18) ZERO(Apps, 19) ZERO(Apps, 20) ZERO(Apps, 22) ZERO(Apps, 24) ZERO(Apps, 25)
ZERO(Apps, 26) ZERO(Apps, 27) ZERO(Apps, 28) ZERO(Apps, 29) ZERO(Apps, 30) ZERO(Apps, 31) ZERO(Apps, 32)
static const void *const apps_vtable[STEAM_APPS_SLOTS] = {
    Apps_BIsSubscribed, Apps_No, Apps_No, Apps_No, Apps_GetCurrentGameLanguage, Apps_GetAvailableGameLanguages,
    Apps_BIsSubscribedApp, Apps_7, Apps_8, Apps_No, Apps_10, Apps_11, Apps_12, Apps_13, Apps_14,
    Apps_GetCurrentBetaName, Apps_MarkContentCorrupt, Apps_17, Apps_18, Apps_19, Apps_20, Apps_GetLaunchQueryParam,
    Apps_22, Apps_GetAppBuildId, Apps_24, Apps_25, Apps_26, Apps_27, Apps_28, Apps_29, Apps_30, Apps_31, Apps_32,
};

static Interface interfaces[] = {
    {(const void *const *)user_vtable, STEAM_USER_VERSION},
    {(const void *const *)friends_vtable, STEAM_FRIENDS_VERSION},
    {(const void *const *)utils_vtable, STEAM_UTILS_VERSION},
    {(const void *const *)apps_vtable, STEAM_APPS_VERSION},
};

// --- the flat API ----------------------------------------------------------------------
// The list names every interface version the client was built against, each
// NUL-terminated, ending with an empty one. Steam checks it can serve them all;
// offline, the ones this adapter lacks are only logged: the client asks for the
// interfaces it uses by name later and gets NULL for any other.
int SteamInternal_SteamAPI_Init(const char *versions, char *error) {
    if (error) error[0] = 0;
    for (const char *v = versions; v && *v; v += strlen(v) + 1) {
        bool served = false;
        for (size_t i = 0; i < sizeof interfaces / sizeof *interfaces; i++)
            served |= !strcmp(v, interfaces[i].version);
        if (!served) LOG("interface %s is not served offline\n", v);
    }
    if (!atomic_exchange(&initialized, true)) {
        started = time(NULL);
        atomic_fetch_add(&init_count, 1);
    }
    find_session();
    if (session())
        LOG("initialised: signed in to Steam through the app's session\n");
    else
        LOG("initialised offline: not logged on, no connection\n");
    return STEAM_INIT_OK;
}

void SteamAPI_Shutdown(void) {
    atomic_store(&initialized, false);
    pthread_mutex_lock(&lock);
    pending_count = 0;
    pthread_mutex_unlock(&lock);
}

int32_t SteamAPI_GetHSteamUser(void) { return atomic_load(&initialized) ? 1 : 0; }

void *SteamInternal_FindOrCreateUserInterface(int32_t user, const char *version) {
    (void)user;
    if (!version) return NULL;
    for (size_t i = 0; i < sizeof interfaces / sizeof *interfaces; i++)
        if (!strcmp(version, interfaces[i].version)) return &interfaces[i];
    LOG("interface %s requested: not served\n", version);
    return NULL;
}

// The steam_api.h accessors: { void (*fill)(void *context); uintptr_t counter;
// context }. The context is (re)filled once per initialisation, then handed out.
typedef struct { void (*fill)(void *context); uintptr_t counter; uint8_t context[]; } ContextInitData;
void *SteamInternal_ContextInit(void *data) {
    ContextInitData *init = data;
    uintptr_t now = atomic_load(&init_count);
    if (__atomic_load_n(&init->counter, __ATOMIC_ACQUIRE) != now) {
        pthread_mutex_lock(&lock);
        if (init->counter != now) {
            init->fill(init->context);
            __atomic_store_n(&init->counter, now, __ATOMIC_RELEASE);
        }
        pthread_mutex_unlock(&lock);
    }
    return init->context;
}
