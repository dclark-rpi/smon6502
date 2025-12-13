/*
 * Copyright (c) 2023 Rumbledethumps
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: Unlicense
 */

#ifndef _CLOCK_H_
#define _CLOCK_H_

#include <time.h>

int __fastcall__ clock_getres(clockid_t clock_id, struct timespec *res);
int __fastcall__ clock_gettime(clockid_t clock_id, struct timespec *tp);
int __fastcall__ clock_settime(clockid_t clock_id, const struct timespec *tp);
int __fastcall__ clock_gettimezone(clockid_t clock_id, struct _timezone *tz);

#endif /* _CLOCK_H_ */
