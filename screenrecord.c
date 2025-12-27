/*
 * screenrecord.c - Native screen recording for somewm
 *
 * Uses libavcodec/libavformat for video encoding.
 * Captures frames via wlroots scene graph compositing.
 * Encoding runs in a separate thread to avoid blocking compositor.
 */

#include "screenrecord.h"
#include "globalconf.h"
#include "somewm_api.h"
#include "util.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

/* libav headers */
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavutil/time.h>

/* wlroots for frame capture */
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/wlr_texture.h>
#include <drm_fourcc.h>
#include <cairo/cairo.h>

/* Global recording context (only one recording at a time) */
static screenrecord_t *rec = NULL;

/* External references */
extern struct wlr_scene *scene;
extern struct wlr_renderer *drw;

/*
 * Frame queue implementation
 */

static void
queue_init(screenrecord_queue_t *q, int max_frames)
{
	q->head = NULL;
	q->tail = NULL;
	q->count = 0;
	q->max_frames = max_frames;
	pthread_mutex_init(&q->mutex, NULL);
	pthread_cond_init(&q->cond, NULL);
}

static void
queue_destroy(screenrecord_queue_t *q)
{
	screenrecord_frame_t *frame, *next;

	pthread_mutex_lock(&q->mutex);
	frame = q->head;
	while (frame) {
		next = frame->next;
		free(frame->data);
		free(frame);
		frame = next;
	}
	q->head = NULL;
	q->tail = NULL;
	q->count = 0;
	pthread_mutex_unlock(&q->mutex);

	pthread_mutex_destroy(&q->mutex);
	pthread_cond_destroy(&q->cond);
}

static bool
queue_push(screenrecord_queue_t *q, screenrecord_frame_t *frame)
{
	pthread_mutex_lock(&q->mutex);

	/* Drop frame if queue is full */
	if (q->count >= q->max_frames) {
		pthread_mutex_unlock(&q->mutex);
		free(frame->data);
		free(frame);
		return false;
	}

	frame->next = NULL;
	if (q->tail) {
		q->tail->next = frame;
	} else {
		q->head = frame;
	}
	q->tail = frame;
	q->count++;

	pthread_cond_signal(&q->cond);
	pthread_mutex_unlock(&q->mutex);
	return true;
}

static screenrecord_frame_t *
queue_pop(screenrecord_queue_t *q, bool blocking)
{
	screenrecord_frame_t *frame;

	pthread_mutex_lock(&q->mutex);

	while (q->count == 0) {
		if (!blocking) {
			pthread_mutex_unlock(&q->mutex);
			return NULL;
		}
		pthread_cond_wait(&q->cond, &q->mutex);
	}

	frame = q->head;
	q->head = frame->next;
	if (!q->head) {
		q->tail = NULL;
	}
	q->count--;

	pthread_mutex_unlock(&q->mutex);
	return frame;
}

static void
queue_signal_stop(screenrecord_queue_t *q)
{
	pthread_mutex_lock(&q->mutex);
	pthread_cond_broadcast(&q->cond);
	pthread_mutex_unlock(&q->mutex);
}

/*
 * Encoder setup
 */

static const AVCodec *
find_encoder_for_format(screenrecord_format_t format, enum AVCodecID *codec_id)
{
	const AVCodec *codec;

	switch (format) {
	case SCREENRECORD_FORMAT_MP4:
	case SCREENRECORD_FORMAT_MKV:
		*codec_id = AV_CODEC_ID_H264;
		codec = avcodec_find_encoder_by_name("libx264");
		if (!codec)
			codec = avcodec_find_encoder(AV_CODEC_ID_H264);
		break;
	case SCREENRECORD_FORMAT_WEBM:
		*codec_id = AV_CODEC_ID_VP9;
		codec = avcodec_find_encoder_by_name("libvpx-vp9");
		if (!codec)
			codec = avcodec_find_encoder(AV_CODEC_ID_VP9);
		break;
	case SCREENRECORD_FORMAT_GIF:
		*codec_id = AV_CODEC_ID_GIF;
		codec = avcodec_find_encoder(AV_CODEC_ID_GIF);
		break;
	default:
		*codec_id = AV_CODEC_ID_H264;
		codec = avcodec_find_encoder(AV_CODEC_ID_H264);
	}

	return codec;
}

