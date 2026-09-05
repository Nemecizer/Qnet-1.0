/* #include <stdlib.h> */
#include "mcn.h"
#include "meschach/oldnames.h"

#ifndef ANSI_C
int main(argc, argv)
     int   argc;
     char *argv[];
#else
int main(int   argc, 
	 char *argv[])
#endif
{
  int  iterative = False, interactive = False, workload = True;
  int  jackson = False, print = FALSE;
  FILE **fp = option(argc, argv, &iterative, &interactive, &workload,
		     &jackson, &print);
  FILE *input_fp  = fp[0]; 
  FILE *output_fp = fp[1]; 
  /* input parameters */
  int d = get_dimension(interactive, input_fp, "stations d");
  int c = (jackson == 
	   TRUE) ? d: get_dimension(interactive, input_fp, "classes c"); 
  VEC  *alpha = get_vec(c);
  VEC  *sca = get_vec(c);
  VEC  *tau = get_vec(c);
  VEC  *scs = get_vec(c); 
  MAT  *P   = get_mat(c, c);
  MAT  *C   = get_mat(d, c);

  /* output parameters */
  MAT  *Gamma   = get_mat(d, d);
  VEC  *theta   = get_vec(d);
  MAT  *R       = get_mat(d, d);
  VEC  *rho     = get_vec(d);
  int   n;

   /* temporary matrices */
  MAT  *d_temp;
  MAT  *c_temp1;
  MAT  *c_temp2;
  MAT  *Gammas, *H, *C_prime, *P_prime;
  MAT  *Q, *M, *K, *B, *CMQ, *Lambda, *G;
  MAT  *CMQ_prime, *rho_diag;
  /* temporary vectors */
  VEC  *v_temp;
  VEC  *rho_inv;
  VEC  *d_ones;
  VEC  *lambda;
  /* temporary indexies */
  int i, j, m, k, l;

  if (jackson == TRUE)
    id_mat(C);
  else
    zero_mat(C);
  mcn_input(alpha, sca, tau, scs, P, C, &n, input_fp, interactive,jackson);
  P_prime = get_mat(c, c);
  m_transp(P, P_prime); /* P_prime = P' */
  Q = get_mat(c, c);
  id_mat(Q);  /*  Q = I  */
  c_temp1 = get_mat(c, c);
  m_sub(Q, P_prime, c_temp1); /* c_temp1  = I - P' */
  m_inverse(c_temp1, Q);      /* Q = (I-P')^{-1} */
  lambda = get_vec(c);
  mv_mlt(Q, alpha, lambda); /* effective arrival rate */

  M = get_mat(c, c);
  v_diag(tau, M);
  v_temp = get_vec(c);
  v_mlt(scs, lambda, v_temp);
  v_mlt(v_temp, tau, v_temp);
  v_mlt(v_temp, tau, v_temp);
  B = get_mat(c, c);
  v_diag(v_temp, B);  /* get B as defined after (4.21) */

  v_mlt(alpha, sca, v_temp);
  K = get_mat(c, c);
  v_diag(v_temp, K);

  /* calculating H and stored into Gammas */
  H = get_mat(c, c);
  Gammas = get_mat(c, c);
  zero_mat(Gammas);
  for (i=0; i<c; i++)
    {
      for (k=0; k<c; k++)
	{
	  H->me[k][k] = P->me[i][k]*(1-P->me[i][k]);
	  for (l=0; l<k; l++){
	    H->me[k][l] = -P->me[i][k]*P->me[i][l];
	    H->me[l][k] = H->me[k][l];
	  }
	}
      ms_mltadd(Gammas, H, lambda->ve[i], Gammas);
     /* Gammas += lambda[i]*H;  */
    }
  freemat(H);
  
  /*Caculating Gamma  */
  C_prime = get_mat(c, d);
  m_transp(C, C_prime);
  c_temp2 = get_mat(c, d);
  m_mlt(B, C_prime, c_temp2);
  freemat(B);
  m_mlt(C, c_temp2, Gamma);

  m_add(K, Gammas, Gammas);  /* K + H */
  freemat(K);

  m_mlt(M, Q, c_temp1);
  CMQ = get_mat(d, c);
  m_mlt(C, c_temp1, CMQ);
  CMQ_prime = get_mat(c, d);
  m_transp(CMQ, CMQ_prime);
  m_mlt(Gammas, CMQ_prime, c_temp2);
  m_resize(c_temp1, d, d);
  m_mlt(CMQ, c_temp2, c_temp1);
  m_add(Gamma, c_temp1, Gamma);
  freemat(CMQ);
  freemat(CMQ_prime);
  freemat(Gammas);  /* that is Gamma */

  Lambda = get_mat(c, c);
  v_diag(lambda, Lambda);
  m_resize(c_temp1, c, c);
  m_mlt(P_prime, Lambda, c_temp1);
  m_resize(c_temp2, c, c);
  m_mlt(Q, c_temp1, c_temp2);
  m_mlt(M, c_temp2, c_temp1);
  m_resize(c_temp2, c, d);
  m_mlt(c_temp1, C_prime, c_temp2);
  freemat(M);
  freemat(Lambda);
  G = get_mat(d, d);
  m_mlt(C, c_temp2, G); /* orginal G */
  freemat(c_temp1);
  freemat(c_temp2);

  /*get traffic intensity */
  v_mlt(tau, lambda, v_temp);
  freevec(lambda);
  mv_mlt(C, v_temp, rho);
  for (i=0; i<d; i++)
    if (rho->ve[i] >= 1 ) error(E_UNKNOWN, "mcn_main");

  /* modify G */
  rho_inv =get_vec(d);
  v_inv(rho, rho_inv);
  rho_diag = get_mat(d, d);
  v_diag(rho_inv, rho_diag);
  freevec(rho_inv);
  d_temp = get_mat(d, d);
  m_mlt(G, rho_diag, d_temp);
  freemat(rho_diag);
  id_mat(G);
  m_add(G, d_temp, G);
  m_inverse(G, R);  /* reflection matrix */
  m_transp(R, G);  
  m_mlt(Gamma, G, d_temp);
  m_mlt(R, d_temp, Gamma);   /* covariance matrix */
  freemat(G);
  freemat(d_temp);

  d_ones = get_vec(d);
  ones_vec(d_ones);
  v_sub(rho, d_ones, d_ones);  /* d_ones = -\theta = rho - ones */
  mv_mlt(R, d_ones, theta);
  freevec(d_ones);
 

  mcn_output(Gamma, theta, R, d, n, output_fp, rho);
  

  freevec(theta);
  freemat(Gamma);
  freemat(R);
  if (print == TRUE)
    mcn_original_data(alpha, sca, tau, scs, P, C, rho, output_fp);
  freevec(alpha);
  freevec(sca);
  freevec(tau);
  freevec(scs);
  freemat(C);
  freemat(P);
  freevec(rho);
  return (0);
  
  
}

