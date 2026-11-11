// The offline Steam adapter (pocket/translation/libsteam_api/Steam.c), driven the way
// the client drives Valve's library: through C++ interfaces and callback objects laid
// out by the compiler, so a wrong slot or field offset in the adapter fails here.
// Builds and runs on the host (tests/run.sh): the Itanium C++ ABI lays these out the
// same on x86_64 and arm64.
#include <cassert>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

extern "C" {
#include "Steam.h"
}

static std::string logged;
extern "C" void AKLogC(const char *fmt, ...) {
    char line[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof line, fmt, args);
    va_end(args);
    logged += line;
}

// The interfaces' first slots as the Steamworks headers declare them.
struct ISteamUser {
    virtual int32_t GetHSteamUser() = 0;
    virtual bool BLoggedOn() = 0;
    virtual uint64_t GetSteamID() = 0;
    virtual int InitiateGameConnection_DEPRECATED(void *, int, uint64_t, uint32_t, uint16_t, bool) = 0;
    virtual void TerminateGameConnection_DEPRECATED(uint32_t, uint16_t) = 0;
    virtual void TrackAppUsageEvent(uint64_t, int, const char *) = 0;
    virtual bool GetUserDataFolder(char *, int) = 0;
    virtual void StartVoiceRecording() = 0;
    virtual void StopVoiceRecording() = 0;
    virtual int GetAvailableVoice(uint32_t *, uint32_t *, uint32_t) = 0;
    virtual int GetVoice(bool, void *, uint32_t, uint32_t *, bool, void *, uint32_t, uint32_t *, uint32_t) = 0;
    virtual int DecompressVoice(const void *, uint32_t, void *, uint32_t, uint32_t *, uint32_t) = 0;
    virtual uint32_t GetVoiceOptimalSampleRate() = 0;
    virtual uint32_t GetAuthSessionTicket(void *, int, uint32_t *, const void *) = 0;
    virtual uint32_t GetAuthTicketForWebApi(const char *identity) = 0;
    virtual int BeginAuthSession(const void *, int, uint64_t) = 0;
    virtual void EndAuthSession(uint64_t) = 0;
    virtual void CancelAuthTicket(uint32_t ticket) = 0;
};
struct ISteamFriends {
    virtual const char *GetPersonaName() = 0;
    virtual uint64_t SetPersonaName(const char *) = 0;
    virtual int GetPersonaState() = 0;
};
struct ISteamUtils {
    virtual uint32_t GetSecondsSinceAppActive() = 0;
    virtual uint32_t GetSecondsSinceComputerActive() = 0;
    virtual int GetConnectedUniverse() = 0;
    virtual uint32_t GetServerRealTime() = 0;
    virtual const char *GetIPCountry() = 0;
    virtual bool GetImageSize(int, uint32_t *, uint32_t *) = 0;
    virtual bool GetImageRGBA(int, uint8_t *, int) = 0;
    virtual bool GetCSERIPPort(uint32_t *, uint16_t *) = 0;
    virtual uint8_t GetCurrentBatteryPower() = 0;
    virtual uint32_t GetAppID() = 0;
    virtual void SetOverlayNotificationPosition(int) = 0;
    virtual bool IsAPICallCompleted(uint64_t, bool *) = 0;
    virtual int GetAPICallFailureReason(uint64_t) = 0;
    virtual bool GetAPICallResult(uint64_t, void *, int, int, bool *) = 0;
    virtual void RunFrame() = 0;
    virtual uint32_t GetIPCCallCount() = 0;
    virtual void SetWarningMessageHook(void *) = 0;
    virtual bool IsOverlayEnabled() = 0;
};
struct ISteamApps {
    virtual bool BIsSubscribed() = 0;
    virtual bool BIsLowViolence() = 0;
    virtual bool BIsCybercafe() = 0;
    virtual bool BIsVACBanned() = 0;
    virtual const char *GetCurrentGameLanguage() = 0;
    virtual const char *GetAvailableGameLanguages() = 0;
    virtual bool BIsSubscribedApp(uint32_t) = 0;
    virtual bool BIsDlcInstalled(uint32_t) = 0;
    virtual uint32_t GetEarliestPurchaseUnixTime(uint32_t) = 0;
    virtual bool BIsSubscribedFromFreeWeekend() = 0;
    virtual int GetDLCCount() = 0;
    virtual bool BGetDLCDataByIndex(int, uint32_t *, bool *, char *, int) = 0;
    virtual void InstallDLC(uint32_t) = 0;
    virtual void UninstallDLC(uint32_t) = 0;
    virtual void RequestAppProofOfPurchaseKey(uint32_t) = 0;
    virtual bool GetCurrentBetaName(char *, int) = 0;
    virtual bool MarkContentCorrupt(bool) = 0;
};

// steam_api_common.h's CCallbackBase and a CCallback-shaped subclass.
class CCallbackBase {
public:
    CCallbackBase() { m_nCallbackFlags = 0; m_iCallback = 0; }
    virtual void Run(void *pvParam) = 0;
    virtual void Run(void *pvParam, bool bIOFailure, uint64_t hSteamAPICall) = 0;
    int GetICallback() { return m_iCallback; }
    virtual int GetCallbackSizeBytes() = 0;
    uint8_t m_nCallbackFlags;
    int m_iCallback;
};
struct TicketCallback : CCallbackBase {
    int runs = 0;
    SteamTicketForWebApiResponse last{};
    void Run(void *param) override { runs++; memcpy(&last, param, sizeof last); }
    void Run(void *param, bool, uint64_t) override { Run(param); }
    int GetCallbackSizeBytes() override { return sizeof(SteamTicketForWebApiResponse); }
};

