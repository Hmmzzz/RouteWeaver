#!/usr/bin/env bash
# Exercise the production snapshot decoder with synthetic sysctl data only.
# No route sockets, installed helper, administrator access, or network are used.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/routeweaver-snapshot-test.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
cat > "$CHECK_DIR/snapshot-checks.c" <<'SOURCE'
#include "CRouteSocket.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/route.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>

static unsigned int assertions;
static unsigned int scenarios;
#define CHECK(condition) do { \
    ++assertions; \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
        exit(1); \
    } \
} while (0)

static unsigned char fixture[2 * 1024 * 1024];
static size_t fixture_size;
static RWRoute expected[8192];
static size_t expected_count;
static unsigned int lookups[UINT16_MAX + 1];
static unsigned int total_lookups;
static unsigned int sysctl_calls;
static unsigned int unavailable_index = UINT32_MAX;
static const char *name_prefix = "en";
static int sysctl_error;

static void expected_name(unsigned int index, char *name) {
    memset(name, 0, IF_NAMESIZE);
    if (index != unavailable_index) snprintf(name, IF_NAMESIZE, "%s%u", name_prefix, index);
}

static char *fixture_if_indextoname(unsigned int index, char *name) {
    CHECK(index <= UINT16_MAX);
    ++lookups[index];
    ++total_lookups;
    if (index == unavailable_index) { errno = ENXIO; return NULL; }
    expected_name(index, name);
    return name;
}

static int fixture_sysctl(int *mib, u_int count, void *output, size_t *length,
                          void *input, size_t input_length) {
    ++sysctl_calls;
    CHECK(count == 6);
    CHECK(mib[0] == CTL_NET && mib[1] == PF_ROUTE && mib[2] == 0);
    CHECK(mib[3] == AF_INET && mib[4] == NET_RT_DUMP && mib[5] == 0);
    CHECK(input == NULL && input_length == 0 && length != NULL);
    if (sysctl_error) { errno = sysctl_error; return -1; }
    if (output) {
        CHECK(*length >= fixture_size);
        memcpy(output, fixture, fixture_size);
    }
    *length = fixture_size;
    return 0;
}

// Compile the actual implementation; intercept only its read-only OS boundary.
#define sysctl fixture_sysctl
#define if_indextoname fixture_if_indextoname
#include "RouteSocket.c"
#undef sysctl
#undef if_indextoname

static void reset_fixture(void) {
    fixture_size = 0;
    expected_count = 0;
    memset(lookups, 0, sizeof(lookups));
    total_lookups = sysctl_calls = 0;
    unavailable_index = UINT32_MAX;
    name_prefix = "en";
    sysctl_error = 0;
}

static void reset_observations(void) {
    memset(lookups, 0, sizeof(lookups));
    total_lookups = sysctl_calls = 0;
}

static void append_route(uint16_t index, uint32_t destination, uint32_t mask,
                         uint32_t gateway, uint32_t flags, int ipv4_gateway) {
    const size_t message_size = sizeof(struct rt_msghdr) + 3 * sizeof(struct sockaddr_in);
    CHECK(expected_count < sizeof(expected) / sizeof(expected[0]));
    CHECK(fixture_size + message_size <= sizeof(fixture));
    struct rt_msghdr header = {0};
    header.rtm_msglen = (unsigned short)message_size;
    header.rtm_version = RTM_VERSION;
    header.rtm_type = RTM_GET;
    header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    header.rtm_index = index;
    header.rtm_flags = (int)flags;
    memcpy(fixture + fixture_size, &header, sizeof(header));
    struct sockaddr_in addresses[3] = {0};
    addresses[0].sin_len = addresses[1].sin_len = addresses[2].sin_len = sizeof(struct sockaddr_in);
    addresses[0].sin_family = AF_INET;
    addresses[1].sin_family = ipv4_gateway ? AF_INET : AF_LINK;
    // Darwin permits netmasks with family zero.
    addresses[2].sin_family = 0;
    addresses[0].sin_addr.s_addr = htonl(destination);
    addresses[1].sin_addr.s_addr = htonl(gateway);
    addresses[2].sin_addr.s_addr = htonl(mask);
    memcpy(fixture + fixture_size + sizeof(header), addresses, sizeof(addresses));
    fixture_size += message_size;
    uint32_t actual_mask = flags & RTF_HOST ? UINT32_MAX : mask;
    expected[expected_count++] = (RWRoute){
        .network = destination & actual_mask, .gateway = ipv4_gateway ? gateway : 0,
        .mask = actual_mask, .flags = flags, .interface_index = index,
        .gateway_is_ipv4 = ipv4_gateway
    };
}

static void check_snapshot(void) {
    RWRoute *routes = NULL;
    size_t count = 0;
    CHECK(rw_snapshot(&routes, &count) == 0);
    CHECK(count == expected_count && routes != NULL);
    for (size_t i = 0; i < count; ++i) {
        CHECK(routes[i].network == expected[i].network);
        CHECK(routes[i].gateway == expected[i].gateway);
        CHECK(routes[i].mask == expected[i].mask);
        CHECK(routes[i].flags == expected[i].flags);
        CHECK(routes[i].interface_index == expected[i].interface_index);
        CHECK(routes[i].gateway_is_ipv4 == expected[i].gateway_is_ipv4);
        char name[IF_NAMESIZE];
        expected_name(routes[i].interface_index, name);
        CHECK(strcmp(routes[i].interface_name, name) == 0);
    }
    rw_free_routes(routes);
}