#ifndef ANSI_C
FILE **option( argc, argv, iterative, interactive, workload, jackson, print)
     int argc;
     char * argv[];
     int * iterative;
     int * interactive;
     int * workload;
     int * jackson;
     int * print;
#else
FILE **option(int argc,
	      char * argv[],
	      int * iterative,
	      int * interactive,
	      int * workload,
	      int * jackson,
	      int * print
	      )
#endif
{
  FILE **fp = (FILE **) malloc((unsigned) 2*sizeof(FILE *));
  int c;
  
  while (--argc > 0 && (*++argv)[0] == '-')
    while ( c = *++argv[0])
      switch (c) {
      case 'v':
	(void) fprintf(stdout, " This is MCN 1.1, C version, June 1992;\n");
	(void) fprintf(stdout, " please contact dai@isye.gatech.edu for ");
	(void) fprintf(stdout, "possible newer version.\n\n");
	exit(0);
	break;
/*      case 'i':
	*iterative =True;
	break; */
      case 'j':
	*jackson = True;
	break;
      case 'p':
	*print = True;
	break;
      case 'h':
	(void)  fprintf(stderr, 
			" Usage: mcn [-h] [-j] [-p] [-v] [data_file ");
	(void)  fprintf(stderr, "[output_file] ]\n");
	(void)  fprintf(stderr, " Options:\n");
	(void)  fprintf(stderr, "  -h print this help message\n");
	(void)  fprintf(stderr, "  -j instruct mcn to function exactly ");
	(void)  fprintf(stderr, "like gjn \n");
	(void)  fprintf(stderr, "  -p print the input data\n");
	(void)  fprintf(stderr, "  -v print the current version of mcn\n");
	exit(0);
	break;
      default:
	(void) fprintf(stderr, " mcn: illegal option %c\n", c);
	argc = -1;
	break;
      }
  if ( argc < 0 || argc > 2) {
    (void)  fprintf(stderr, " Usage: mcn [-h] [-j] [-p] [-v] [data_file ");
    (void)  fprintf(stderr, "[output_file] ]\n");
    exit (0);
  }
  else if (argc == 0) {
    fp[0] = stdin;
    fp[1] = stdout;
    *interactive = True;
  } 
  else if (argc == 1) {
    fp[0] = fopen(*argv, "r");
    fp[1] = stdout;
  }
  else if (argc == 2) {


    fp[0] = fopen(*argv++, "r");
    fp[1] = fopen(*argv, "w");  
  }
  return (fp);
}

