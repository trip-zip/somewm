#ifndef SOMEWM_DECLARE_SRC_H
#define SOMEWM_DECLARE_SRC_H

/* Where a declared number came from, per axis (spec D050): the eight
 * source words, plus last-frame, which is none of them. A size with no
 * number carries DECLARE_SRC_NONE. */
enum declare_src {
	DECLARE_SRC_NONE = 0,
	DECLARE_SRC_USER,
	DECLARE_SRC_THEME,
	DECLARE_SRC_OUTPUT,
	DECLARE_SRC_PROTOCOL,
	DECLARE_SRC_LEGACY,
	DECLARE_SRC_TRANSITION,
	DECLARE_SRC_SCROLL,
	DECLARE_SRC_DERIVED,
	DECLARE_SRC_LAST_FRAME,
	DECLARE_SRC_COUNT,
};

/* The word each value prints as, NULL for none. */
extern const char *const declare_src_names[DECLARE_SRC_COUNT];

/* One of the eight words as Lua declares it, DECLARE_SRC_NONE for anything
 * else, last-frame included. */
enum declare_src declare_src_parse(const char *word);

#endif
