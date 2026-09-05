/*
 * index.c - Index computation functions
 * Updated to use new bnet.h with SuiteSparse types
 */

#include "bnet.h"
#include <math.h>

int **ComputeC(dd, nn)
     int dd, nn;
{
  int i, l;
  int combi();
  int **c;

  c = imatrix(0, dd, -1, nn);    /* make  c[d+1][n+2] matrix */
  for (l=0; l<=dd; l++) for (i = -1; i<= nn; i++)
    c[l][i] = combi(l, i);     /* c[l][-1] = 0 */
  return c;
}

int combi(k, m)
     int k, m;
{
  /* Binomial-coefficient C(k+m, k). The original implementation cast
     a double accumulator to (int) at the end, which silently wrapped
     to a negative number once the true value exceeded INT_MAX. That
     made the monotonic table c[][] non-monotonic and caused
     `InverseIndex`'s linear search to walk off the end of the row,
     hitting a malloc guard page and crashing with SIGBUS.

     Fix: accumulate in long-double precision, then clamp to INT_MAX
     before casting. The table stays monotone (so the search
     terminates) even if the user picks a (dim, n) combination that
     mathematically overflows the int representation. The downstream
     spectral algorithm has its own size limits, so a clamped value
     just produces a clean error rather than a crash. */
  long double tmp_n = 1.0L;
  long double tmp_d = 1.0L;
  long double v;
  int i;

  if (m < 0) return 0;
  for (i = 1; i <= k; i++) {
    tmp_n *= (long double)(m + i);
    tmp_d *= (long double) i;
  }
  v = tmp_n / tmp_d;
  if (v < 0) v = 0;
  if (v > 2147483600.0L) v = 2147483600.0L;   /* clamp below INT_MAX */
  return (int) v;
}

real     **ComputeWeight(mygamma, dd, nn)
     real *mygamma;
     int dd, nn;

{
  int i, l;
  long factorial();
  int twon;
  real **w;

  twon = 2 * nn;
  w = dmatrix(1, dd, 0, twon);
  for (l=1; l<=dd ; l++) for (i=0; i<= twon; i++)
    w[l][i] = factorial(i)/(real) pow((double) 2*mygamma[l], (double) i+1);
  return w;
}

long factorial( k)
     int k;
{
  /* `long` is 64-bit on macOS arm64 / linux x86_64; max long ≈ 9.2 × 10^18.
     21! = 5.1 × 10^19 already overflows. Called from ComputeWeight with
     i ∈ [0, 2n], so n ≥ 11 silently corrupts the weight matrix and
     downstream inner products. Accumulate in long double, clamp at
     LONG_MAX and abort: garbage weights are worse than a clean stop. */
  int i;
  long double tmp = 1.0L;

  for (i = 1; i <= k; i++)
    tmp *= (long double) i;
  if (tmp > 9.2e18L) {
    fprintf(stderr,
        "bnet: factorial(%d) = %.3Le overflows 64-bit long; "
        "polynomial degree n is too large (need 2n < 21).\n", k, tmp);
    exit(2);
  }
  return (long) tmp;
}

    

int **ComputeIndex(c, dim, n)
     int dim;                  /* dim = d and d-1 */
     int **c, n;
{
  int  i, **II, *InverseIndex();

  II = (int **) malloc((unsigned)c[dim][n]*sizeof(int *));
  II -= 1;
  /* Pass `n` to InverseIndex so its inner search has an explicit
     upper bound on the row index. Previously the search could walk
     past column n and read into a malloc guard page. */
  for (i=1; i<=c[dim][n]; i++)   II[i] = InverseIndex(dim, i, c, n);
  return (II);
}

int *InverseIndex(dim, i, c, n)
     int dim, i, n;
     int **c;
{
  int j,  *k, *II;

  k = ivector(1, dim);
  for (j=dim; j>=1; j--) {
    k[j] = -1;
    /* Linear search WITH an upper bound. The matrix `c` is allocated
       as imatrix(0, dim, -1, n), so column indices are valid only in
       [-1, n]. Without the `k[j] < n` guard, a corrupted (e.g.
       overflowed) c[j][n] could cause the search to never terminate
       and read past the row, triggering EXC_BAD_ACCESS at the next
       guard page. The guard caps the search at n; if no match is
       found, the algorithm falls back to k[j] = n (the largest valid
       index) which is the right behaviour for the saturated case. */
    while (k[j] < n && i > c[j][k[j]]) k[j]++;
    i -= c[j][k[j]-1];
   }
  II = ivector(0, dim);
  II[0] = k[dim];
  for(j=1; j<dim; j++)  II[j] = k[dim-j+1] - k[dim-j];
  II[dim] = k[1];
  k += 1;
  free((char *) k );
  return (II);
}  

long Index(dim, II, c)
     int dim, *II;
     int **c;
{
  long tmp=1;
  int l, k=II[0]-1;
  
  for (l=dim; l>=1; l--) {
    tmp += c[l][k]; 
    k -= II[dim-l+1];
  }
  return (tmp);
}
  
