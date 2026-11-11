// The offline guard (pocket/translation/libSystem.B/NetworkPolicy.c) on the host: its
// connect and getaddrinfo stand in for the C library's here as they stand in for
// libSystem's in front of the client. Nothing in this test leaves the machine: the
// refused calls must fail before any packet or query, and the allowed ones use
// loopback.
#include "NetworkPolicy.h"
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static char logged[4096];
void AKLogC(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    size_t used = strlen(logged);
    vsnprintf(logged + used, sizeof logged - used, fmt, args);
    va_end(args);
}
static int occurrences(const char *needle) {
    int n = 0;
    for (const char *at = logged; (at = strstr(at, needle)); at++) n++;
    return n;
}

static struct sockaddr_in v4(const char *host, unsigned port) {
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    assert(inet_pton(AF_INET, host, &a.sin_addr) == 1);
    return a;
}
static struct sockaddr_in6 v6(const char *host, unsigned port) {
    struct sockaddr_in6 a = {.sin6_family = AF_INET6, .sin6_port = htons(port)};
    assert(inet_pton(AF_INET6, host, &a.sin6_addr) == 1);
    return a;
}

int main(void) {
    // Which names may be looked up: none, localhost, numeric addresses.
    assert(np_host_allowed(NULL));
    assert(np_host_allowed("localhost") && np_host_allowed("LOCALHOST") && np_host_allowed("localhost."));
    assert(np_host_allowed("127.0.0.1") && np_host_allowed("::1") && np_host_allowed("203.0.113.9"));
    assert(!np_host_allowed("brightershores.com") && !np_host_allowed("localhost.example.com") && !np_host_allowed(""));

    // Which addresses may be reached: loopback (v4, v6, v4-mapped) and local sockets.
    struct sockaddr_in loop4 = v4("127.0.0.1", 80), loop4b = v4("127.200.1.2", 80), remote4 = v4("192.0.2.1", 443);
    struct sockaddr_in6 loop6 = v6("::1", 80), mapped = v6("::ffff:127.0.0.1", 80), mapped_remote = v6("::ffff:192.0.2.1", 80),
                        remote6 = v6("2001:db8::1", 443);
    struct sockaddr_un local = {.sun_family = AF_UNIX};
    assert(np_address_allowed((struct sockaddr *)&loop4, sizeof loop4));
    assert(np_address_allowed((struct sockaddr *)&loop4b, sizeof loop4b));
    assert(np_address_allowed((struct sockaddr *)&loop6, sizeof loop6));
    assert(np_address_allowed((struct sockaddr *)&mapped, sizeof mapped));
    assert(np_address_allowed((struct sockaddr *)&local, sizeof local));
    assert(!np_address_allowed((struct sockaddr *)&remote4, sizeof remote4));
    assert(!np_address_allowed((struct sockaddr *)&remote6, sizeof remote6));
    assert(!np_address_allowed((struct sockaddr *)&mapped_remote, sizeof mapped_remote));
    assert(!np_address_allowed(NULL, 0));
    assert(!np_address_allowed((struct sockaddr *)&loop4, 4));   // cut short

    // A host name is refused without a query, logged once however often it is asked.
    struct addrinfo *found = (struct addrinfo *)1;
    assert(getaddrinfo("game.example.invalid", "443", NULL, &found) == EAI_NONAME && found == NULL);
    assert(getaddrinfo("game.example.invalid", "443", NULL, &found) == EAI_NONAME);
    assert(occurrences("lookup of game.example.invalid (service 443) refused") == 1);
    // A numeric address is converted by the system.
    struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM, .ai_flags = AI_NUMERICHOST};
    assert(getaddrinfo("127.0.0.1", "8080", &hints, &found) == 0 && found);
    assert(((struct sockaddr_in *)found->ai_addr)->sin_port == htons(8080));
    freeaddrinfo(found);

    // A remote address fails at once, before anything is sent.
    int s = socket(AF_INET, SOCK_STREAM, 0);
    assert(s >= 0);
    errno = 0;
    assert(connect(s, (struct sockaddr *)&remote4, sizeof remote4) == -1 && errno == ENETUNREACH);
    assert(occurrences("connect to 192.0.2.1 port 443 refused") == 1);
    close(s);

    // Loopback reaches the system's connect: a listener on an ephemeral port accepts.
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in any = v4("127.0.0.1", 0);
    socklen_t length = sizeof any;
    assert(!bind(listener, (struct sockaddr *)&any, sizeof any) && !listen(listener, 1));
    assert(!getsockname(listener, (struct sockaddr *)&any, &length));
    s = socket(AF_INET, SOCK_STREAM, 0);
    assert(connect(s, (struct sockaddr *)&any, sizeof any) == 0);
    int accepted = accept(listener, NULL, NULL);
    assert(accepted >= 0);
    close(accepted); close(s); close(listener);

    puts("network: ok");
    return 0;
}
