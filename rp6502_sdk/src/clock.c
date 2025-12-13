/*
 * Copyright (c) 2023 Rumbledethumps
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: Unlicense
 */

#include <rp6502.h>
#include <clock.h>

static int get_timespec(struct timespec *res, unsigned char op)
{
    int ax = ria_call_int_errno(op);
    if (ax >= 0)
    {
        res->tv_sec = ria_pop_long();
        res->tv_nsec = ria_pop_long();
    }
    return ax;
}

int clock_getres(clockid_t clock_id, struct timespec *res)
{
    ria_set_ax(clock_id);
    return get_timespec(res, RIA_OP_CLOCK_GETRES);
}

int clock_gettime(clockid_t clock_id, struct timespec *tp)
{
    (void)clock_id;
    // time.s doesn't set the stack value for clock_id
    ria_set_ax(CLOCK_REALTIME);
    return get_timespec(tp, RIA_OP_CLOCK_GETTIME);
}

int clock_settime(clockid_t clock_id, const struct timespec *tp)
{
    ria_set_ax(clock_id);
    ria_push_long(tp->tv_nsec);
    ria_push_long(tp->tv_sec);
    return ria_call_int_errno(RIA_OP_CLOCK_SETTIME);
}

int clock_gettimezone(clockid_t clock_id, struct _timezone *tz)
{
    int ax;
    ria_set_ax(clock_id);
    ax = ria_call_int_errno(RIA_OP_CLOCK_GETTIMEZONE);
    if (ax >= 0)
    {
        char i;
        for (i = 0; i < sizeof(struct _timezone); i++)
            ((char *)tz)[i] = ria_pop_char();
    }
    return ax;
}
