/*
 * Copyright (c) 2023 Rumbledethumps
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: Unlicense
 */

#include <rp6502.h>

unsigned long __fastcall__ lrand(void)
{
    return ria_call_long(RIA_OP_LRAND);
}
