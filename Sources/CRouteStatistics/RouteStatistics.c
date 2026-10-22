#include "CRouteStatistics.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <time.h>
#include <unistd.h>

/* Private XNU wire layouts, adapted under APSL 2.0 in this header.
 * Exact lengths and identity are checked; incompatible data stays unknown.
 * Register sources individually to avoid overflowing the receive queue.
 * The adapted source ships in Contents/Resources/Licenses/Source/ alongside
 * its license; see THIRD_PARTY_NOTICES.md for scope and source availability. */
#include "NetworkStatisticsABI.h"

typedef struct { uint64_t reference; size_t index; } ReferenceIndex;

#define STATS_MAX_TARGETS 20000U
#define STATS_BUFFER_SIZE 65536U
#define STATS_MAX_TIMEOUT_MS 10000U
#define STATS_ALL_REFERENCES UINT64_MAX

struct RWStatsHandle {
    int fd;
    size_t count;
    uint64_t next_context;
    ReferenceIndex *references;
    unsigned char *buffer;
    bool usable;
};

static uint64_t monotonic_milliseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
}

static int wait_ready(int fd, short events, uint64_t deadline) {
    for (;;) {
        uint64_t now = monotonic_milliseconds();
        if (now == 0 || now >= deadline) return ETIMEDOUT;
        uint64_t remaining = deadline - now;
        int timeout = remaining > INT_MAX ? INT_MAX : (int)remaining;
        struct pollfd pfd = { .fd = fd, .events = events };
        int result = poll(&pfd, 1, timeout);
        if (result < 0) { if (errno == EINTR) continue; return errno; }
        if (result == 0) return ETIMEDOUT;
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return EIO;
        if (pfd.revents & events) return 0;
    }
}

static int send_message(RWStatsHandle *handle, const void *message, size_t length,
                        uint64_t deadline) {
    for (;;) {
        if (monotonic_milliseconds() >= deadline) return ETIMEDOUT;
        ssize_t result = send(handle->fd, message, length, 0);
        if (result == (ssize_t)length) return 0;
        if (result >= 0) return EIO;
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return errno;
        int error = wait_ready(handle->fd, POLLOUT, deadline);
        if (error) return error;
    }
}

static int receive_message(RWStatsHandle *handle, size_t *length, uint64_t deadline) {
    for (;;) {
        int error = wait_ready(handle->fd, POLLIN, deadline);
        if (error) return error;
        struct iovec iov = { .iov_base = handle->buffer, .iov_len = STATS_BUFFER_SIZE };
        struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
        ssize_t result = recvmsg(handle->fd, &msg, 0);
        if (result < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            return errno;
        }
        if (result < (ssize_t)sizeof(StatsHeader) || (msg.msg_flags & MSG_TRUNC)) return EPROTO;
        *length = (size_t)result;
        return 0;
    }
}

static int read_header(const unsigned char *bytes, size_t available, StatsHeader *header) {
    if (available < sizeof(*header)) return EPROTO;
    memcpy(header, bytes, sizeof(*header));
    if (header->length < sizeof(*header) || header->length > available) return EPROTO;
    if (header->type == StatsError) {
        uint32_t error;
        if (header->length < 24) return EPROTO;
        memcpy(&error, bytes + 16, sizeof(error));
        return error > 0 && error < 256 ? (int)error : EPROTO;
    }
    return 0;
}

static int reference_compare(const void *a, const void *b) {
    uint64_t av = ((const ReferenceIndex *)a)->reference;
    uint64_t bv = ((const ReferenceIndex *)b)->reference;
    return av < bv ? -1 : av > bv;
}

static int target_compare(const void *a, const void *b) {
    const RWStatsTarget *av = a, *bv = b;
    if (av->network != bv->network) return av->network < bv->network ? -1 : 1;
    if (av->mask != bv->mask) return av->mask < bv->mask ? -1 : 1;
    if (av->gateway != bv->gateway) return av->gateway < bv->gateway ? -1 : 1;
    return av->interface_index < bv->interface_index ? -1 : av->interface_index > bv->interface_index;
}

