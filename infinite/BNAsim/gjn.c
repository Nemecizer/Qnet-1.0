/* #include <stdlib.h> */
#include "gjn.h"
#include "oldnames.h"

extern MAT *v_diag();

#ifndef ANSI_C
int main(argc, argv)
     int   argc;
     char *argv[];
#else
int main(int   argc, 
	 char *argv[])
#endif
{
  int  iterative = False , interactive = False, workload = True;
  int garb = False, print=False;
  FILE **fp = option(argc, argv, &iterative, &interactive, &workload,
		     &print);
  FILE *input_fp  = fp[0]; 
  FILE *output_fp = fp[1]; 
  int d = get_dimension(interactive, input_fp);
  VEC  *alpha  = get_vec(d); /* alpha = mu initially */
  VEC  *mu  = get_vec(d); /* alpha = mu initially */
  VEC  *sca = get_vec(d);
  VEC  *tau = get_vec(d);
  VEC  *scs = get_vec(d); 
  MAT  *R   = get_mat(d, d);
  MAT  *P   = get_mat(d, d);
  MAT  *Gamma   = get_mat(d, d);
  VEC  *rho;
  int   n;

   /* temporary matrices */
  MAT  *temp = get_mat(d, d);
  MAT  *m_temp = get_mat(d, d);
  MAT  *Gammas, *H;
  /* temporary vectors */
  VEC *mucpy=get_vec(d);
  VEC *vtemp=get_vec(d); 
  VEC *beta =get_vec(d);  
  VEC *lambda;
  /* temporary indexies */
  int i, j, m, k, l;
  PERM *pivot=get_perm(d);

  gjn_input(mu, sca, tau, scs, P, d, &n, interactive, input_fp);
  cp_vec(mu, alpha);
  m_transp(P, m_temp); /* P_prime = P' */
  id_mat(R);  /*  R = I  */
  m_sub(R, m_temp, R); /* R  = I - P' */
  cp_mat(R, m_temp);
  cp_vec(mu, mucpy);

  LUfactor(m_temp, pivot);
  lambda = LUsolve(m_temp, pivot,  mucpy, VNULL);  /* mu=alpha */
  freevec(mucpy);
  /*
  lambda = get_vec(d);
  ones_vec(lambda);
  */
  freevec(beta);

  /*Caculating Gamma  */

  /* Gamma for queue length formulation */
  m_temp  = v_diag(mu, MNULL);
  temp    = v_diag(sca,MNULL);

  m_mlt(m_temp, temp, Gamma);  /* Gamma = diag(alpha)*diag(sca); */
  v_diag(lambda, m_temp);
  v_diag(scs, temp);

  Gammas   = get_mat(d, d);
  m_mlt(m_temp, temp, Gammas); /* Gammas = diag(lambda)*diag(scs); */
  m_mlt(R, Gammas, m_temp);
  m_transp(R, temp);
  m_mlt(m_temp, temp, Gammas); 
  /* Gammas = (I-P')*diag(lambda)*diag(scs)*(I-P) */
  m_add(Gamma, Gammas, Gamma); /* Gamma = Gamma + Gammas */
  H = get_mat(d, d);
  zero_mat(Gammas);
  for (i=0; i<d; i++)
    {
      for (k=0; k<d; k++)
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
  m_add(Gamma, Gammas, Gamma);
  /*  Gamma += Gammas; */
  freemat(H);
  freemat(Gammas);
  freevec(vtemp);
  freemat(m_temp);
  freemat(temp);

      /* Gamma for workload formulation */
  if (workload == True ){
	/* Gamma = T G T */ /* R = T (I-P') T^{-1} */
    for (i=0; i<d; i++)
      for (j=0; j<d; j++) {
	Gamma->me[i][j] *= tau->ve[i] * tau->ve[j];
	R->me[i][j] *= tau->ve[i] /tau->ve[j];
      }
  }

  /* calculating the traffic intensities 
    if traffic intensity at one station 
    is larger than 1
    echo error and exit
    */
  rho = get_vec(d);
  for (i=0; i<d; i++)
    rho->ve[i] = tau->ve[i]*lambda->ve[i];
  for (i=0; i<d; i++)
    if (rho->ve[i] >= 1) {
      (void) fprintf(stderr," Station %d is over saturated\n", i+1);
      garb = True;
    }
  if (garb == True) error(EF_EXIT,"No bnet data is produced");
  
  if (workload == True) {
	/* calculating mu = R ( rho - e) */
    for (i=0; i<d; i++) {
      mu->ve[i] = 0;
      for (j=0; j<d; j++)
	mu->ve[i] += R->me[i][j] * ( rho->ve[j] - 1);
    }
  } 
  else {
    
    /* calculating mu = R diag(1/tau) * ( rho - e) = alpha - (I-P')1/tau */
	/* mu = (I-P')(lambda - 1/tau); */
    for (i=0; i<d; i++ )
      lambda->ve[i] = lambda->ve[i] - 1/tau->ve[i];
    for (i=0; i<d; i++) {
      mu->ve[i] = 0;
      for (j=0; j<d; j++)
	mu->ve[i] += R->me[i][j] * lambda->ve[j];
    }
    
  }
  freevec(lambda);



  gjn_output(Gamma, mu, R, d, n, output_fp, rho);

  freevec(mu);
  freemat(Gamma);
  freemat(R);

  if (print == TRUE)
    gjn_original_data(alpha, sca, tau, scs, P, rho, output_fp);
  freemat(P);
  freevec(rho);
  freevec(tau);
  freevec(alpha);
  freevec(sca);
  freevec(scs);
  return (0);
  
  
}

#ifndef ANSI_C
FILE **option( argc, argv, iterative, interactive, workload, print)
     int argc;
     char * argv[];
     int * iterative;
     int * interactive;
     int * workload;
     int * print;
#else
FILE **option(int argc,
	      char * argv[],
	      int * iterative,
	      int * interactive,
	      int * workload,
	      int * print)
#endif
{
  FILE **fp = (FILE **) malloc((unsigned) 2*sizeof(FILE *));
  int c;
  
  while (--argc > 0 && (*++argv)[0] == '-')
    while ( c = *++argv[0])
      switch (c) {
      case 'v':
	(void) fprintf(stdout, " This is GJN 1.1, C version, June 1992;\n");
	(void) fprintf(stdout, " please contact dai@isye.gatech.edu for ");
	(void) fprintf(stdout, "possible newer version.\n\n");
	exit(0);
	break;
      case 'i':
	*iterative =True;
	break;
      case 'p':
	*print =True;
	break;
      case 'h':
	(void)  fprintf(stderr, " Usage: gjn [-h] [-q] [-p] [-v] [data_file ");
	(void)  fprintf(stderr, "[output_file] ]\n");
	(void)  fprintf(stderr, " Options: \n");
	(void)  fprintf(stderr, "  -h print this message\n");
	(void)  fprintf(stderr, "  -q use the queue length formulation \n");
	(void)  fprintf(stderr, "  -p print the original network data\n");
	(void)  fprintf(stderr, "  -v print the current version of gjn \n");
	exit(0);
	break;
      case 'q':
	*workload = False;
	break;
      default:
	(void) fprintf(stderr, " gjn: illegal option %c\n", c);
	argc = -1;
	break;
      }
  if ( argc < 0 || argc > 2) {
    (void)  fprintf(stderr, " Usage: gjn [-h] [-q] [-p] [-v] [data_file ");
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

void gjn_input(alpha, sca, tau, scs, P, d, n, interactive, input_fp)
     VEC * alpha;  /* exogeneous arrival rate */
     VEC * sca;    /* SCV for inter-arrival time */
     VEC * tau;    /* mean service times */
     VEC * scs;    /* SCV for service times */
     MAT * P;      /* routing matrix */
     int d;        /* of stations */
     int * n;      /* maximum degree to use */
     int interactive;
     FILE *input_fp;

#else

void gjn_input(VEC * alpha,  /* exogeneous arrival rate */
	       VEC * sca,    /* SCV for inter-arrival time */
	       VEC * tau,    /* mean service times */
	       VEC * scs,    /* SCV for service times */
	       MAT * P,      /* routing matrix */
	       int d,        /* of stations */
	       int * n,      /* maximum degree to use */
	       int interactive, 
	       FILE *input_fp
	       )
#endif
{
  char garb;
  int i, j;

  if (interactive == True) {
    for (i=0; i<d; i++) {
      /* data at station i */
      (void) fprintf(stderr,"\n Data at station %d\n", i+1);
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

      /* The following block is doing  inputing of P[i][1], ..., P[i][d] */
      (void) fprintf(stderr,"\n   Now please specify the probability a ");
      (void) fprintf(stderr,"customer \n");
      (void) fprintf(stderr,"   who finishs service at current ");
      (void) fprintf(stderr,"station will go next to other stations\n");
      for (j=0; j<d; j++) {
	(void) fprintf(stderr, 
		       "\n     probability to station %d  P[%d][%d] = ",
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
    for (i=0; i<d; i++) {
      /* data at station i */
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

      /* The following block is doing  inputing of P  */
      for (j=0; j<d; j++) {
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

void gjn_output(Gamma, mu, R, d, n, output_fp, rho)
     MAT * Gamma;
     VEC * mu;
     MAT * R;
     int d;
     int n;
     FILE * output_fp;
     VEC * rho;

#else

void gjn_output(MAT * Gamma, 
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
(void) fprintf(stderr, "              T H I S  I S  GJN  1.1,  C   V E R S I O N \n");
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
int get_dimension(interactive, input_fp)
     int interactive;
     FILE * input_fp;
#else
int get_dimension(int interactive, 
		  FILE * input_fp)
#endif
{
  int d;
  char garb;
  if (interactive == True) {
    (void) fprintf(stderr,"\n Number of stations d = ");
    while (fscanf(input_fp,"%d", &d) != 1) {
      (void) fprintf(stderr, " bnet error! d should be a positive integer\n");
      (void) fscanf(input_fp,"%c", &garb); /* collect garbage */
      (void) fprintf(stderr," d = ");
    }
  }
  else if( fscanf(input_fp,"%d", &d) != 1)
        error(EF_EXIT,"d should be a positive integer");
  return d;
}

#ifndef ANSI_C
MAT *v_diag(mu, out)
     VEC * mu;
     MAT *out;
#else
MAT *v_diag(VEC * mu, MAT *out)
#endif
{
  int i;
  if ( mu ==(VEC *)NULL)
    error(E_NULL,"v_diag");
  if ( out==(MAT *)NULL || out->m != mu->dim || out->n != mu->dim)
    out = m_resize(out,mu->dim,mu->dim);
  zero_mat(out);
  for (i=0; i< out->n; i++)
    out->me[i][i] = mu->ve[i];
  return out;
}



int gjn_original_data(alpha, sca, tau, scs, P, rho, output_fp)
     VEC *alpha;
     VEC *sca;
     VEC *tau;
     VEC *scs;
     MAT *P;
     VEC *rho;
     FILE *output_fp;
{
  int i, j, k;
  int d=P->n;

  (void) fprintf(output_fp, 
"\n                        GJN   I N P U T   D A T A                    \n");

  (void) fprintf(output_fp, "\n");
  (void) fprintf(output_fp, 
		 " The number of stations                    = %4d\n", d);
  for (i=0; i<d; i++) {
        (void) fprintf(output_fp, " Station %d data :\n", i+1);
    (void) fprintf(output_fp, 
      "      exogenous arrival rate               = %8.3f \n", alpha->ve[i]);
    (void) fprintf(output_fp, 
      "      arrival SCV                          = %8.3f \n", sca->ve[i]);
    (void) fprintf(output_fp, 
      "      mean service requirement             = %8.3f \n", tau->ve[i]);
    (void) fprintf(output_fp,
      "      service SCV                          = %8.3f \n", scs->ve[i]);
    (void) fprintf(output_fp,
		  "      probabilities visiting other stations: \n");
    for (j=0; j<d; j++)
      (void) fprintf(output_fp,
   "         chance to visit station %d         = %8.3f\n", j+1, P->me[i][j]);
	(void) fprintf(output_fp, 
     "  station %d utilization                    = %8.3f \n", i+1, rho->ve[i]);
	(void) fprintf(output_fp, "\n");
    
      }
  return 0;
}
