#include "bench.h"

#ifdef SOMEWM_BENCH

#include <string.h>
#include <wlr/types/wlr_scene.h>

/* --- Shared stats computation --- */

/* Insertion sort + min/max/avg/p99 over n entries.
 * n must be <= BENCH_FRAME_HISTORY. */
static void
bench_compute_stats(const uint64_t *data, int n,
                    uint64_t *min_ns, uint64_t *max_ns,
                    uint64_t *avg_ns, uint64_t *p99_ns)
{
    if (n <= 0) {
        *min_ns = *max_ns = *avg_ns = *p99_ns = 0;
        return;
    }

    uint64_t sorted[BENCH_FRAME_HISTORY];
    memcpy(sorted, data, n * sizeof(uint64_t));

    for (int i = 1; i < n; i++) {
        uint64_t key = sorted[i];
        int j = i - 1;
        while (j >= 0 && sorted[j] > key) {
            sorted[j + 1] = sorted[j];
            j--;
        }
        sorted[j + 1] = key;
    }

    *min_ns = sorted[0];
    *max_ns = sorted[n - 1];

    uint64_t sum = 0;
    for (int i = 0; i < n; i++)
        sum += sorted[i];
    *avg_ns = sum / n;

    int p99_idx = (int)((n - 1) * 0.99);
    *p99_ns = sorted[p99_idx];
}

/* --- Signal dispatch counters --- */

uint64_t bench_signal_emit_count = 0;
uint64_t bench_signal_handler_calls = 0;
uint64_t bench_signal_lookup_misses = 0;

void
bench_signal_counters_reset(void)
{
    bench_signal_emit_count = 0;
    bench_signal_handler_calls = 0;
    bench_signal_lookup_misses = 0;
}

/* --- Frame timing --- */

static uint64_t bench_frame_times_ns[BENCH_FRAME_HISTORY];
static int bench_frame_index = 0;
static int bench_frame_count = 0;
static uint64_t bench_refresh_count = 0;

uint64_t
timespec_diff_ns(struct timespec *start, struct timespec *end)
{
    return (uint64_t)(end->tv_sec - start->tv_sec) * 1000000000ULL
         + (uint64_t)(end->tv_nsec - start->tv_nsec);
}

void
bench_frame_stats_get(uint64_t *count, uint64_t *min_ns, uint64_t *max_ns,
                      uint64_t *avg_ns, uint64_t *p99_ns)
{
    *count = bench_refresh_count;
    int n = bench_frame_count < BENCH_FRAME_HISTORY
          ? bench_frame_count : BENCH_FRAME_HISTORY;
    bench_compute_stats(bench_frame_times_ns, n, min_ns, max_ns, avg_ns, p99_ns);
}

void
bench_frame_stats_reset(void)
{
    bench_frame_index = 0;
    bench_frame_count = 0;
    bench_refresh_count = 0;
}

/* --- Per-stage frame budget timing --- */

const char *bench_stage_names[BENCH_STAGE_COUNT] = {
    "lua_refresh",
    "animation",
    "drawin",
    "client",
    "banning",
    "stack",
    "destroy",
};

static uint64_t bench_stage_times_ns[BENCH_STAGE_COUNT][BENCH_FRAME_HISTORY];
static int bench_stage_index = 0;
static int bench_stage_count = 0;

void
bench_stage_record(bench_stage_t stage, uint64_t elapsed_ns)
{
    bench_stage_times_ns[stage][bench_stage_index] = elapsed_ns;
}

/* Called once per frame after all stages recorded, to advance the shared index */
static void
bench_stage_frame_end(void)
{
    bench_stage_index = (bench_stage_index + 1) % BENCH_FRAME_HISTORY;
    bench_stage_count++;
}

void
bench_stage_stats_get(bench_stage_t stage, uint64_t *min_ns,
                      uint64_t *max_ns, uint64_t *avg_ns, uint64_t *p99_ns)
{
    int n = bench_stage_count < BENCH_FRAME_HISTORY
          ? bench_stage_count : BENCH_FRAME_HISTORY;
    bench_compute_stats(bench_stage_times_ns[stage], n,
                        min_ns, max_ns, avg_ns, p99_ns);
}