static int validate_description(const unsigned char *bytes, size_t length,
                                uint64_t context, uint64_t reference,
                                const RWStatsTarget *target) {
    StatsHeader header;
    int error = read_header(bytes, length, &header);
    if (error) return error;
    if (header.type != StatsDescription || header.length != 160 || length != 160 ||
        header.context != context || header.flags != 0) return EPROTO;
    uint64_t actual_reference, event_flags;
    uint32_t provider;
    memcpy(&actual_reference, bytes + 16, 8);
    memcpy(&event_flags, bytes + 24, 8);
    memcpy(&provider, bytes + 32, 4);
    if (actual_reference != reference || event_flags != 0 || provider != StatsProviderRoute) return EPROTO;
    RouteDescription description;
    memcpy(&description, bytes + 40, sizeof(description));
    uint32_t required = RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_PROTO1 | RTF_PROTO2;
    uint32_t excluded = RTF_WASCLONED | RTF_REJECT | RTF_BLACKHOLE;
    if (description.destination.v4.sin_family != AF_INET || description.destination.v4.sin_len != sizeof(struct sockaddr_in) ||
        description.gateway.v4.sin_family != AF_INET || description.gateway.v4.sin_len != sizeof(struct sockaddr_in) ||
        (description.flags & required) != required || (description.flags & excluded) != 0 ||
        description.interface_index != target->interface_index ||
        ntohl(description.destination.v4.sin_addr.s_addr) != target->network ||
        ntohl(description.gateway.v4.sin_addr.s_addr) != target->gateway) return ESTALE;
    uint32_t mask = description.flags & RTF_HOST ? UINT32_MAX : ntohl(description.mask.v4.sin_addr.s_addr);
    if (!(description.flags & RTF_HOST) && description.mask.v4.sin_len > sizeof(struct sockaddr_in)) return EPROTO;
    return mask == target->mask ? 0 : ESTALE;
}

static int register_target(RWStatsHandle *handle, const RWStatsTarget *target,
                           size_t index, uint64_t deadline) {
    AddRequest request = {0};
    request.header = (StatsHeader){ .context = handle->next_context++, .type = StatsAdd, .length = sizeof(request) };
    request.provider = StatsProviderRoute;
    request.interface_index = target->interface_index;
    request.destination.v4 = (struct sockaddr_in){ .sin_len = sizeof(struct sockaddr_in), .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(target->network) };
    /* Lookup the base address, then strictly validate the returned prefix.
     * Passing an explicit sockaddr mask is rejected on current XNU builds.
     * A more-specific host route at this exact address causes ESTALE, never
     * silent attribution to the wrong route. No route is created by lookup. */
    int error = send_message(handle, &request, sizeof(request), deadline);
    if (error) return error;
    size_t length;
    error = receive_message(handle, &length, deadline);
    if (error) return error;
    StatsHeader header;
    error = read_header(handle->buffer, length, &header);
    if (error) return error;
    if (length != 32 || header.length != 32 || header.type != StatsAdded ||
        header.context != request.header.context || header.flags != 0) return EPROTO;
    uint64_t reference;
    uint32_t provider;
    memcpy(&reference, handle->buffer + 16, 8);
    memcpy(&provider, handle->buffer + 24, 4);
    if (reference == 0 || reference == STATS_ALL_REFERENCES || provider != StatsProviderRoute) return EPROTO;
    QueryRequest query = { .header = { .context = handle->next_context++, .type = StatsDescribe, .length = sizeof(query) },
        .reference = reference };
    error = send_message(handle, &query, sizeof(query), deadline);
    if (error) return error;
    error = receive_message(handle, &length, deadline);
    if (error) return error;
    error = validate_description(handle->buffer, length, query.header.context, reference, target);
    if (error) return error;
    handle->references[index] = (ReferenceIndex){ .reference = reference, .index = index };
    return 0;
}

void rw_stats_close(RWStatsHandle *handle) {
    if (!handle) return;
    if (handle->fd >= 0) close(handle->fd);
    free(handle->references);
    free(handle->buffer);
    free(handle);
}

