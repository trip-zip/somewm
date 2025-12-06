/*
 * awm_signal.h - AwesomeWM signal compatibility layer for somewm
 *
 * This provides AwesomeWM's signal interface using somewm's signal implementation.
 * AwesomeWM uses hash-based signals, somewm uses name-based signals.
 *
 * Adapted from AwesomeWM common/signal.h
 * Copyright © 2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef AWESOME_COMMON_SIGNAL_H
#define AWESOME_COMMON_SIGNAL_H

#include "objects/signal.h"
#include "common/array.h"
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

/* For AwesomeWM compatibility, we just use somewm's signal_array_t directly.
 * The LUA_OBJECT_HEADER macro will use this type.
 */

/* Array of const void * for signal function pointers (AwesomeWM compatibility) */
DO_ARRAY(const void *, cptr, DO_NOTHING)

/** Connect a signal inside a signal array (somewm implementation).
 * You are in charge of reference counting.
 * \param arr The signal array.
 * \param name The signal name.
 * \param ref The reference to add (as intptr_t).
 */
static inline void
signal_connect(signal_array_t *arr, const char *name, const void *ref)
{
    signal_t *sigfound;
    signal_t *sig;
    /* Somewm's signal_array_getbyname is implemented in objects/signal.c */
    extern signal_t *signal_array_getbyname(signal_array_t *arr, const char *name);

    sigfound = signal_array_getbyname(arr, name);
    if(sigfound)
    {
        /* Grow refs array if needed */
        if(sigfound->ref_count >= sigfound->ref_capacity)
        {
            sigfound->ref_capacity = sigfound->ref_capacity ? sigfound->ref_capacity * 2 : 4;
            sigfound->refs = realloc(sigfound->refs, sigfound->ref_capacity * sizeof(intptr_t));
        }
        sigfound->refs[sigfound->ref_count++] = (intptr_t)ref;
    }
    else
    {
        /* Create new signal */
        if(arr->count >= arr->capacity)
        {
            arr->capacity = arr->capacity ? arr->capacity * 2 : 4;
            arr->signals = realloc(arr->signals, arr->capacity * sizeof(signal_t));
        }
        sig = &arr->signals[arr->count++];
        sig->name = strdup(name);
        sig->ref_capacity = 4;
        sig->refs = malloc(sig->ref_capacity * sizeof(intptr_t));
        sig->ref_count = 1;
        sig->refs[0] = (intptr_t)ref;
    }
}

/** Disconnect a signal inside a signal array (somewm implementation).
 * You are in charge of reference counting.
 * \param arr The signal array.
 * \param name The signal name.
 * \param ref The reference to remove.
 */
static inline bool
signal_disconnect(signal_array_t *arr, const char *name, const void *ref)
{
    signal_t *sigfound;
    size_t i, j;
    extern signal_t *signal_array_getbyname(signal_array_t *arr, const char *name);

    sigfound = signal_array_getbyname(arr, name);
    if(sigfound)
    {
        for(i = 0; i < sigfound->ref_count; i++)
        {
            if(sigfound->refs[i] == (intptr_t)ref)
            {
                /* Remove by shifting remaining elements */
                for(j = i; j < sigfound->ref_count - 1; j++)
                    sigfound->refs[j] = sigfound->refs[j + 1];
                sigfound->ref_count--;
                return true;
            }
        }
    }
    return false;
}

#endif

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