void
bench_stage_stats_reset(void)
{
    bench_stage_index = 0;
    bench_stage_count = 0;
    memset(bench_stage_times_ns, 0, sizeof(bench_stage_times_ns));
}

/* --- C/Lua boundary crossing counter --- */

uint64_t bench_clua_crossings_this_frame = 0;

static uint64_t bench_crossings_per_frame[BENCH_FRAME_HISTORY];
static int bench_crossings_index = 0;
static int bench_crossings_count = 0;

static void
bench_crossings_frame_end(void)
{
    bench_crossings_per_frame[bench_crossings_index] = bench_clua_crossings_this_frame;
    bench_crossings_index = (bench_crossings_index + 1) % BENCH_FRAME_HISTORY;
    bench_crossings_count++;
    bench_clua_crossings_this_frame = 0;
}

void
bench_crossings_stats_get(double *avg, uint64_t *max)
{
    if (bench_crossings_count == 0) {
        *avg = 0;
        *max = 0;
        return;
    }

    int n = bench_crossings_count < BENCH_FRAME_HISTORY
          ? bench_crossings_count : BENCH_FRAME_HISTORY;
    uint64_t sum = 0;
    uint64_t mx = 0;
    for (int i = 0; i < n; i++) {
        sum += bench_crossings_per_frame[i];
        if (bench_crossings_per_frame[i] > mx)
            mx = bench_crossings_per_frame[i];
    }
    *avg = (double)sum / n;
    *max = mx;
}

void
bench_crossings_reset(void)
{
    bench_clua_crossings_this_frame = 0;
    bench_crossings_index = 0;
    bench_crossings_count = 0;
}

/* --- End-of-frame bookkeeping ---
 *
 * bench_record_frame_time() is the single entry point called at the end of
 * some_refresh(). It records the total frame time and advances all per-frame
 * circular buffers together. */

void
bench_record_frame_time(uint64_t elapsed_ns)
{
    bench_frame_times_ns[bench_frame_index] = elapsed_ns;
    bench_frame_index = (bench_frame_index + 1) % BENCH_FRAME_HISTORY;
    bench_frame_count++;
    bench_refresh_count++;

    bench_crossings_frame_end();
    bench_stage_frame_end();
}

/* --- Input-to-display latency --- */

static uint64_t bench_pending_inputs[BENCH_INPUT_RING];
static int bench_input_head = 0;
static int bench_input_tail = 0;

static uint64_t bench_input_latencies[BENCH_FRAME_HISTORY];
static int bench_input_lat_index = 0;
static int bench_input_lat_count = 0;