#ifndef ANSI_C

void mcn_input(alpha, sca, tau, scs, P, C, n, input_fp, interactive, jackson)
     VEC * alpha;  /* exogeneous arrival rate */
     VEC * sca;    /* SCV for inter-arrival time */
     VEC * tau;    /* mean service times */
     VEC * scs;    /* SCV for service times */
     MAT * P;      /* routing matrix */
     MAT * C;      /* constituency matrix */
     int * n;      /* maximum degree to use */
     FILE *input_fp;
     int   interactive;
     int   jackson;

#else

void mcn_input(VEC * alpha,  /* exogeneous arrival rate */
	       VEC * sca,    /* SCV for inter-arrival time */
	       VEC * tau,    /* mean service times */
	       VEC * scs,    /* SCV for service times */
	       MAT * P,      /* routing matrix */
	       MAT * C,      /* constituency matrix */
	       int * n,      /* maximum degree to use */
	       FILE *input_fp,
	       int   interactive,
	       int   jackson
	       )
#endif
{
  char garb;
  int  intgarb;
  int i, j;
  int d = C->m;
  int c = C->n;
  int gjn=jackson;

  if (interactive == True) {
    for (i=0; i<c; i++) {
      /* data at class i */
      (void) fprintf(stderr,"\n Data at class %d\n", i+1);
      /* exogenous arrival rate, reciprocal to the mean exogenous 
	 interarrival time */  
      (void) fprintf(stderr,   "\n   exogenous arrival rate alpha = ");
      while(fscanf(input_fp,"%lf", &alpha->ve[i])!=1) {
	(void) fprintf(stderr, "\n   bnet errror! exogenous");
	(void) fprintf(stderr, " arrival should be a non-negative number\n");
	(void) fprintf(stderr, "   exogenous arrival rate alpha = ");
	(void) fscanf(input_fp, "%c", &garb);
      }
      /* SCV for exogenous interarrival time */
      (void) fprintf(stderr,   "\n   SCV of inter-arrival time distribution ");
      (void) fprintf(stderr,   "sca = ");
      while (fscanf(input_fp,"%lf", &sca->ve[i]) !=1) {
	(void) fprintf(stderr, "\n   bnet errror! ");
	(void) fprintf(stderr, " SCV should be a non-negative number\n");
	(void) fprintf(stderr,   "sca = ");
	(void) fscanf(input_fp, "%c", &garb);
      }
      /* mean service time */
      (void) fprintf(stderr,"\n   mean service time tau = ");
      while (fscanf(input_fp,"%lf", &tau->ve[i])!=1) {
	(void) fprintf(stderr, "\n   bnet errror! ");
	(void) fprintf(stderr, " tau should be a non-negative number\n");
	(void) fprintf(stderr,   "tau = ");
	(void) fscanf(input_fp, "%c", &garb);
      }
      /* SCV  of the  service time */
      (void) fprintf(stderr,"\n   SCV of  service time scs = ");
      while (fscanf(input_fp,"%lf", &scs->ve[i])!= 1)  {
	(void) fprintf(stderr, "\n   bnet errror! ");
	(void) fprintf(stderr, " SCV should be a non-negative number\n");
	(void) fprintf(stderr,   "scs = ");
	(void) fscanf(input_fp, "%c", &garb);
      }

      if (gjn==FALSE) {
	/* the constituency class for the class */
	(void) fprintf(stderr,"\n   the station number the class will visit = ");
	while (fscanf(input_fp,"%d", &intgarb)!= 1)  {
	  (void) fprintf(stderr, "\n   bnet errror! ");
	  (void) fprintf(stderr, " constituency should be a positive integer\n");
	  (void) fprintf(stderr,   "station number = ");
	  (void) fscanf(stdin, "%c", &garb);
	}
	C->me[intgarb-1][i] = 1;
      }

      /* The following block is doing  inputing of P[i][1], ..., P[i][d] */
      (void) fprintf(stderr,"\n   Now please specify the probability a ");
      (void) fprintf(stderr,"customer \n");
      (void) fprintf(stderr,"   who finishs service at current ");
      (void) fprintf(stderr,"class will go next to other classs\n");
      for (j=0; j<c; j++) {
	(void) fprintf(stderr, 
		       "\n     probability to class %d  P[%d][%d] = ",
		       j+1,i+1,j+1);
	while (fscanf(input_fp, "%lf", &P->me[i][j]) !=1 ) {
	(void) fprintf(stderr, "\n     bnet errror! ");
	(void) fprintf(stderr, " P[%d][%d] should be a number between 0", i+1,j+1);
        (void) fprintf(stderr, " and 1 \n"); 
	(void) fprintf(stderr, "      P[%d][%d] = ", i+1, j+1);
	(void) fscanf(input_fp, "%c", &garb);
      }
      }
    }
    /* the next reads in n, if the value is not provided, the default value
       ( = 4 ) is provided.*/
    (void) fprintf(stderr,"\n The approximating degree n (default is 4) = ");
    if (( fscanf(input_fp,"%d", n) != 1) && *n == '\n')
      *n = 4;
    (void) fprintf(stderr,"\n");
  }

  else {
    for (i=0; i<c; i++) {
      /* data at class i */
      /* exogenous arrival rate, reciprocal to the mean exogenous 
	 interarrival time */  
      if(fscanf(input_fp,"%lf", &alpha->ve[i])!=1)
	error(EF_EXIT,"Error during the input of exogenous arrival");
      /* SCV for exogenous interarrival time */
      if(fscanf(input_fp,"%lf", &sca->ve[i]) !=1)
	error(EF_EXIT,"Error during the input of SCV of interarrival time"); 
      /* mean service time */
      if (fscanf(input_fp,"%lf", &tau->ve[i])!=1)
	error(EF_EXIT,"Error during the input of mean service time"); 
      /* SCV  of the  service time */
      if (fscanf(input_fp,"%lf", &scs->ve[i])!= 1)
	error(EF_EXIT,"Error during input of SCV of the service time"); 

      if (gjn==FALSE) {
	if (fscanf(input_fp,"%d", &intgarb) !=1)
	  error(E_FORMAT, "Constituency station should be an positbe integer");
	C->me[intgarb-1][i] = 1;
      }

      /* The following block is doing  inputing of P  */
      for (j=0; j<c; j++) {
	if (fscanf(input_fp, "%lf", &P->me[i][j]) !=1 )
	  error(EF_EXIT,"Input of the routing matrix is wrong");
	} 
    }
    /* the next reads in n, if the value is not provided, the default value
       ( = 4 ) is provided.*/
    if ( fscanf(input_fp,"%d", n) != 1)
      *n = 4;
  }
}