static const char *
get_format_name(screenrecord_format_t format)
{
	switch (format) {
	case SCREENRECORD_FORMAT_MP4:
		return "mp4";
	case SCREENRECORD_FORMAT_WEBM:
		return "webm";
	case SCREENRECORD_FORMAT_MKV:
		return "matroska";
	case SCREENRECORD_FORMAT_GIF:
		return "gif";
	default:
		return "mp4";
	}
}

static bool
setup_encoder(screenrecord_t *r)
{
	const AVCodec *codec;
	enum AVCodecID codec_id;
	AVDictionary *opts = NULL;
	int ret;

	/* Find encoder */
	codec = find_encoder_for_format(r->format, &codec_id);
	if (!codec) {
		r->error_message = strdup("Failed to find encoder");
		return false;
	}

	/* Allocate codec context */
	r->codec_ctx = avcodec_alloc_context3(codec);
	if (!r->codec_ctx) {
		r->error_message = strdup("Failed to allocate codec context");
		return false;
	}

	/* Configure encoder */
	r->codec_ctx->width = r->width;
	r->codec_ctx->height = r->height;
	r->codec_ctx->time_base = (AVRational){1, r->framerate};
	r->codec_ctx->framerate = (AVRational){r->framerate, 1};

	/* Pixel format depends on codec */
	if (r->format == SCREENRECORD_FORMAT_GIF) {
		r->codec_ctx->pix_fmt = AV_PIX_FMT_PAL8;
	} else {
		r->codec_ctx->pix_fmt = AV_PIX_FMT_YUV420P;
	}

	/* MP4/MKV containers need global header (SPS/PPS in container, not in-band) */
	if (r->format == SCREENRECORD_FORMAT_MP4 || r->format == SCREENRECORD_FORMAT_MKV) {
		r->codec_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
	}

	/* Codec-specific options */
	if (codec_id == AV_CODEC_ID_H264) {
		r->codec_ctx->bit_rate = 4000000; /* 4 Mbps */
		r->codec_ctx->gop_size = r->framerate; /* Keyframe every second */
		r->codec_ctx->max_b_frames = 2;
		av_dict_set(&opts, "preset", "fast", 0);
		av_dict_set(&opts, "tune", "zerolatency", 0);
	} else if (codec_id == AV_CODEC_ID_VP9) {
		r->codec_ctx->bit_rate = 4000000;
		r->codec_ctx->gop_size = r->framerate;
		av_dict_set(&opts, "deadline", "realtime", 0);
		av_dict_set(&opts, "cpu-used", "8", 0);
	} else if (codec_id == AV_CODEC_ID_GIF) {
		/* GIF has lower framerate by default */
		if (r->framerate > 15) {
			r->codec_ctx->time_base = (AVRational){1, 15};
			r->codec_ctx->framerate = (AVRational){15, 1};
		}
	}

	/* Open codec */
	ret = avcodec_open2(r->codec_ctx, codec, &opts);
	av_dict_free(&opts);
	if (ret < 0) {
		char errbuf[256];
		av_strerror(ret, errbuf, sizeof(errbuf));
		r->error_message = strdup(errbuf);
		return false;
	}

	return true;
}

