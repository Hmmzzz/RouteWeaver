#ifndef ROUTEWEAVER_SOCKET_H
#define ROUTEWEAVER_SOCKET_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    uint32_t network; /* host byte order */
    uint32_t gateway;
    uint32_t mask;
    uint32_t flags;
    uint16_t interface_index;
    int gateway_is_ipv4;
    char interface_name[32];
} RWRoute;
/* Caller frees the allocated array with rw_free_routes. */
int rw_snapshot(RWRoute **routes, size_t *count);
void rw_free_routes(RWRoute *routes);
int rw_open(void);
void rw_close(int descriptor);
/* Returns errno value, 0 means kernel accepted. Never changes existing routes. */
int rw_add(int descriptor, uint32_t network, uint32_t mask, uint32_t gateway, uint16_t interface_index);
int rw_delete(int descriptor, uint32_t network, uint32_t mask, uint32_t gateway, uint16_t interface_index);
#endif
