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

void
clay_scroll_set(Clay_ElementId id, float x, float y)
{
	Clay_ScrollContainerData data = Clay_GetScrollContainerData(id);

	if (data.found)
		*data.scrollPosition = (Clay_Vector2) { x, y };
}

int32_t
clay_root_count(void)
{
	return Clay_GetCurrentContext()->layoutElementTreeRoots.length;
}

int32_t
clay_root_element(int32_t root)
{
	return Clay__LayoutElementTreeRootArray_Get(
		&Clay_GetCurrentContext()->layoutElementTreeRoots, root)->layoutElementIndex;
}

void
clay_element_view(int32_t index, struct clay_element_view *out)
{
	Clay_LayoutElement *el = Clay_LayoutElementArray_Get(
		&Clay_GetCurrentContext()->layoutElements, index);
	Clay_LayoutElementHashMapItem *item = Clay__GetHashMapItem(el->id);

	*out = (struct clay_element_view) {
		.id = el->id,
		.name = item == &Clay_LayoutElementHashMapItem_DEFAULT
			? (Clay_String) { 0 } : item->elementId.stringId,
		.text = el->isTextElement,
		.exiting = el->exiting,
		.children = el->children.elements,
		.children_len = el->children.length,
	};
	if (el->isTextElement) {
		out->text_string = el->textElementData.text;
		out->font = el->textConfig.fontId;
	} else {
		out->config = el->config;
		out->floating = el->config.floating.attachTo != CLAY_ATTACH_TO_NONE;
	}
}

bool
clay_transitions_active(void)
{
	Clay_Context *context = Clay_GetCurrentContext();

	for (int32_t i = 0; i < context->transitionDatas.length; i++)
		if (Clay__TransitionDataInternalArray_Get(&context->transitionDatas, i)->state
				!= CLAY_TRANSITION_STATE_IDLE)
			return true;
	return false;
}
