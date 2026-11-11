// The part of Steamworks' ABI the Brighter Shores client uses, as the offline
// adapter (Steam.c) implements it. Interface versions and slot counts are those of
// the Steamworks headers the client was built with: SteamUser023, SteamFriends017,
// SteamUtils010 and STEAMAPPS_INTERFACE_VERSION008.
#pragma once
#include <stdint.h>

#define STEAM_APP_ID 2791440u
#define STEAM_USER_VERSION "SteamUser023"
#define STEAM_FRIENDS_VERSION "SteamFriends017"
#define STEAM_UTILS_VERSION "SteamUtils010"
#define STEAM_APPS_VERSION "STEAMAPPS_INTERFACE_VERSION008"
// Virtual functions in each interface's table, private ones included.
enum { STEAM_USER_SLOTS = 33, STEAM_FRIENDS_SLOTS = 80, STEAM_UTILS_SLOTS = 39, STEAM_APPS_SLOTS = 33 };

enum { STEAM_INIT_OK = 0 };                           // ESteamAPIInitResult
enum { STEAM_RESULT_OK = 1, STEAM_RESULT_NO_CONNECTION = 3 };   // EResult
// Callback numbers: k_iSteamUserCallbacks (100) plus the struct's offset.
enum { STEAM_CALLBACK_MICROTXN_AUTHORIZATION = 152, STEAM_CALLBACK_TICKET_FOR_WEB_API = 168 };

// GetTicketForWebApiResponse_t (4-byte packing on macOS, as on every non-Windows platform).
#define STEAM_TICKET_MAX 2560
typedef struct {
    uint32_t ticket;          // HAuthTicket
    int32_t result;           // EResult
    int32_t size;
    uint8_t bytes[STEAM_TICKET_MAX];
} SteamTicketForWebApiResponse;

// The flat functions the client imports.
int SteamInternal_SteamAPI_Init(const char *versions, char *error);
void SteamAPI_Shutdown(void);
int32_t SteamAPI_GetHSteamUser(void);
void *SteamInternal_FindOrCreateUserInterface(int32_t user, const char *version);
void *SteamInternal_ContextInit(void *data);
void SteamAPI_RegisterCallback(void *callback, int number);
void SteamAPI_UnregisterCallback(void *callback);
void SteamAPI_RunCallbacks(void);