static bool
setup_muxer(screenrecord_t *r)
{
	int ret;

	/* Allocate output context */
	ret = avformat_alloc_output_context2(&r->format_ctx, NULL,
		get_format_name(r->format), r->output_path);
	if (ret < 0 || !r->format_ctx) {
		r->error_message = strdup("Failed to create output context");
		return false;
	}

	/* Create video stream */
	r->video_stream = avformat_new_stream(r->format_ctx, NULL);
	if (!r->video_stream) {
		r->error_message = strdup("Failed to create video stream");
		return false;
	}

	r->video_stream->time_base = r->codec_ctx->time_base;
	ret = avcodec_parameters_from_context(r->video_stream->codecpar, r->codec_ctx);
	if (ret < 0) {
		r->error_message = strdup("Failed to copy codec parameters");
		return false;
	}

	/* Open output file */
	if (!(r->format_ctx->oformat->flags & AVFMT_NOFILE)) {
		ret = avio_open(&r->format_ctx->pb, r->output_path, AVIO_FLAG_WRITE);
		if (ret < 0) {
			char errbuf[256];
			av_strerror(ret, errbuf, sizeof(errbuf));
			r->error_message = strdup(errbuf);
			return false;
		}
	}

	/* Write header */
	ret = avformat_write_header(r->format_ctx, NULL);
	if (ret < 0) {
		char errbuf[256];
		av_strerror(ret, errbuf, sizeof(errbuf));
		r->error_message = strdup(errbuf);
		return false;
	}

	return true;
}

static bool
setup_scaler(screenrecord_t *r)
{
	enum AVPixelFormat dst_fmt;

	dst_fmt = r->codec_ctx->pix_fmt;

	/* Create scaler context (ARGB -> YUV420P or PAL8) */
	r->sws_ctx = sws_getContext(
		r->width, r->height, AV_PIX_FMT_BGRA,
		r->width, r->height, dst_fmt,
		SWS_BILINEAR, NULL, NULL, NULL);

	if (!r->sws_ctx) {
		r->error_message = strdup("Failed to create scaler context");
		return false;
	}

	/* Allocate output frame */
	r->yuv_frame = av_frame_alloc();
	if (!r->yuv_frame) {
		r->error_message = strdup("Failed to allocate frame");
		return false;
	}

	r->yuv_frame->format = dst_fmt;
	r->yuv_frame->width = r->width;
	r->yuv_frame->height = r->height;

	if (av_frame_get_buffer(r->yuv_frame, 0) < 0) {
		r->error_message = strdup("Failed to allocate frame buffer");
		return false;
	}

	/* Allocate packet */
	r->packet = av_packet_alloc();
	if (!r->packet) {
		r->error_message = strdup("Failed to allocate packet");
		return false;
	}

	return true;
}

/*
 * Encoding
 */

static bool
encode_frame(screenrecord_t *r, screenrecord_frame_t *frame)
{
	uint8_t *src_data[1];
	int src_linesize[1];
	int ret;

	/* Make frame writable */
	ret = av_frame_make_writable(r->yuv_frame);
	if (ret < 0)
		return false;

	/* Convert BGRA to YUV420P */
	src_data[0] = frame->data;
	src_linesize[0] = frame->stride;

	sws_scale(r->sws_ctx, (const uint8_t * const *)src_data, src_linesize,
		0, r->height, r->yuv_frame->data, r->yuv_frame->linesize);

	r->yuv_frame->pts = frame->pts;

	/* Send frame to encoder */
	ret = avcodec_send_frame(r->codec_ctx, r->yuv_frame);
	if (ret < 0 && ret != AVERROR(EAGAIN))
		return false;

	/* Receive encoded packets */
	while (ret >= 0) {
		ret = avcodec_receive_packet(r->codec_ctx, r->packet);
		if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
			break;
		if (ret < 0)
			return false;

		/* Rescale timestamps */
		av_packet_rescale_ts(r->packet, r->codec_ctx->time_base,
			r->video_stream->time_base);
		r->packet->stream_index = r->video_stream->index;

		/* Write packet */
		ret = av_interleaved_write_frame(r->format_ctx, r->packet);
		av_packet_unref(r->packet);
		if (ret < 0)
			return false;
	}

	return true;
}

