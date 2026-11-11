// The network guard: the client reaches its servers only through a VPN.
//
// The client's whole network surface is BSD sockets: getaddrinfo, socket and
// connect (docs/client-analysis.md); it links no URL loading, CFNetwork or Network
// framework. This adapter stands in front of libSystem for the client's imports
// only (the launcher and every other adapter link the real library). Joe's
// decision of 2026-11-11 lets the game reach its servers, but only through a VPN:
//
// - While the device has a VPN up (its system proxy settings name a scoped tunnel
//   interface, as a VPN app's tunnel appears), a lookup and a connect are the
//   system's, and each name and address is logged once as going through the VPN.
// - With no VPN, getaddrinfo answers a host name with EAI_NONAME, as with no
//   network, and never asks DNS; connect to anything but loopback or a local socket
//   fails with ENETUNREACH. Loopback names and numeric addresses are passed to the
//   system, which converts them without a query.
//
// Each refusal is logged once per name or address, so the log shows what the
// client tried. Everything else the client imports from libSystem is the real one,
// re-exported.
#include "NetworkPolicy.h"
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/un.h>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#endif

void AKLogC(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#define LOG(...) AKLogC("[network] " __VA_ARGS__)
#define SYSTEM_LIBRARY "/usr/lib/libSystem.B.dylib"

// The system's function behind this one (platform/translation/Metal/RealFunction.h
// explains the order): never this wrapper, which would call itself.
static void *real(const char *name, void *wrapper) {
    void *function = dlsym(RTLD_NEXT, name);
    if (!function || function == wrapper) {
        void *handle = dlopen(SYSTEM_LIBRARY, RTLD_LAZY | RTLD_NOLOAD);
        function = handle ? dlsym(handle, name) : NULL;
        if (handle) dlclose(handle);
    }
    return function == wrapper ? NULL : function;
}

// Each refusal once: a small set of what was already logged.
static void log_once(const char *what) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static char seen[32][128];
    static unsigned count;
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < count; i++)
        if (!strncmp(seen[i], what, sizeof seen[i] - 1)) { pthread_mutex_unlock(&lock); return; }
    if (count < sizeof seen / sizeof *seen) snprintf(seen[count++], sizeof seen[0], "%s", what);
    pthread_mutex_unlock(&lock);
    LOG("%s\n", what);
}

bool np_address_allowed(const struct sockaddr *address, socklen_t length) {
    if (!address || length < (socklen_t)sizeof(sa_family_t)) return false;
    switch (address->sa_family) {
        case AF_UNIX:
            return true;
        case AF_INET: {
            if (length < (socklen_t)sizeof(struct sockaddr_in)) return false;
            uint32_t host = ntohl(((const struct sockaddr_in *)address)->sin_addr.s_addr);
            return (host >> 24) == 127;
        }
        case AF_INET6: {
            if (length < (socklen_t)sizeof(struct sockaddr_in6)) return false;
            const struct in6_addr *a = &((const struct sockaddr_in6 *)address)->sin6_addr;
            if (IN6_IS_ADDR_LOOPBACK(a)) return true;
            return IN6_IS_ADDR_V4MAPPED(a) && a->s6_addr[12] == 127;
        }
        default:
            return false;
    }
}

