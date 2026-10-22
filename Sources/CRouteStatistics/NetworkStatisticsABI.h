/*
 * Copyright (c) 2010-2024 Apple Inc. All rights reserved.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. The rights granted to you under the License
 * may not be used to create, or enable the creation or redistribution of,
 * unlawful or unlicensed copies of an Apple operating system, or to
 * circumvent, violate, or enable the circumvention or violation of, any
 * terms of an Apple operating system software license agreement.
 *
 * Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */
/*
 * RouteWeaver modifications, 2026-10-21:
 * Select and rename the route statistics wire layouts and message constants;
 * combine request headers with parameters, use standard fixed-width types,
 * and add ABI size/offset assertions. No XNU function bodies are included.
 * Source: apple-oss-distributions/xnu, commit
 * f6217f891ac0bb64f3d375211650a4c1ff8ca1ea, bsd/net/ntstat.h.
 * This adapted header is distributed under APSL 2.0; see
 * LICENSES/APSL-2.0.txt. It is not covered by the project MIT license.
 */
#ifndef ROUTEWEAVER_NETWORK_STATISTICS_ABI_H
#define ROUTEWEAVER_NETWORK_STATISTICS_ABI_H

#include <stddef.h>
#include <stdint.h>
#include <netinet/in.h>

typedef struct { uint64_t context; uint32_t type; uint16_t length, flags; } StatsHeader;
typedef union { struct sockaddr_in v4; struct sockaddr_in6 v6; } StatsAddress;
typedef struct {
    StatsHeader header;
    uint32_t provider, reserved;
    StatsAddress destination, mask;
    uint32_t interface_index;
} AddRequest;
typedef struct { StatsHeader header; uint64_t reference; } QueryRequest;
typedef struct {
    uint64_t identifier, parent_identifier, gateway_identifier;
    StatsAddress destination, mask, gateway;
    uint32_t interface_index, flags, reserved;
} RouteDescription;

_Static_assert(sizeof(StatsHeader) == 16, "Unexpected nstat header ABI");
_Static_assert(sizeof(AddRequest) == 88, "Unexpected route add ABI");
_Static_assert(sizeof(QueryRequest) == 24, "Unexpected query ABI");
_Static_assert(sizeof(RouteDescription) == 120, "Unexpected route description ABI");
_Static_assert(offsetof(RouteDescription, destination) == 24, "Unexpected destination offset");
_Static_assert(offsetof(RouteDescription, interface_index) == 108, "Unexpected interface offset");

enum { StatsSuccess = 0, StatsError = 1, StatsAdd = 1001,
       StatsQuery = 1004, StatsDescribe = 1005, StatsAdded = 10001,
       StatsDescription = 10003, StatsCounts = 10004,
       StatsProviderRoute = 1, StatsAggregate = 1, StatsContinuation = 2 };
#endif
