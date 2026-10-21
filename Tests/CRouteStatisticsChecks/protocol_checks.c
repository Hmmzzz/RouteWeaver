#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>

/* Exercise the production decoder against a local datagram peer. This is
 * intentionally outside SwiftPM's test targets: no private API, installed
 * daemon, administrator permission, or active routes are needed. */
#include "../../Sources/CRouteStatistics/RouteStatistics.c"

typedef struct { int fd, mode; } Scenario;
static const char *case_names[] = {
    "complete frame", "short header", "length exceeds datagram", "unknown source",
    "duplicate source", "missing source", "bounded timeout", "removed source",
    "continuation without progress", "wrong context", "incompatible counts ABI",
    "complete multi-part frame", "trailing malformed byte"
};

static void append_count(unsigned char *buffer, size_t *offset, uint64_t reference,
                         uint64_t received, uint64_t sent, uint16_t length) {
    StatsHeader header = { .type = StatsCounts, .length = length };
    memset(buffer + *offset, 0, length);
    memcpy(buffer + *offset, &header, 16);
    memcpy(buffer + *offset + 16, &reference, 8);
    uint64_t values[4] = { 1, received, 1, sent };
    memcpy(buffer + *offset + 32, values, sizeof(values));
    *offset += length;
}

static void append_success(unsigned char *buffer, size_t *offset,
                           uint64_t context, uint16_t flags) {
    StatsHeader header = { .context = context, .type = StatsSuccess, .length = 16, .flags = flags };
    memcpy(buffer + *offset, &header, 16);
    *offset += 16;
}

static void *serve_scenario(void *argument) {
    Scenario *scenario = argument;
    QueryRequest request;
    ssize_t length = recv(scenario->fd, &request, sizeof(request), 0);
    if (length != (ssize_t)sizeof(request)) return NULL;
    unsigned char buffer[1024] = {0};
    size_t size = 0;
    switch (scenario->mode) {
    case 0:
        append_count(buffer, &size, 1, 20, 40, 144);
        append_success(buffer, &size, request.header.context, 0);
        break;
    case 1:
        size = 8;
        break;
    case 2: {
        StatsHeader header = { .type = StatsCounts, .length = 500 };
        memcpy(buffer, &header, 16);
        size = 16;
        break;
    }
    case 3:
        append_count(buffer, &size, 99, 20, 40, 144);
        append_success(buffer, &size, request.header.context, 0);
        break;
    case 4:
        append_count(buffer, &size, 1, 20, 40, 144);
        append_count(buffer, &size, 1, 30, 40, 144);
        append_success(buffer, &size, request.header.context, 0);
        break;
    case 5:
        append_success(buffer, &size, request.header.context, 0);
        break;
    case 6:
        break; // Remain silent until the caller's deadline expires.
    case 7: {
        StatsHeader header = { .type = 10002, .length = 24 };
        memcpy(buffer, &header, 16);
        size = 24;
        break;
    }
    case 8:
        append_success(buffer, &size, request.header.context, StatsContinuation);
        break;
    case 9:
        append_count(buffer, &size, 1, 20, 40, 144);
        append_success(buffer, &size, request.header.context + 1, 0);
        break;
    case 10:
        append_count(buffer, &size, 1, 20, 40, 128);
        append_success(buffer, &size, request.header.context, 0);
        break;
    case 11:
        append_count(buffer, &size, 2, 10, 30, 144);
        append_success(buffer, &size, request.header.context, StatsContinuation);
        break;
    case 12:
        append_count(buffer, &size, 1, 20, 40, 144);
        append_success(buffer, &size, request.header.context, 0);
        buffer[size++] = 0xaa;
        break;
    default:
        assert(false);
    }
    if (size) assert(send(scenario->fd, buffer, size, 0) == (ssize_t)size);
    if (scenario->mode == 11) {
        assert(recv(scenario->fd, &request, sizeof(request), 0) == (ssize_t)sizeof(request));
        size = 0;
        append_count(buffer, &size, 1, 20, 40, 144);
        append_success(buffer, &size, request.header.context, 0);
        assert(send(scenario->fd, buffer, size, 0) == (ssize_t)size);
    }
    // A one-byte local acknowledgement keeps the peer alive until decoding
    // finishes, so peer shutdown cannot accidentally replace the tested error.
    (void)recv(scenario->fd, buffer, sizeof(buffer), 0);
    return NULL;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    size_t total = sizeof(case_names) / sizeof(case_names[0]);
    for (size_t mode = 0; mode < total; ++mode) {
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) == 0);
        assert(fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0);
        size_t count = mode == 11 ? 2 : 1;
        RWStatsHandle handle = { .fd = pair[0], .count = count, .next_context = 1, .usable = true };
        ReferenceIndex references[2] = { {1, 0}, {2, 1} };
        handle.references = references;
        handle.buffer = malloc(STATS_BUFFER_SIZE);
        assert(handle.buffer);
        RWStatsCounters values[2] = { {999, 999}, {999, 999} };
        Scenario scenario = { pair[1], (int)mode };
        pthread_t worker;
        assert(pthread_create(&worker, NULL, serve_scenario, &scenario) == 0);

        uint64_t started = monotonic_milliseconds();
        int error = rw_stats_read(&handle, values, count, 100);
        uint64_t elapsed = monotonic_milliseconds() - started;
        bool valid = mode == 0 || mode == 11;
        if (valid) {
            assert(error == 0 && values[0].received == 20 && values[0].sent == 40);
            if (count == 2) assert(values[1].received == 10 && values[1].sent == 30);
        } else {
            assert(error != 0 && !handle.usable && values[0].received == 0 && values[0].sent == 0);
        }
        if (mode == 6) assert(error == ETIMEDOUT && elapsed < 500);
        unsigned char done = 0;
        assert(send(pair[0], &done, 1, 0) == 1);
        pthread_join(worker, NULL);
        close(pair[0]);
        close(pair[1]);
        free(handle.buffer);
        printf("PASS %s (error=%d, elapsed=%llu ms)\n", case_names[mode], error, (unsigned long long)elapsed);
    }

    int error = 0;
    assert(rw_stats_open(NULL, 0, 100, &error) == NULL && error == EINVAL);
    RWStatsTarget noncanonical = { .network = 1, .mask = 0xffffff00, .gateway = 1, .interface_index = 1 };
    assert(rw_stats_open(&noncanonical, 1, 100, &error) == NULL && error == EINVAL);
    printf("PASS %zu protocol cases plus input guards\n", total);
    return 0;
}