static bool
flush_encoder(screenrecord_t *r)
{
	int ret;

	/* Send NULL frame to flush */
	ret = avcodec_send_frame(r->codec_ctx, NULL);
	if (ret < 0)
		return false;

	/* Drain remaining packets */
	while (1) {
		ret = avcodec_receive_packet(r->codec_ctx, r->packet);
		if (ret == AVERROR_EOF)
			break;
		if (ret < 0)
			return false;

		av_packet_rescale_ts(r->packet, r->codec_ctx->time_base,
			r->video_stream->time_base);
		r->packet->stream_index = r->video_stream->index;

		ret = av_interleaved_write_frame(r->format_ctx, r->packet);
		av_packet_unref(r->packet);
		if (ret < 0)
			return false;
	}

	return true;
}

/*
 * Encoder thread
 */

static void *
encoder_thread_func(void *arg)
{
	screenrecord_t *r = arg;
	screenrecord_frame_t *frame;
	time_t start_time, current_time;

	start_time = time(NULL);

	while (!r->stop_requested) {
		/* Wait for frame with timeout */
		pthread_mutex_lock(&r->queue.mutex);
		while (r->queue.count == 0 && !r->stop_requested) {
			struct timespec ts;
			clock_gettime(CLOCK_REALTIME, &ts);
			ts.tv_nsec += 100000000; /* 100ms timeout */
			if (ts.tv_nsec >= 1000000000) {
				ts.tv_sec++;
				ts.tv_nsec -= 1000000000;
			}
			pthread_cond_timedwait(&r->queue.cond, &r->queue.mutex, &ts);
		}
		pthread_mutex_unlock(&r->queue.mutex);

		if (r->stop_requested)
			break;

		/* Get frame from queue */
		frame = queue_pop(&r->queue, false);
		if (!frame)
			continue;

		/* Encode frame */
		if (!encode_frame(r, frame)) {
			/* Encoding error - continue anyway */
		}

		free(frame->data);
		free(frame);
		r->frame_count++;

		/* Update elapsed time */
		current_time = time(NULL);
		r->elapsed_seconds = (int)(current_time - start_time);
	}

	/* Drain remaining frames */
	while ((frame = queue_pop(&r->queue, false)) != NULL) {
		encode_frame(r, frame);
		free(frame->data);
		free(frame);
		r->frame_count++;
	}

	/* Flush encoder */
	flush_encoder(r);

	r->encoder_running = false;
	return NULL;
}

/*
 * Frame capture
 */

/* Callback data for scene traversal */
struct capture_data {
	cairo_t *cr;
	struct wlr_renderer *renderer;
	int offset_x;
	int offset_y;
};

