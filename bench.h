#ifndef SOMEWM_BENCH_H
#define SOMEWM_BENCH_H

#ifdef SOMEWM_BENCH

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

#define BENCH_FRAME_HISTORY 1000

/* --- Signal dispatch counters --- */

extern uint64_t bench_signal_emit_count;
extern uint64_t bench_signal_handler_calls;
extern uint64_t bench_signal_lookup_misses;

void bench_signal_counters_reset(void);

/* --- Frame timing --- */

uint64_t timespec_diff_ns(struct timespec *start, struct timespec *end);

void bench_record_frame_time(uint64_t elapsed_ns);
void bench_frame_stats_get(uint64_t *count, uint64_t *min_ns, uint64_t *max_ns,
                           uint64_t *avg_ns, uint64_t *p99_ns);
void bench_frame_stats_reset(void);

/* --- Per-stage frame budget timing --- */

typedef enum {
    BENCH_STAGE_LUA_REFRESH,
    BENCH_STAGE_ANIMATION,
    BENCH_STAGE_DRAWIN,
    BENCH_STAGE_CLIENT,
    BENCH_STAGE_BANNING,
    BENCH_STAGE_STACK,
    BENCH_STAGE_DESTROY,
    BENCH_STAGE_COUNT
} bench_stage_t;

void bench_stage_record(bench_stage_t stage, uint64_t elapsed_ns);
void bench_stage_stats_get(bench_stage_t stage, uint64_t *min_ns,
                           uint64_t *max_ns, uint64_t *avg_ns, uint64_t *p99_ns);
void bench_stage_stats_reset(void);

extern const char *bench_stage_names[BENCH_STAGE_COUNT];

/* --- C/Lua boundary crossing counter --- */

extern uint64_t bench_clua_crossings_this_frame;

void bench_crossings_stats_get(double *avg, uint64_t *max);
void bench_crossings_reset(void);

/* --- Input-to-display latency --- */

#define BENCH_INPUT_RING 64

void bench_input_event_record(void);
void bench_input_commit_flush(void);
void bench_input_latency_stats_get(uint64_t *count, uint64_t *avg_ns,
                                   uint64_t *p99_ns, uint64_t *max_ns);
void bench_input_latency_reset(void);

/* --- Client manage latency --- */

void bench_manage_start(void *client_ptr);
void bench_manage_end(void *client_ptr);
void bench_manage_latency_stats_get(uint64_t *count, uint64_t *avg_ns,
                                    uint64_t *p99_ns, uint64_t *max_ns);
void bench_manage_latency_reset(void);

/* --- Render (compositing) phase timing --- */

void bench_render_record(uint64_t elapsed_ns);
void bench_render_stats_get(uint64_t *count, uint64_t *min_ns, uint64_t *max_ns,
                            uint64_t *avg_ns, uint64_t *p99_ns);
void bench_render_reset(void);

/* Scene node counting (called at query time, not per-frame) */
struct wlr_scene_node;
void bench_count_scene_nodes(struct wlr_scene_node *root,
                             int *trees, int *rects, int *buffers);

/* --- Full reset --- */

void bench_reset_all(void);

#endif /* SOMEWM_BENCH */

#endif /* SOMEWM_BENCH_H */
