/*
 * util.h - Utility functions and macros
 *
 * Copyright © 2024 somewm contributors
 * Based on AwesomeWM utility patterns
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef UTIL_H
#define UTIL_H

#include <string.h>
#include <strings.h>  /* For strcasecmp */
#include <stdlib.h>
#include <alloca.h>   /* For alloca */
#include <sys/types.h> /* For ssize_t */

void die(const char *fmt, ...);
void *ecalloc(size_t nmemb, size_t size);
int fd_set_nonblock(int fd);

/* AwesomeWM-compatible utility macros and functions */
#define DO_NOTHING(...)
#define p_alloc_nr(x)           (((x) + 16) * 3 / 2)
#define p_new(type, count)      ((type *)ecalloc((count), sizeof(type)))
#define p_clear(p, count)       ((void)memset((p), 0, sizeof(*(p)) * (count)))
#define p_alloca(type, count)   ((type *)alloca(sizeof(type) * (count)))
#define p_delete(mem_pp)        \
    do {                        \
        typeof(**(mem_pp)) **__ptr = (mem_pp); \
        free(*__ptr);           \
        *__ptr = NULL;          \
    } while(0)

/** Realloc a pointer and update it in place (AwesomeWM pattern)
 * \param ptr Pointer to the pointer to reallocate
 * \param newsize The new size in bytes
 */
static inline void
xrealloc(void **ptr, ssize_t newsize)
{
	if (newsize <= 0)
		p_delete(ptr);
	else
	{
		*ptr = realloc(*ptr, newsize);
		if (!*ptr)
			abort();
	}
}

#define p_realloc(pp, count)    xrealloc((void**)(pp), sizeof(**(pp)) * (count))
#define p_grow(pp, goalnb, allocnb)                  \
    do {                                             \
        if ((goalnb) > *(allocnb)) {                 \
            if (p_alloc_nr(*(allocnb)) < (goalnb)) { \
                *(allocnb) = (goalnb);               \
            } else {                                 \
                *(allocnb) = p_alloc_nr(*(allocnb)); \
            }                                        \
            p_realloc((pp), *(allocnb));             \
        }                                            \
    } while (0)

/* Memory duplication macro */
#define p_dup(p, count)         memdup((p), sizeof(*(p)) * (count))

/* Helper for p_dup - duplicates memory block */
static inline void *memdup(const void *src, size_t len)
{
    void *dst = malloc(len);
    if (dst)
        memcpy(dst, src, len);
    return dst;
}

/* Type introspection macros */
#define fieldtypeof(type_t, m)  typeof(((type_t *)0)->m)

/* String comparison macros (NULL-safe) */
#define NONULL(x)               ((x) ? (x) : "")

static inline int a_strcmp(const char *a, const char *b)
{
    return strcmp(NONULL(a), NONULL(b));
}

static inline int a_strcasecmp(const char *a, const char *b)
{
    return strcasecmp(NONULL(a), NONULL(b));
}

static inline int a_strncmp(const char *a, const char *b, ssize_t n)
{
    return strncmp(NONULL(a), NONULL(b), n);
}

#define  A_STREQ(a, b)       (((a) == (b)) || a_strcmp(a, b) == 0)
#define A_STRNEQ(a, b)       (!A_STREQ(a, b))
#define  A_STREQ_CASE(a, b)  (((a) == (b)) || a_strcasecmp(a, b) == 0)
#define A_STRNEQ_CASE(a, b)  (!A_STREQ_CASE(a, b))
#define  A_STREQ_N(a, b, n)  (((a) == (b)) || (n) == ((ssize_t) 0) || a_strncmp(a, b, n) == 0)
#define A_STRNEQ_N(a, b)     (!A_STREQ_N(a, b))

/* Branch prediction hints (AwesomeWM-compatible) */
#ifdef __GNUC__
#define likely(expr)    __builtin_expect(!!(expr), 1)
#define unlikely(expr)  __builtin_expect((expr), 0)
#else
#define likely(expr)    expr
#define unlikely(expr)  expr
#endif

/* NULL-resistant strlen */
static inline ssize_t a_strlen(const char *s)
{
    return s ? strlen(s) : 0;
}

/* NULL-safe strdup using p_dup */
static inline char *a_strdup(const char *s)
{
    ssize_t len = a_strlen(s);
    return len ? p_dup(s, len + 1) : NULL;
}

/* Memory allocation with abort on failure (AwesomeWM-compatible) */
static inline void * __attribute__ ((malloc)) xmalloc(ssize_t size)
{
    void *ptr;

    if(size <= 0)
        return NULL;

    ptr = calloc(1, size);

    if(!ptr)
        abort();

    return ptr;
}

#endif /* UTIL_H */
