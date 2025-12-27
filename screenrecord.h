/*
 * screenrecord.h - Native screen recording for somewm
 *
 * Uses libavcodec/libavformat for video encoding.
 * No external tools required - all encoding built-in.
 */
#ifndef SCREENRECORD_H
#define SCREENRECORD_H

#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>
#include <lua.h>

/* Forward declarations for libav types */
struct AVCodecContext;
struct AVFormatContext;
struct AVStream;
struct SwsContext;
struct AVFrame;
struct AVPacket;

/* Output format types */
typedef enum {
	SCREENRECORD_FORMAT_MP4,
	SCREENRECORD_FORMAT_WEBM,
	SCREENRECORD_FORMAT_MKV,
	SCREENRECORD_FORMAT_GIF,
} screenrecord_format_t;

/* Recording state */
typedef enum {
	SCREENRECORD_STATE_IDLE,
	SCREENRECORD_STATE_RECORDING,
	SCREENRECORD_STATE_STOPPING,
	SCREENRECORD_STATE_ERROR,
} screenrecord_state_t;

/* Frame in the queue */
typedef struct screenrecord_frame {
	uint8_t *data;           /* ARGB pixel data */
	int width;
	int height;
	int stride;
	int64_t pts;             /* Presentation timestamp */
	struct screenrecord_frame *next;
} screenrecord_frame_t;

/* Frame queue (producer-consumer) */
typedef struct {
	screenrecord_frame_t *head;
	screenrecord_frame_t *tail;
	int count;
	int max_frames;          /* Max queue depth before dropping */
	pthread_mutex_t mutex;
	pthread_cond_t cond;
} screenrecord_queue_t;

/* Main recording context */
typedef struct {
	/* Recording state */
	screenrecord_state_t state;
	int elapsed_seconds;
	char *output_path;
	char *error_message;

	/* Capture config */
	int x, y, width, height; /* Region (0,0 = full screen) */
	int framerate;           /* Target FPS (default 30) */
	screenrecord_format_t format;

	/* Encoder state (libav) */
	struct AVCodecContext *codec_ctx;
	struct AVFormatContext *format_ctx;
	struct AVStream *video_stream;
	struct SwsContext *sws_ctx;
	struct AVFrame *yuv_frame;
	struct AVPacket *packet;
	int64_t frame_count;     /* Total frames encoded */

	/* Threading */
	pthread_t encoder_thread;
	screenrecord_queue_t queue;
	bool stop_requested;
	bool encoder_running;

	/* For GIF: palette handling */
	uint8_t *gif_palette;
	int gif_palette_size;
} screenrecord_t;

/* Configuration for starting a recording */
typedef struct {
	const char *output_path; /* Full path to output file */
	int x, y;                /* Region origin (0,0 for full) */
	int width, height;       /* Region size (0,0 for full) */
	int framerate;           /* FPS (default 30) */
	screenrecord_format_t format;
} screenrecord_config_t;

/*
 * Public API
 */

/** Initialize the screenrecord subsystem.
 * Call once at compositor startup.
 */
void screenrecord_init(void);

/** Cleanup the screenrecord subsystem.
 * Call once at compositor shutdown.
 */
void screenrecord_cleanup(void);

/** Start a new recording.
 * \param config Recording configuration
 * \return true on success, false on error (check screenrecord_get_error())
 */
bool screenrecord_start(const screenrecord_config_t *config);

/** Stop the current recording and save the file.
 * Blocks until encoding is complete.
 * \return true on success, false on error
 */
bool screenrecord_stop(void);

/** Cancel the current recording without saving.
 * Deletes any partial output file.
 */
void screenrecord_cancel(void);

/** Check if recording is in progress.
 * \return true if recording
 */
bool screenrecord_is_recording(void);

/** Get recording state.
 * \return Current state
 */
screenrecord_state_t screenrecord_get_state(void);

/** Get elapsed recording time.
 * \return Seconds elapsed since recording started
 */
int screenrecord_get_elapsed(void);

/** Get error message if state is ERROR.
 * \return Error string or NULL
 */
const char *screenrecord_get_error(void);

/** Get output file path.
 * \return Path to output file or NULL if not recording
 */
const char *screenrecord_get_output_path(void);

/** Capture and queue a frame for encoding.
 * Called by the compositor on each frame tick.
 * This function is non-blocking - frame is queued for encoder thread.
 */
void screenrecord_capture_frame(void);

/*
 * Lua bindings (exposed via root object)
 */

/** root.screenrecord_start(config) - Start recording
 * config = { path, x, y, width, height, framerate, format }
 */
int luaA_screenrecord_start(lua_State *L);

/** root.screenrecord_stop() - Stop and save */
int luaA_screenrecord_stop(lua_State *L);

/** root.screenrecord_cancel() - Cancel without saving */
int luaA_screenrecord_cancel(lua_State *L);

/** root.screenrecord_is_recording - Property getter */
int luaA_screenrecord_is_recording(lua_State *L);

/** root.screenrecord_elapsed - Property getter */
int luaA_screenrecord_elapsed(lua_State *L);

/** root.screenrecord_capture_frame() - Capture one frame */
int luaA_screenrecord_capture_frame(lua_State *L);

#endif /* SCREENRECORD_H */
