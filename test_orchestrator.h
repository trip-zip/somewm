#ifndef SOMEWM_TEST_ORCHESTRATOR_H
#define SOMEWM_TEST_ORCHESTRATOR_H

#include <stdbool.h>

/*
 * Inspired by AWMTT (https://github.com/serialoverflow/awmtt).
 *
 * Runs a nested somewm compositor in a sandboxed XDG environment so the user
 * can iterate on rc.lua without touching their real session.
 */

int test_orchestrator_run(int argc, char *argv[], int json_mode);

void test_orchestrator_print_usage(const char *progname);

/* Defined in somewm-client.c. Prints the reply read from sock and returns
 * 0, 1 for an error reply, or -1 when the read fails. */
int read_response(int sock);

#endif