void
bench_input_event_record(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t now = (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;

    int next = (bench_input_head + 1) % BENCH_INPUT_RING;
    if (next != bench_input_tail) {
        bench_pending_inputs[bench_input_head] = now;
        bench_input_head = next;
    }
    /* If ring is full, drop the oldest */
}

void
bench_input_commit_flush(void)
{
    if (bench_input_head == bench_input_tail)
        return;  /* No pending inputs */

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t now = (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;

    uint64_t max_latency = 0;
    while (bench_input_tail != bench_input_head) {
        uint64_t latency = now - bench_pending_inputs[bench_input_tail];
        if (latency > max_latency)
            max_latency = latency;
        bench_input_tail = (bench_input_tail + 1) % BENCH_INPUT_RING;
    }

    bench_input_latencies[bench_input_lat_index] = max_latency;
    bench_input_lat_index = (bench_input_lat_index + 1) % BENCH_FRAME_HISTORY;
    bench_input_lat_count++;
}

void
bench_input_latency_stats_get(uint64_t *count, uint64_t *avg_ns,
                              uint64_t *p99_ns, uint64_t *max_ns)
{
    *count = bench_input_lat_count;
    int n = bench_input_lat_count < BENCH_FRAME_HISTORY
          ? bench_input_lat_count : BENCH_FRAME_HISTORY;
    uint64_t min_ns;
    bench_compute_stats(bench_input_latencies, n,
                        &min_ns, max_ns, avg_ns, p99_ns);
}

void
bench_input_latency_reset(void)
{
    bench_input_head = 0;
    bench_input_tail = 0;
    bench_input_lat_index = 0;
    bench_input_lat_count = 0;
}

/* --- Client manage latency --- */

#define BENCH_MANAGE_HISTORY 256

struct bench_manage_entry {
    void *client_ptr;
    uint64_t start_ns;
};

static struct bench_manage_entry bench_manage_pending[BENCH_MANAGE_HISTORY];
static int bench_manage_pending_count = 0;

static uint64_t bench_manage_latencies[BENCH_MANAGE_HISTORY];
static int bench_manage_lat_index = 0;
static int bench_manage_lat_count = 0;

void
bench_manage_start(void *client_ptr)
{
    if (bench_manage_pending_count >= BENCH_MANAGE_HISTORY)
        return;

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    bench_manage_pending[bench_manage_pending_count].client_ptr = client_ptr;
    bench_manage_pending[bench_manage_pending_count].start_ns =
        (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
    bench_manage_pending_count++;
}

void
bench_manage_end(void *client_ptr)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t now = (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;

    for (int i = 0; i < bench_manage_pending_count; i++) {
        if (bench_manage_pending[i].client_ptr == client_ptr) {
            uint64_t latency = now - bench_manage_pending[i].start_ns;
            bench_manage_latencies[bench_manage_lat_index] = latency;
            bench_manage_lat_index = (bench_manage_lat_index + 1) % BENCH_MANAGE_HISTORY;
            bench_manage_lat_count++;

            /* Remove from pending by swapping with last */
            bench_manage_pending[i] = bench_manage_pending[bench_manage_pending_count - 1];
            bench_manage_pending_count--;
            return;
        }
    }
}

void
bench_manage_latency_stats_get(uint64_t *count, uint64_t *avg_ns,
                               uint64_t *p99_ns, uint64_t *max_ns)
{
    *count = bench_manage_lat_count;
    int n = bench_manage_lat_count < BENCH_MANAGE_HISTORY
          ? bench_manage_lat_count : BENCH_MANAGE_HISTORY;
    uint64_t min_ns;
    bench_compute_stats(bench_manage_latencies, n,
                        &min_ns, max_ns, avg_ns, p99_ns);
}

void
bench_manage_latency_reset(void)
{
    bench_manage_pending_count = 0;
    bench_manage_lat_index = 0;
    bench_manage_lat_count = 0;
}

/* --- Render (compositing) phase timing --- */

static uint64_t bench_render_times_ns[BENCH_FRAME_HISTORY];
static int bench_render_index = 0;
static int bench_render_count = 0;

void
bench_render_record(uint64_t elapsed_ns)
{
    bench_render_times_ns[bench_render_index] = elapsed_ns;
    bench_render_index = (bench_render_index + 1) % BENCH_FRAME_HISTORY;
    bench_render_count++;
}

void
bench_render_stats_get(uint64_t *count, uint64_t *min_ns, uint64_t *max_ns,
                       uint64_t *avg_ns, uint64_t *p99_ns)
{
    *count = bench_render_count;
    int n = bench_render_count < BENCH_FRAME_HISTORY
          ? bench_render_count : BENCH_FRAME_HISTORY;
    bench_compute_stats(bench_render_times_ns, n, min_ns, max_ns, avg_ns, p99_ns);
}

void
bench_render_reset(void)
{
    bench_render_index = 0;
    bench_render_count = 0;
}

void
bench_count_scene_nodes(struct wlr_scene_node *root,
                        int *trees, int *rects, int *buffers)
{
    if (!root) return;

    switch (root->type) {
    case WLR_SCENE_NODE_TREE: (*trees)++; break;
    case WLR_SCENE_NODE_RECT: (*rects)++; break;
    case WLR_SCENE_NODE_BUFFER: (*buffers)++; break;
    }

    if (root->type == WLR_SCENE_NODE_TREE) {
        struct wlr_scene_tree *tree = wlr_scene_tree_from_node(root);
        struct wlr_scene_node *child;
        wl_list_for_each(child, &tree->children, link)
            bench_count_scene_nodes(child, trees, rects, buffers);
    }
}

/* --- Full reset --- */

void
bench_reset_all(void)
{
    bench_signal_counters_reset();
    bench_frame_stats_reset();
    bench_stage_stats_reset();
    bench_crossings_reset();
    bench_input_latency_reset();
    bench_manage_latency_reset();
    bench_render_reset();
}

#endif /* SOMEWM_BENCH */
