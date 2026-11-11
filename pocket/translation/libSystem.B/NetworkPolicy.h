// The offline guard's two decisions (NetworkPolicy.c), for its tests.
#pragma once
#include <stdbool.h>
#include <sys/socket.h>

// Whether connect may reach this address: a local socket or loopback only.
bool np_address_allowed(const struct sockaddr *address, socklen_t length);
// Whether getaddrinfo may resolve this node: none, localhost, or a numeric address.
bool np_host_allowed(const char *node);
