#ifndef SRBM_MEM_H
#define SRBM_MEM_H

#include <stddef.h>

void *srbm_malloc(size_t size);
void *srbm_calloc(size_t count, size_t size);
void *srbm_realloc(void *ptr, size_t size);
void  srbm_free(void *ptr);

#endif /* SRBM_MEM_H */