static const uint32_t owned_flags = RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_PROTO1 | RTF_PROTO2;

static void repeated_indices(void) {
    reset_fixture();
    for (unsigned int i = 0; i < 4096; ++i)
        append_route(i % 2 ? 7 : 9, 0x01000000 + i * 256, 0xffffff00,
                     0xc0000201, owned_flags, 1);
    check_snapshot();
    CHECK(sysctl_calls == 2);
    CHECK(total_lookups == 2 && lookups[7] == 1 && lookups[9] == 1);
    ++scenarios;
}

static void changes_between_snapshots(void) {
    reset_fixture();
    for (unsigned int i = 0; i < 40; ++i)
        append_route(7, 0x02000000 + i * 256, 0xffffff00, 0xc0000201, owned_flags, 1);
    check_snapshot();
    CHECK(lookups[7] == 1);
    reset_observations(); name_prefix = "ren";
    check_snapshot();
    CHECK(lookups[7] == 1);
    reset_observations(); unavailable_index = 7;
    check_snapshot();
    CHECK(lookups[7] == 1);
    reset_observations(); unavailable_index = UINT32_MAX; name_prefix = "new";
    check_snapshot();
    CHECK(lookups[7] == 1);
    ++scenarios;
}

static void failed_lookup_is_empty_and_reused(void) {
    reset_fixture(); unavailable_index = 0;
    for (unsigned int i = 0; i < 50; ++i)
        append_route(i % 2 ? 0 : 7, 0x03000000 + i * 256, 0xffffff00,
                     0xc0000201, owned_flags, 1);
    check_snapshot();
    CHECK(total_lookups == 2 && lookups[0] == 1 && lookups[7] == 1);
    ++scenarios;
}

static void full_cache_falls_back_without_losing_routes(void) {
    reset_fixture();
    for (unsigned int pass = 0; pass < 3; ++pass)
        for (unsigned int i = 1; i <= 70; ++i)
            append_route((uint16_t)i, 0x04000000 + (pass * 70 + i) * 256,
                         0xffffff00, 0xc0000201, owned_flags, 1);
    check_snapshot();
    for (unsigned int i = 1; i <= 64; ++i) CHECK(lookups[i] == 1);
    for (unsigned int i = 65; i <= 70; ++i) CHECK(lookups[i] == 3);
    CHECK(total_lookups == 64 + 3 * 6);
    ++scenarios;
}

static void route_fields_and_flags_remain_exact(void) {
    reset_fixture();
    append_route(5, 0, 0, 0xc0000201, RTF_UP | RTF_GATEWAY, 1);
    append_route(5, 0x01820304, 0xffff0000, 0xc0000201, owned_flags, 1);
    append_route(6, 0x05820304, 0xffff0000, 0xc0000202, owned_flags | RTF_HOST, 1);
    append_route(6, 0x06820304, 0xffffff00, 0, RTF_UP | RTF_WASCLONED, 0);
    append_route(7, 0x07820304, 0xffffff00, 0xc0000201, owned_flags | RTF_REJECT, 1);
    append_route(7, 0x08820304, 0xffffff00, 0xc0000201, owned_flags | RTF_BLACKHOLE, 1);
    check_snapshot();
    CHECK(total_lookups == 3);
    ++scenarios;
}

static void empty_snapshot(void) {
    reset_fixture();
    check_snapshot();
    CHECK(total_lookups == 0);
    ++scenarios;
}

static void malformed_snapshot_is_rejected(void) {
    reset_fixture();
    append_route(7, 0x01000000, 0xffffff00, 0xc0000201, owned_flags, 1);
    struct rt_msghdr header;
    memcpy(&header, fixture, sizeof(header));
    header.rtm_msglen = 2;
    memcpy(fixture, &header, sizeof(header));
    RWRoute *routes = NULL; size_t count = 0;
    CHECK(rw_snapshot(&routes, &count) == EINVAL);
    CHECK(routes == NULL && total_lookups == 0);
    ++scenarios;
}

static void snapshot_error_is_propagated(void) {
    reset_fixture(); sysctl_error = ENOMEM;
    RWRoute *routes = NULL; size_t count = 0;
    CHECK(rw_snapshot(&routes, &count) == ENOMEM);
    CHECK(routes == NULL && count == 0 && total_lookups == 0);
    ++scenarios;
}

int main(void) {
    repeated_indices();
    changes_between_snapshots();
    failed_lookup_is_empty_and_reused();
    full_cache_falls_back_without_losing_routes();
    route_fields_and_flags_remain_exact();
    empty_snapshot();
    malformed_snapshot_is_rejected();
    snapshot_error_is_propagated();
    printf("Route snapshot checks: %u scenarios, %u assertions passed\n", scenarios, assertions);
    return 0;
}
SOURCE
/usr/bin/clang -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -I "$ROOT_DIR/Sources/CRouteSocket/include" -I "$ROOT_DIR/Sources/CRouteSocket" \
    "$CHECK_DIR/snapshot-checks.c" -o "$CHECK_DIR/snapshot-checks"
"$CHECK_DIR/snapshot-checks"