static void
capture_scene_buffer(struct wlr_scene_buffer *scene_buffer,
	int sx, int sy, void *data)
{
	struct capture_data *cd = data;
	struct wlr_buffer *buffer;
	cairo_surface_t *buf_surface;
	int buf_width, buf_height;
	void *shm_data;
	uint32_t shm_format;
	size_t shm_stride;
	void *pixels = NULL;
	size_t stride;
	bool need_free = false;
	cairo_format_t cairo_fmt;

	if (!scene_buffer->buffer)
		return;

	buffer = scene_buffer->buffer;
	buf_width = scene_buffer->dst_width;
	buf_height = scene_buffer->dst_height;

	if (buf_width <= 0 || buf_height <= 0)
		return;

	/* First try direct buffer access (works for SHM buffers - widgets) */
	if (wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
	                                     &shm_data, &shm_format, &shm_stride)) {
		/* Direct access succeeded - this is an SHM buffer */

		/* Check format compatibility with Cairo */
		if (shm_format == DRM_FORMAT_ARGB8888 || shm_format == DRM_FORMAT_XRGB8888) {
			cairo_fmt = (shm_format == DRM_FORMAT_ARGB8888) ?
			            CAIRO_FORMAT_ARGB32 : CAIRO_FORMAT_RGB24;
			buf_surface = cairo_image_surface_create_for_data(
				shm_data, cairo_fmt, buf_width, buf_height, shm_stride);

			if (cairo_surface_status(buf_surface) == CAIRO_STATUS_SUCCESS) {
				cairo_save(cd->cr);
				cairo_set_source_surface(cd->cr, buf_surface,
					sx - cd->offset_x, sy - cd->offset_y);
				cairo_paint(cd->cr);
				cairo_restore(cd->cr);
				cairo_surface_destroy(buf_surface);
			}
		}
		wlr_buffer_end_data_ptr_access(buffer);
		return;
	}

	/* Direct access failed - try GPU texture path (for DMA-BUF/GPU buffers) */
	{
		struct wlr_texture *texture;

		texture = wlr_texture_from_buffer(cd->renderer, buffer);
		if (!texture)
			return;

		/* Allocate pixel buffer for reading */
		stride = buf_width * 4;
		pixels = malloc(stride * buf_height);
		if (!pixels) {
			wlr_texture_destroy(texture);
			return;
		}
		need_free = true;

		/* Read pixels from texture */
		if (!wlr_texture_read_pixels(texture, &(struct wlr_texture_read_pixels_options){
			.data = pixels,
			.format = DRM_FORMAT_ARGB8888,
			.stride = stride,
			.src_box = { .x = 0, .y = 0, .width = buf_width, .height = buf_height },
		})) {
			free(pixels);
			wlr_texture_destroy(texture);
			return;
		}

		wlr_texture_destroy(texture);
	}

	/* Create Cairo surface from pixel data */
	buf_surface = cairo_image_surface_create_for_data(
		pixels, CAIRO_FORMAT_ARGB32, buf_width, buf_height, stride);

	if (cairo_surface_status(buf_surface) != CAIRO_STATUS_SUCCESS) {
		if (need_free)
			free(pixels);
		return;
	}

	/* Composite onto target surface */
	cairo_save(cd->cr);
	cairo_set_source_surface(cd->cr, buf_surface,
		sx - cd->offset_x, sy - cd->offset_y);
	cairo_paint(cd->cr);
	cairo_restore(cd->cr);

	cairo_surface_destroy(buf_surface);
	if (need_free)
		free(pixels);
}

void
screenrecord_capture_frame(void)
{
	screenrecord_frame_t *frame;
	cairo_surface_t *surf;
	cairo_t *cr;
	struct capture_data cd;
	uint8_t *data;
	int stride;

	if (!rec || rec->state != SCREENRECORD_STATE_RECORDING)
		return;

	/* Create cairo surface for capture */
	surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, rec->width, rec->height);
	if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(surf);
		return;
	}

	cr = cairo_create(surf);

	/* Clear to black */
	cairo_set_source_rgb(cr, 0, 0, 0);
	cairo_paint(cr);

	/* Traverse scene and composite buffers */
	cd.cr = cr;
	cd.renderer = drw;
	cd.offset_x = rec->x;
	cd.offset_y = rec->y;

	wlr_scene_node_for_each_buffer(&scene->tree.node,
		capture_scene_buffer, &cd);

	cairo_destroy(cr);
	cairo_surface_flush(surf);

	/* Copy pixel data */
	stride = cairo_image_surface_get_stride(surf);
	data = malloc(stride * rec->height);
	if (!data) {
		cairo_surface_destroy(surf);
		return;
	}
	memcpy(data, cairo_image_surface_get_data(surf), stride * rec->height);
	cairo_surface_destroy(surf);

	/* Create frame and queue it */
	frame = calloc(1, sizeof(*frame));
	if (!frame) {
		free(data);
		return;
	}

	frame->data = data;
	frame->width = rec->width;
	frame->height = rec->height;
	frame->stride = stride;
	frame->pts = rec->frame_count;

	if (!queue_push(&rec->queue, frame)) {
		/* Queue full, frame was dropped */
	}
}