#ifndef ANSI_C

void mcn_output(Gamma, mu, R, d, n, output_fp, rho)
     MAT * Gamma;
     VEC * mu;
     MAT * R;
     int d;
     int n;
     FILE * output_fp;
     VEC * rho;

#else

void mcn_output(MAT * Gamma, 
		VEC * mu,
	        MAT * R,
		int d,
		int n,
		FILE * output_fp,
		VEC * rho
		)
#endif
{

  int i, j;

      /* copyleft messages */
(void) fprintf(stderr, "              T H I S  I S  MCN  1.1,  C   V E R S I O N \n");
(void) fprintf(stderr, "           Copyright (C) 1992 by Jim Dai and J. Michael Harrison\n");
(void) fprintf(stderr, "                  A L L   R I G H T S   R E S E R V E D\n");
  /* output d, n, Gamma, mu, R , rho for BNET to use */
  (void) fprintf(output_fp, "\n%10d %10d \n\n", d, n);

  for (i=0; i<d; i++) {
    for (j=0; j<i; j++)
      (void) fprintf(output_fp, "           ");
    for (j=i; j<d; j++)
      (void) fprintf(output_fp, "%10.5f ", Gamma->me[i][j]);
    (void) fprintf(output_fp, "\n");
  }
  (void) fprintf(output_fp, "\n");  
  for (i=0; i<d; i++)
    (void) fprintf(output_fp, "%10.5f ", mu->ve[i]);
  (void) fprintf(output_fp, "\n\n");  
  for (i=0; i<d; i++) {
    for (j=0; j<d; j++)
      (void) fprintf(output_fp, "%10.5f ", R->me[i][j]);
    (void) fprintf(output_fp, "\n");
  }
  (void) fprintf(output_fp, "\n");      
    for (i=0; i<d; i++)
    (void) fprintf(output_fp, "%10.5f ", rho->ve[i]);
  (void) fprintf(output_fp, "\n");  
(void) fprintf(stderr, "\n Your bnet data is successfully generated.\n");

}

