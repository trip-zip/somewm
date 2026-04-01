#ifndef CHECK_CONFIG_H
#define CHECK_CONFIG_H

#include <stdbool.h>

/** Result from pre-scanning a config for dangerous patterns.
 * If found_fatal is true, the caller should copy these fields
 * to globalconf.x11_fallback for Lua notification.
 */
typedef struct {
    bool found_fatal;
    char *config_path;
    int line_number;
    char *pattern_desc;
    char *suggestion;
    char *line_content;
} prescan_result_t;

/** Pre-scan a config file for X11 patterns that may hang on Wayland.
 * Scans the file and all require()d dependencies recursively.
 * \param config_path Path to the main config file
 * \param config_dir Directory containing the config (for require resolution), or NULL
 * \param result Output struct populated with first fatal pattern info (if any)
 * \return true if config is safe to load, false if dangerous patterns found
 */
bool check_config_prescan(const char *config_path, const char *config_dir,
                          prescan_result_t *result);

/** Run check mode on a config file (somewm --check).
 * Scans config without starting compositor and outputs a report.
 * \param config_path Path to the main config file
 * \param use_color Whether to use ANSI colors in output
 * \param min_severity Minimum severity for non-zero exit (0=info, 1=warning, 2=critical)
 * \return Exit code (0=ok, 1=warnings, 2=critical)
 */
int check_config_run(const char *config_path, bool use_color, int min_severity);

#endif