/*
 * Public API
 */

void
screenrecord_init(void)
{
	/* Nothing to do - recording context created on start */
}

void
screenrecord_cleanup(void)
{
	if (rec) {
		screenrecord_cancel();
	}
}

bool
screenrecord_start(const screenrecord_config_t *config)
{
	struct wlr_box box;
	int root_w, root_h;

	if (rec && rec->state == SCREENRECORD_STATE_RECORDING) {
		return false; /* Already recording */
	}

	/* Get root size (bounding box of all outputs) */
	wlr_output_layout_get_box(some_get_output_layout(), NULL, &box);
	root_w = box.width;
	root_h = box.height;

	/* Allocate context */
	rec = calloc(1, sizeof(*rec));
	if (!rec)
		return false;

	/* Copy config */
	rec->output_path = strdup(config->output_path);
	rec->x = config->x;
	rec->y = config->y;
	rec->width = config->width > 0 ? config->width : root_w;
	rec->height = config->height > 0 ? config->height : root_h;
	rec->framerate = config->framerate > 0 ? config->framerate : 30;
	rec->format = config->format;

	/* Ensure even dimensions (required by most codecs) */
	rec->width = (rec->width / 2) * 2;
	rec->height = (rec->height / 2) * 2;

	/* Initialize queue */
	queue_init(&rec->queue, 30); /* Buffer up to 1 second */

	/* Setup encoder */
	if (!setup_encoder(rec)) {
		rec->state = SCREENRECORD_STATE_ERROR;
		return false;
	}

	/* Setup muxer */
	if (!setup_muxer(rec)) {
		rec->state = SCREENRECORD_STATE_ERROR;
		return false;
	}

	/* Setup scaler */
	if (!setup_scaler(rec)) {
		rec->state = SCREENRECORD_STATE_ERROR;
		return false;
	}

	/* Start encoder thread */
	rec->stop_requested = false;
	rec->encoder_running = true;
	if (pthread_create(&rec->encoder_thread, NULL, encoder_thread_func, rec) != 0) {
		rec->error_message = strdup("Failed to create encoder thread");
		rec->state = SCREENRECORD_STATE_ERROR;
		return false;
	}

	rec->state = SCREENRECORD_STATE_RECORDING;
	return true;
}

bool
screenrecord_stop(void)
{
	if (!rec || rec->state != SCREENRECORD_STATE_RECORDING)
		return false;

	rec->state = SCREENRECORD_STATE_STOPPING;
	rec->stop_requested = true;
	queue_signal_stop(&rec->queue);

	/* Wait for encoder thread */
	pthread_join(rec->encoder_thread, NULL);

	/* Write trailer */
	av_write_trailer(rec->format_ctx);

	/* Cleanup */
	if (rec->packet)
		av_packet_free(&rec->packet);
	if (rec->yuv_frame)
		av_frame_free(&rec->yuv_frame);
	if (rec->sws_ctx)
		sws_freeContext(rec->sws_ctx);
	if (rec->codec_ctx)
		avcodec_free_context(&rec->codec_ctx);
	if (rec->format_ctx) {
		if (!(rec->format_ctx->oformat->flags & AVFMT_NOFILE))
			avio_closep(&rec->format_ctx->pb);
		avformat_free_context(rec->format_ctx);
	}

	queue_destroy(&rec->queue);

	rec->state = SCREENRECORD_STATE_IDLE;
	return true;
}