RWStatsHandle *rw_stats_open(const RWStatsTarget *targets, size_t count,
                            uint32_t timeout_ms, int *error_out) {
    int error = EINVAL;
    RWStatsHandle *handle = NULL;
    RWStatsTarget *sorted = NULL;
    if (error_out) *error_out = 0;
    if (!targets || count == 0 || count > STATS_MAX_TARGETS || timeout_ms == 0 || timeout_ms > STATS_MAX_TIMEOUT_MS) goto fail;
    uint64_t start = monotonic_milliseconds();
    if (start == 0) { error = EIO; goto fail; }
    uint64_t deadline = start + timeout_ms;
    for (size_t i = 0; i < count; ++i) {
        uint32_t inverse = ~targets[i].mask;
        if (targets[i].mask == 0 || (inverse & (inverse + 1)) != 0 ||
            (targets[i].network & inverse) != 0 || targets[i].gateway == 0 || targets[i].interface_index == 0) goto fail;
    }
    sorted = malloc(count * sizeof(*sorted));
    if (!sorted) { error = ENOMEM; goto fail; }
    memcpy(sorted, targets, count * sizeof(*sorted));
    qsort(sorted, count, sizeof(*sorted), target_compare);
    for (size_t i = 1; i < count; ++i) if (target_compare(&sorted[i-1], &sorted[i]) == 0) goto fail;
    free(sorted); sorted = NULL;
    handle = calloc(1, sizeof(*handle));
    if (!handle) { error = ENOMEM; goto fail; }
    handle->fd = -1;
    handle->count = count;
    handle->next_context = 1;
    handle->references = calloc(count, sizeof(*handle->references));
    handle->buffer = malloc(STATS_BUFFER_SIZE);
    if (!handle->references || !handle->buffer) { error = ENOMEM; goto fail; }
    handle->fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (handle->fd < 0) { error = errno; goto fail; }
    if (fcntl(handle->fd, F_SETFD, FD_CLOEXEC) < 0) { error = errno; goto fail; }
    struct ctl_info info = {0};
    const char control_name[] = "com.apple.network.statistics";
    memcpy(info.ctl_name, control_name, sizeof(control_name));
    if (ioctl(handle->fd, CTLIOCGINFO, &info) < 0) { error = errno; goto fail; }
    struct sockaddr_ctl address = { .sc_len = sizeof(address), .sc_family = AF_SYSTEM,
        .ss_sysaddr = AF_SYS_CONTROL, .sc_id = info.ctl_id };
    if (connect(handle->fd, (struct sockaddr *)&address, sizeof(address)) < 0) { error = errno; goto fail; }
    int buffer_size = 1024 * 1024;
    if (setsockopt(handle->fd, SOL_SOCKET, SO_RCVBUF, &buffer_size, sizeof(buffer_size)) < 0) { error = errno; goto fail; }
    int flags = fcntl(handle->fd, F_GETFL);
    if (flags < 0 || fcntl(handle->fd, F_SETFL, flags | O_NONBLOCK) < 0) { error = errno; goto fail; }
    for (size_t i = 0; i < count; ++i) {
        error = register_target(handle, &targets[i], i, deadline);
        if (error) goto fail;
    }
    qsort(handle->references, count, sizeof(*handle->references), reference_compare);
    for (size_t i = 1; i < count; ++i) if (handle->references[i-1].reference == handle->references[i].reference) { error = EPROTO; goto fail; }
    handle->usable = true;
    return handle;
fail:
    free(sorted);
    rw_stats_close(handle);
    if (error_out) *error_out = error;
    return NULL;
}

int rw_stats_read(RWStatsHandle *handle, RWStatsCounters *counters, size_t count,
                  uint32_t timeout_ms) {
    if (!handle || !handle->usable || !counters || count != handle->count ||
        timeout_ms == 0 || timeout_ms > STATS_MAX_TIMEOUT_MS) return EINVAL;
    memset(counters, 0, count * sizeof(*counters));
    bool *seen = calloc(count, sizeof(*seen));
    if (!seen) return ENOMEM;
    uint64_t start = monotonic_milliseconds();
    uint64_t deadline = start + timeout_ms;
    int error = start == 0 ? EIO : 0;
    QueryRequest query = { .header = { .context = handle->next_context++, .type = StatsQuery,
        .length = sizeof(query), .flags = StatsAggregate | StatsContinuation }, .reference = STATS_ALL_REFERENCES };
    size_t received = 0, fragments = 0;
    bool done = false;
    while (!error && !done) {
        if (++fragments > count + 1) { error = EPROTO; break; }
        error = send_message(handle, &query, sizeof(query), deadline);
        if (error) break;
        bool success = false;
        size_t before = received;
        while (!error && !success) {
            size_t length;
            error = receive_message(handle, &length, deadline);
            if (error) break;
            size_t offset = 0;
            while (offset < length && !error) {
                StatsHeader header;
                error = read_header(handle->buffer + offset, length - offset, &header);
                if (error) break;
                const unsigned char *message = handle->buffer + offset;
                if (success) { error = EPROTO; break; }
                if (header.type == StatsCounts) {
                    if (header.length != 144 || header.flags != 0 ||
                        (header.context != 0 && header.context != query.header.context)) { error = EPROTO; break; }
                    uint64_t reference, event_flags, values[4];
                    memcpy(&reference, message + 16, 8);
                    memcpy(&event_flags, message + 24, 8);
                    memcpy(values, message + 32, sizeof(values));
                    ReferenceIndex key = { .reference = reference };
                    ReferenceIndex *entry = bsearch(&key, handle->references, count, sizeof(*entry), reference_compare);
                    if (!entry || entry->index >= count || seen[entry->index] || event_flags != 0) { error = EPROTO; break; }
                    seen[entry->index] = true;
                    counters[entry->index] = (RWStatsCounters){ .received = values[1], .sent = values[3] };
                    ++received;
                } else if (header.type == StatsSuccess) {
                    if (header.length != 16 || header.context != query.header.context ||
                        (header.flags & ~StatsContinuation) != 0) { error = EPROTO; break; }
                    success = true;
                    done = (header.flags & StatsContinuation) == 0;
                } else { error = ESTALE; break; } /* Includes source removed or unsolicited description. */
                offset += header.length;
            }
        }
        if (!error && !done && before == received) error = EPROTO;
    }
    if (!error && received != count) error = EPROTO;
    free(seen);
    if (error) {
        memset(counters, 0, count * sizeof(*counters));
        handle->usable = false;
    }
    return error;
}
