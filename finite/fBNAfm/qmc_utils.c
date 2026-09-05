/*
 * qmc_utils.c - Bit reversal and radical inverse utilities
 *
 * Part of the QMC integration library.
 */
#include "qmc.h"

/*
 * Reverse all bits of a 32-bit unsigned integer.
 * Uses the standard parallel bit-swap algorithm:
 *   swap adjacent single bits, then pairs, nibbles, bytes, 16-bit halves.
 */
static uint32_t bit_reverse_32(uint32_t k)
{
    k = ((k >>  1) & 0x55555555u) | ((k & 0x55555555u) <<  1);
    k = ((k >>  2) & 0x33333333u) | ((k & 0x33333333u) <<  2);
    k = ((k >>  4) & 0x0F0F0F0Fu) | ((k & 0x0F0F0F0Fu) <<  4);
    k = ((k >>  8) & 0x00FF00FFu) | ((k & 0x00FF00FFu) <<  8);
    k = (k >> 16) | (k << 16);
    return k;
}

double qmc_radical_inverse_base2(uint32_t k)
{
    static const double scale = 1.0 / 4294967296.0;  /* 1 / 2^32 */
    return scale * (double)bit_reverse_32(k);
}
