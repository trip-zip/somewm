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
#include <wlr/util/log.h>

void die(const char *fmt, ...);
void *ecalloc(size_t nmemb, size_t size);
int fd_set_nonblock(int fd);

/* AwesomeWM-compatible utility macros and functions */
#ifndef MAX
#define MAX(a,b) ((a) < (b) ? (b) : (a))
#endif
#ifndef MIN
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif
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

/** Compute a hash for a string (djb2 algorithm).
 * Used by AwesomeWM's signal system for fast signal lookup.
 * \param str The string to hash.
 * \return The hash value.
 */
static inline unsigned long __attribute__ ((nonnull(1)))
a_strhash(const unsigned char *str)
{
    unsigned long hash = 5381;
    int c;

    while((c = *str++))
        hash = ((hash << 5) + hash) + c; /* hash * 33 + c */

    return hash;
}

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

/* AwesomeWM error/warning macros and functions */
#define fatal(string, ...) _fatal(__LINE__, \
                                  __func__, \
                                  string, ## __VA_ARGS__)
void _fatal(int, const char *, const char *, ...)
    __attribute__ ((noreturn)) __attribute__ ((format(printf, 3, 4)));

#define warn(string, ...) _warn(__LINE__, \
                                __func__, \
                                string, ## __VA_ARGS__)
void _warn(int, const char *, const char *, ...)
    __attribute__ ((format(printf, 3, 4)));

#define check(condition) do { \
        if (!(condition)) \
            _warn(__LINE__, __func__, \
                    "Checking assertion failed: " #condition); \
    } while (0)

/* Level-aware logging macros (uses wlroots logging)
 * Log level is controlled by wlr_log_init() which respects globalconf.log_level.
 * Use -d for debug, --verbose for info, or set awesome.log_level in Lua. */
#define log_error(fmt, ...)  wlr_log(WLR_ERROR, fmt, ##__VA_ARGS__)
#define log_info(fmt, ...)   wlr_log(WLR_INFO, fmt, ##__VA_ARGS__)
#define log_debug(fmt, ...)  wlr_log(WLR_DEBUG, fmt, ##__VA_ARGS__)

const char *a_current_time_str(void);

void a_exec(const char *);

ssize_t a_strncpy(char *dst, ssize_t n, const char *src, ssize_t l) __attribute__((nonnull(1)));
ssize_t a_strcpy(char *dst, ssize_t n, const char *src) __attribute__((nonnull(1)));

#endif /* UTIL_H */