// What the client's accessors pass to SteamInternal_ContextInit.
struct UserContext { void (*fill)(void *); uintptr_t counter; ISteamUser *user; };
static int fills;
static void fill_user(void *context) {
    fills++;
    *(ISteamUser **)context = (ISteamUser *)SteamInternal_FindOrCreateUserInterface(SteamAPI_GetHSteamUser(), STEAM_USER_VERSION);
}

static void check_slots(void *iface, int slots) {
    void *const *table = *(void *const **)iface;
    for (int i = 0; i < slots; i++) assert(table[i]);
}

int main() {
    // The version list the client passes: NUL-separated, ending with an empty name.
    static const char versions[] = "SteamUtils010\0SteamNetworkingUtils004\0SteamUser023\0SteamFriends017\0"
                                   "STEAMAPPS_INTERFACE_VERSION008\0";
    UserContext context = {fill_user, 0, nullptr};
    assert(SteamAPI_GetHSteamUser() == 0);
    char error[1024] = "untouched";
    assert(SteamInternal_SteamAPI_Init(versions, error) == STEAM_INIT_OK);
    assert(error[0] == 0);
    assert(logged.find("SteamNetworkingUtils004 is not served") != std::string::npos);
    assert(SteamAPI_GetHSteamUser() == 1);

    // The accessor fills its context once per initialisation.
    ISteamUser *user = *(ISteamUser **)SteamInternal_ContextInit(&context);
    assert(user && fills == 1);
    assert(*(ISteamUser **)SteamInternal_ContextInit(&context) == user && fills == 1);
    check_slots(user, STEAM_USER_SLOTS);
    assert(user->GetHSteamUser() == 1);
    assert(!user->BLoggedOn());
    assert(user->GetSteamID() == 0);
    uint32_t size = 99;
    assert(user->GetAuthSessionTicket(nullptr, 0, &size, nullptr) == 0 && size == 0);

    // A web API ticket: a handle now, a failed result at the next RunCallbacks.
    TicketCallback ticket;
    SteamAPI_RegisterCallback(&ticket, STEAM_CALLBACK_TICKET_FOR_WEB_API);
    assert(ticket.m_iCallback == STEAM_CALLBACK_TICKET_FOR_WEB_API && (ticket.m_nCallbackFlags & 1));
    TicketCallback other;   // another callback number hears nothing
    SteamAPI_RegisterCallback(&other, STEAM_CALLBACK_MICROTXN_AUTHORIZATION);
    uint32_t handle = user->GetAuthTicketForWebApi("brightershores");
    assert(handle != 0 && ticket.runs == 0);
    SteamAPI_RunCallbacks();
    assert(ticket.runs == 1 && other.runs == 0);
    assert(ticket.last.ticket == handle && ticket.last.result == STEAM_RESULT_NO_CONNECTION && ticket.last.size == 0);
    SteamAPI_RunCallbacks();
    assert(ticket.runs == 1);

    // A cancelled ticket's result is never delivered; an unregistered callback hears nothing.
    uint32_t cancelled = user->GetAuthTicketForWebApi("brightershores");
    assert(cancelled != handle);
    user->CancelAuthTicket(cancelled);
    SteamAPI_RunCallbacks();
    assert(ticket.runs == 1);
    SteamAPI_UnregisterCallback(&ticket);
    assert(!(ticket.m_nCallbackFlags & 1));
    user->GetAuthTicketForWebApi("brightershores");
    SteamAPI_RunCallbacks();
    assert(ticket.runs == 1);

    // A slot the client is not known to call answers zero and is logged once.
    assert(user->InitiateGameConnection_DEPRECATED(nullptr, 0, 0, 0, 0, false) == 0);
    assert(logged.find("SteamUser023 slot 3 called") != std::string::npos);

    auto *friends = (ISteamFriends *)SteamInternal_FindOrCreateUserInterface(1, STEAM_FRIENDS_VERSION);
    check_slots(friends, STEAM_FRIENDS_SLOTS);
    assert(!strcmp(friends->GetPersonaName(), "Player"));
    assert(friends->GetPersonaState() == 0);

    auto *utils = (ISteamUtils *)SteamInternal_FindOrCreateUserInterface(0, STEAM_UTILS_VERSION);
    check_slots(utils, STEAM_UTILS_SLOTS);
    assert(utils->GetAppID() == STEAM_APP_ID);
    assert(!utils->IsOverlayEnabled());
    assert(!strcmp(utils->GetIPCountry(), ""));
    assert(utils->GetServerRealTime() > 0);

    auto *apps = (ISteamApps *)SteamInternal_FindOrCreateUserInterface(1, STEAM_APPS_VERSION);
    check_slots(apps, STEAM_APPS_SLOTS);
    assert(apps->BIsSubscribed() && apps->BIsSubscribedApp(STEAM_APP_ID) && !apps->BIsSubscribedApp(1));
    assert(!apps->BIsVACBanned());
    assert(!strcmp(apps->GetCurrentGameLanguage(), "english"));
    char beta[16] = "x";
    assert(!apps->GetCurrentBetaName(beta, sizeof beta) && beta[0] == 0);
    assert(!apps->MarkContentCorrupt(false));

    assert(!SteamInternal_FindOrCreateUserInterface(1, "SteamNetworkingSockets012"));
    assert(!SteamInternal_FindOrCreateUserInterface(1, nullptr));

    // After a shutdown and a new initialisation the accessor fills its context again.
    SteamAPI_Shutdown();
    assert(SteamAPI_GetHSteamUser() == 0);
    assert(SteamInternal_SteamAPI_Init(versions, error) == STEAM_INIT_OK);
    SteamInternal_ContextInit(&context);
    assert(fills == 2);
    puts("steam: ok");
    return 0;
}
