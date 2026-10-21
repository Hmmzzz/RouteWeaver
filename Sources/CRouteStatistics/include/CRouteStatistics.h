#ifndef ROUTEWEAVER_C_ROUTE_STATISTICS_H
#define ROUTEWEAVER_C_ROUTE_STATISTICS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* All IPv4 fields are host-order, matching CRouteSocket's snapshot API. */
typedef struct {
    uint32_t network;
    uint32_t mask;
    uint32_t gateway;
    uint32_t interface_index;
} RWStatsTarget;

typedef struct {
    uint64_t received;
    uint64_t sent;
} RWStatsCounters;

typedef struct RWStatsHandle RWStatsHandle;

/*
 * Read-only, ordinary-user access to macOS's private network-statistics ABI.
 * Fails closed when the ABI, route identity, permissions, or message framing
 * do not match. It does not open a route-writing socket or capture packets.
 * Every operation on a handle, including close, must run on the same serial
 * execution context. timeout_ms is a total deadline, not a per-message wait.
 */
RWStatsHandle *rw_stats_open(const RWStatsTarget *targets, size_t count,
                            uint32_t timeout_ms, int *error_out);
/* Zero means a complete sample; positive errno otherwise. Never use partial output. */
int rw_stats_read(RWStatsHandle *handle, RWStatsCounters *counters, size_t count,
                  uint32_t timeout_ms);
void rw_stats_close(RWStatsHandle *handle);

#ifdef __cplusplus
}
#endif
#endif
