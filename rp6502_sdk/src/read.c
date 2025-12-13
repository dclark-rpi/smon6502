/*
 * Copyright (c) 2023 Rumbledethumps
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: Unlicense
 */

#include <rp6502.h>

int __fastcall__ read(int fildes, void *buf, unsigned count)
{
    int ax, total = 0;
    while (count)
    {
        int blockcount = (count > 256) ? 256 : count;
        ax = read_xstack(&((char *)buf)[total], blockcount, fildes);
        if (ax < 0)
            return ax;
        total += ax;
        count -= ax;
        if (ax < blockcount)
            break;
    }
    return total;
}