void
screenrecord_cancel(void)
{
	char *path;

	if (!rec)
		return;

	path = rec->output_path ? strdup(rec->output_path) : NULL;

	if (rec->state == SCREENRECORD_STATE_RECORDING) {
		rec->stop_requested = true;
		queue_signal_stop(&rec->queue);
		pthread_join(rec->encoder_thread, NULL);
	}

	/* Cleanup without writing trailer */
	if (rec->packet)
		av_packet_free(&rec->packet);
	if (rec->yuv_frame)
		av_frame_free(&rec->yuv_frame);
	if (rec->sws_ctx)
		sws_freeContext(rec->sws_ctx);
	if (rec->codec_ctx)
		avcodec_free_context(&rec->codec_ctx);
	if (rec->format_ctx) {
		if (!(rec->format_ctx->oformat->flags & AVFMT_NOFILE))
			avio_closep(&rec->format_ctx->pb);
		avformat_free_context(rec->format_ctx);
	}

	queue_destroy(&rec->queue);

	/* Delete partial file */
	if (path) {
		unlink(path);
		free(path);
	}

	free(rec->output_path);
	free(rec->error_message);
	free(rec);
	rec = NULL;
}

bool
screenrecord_is_recording(void)
{
	return rec && rec->state == SCREENRECORD_STATE_RECORDING;
}

screenrecord_state_t
screenrecord_get_state(void)
{
	return rec ? rec->state : SCREENRECORD_STATE_IDLE;
}

int
screenrecord_get_elapsed(void)
{
	return rec ? rec->elapsed_seconds : 0;
}

const char *
screenrecord_get_error(void)
{
	return rec ? rec->error_message : NULL;
}

const char *
screenrecord_get_output_path(void)
{
	return rec ? rec->output_path : NULL;
}

/*
 * Lua bindings
 */

int
luaA_screenrecord_start(lua_State *L)
{
	screenrecord_config_t config = {0};
	const char *format_str;

	luaL_checktype(L, 1, LUA_TTABLE);

	/* Get config from table */
	lua_getfield(L, 1, "path");
	config.output_path = luaL_checkstring(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, 1, "x");
	config.x = lua_isnil(L, -1) ? 0 : lua_tointeger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, 1, "y");
	config.y = lua_isnil(L, -1) ? 0 : lua_tointeger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, 1, "width");
	config.width = lua_isnil(L, -1) ? 0 : lua_tointeger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, 1, "height");
	config.height = lua_isnil(L, -1) ? 0 : lua_tointeger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, 1, "framerate");
	config.framerate = lua_isnil(L, -1) ? 30 : lua_tointeger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, 1, "format");
	format_str = lua_isnil(L, -1) ? "mp4" : lua_tostring(L, -1);
	if (strcmp(format_str, "webm") == 0)
		config.format = SCREENRECORD_FORMAT_WEBM;
	else if (strcmp(format_str, "mkv") == 0)
		config.format = SCREENRECORD_FORMAT_MKV;
	else if (strcmp(format_str, "gif") == 0)
		config.format = SCREENRECORD_FORMAT_GIF;
	else
		config.format = SCREENRECORD_FORMAT_MP4;
	lua_pop(L, 1);

	if (screenrecord_start(&config)) {
		lua_pushboolean(L, 1);
	} else {
		lua_pushboolean(L, 0);
		lua_pushstring(L, screenrecord_get_error());
		return 2;
	}

	return 1;
}

int
luaA_screenrecord_stop(lua_State *L)
{
	if (screenrecord_stop()) {
		lua_pushboolean(L, 1);
		lua_pushstring(L, screenrecord_get_output_path());
		return 2;
	}

	lua_pushboolean(L, 0);
	return 1;
}

int
luaA_screenrecord_cancel(lua_State *L)
{
	screenrecord_cancel();
	return 0;
}

int
luaA_screenrecord_is_recording(lua_State *L)
{
	lua_pushboolean(L, screenrecord_is_recording());
	return 1;
}

int
luaA_screenrecord_elapsed(lua_State *L)
{
	lua_pushinteger(L, screenrecord_get_elapsed());
	return 1;
}

int
luaA_screenrecord_capture_frame(lua_State *L)
{
	screenrecord_capture_frame();
	return 0;
}