#ifndef ANSI_C
int get_dimension(interactive, input_fp, prompt)
     int interactive;
     FILE * input_fp;
     char *prompt;
#else
int get_dimension(int interactive, 
                  FILE * input_fp,
                  char *prompt)
#endif
{
  int d;
  char garb;
  if (interactive == True) {
    (void) fprintf(stderr,"\n Number of %s = ", prompt);
    while (fscanf(input_fp,"%d", &d) != 1) {
      (void) fprintf(stderr, " bnet error!  should be a positive integer\n");
      (void) fscanf(input_fp,"%c", &garb); /* collect garbage */
      (void) fprintf(stderr," %s = ", prompt);
    }
  }
  else if( fscanf(input_fp,"%d", &d) != 1)
        error(EF_EXIT," should be a positive integer");
  return d;
}




int mcn_original_data(alpha, sca, tau, scs, P, C, rho, output_fp)
     VEC *alpha;
     VEC *sca;
     VEC *tau;
     VEC *scs;
     MAT *P;
     MAT *C;
     VEC *rho;
     FILE *output_fp;
{
  int i, j, k;
  int d=C->m;
  int c=C->n;

  (void) fprintf(output_fp, 
"\n                        MCN   I N P U T   D A T A                    \n");

  (void) fprintf(output_fp, "\n");
  (void) fprintf(output_fp, 
		 " The number of stations                   = %4d\n", d);
  (void) fprintf(output_fp, 
		 " The number of classes                    = %4d\n", d);
  for (i=0; i<c; i++) {
        (void) fprintf(output_fp, " Class %d data :\n", i+1);
    (void) fprintf(output_fp, 
      "      exogenous arrival rate              = %8.3f \n", alpha->ve[i]);
    (void) fprintf(output_fp,
      "      arrival SCV                         = %8.3f \n", sca->ve[i]);
    (void) fprintf(output_fp, 
      "      mean service requirement            = %8.3f \n", tau->ve[i]);
    (void) fprintf(output_fp,
      "      service SCV                         = %8.3f \n", scs->ve[i]);
	k = C->me[i][i]+1;
    (void) fprintf(output_fp,
		   "      station number                      = %4d \n", k);
    (void) fprintf(output_fp,
		  "      probabilities visiting other classes: \n");
    for (j=0; j<c; j++)
      (void) fprintf(output_fp,
     "         chance to visit class %d          = %8.3f\n", j+1, P->me[i][j]);
	(void) fprintf(output_fp, "\n");
    
      }

  (void) fprintf(output_fp, " Traffic intensities:\n");      
  for (i=0; i<d; i++)
    (void) fprintf(output_fp, 
     "  station %d utilization                   = %8.3f \n", i+1, rho->ve[i]);
  (void) fprintf(output_fp, "\n");  
  return 0;
}
