/* Clay upstream pin e6cc36941ab2af5d81107617039d6f527a1c660b.
 * Local native extensions: third_party/README.clay.md and clay-local.patch. */

/* The single production translation unit that compiles Clay itself. Clay is a
 * header-only library: every other production file includes clay.h for the
 * declarations, and CLAY_IMPLEMENTATION is defined here and nowhere else. */

#define CLAY_IMPLEMENTATION
#include "clay.h"

#include "clay_impl.h"

Clay_RenderCommandArray
clay_render_commands(void)
{
	return Clay_GetCurrentContext()->renderCommands;
}

bool
clay_element_declaration(Clay_ElementId id, Clay_ElementDeclaration *out)
{
	Clay_LayoutElementHashMapItem *item = Clay__GetHashMapItem(id.id);
	if (item == &Clay_LayoutElementHashMapItem_DEFAULT
			|| item->generation != Clay_GetCurrentContext()->generation + 1
			|| !item->layoutElement || item->layoutElement->isTextElement)
		return false;
	*out = item->layoutElement->config;
	return true;
}

/* Offsets come from Lua on every layout (third_party/clay.h:2733-2745).
 * Clay_UpdateScrollContainers skips a swapped record during cleanup and
 * runs its own wheel and drag scrolling (third_party/clay.h:4045-4155). */
void
clay_scroll_records_clear(void)
{
	Clay_GetCurrentContext()->scrollContainerDatas.length = 0;
}