// --- whether a VPN is up ---------------------------------------------------------------------
// A VPN app's tunnel shows in the system proxy settings' per-interface ("__SCOPED__")
// entries as utun*, ipsec*, ppp*, tap* or tun*. CFNetwork is looked up at run time, so
// this adapter links nothing new.
static bool tunnel_name(const char *name) {
    static const char *const prefixes[] = {"utun", "ipsec", "ppp", "tap", "tun"};
    for (size_t i = 0; i < sizeof prefixes / sizeof *prefixes; i++)
        if (!strncmp(name, prefixes[i], strlen(prefixes[i]))) return true;
    return false;
}
static bool system_vpn_active(void) {
#ifdef __APPLE__
    static CFDictionaryRef (*copy_settings)(void);
    if (!copy_settings) {
        void *network = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY);
        copy_settings = network ? (CFDictionaryRef (*)(void))dlsym(network, "CFNetworkCopySystemProxySettings") : NULL;
        if (!copy_settings) return false;
    }
    CFDictionaryRef settings = copy_settings();
    if (!settings) return false;
    bool found = false;
    CFDictionaryRef scoped = CFDictionaryGetValue(settings, CFSTR("__SCOPED__"));
    if (scoped && CFGetTypeID(scoped) == CFDictionaryGetTypeID()) {
        CFIndex count = CFDictionaryGetCount(scoped);
        const void *keys[64];
        if (count > 64) count = 64;
        CFDictionaryGetKeysAndValues(scoped, keys, NULL);
        for (CFIndex i = 0; i < count && !found; i++) {
            char name[64];
            if (CFGetTypeID(keys[i]) == CFStringGetTypeID() &&
                CFStringGetCString(keys[i], name, sizeof name, kCFStringEncodingUTF8))
                found = tunnel_name(name);
        }
    }
    CFRelease(settings);
    return found;
#else
    return false;   // the host tests choose with np_set_vpn_probe
#endif
}
static bool (*vpn_probe)(void) = system_vpn_active;
void np_set_vpn_probe(bool (*probe)(void)) { vpn_probe = probe ? probe : system_vpn_active; }
bool np_vpn_active(void) { return vpn_probe(); }
bool np_tunnel_interface(const char *name) { return name && tunnel_name(name); }

bool np_host_allowed(const char *node) {
    if (!node || !strcasecmp(node, "localhost") || !strcasecmp(node, "localhost.")) return true;
    // A numeric address needs no query: the system converts it, and connect
    // decides whether it may be reached.
    unsigned char scratch[sizeof(struct in6_addr)];
    return inet_pton(AF_INET, node, scratch) == 1 || inet_pton(AF_INET6, node, scratch) == 1;
}

static void describe(const struct sockaddr *address, const char *outcome, char *out, size_t size) {
    char host[INET6_ADDRSTRLEN] = "?";
    unsigned port = 0;
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)address;
        inet_ntop(AF_INET, &in->sin_addr, host, sizeof host);
        port = ntohs(in->sin_port);
    } else if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in = (const struct sockaddr_in6 *)address;
        inet_ntop(AF_INET6, &in->sin6_addr, host, sizeof host);
        port = ntohs(in->sin6_port);
    }
    snprintf(out, size, "connect to %s port %u %s", host, port, outcome);
}

int connect(int socket, const struct sockaddr *address, socklen_t length) {
    if (!np_address_allowed(address, length)) {
        char what[128];
        bool vpn = address && length >= (socklen_t)sizeof(sa_family_t) && np_vpn_active();
        if (address && length >= (socklen_t)sizeof(sa_family_t))
            describe(address, vpn ? "through the VPN" : "refused: no VPN", what, sizeof what);
        else
            snprintf(what, sizeof what, "connect with no address refused");
        log_once(what);
        if (!vpn) {
            errno = ENETUNREACH;
            return -1;
        }
    }
    static int (*system_connect)(int, const struct sockaddr *, socklen_t);
    if (!system_connect) system_connect = (int (*)(int, const struct sockaddr *, socklen_t))real("connect", (void *)connect);
    if (!system_connect) { errno = ENOSYS; return -1; }
    return system_connect(socket, address, length);
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
    if (result) *result = NULL;
    if (!np_host_allowed(node)) {
        bool vpn = np_vpn_active();
        char what[128];
        snprintf(what, sizeof what, "lookup of %.64s (service %.16s) %s", node, service ? service : "-",
                 vpn ? "through the VPN" : "refused: no VPN");
        log_once(what);
        if (!vpn) return EAI_NONAME;
    }
    static int (*system_getaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
    if (!system_getaddrinfo)
        system_getaddrinfo = (int (*)(const char *, const char *, const struct addrinfo *, struct addrinfo **))
            real("getaddrinfo", (void *)getaddrinfo);
    if (!system_getaddrinfo) return EAI_FAIL;
    return system_getaddrinfo(node, service, hints, result);
}
