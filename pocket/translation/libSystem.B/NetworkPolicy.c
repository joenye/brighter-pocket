// The offline guard: the client reaches no game server.
//
// The client's whole network surface is BSD sockets: getaddrinfo, socket and
// connect (docs/client-analysis.md); it links no URL loading, CFNetwork or Network
// framework. This adapter stands in front of libSystem for the client's imports
// only (the launcher and every other adapter link the real library) and refuses
// both ways off the device:
//
// - getaddrinfo answers a host name with EAI_NONAME, as with no network, and never
//   asks DNS. Loopback names and numeric addresses are passed to the system, which
//   converts them without a query.
// - connect to anything but loopback or a local socket fails with ENETUNREACH.
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

bool np_host_allowed(const char *node) {
    if (!node || !strcasecmp(node, "localhost") || !strcasecmp(node, "localhost.")) return true;
    // A numeric address needs no query: the system converts it, and connect
    // decides whether it may be reached.
    unsigned char scratch[sizeof(struct in6_addr)];
    return inet_pton(AF_INET, node, scratch) == 1 || inet_pton(AF_INET6, node, scratch) == 1;
}

static void describe(const struct sockaddr *address, char *out, size_t size) {
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
    snprintf(out, size, "connect to %s port %u refused: offline", host, port);
}

int connect(int socket, const struct sockaddr *address, socklen_t length) {
    if (!np_address_allowed(address, length)) {
        char what[128];
        if (address && length >= (socklen_t)sizeof(sa_family_t)) describe(address, what, sizeof what);
        else snprintf(what, sizeof what, "connect with no address refused");
        log_once(what);
        errno = ENETUNREACH;
        return -1;
    }
    static int (*system_connect)(int, const struct sockaddr *, socklen_t);
    if (!system_connect) system_connect = (int (*)(int, const struct sockaddr *, socklen_t))real("connect", (void *)connect);
    if (!system_connect) { errno = ENOSYS; return -1; }
    return system_connect(socket, address, length);
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
    if (result) *result = NULL;
    if (!np_host_allowed(node)) {
        char what[128];
        snprintf(what, sizeof what, "lookup of %.64s (service %.16s) refused: offline", node, service ? service : "-");
        log_once(what);
        return EAI_NONAME;
    }
    static int (*system_getaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
    if (!system_getaddrinfo)
        system_getaddrinfo = (int (*)(const char *, const char *, const struct addrinfo *, struct addrinfo **))
            real("getaddrinfo", (void *)getaddrinfo);
    if (!system_getaddrinfo) return EAI_FAIL;
    return system_getaddrinfo(node, service, hints, result);
}
