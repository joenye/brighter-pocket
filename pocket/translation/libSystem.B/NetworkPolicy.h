// The network guard's decisions (NetworkPolicy.c), for its tests.
#pragma once
#include <stdbool.h>
#include <sys/socket.h>

// Whether connect may reach this address with no VPN: a local socket or loopback only.
bool np_address_allowed(const struct sockaddr *address, socklen_t length);
// Whether getaddrinfo may resolve this node with no VPN: none, localhost, or a numeric address.
bool np_host_allowed(const char *node);
// Whether a VPN is up; anything else goes through only then.
bool np_vpn_active(void);
// Whether an interface name is a tunnel's, as a VPN app's appears (utun, ipsec, ppp, tap, tun).
bool np_tunnel_interface(const char *name);
// Replace the VPN check (the host tests); NULL restores the system's.
void np_set_vpn_probe(bool (*probe)(void));
