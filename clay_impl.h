#pragma once
#include "clay.h"

void clay_scroll_records_clear(void);
/* Read a non-text element in the current declaration, without solving it. */
bool clay_element_declaration(Clay_ElementId id, Clay_ElementDeclaration *out);
/* Borrow the current context's last completed command array for readback. */
Clay_RenderCommandArray clay_render_commands(void);
