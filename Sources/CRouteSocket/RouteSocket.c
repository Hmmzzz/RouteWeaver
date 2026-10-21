#include "CRouteSocket.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/route.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

static size_t align_sa(size_t n) { return n ? ((n + sizeof(uint32_t) - 1) & ~(sizeof(uint32_t) - 1)) : sizeof(uint32_t); }
static uint32_t ipv4(const struct sockaddr *sa) {
    uint32_t v = 0;
    /* Netmasks can have a shortened sockaddr, including family 0. */
    size_t off = offsetof(struct sockaddr_in, sin_addr);
    if (sa && sa->sa_len > off) {
        size_t n = sa->sa_len - off;
        memcpy(&v, (const char *)sa + off, n < 4 ? n : 4);
    }
    return ntohl(v);
}
int rw_snapshot(RWRoute **routes, size_t *count) {
    *routes = NULL; *count = 0;
    int mib[] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 };
    size_t size = 0;
    if (sysctl(mib, 6, NULL, &size, NULL, 0) < 0) return errno;
    if (size > 128 * 1024 * 1024) return EOVERFLOW;
    char *data = malloc(size ? size : 1);
    if (!data) return ENOMEM;
    if (sysctl(mib, 6, data, &size, NULL, 0) < 0) { int e = errno; free(data); return e; }
    size_t capacity = size / sizeof(struct rt_msghdr) + 1;
    RWRoute *result = calloc(capacity, sizeof(RWRoute));
    if (!result) { free(data); return ENOMEM; }
    char *end = data + size;
    for (char *p = data; p < end;) {
        if ((size_t)(end-p) < sizeof(struct rt_msghdr)) { free(data); free(result); return EINVAL; }
        struct rt_msghdr *h = (struct rt_msghdr *)p;
        if (h->rtm_msglen < sizeof(*h) || h->rtm_msglen > (size_t)(end-p)) { free(data); free(result); return EINVAL; }
        const struct sockaddr *a[RTAX_MAX] = {0};
        char *s = p + sizeof(*h), *message_end = p + h->rtm_msglen;
        for (int i = 0; i < RTAX_MAX; i++) {
            if (!(h->rtm_addrs & (1 << i))) continue;
            if (s + 2 > message_end) { free(data); free(result); return EINVAL; }
            struct sockaddr *sa = (struct sockaddr *)s;
            size_t span = align_sa(sa->sa_len);
            if (s + span > message_end) { free(data); free(result); return EINVAL; }
            a[i] = sa; s += span;
        }
        if (a[RTAX_DST] && a[RTAX_DST]->sa_family == AF_INET) {
            RWRoute *r = &result[(*count)++];
            r->network = ipv4(a[RTAX_DST]);
            r->mask = (h->rtm_flags & RTF_HOST) ? UINT32_MAX : ipv4(a[RTAX_NETMASK]);
            r->network &= r->mask;
            r->gateway_is_ipv4 = a[RTAX_GATEWAY] && a[RTAX_GATEWAY]->sa_family == AF_INET;
            r->gateway = r->gateway_is_ipv4 ? ipv4(a[RTAX_GATEWAY]) : 0;
            r->flags = h->rtm_flags;
            r->interface_index = h->rtm_index;
            if_indextoname(h->rtm_index, r->interface_name);
        }
        p += h->rtm_msglen;
    }
    free(data); *routes = result; return 0;
}
void rw_free_routes(RWRoute *routes) { free(routes); }
int rw_open(void) {
    int s = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (s < 0) return -1;
    /* Darwin route_output returns synchronous route-operation errno from write.
       Disable own response copies: no blocking receive and no overflow per batch. */
    int off = 0;
    if (setsockopt(s, SOL_SOCKET, SO_USELOOPBACK, &off, sizeof(off)) < 0) { int e=errno; close(s); errno=e; return -1; }
    return s;
}
void rw_close(int s) { if (s >= 0) close(s); }
static int mutate(int s, int type, uint32_t network, uint32_t mask, uint32_t gateway, uint16_t index) {
    struct { struct rt_msghdr header; struct sockaddr_in dst, gw, mask; struct sockaddr_dl ifp; } m;
    memset(&m, 0, sizeof(m));
    m.header.rtm_msglen = sizeof(m);
    m.header.rtm_version = RTM_VERSION;
    m.header.rtm_type = type;
    m.header.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_PROTO1 | RTF_PROTO2;
    m.header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK | RTA_IFP;
    m.header.rtm_index = index;
    m.header.rtm_pid = getpid();
    m.dst.sin_len = m.gw.sin_len = m.mask.sin_len = sizeof(struct sockaddr_in);
    m.dst.sin_family = m.gw.sin_family = m.mask.sin_family = AF_INET;
    m.dst.sin_addr.s_addr = htonl(network);
    m.gw.sin_addr.s_addr = htonl(gateway);
    m.mask.sin_addr.s_addr = htonl(mask);
    /* rtm_index only scopes a route when RTF_IFSCOPE is set. RTA_IFP
       selects the physical interface while keeping this route global. */
    m.ifp.sdl_len = sizeof(m.ifp);
    m.ifp.sdl_family = AF_LINK;
    m.ifp.sdl_index = index;
    ssize_t n;
    do { n = write(s, &m, sizeof(m)); } while (n < 0 && errno == EINTR);
    return n == sizeof(m) ? 0 : (n < 0 ? errno : EIO);
}
int rw_add(int s, uint32_t n, uint32_t m, uint32_t g, uint16_t i) { return mutate(s, RTM_ADD, n, m, g, i); }
int rw_delete(int s, uint32_t n, uint32_t m, uint32_t g, uint16_t i) { return mutate(s, RTM_DELETE, n, m, g, i); }
