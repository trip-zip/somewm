/* Clay upstream pin e6cc36941ab2af5d81107617039d6f527a1c660b.
 * Pin provenance and application readback helpers: third_party/README.clay.md. */

/* The single production translation unit that compiles Clay itself. Clay is a
 * header-only library: every other production file includes clay.h for the
 * declarations, and CLAY_IMPLEMENTATION is defined here and nowhere else. */

#define CLAY_IMPLEMENTATION
#include "clay.h"

#include "clay_impl.h"
#include <string.h>

struct clay_capacity clay_capacity(void)
{
    Clay_Context *c = Clay_GetCurrentContext();
    return (struct clay_capacity){c->layoutElements.length, c->maxElementCount,
        c->layoutElementsHashMapInternal.length, c->layoutElementsHashMapFreeList.length,
        c->transitionDatas.length};
}

bool clay_references_memory(const void *memory, size_t size, uintptr_t mask)
{
    if (!memory || !size) return false;
    Clay_Context *c = Clay_GetCurrentContext();
    uintptr_t begin = (uintptr_t)memory;
    /* After EndLayout the active array includes exiting subtrees. Clay's
     * arena-tail clones borrow the same payloads as those active elements. */
    for (int32_t i = 0; i < c->layoutElements.length; i++) {
        Clay_LayoutElement *element = &c->layoutElements.internalArray[i];
        uintptr_t pointers[2] = {0};
        if (element->isTextElement) pointers[0] = (uintptr_t)element->textElementData.text.chars;
        else {
            pointers[0] = (uintptr_t)element->config.image.imageData;
            pointers[1] = (uintptr_t)element->config.custom.customData;
        }
        for (int j = 0; j < 2; j++)
            if ((pointers[j] & mask) >= begin && (pointers[j] & mask) - begin < size) return true;
    }
    return false;
}

/* Declarations reuse scrolling state by identity, but host clips must not
 * occupy records needed by a newly declared scroll container. Keep the old
 * records outside Clay while the current declarations claim their budget. */
static Clay__ScrollContainerDataInternal previous_scrolls[100];
static int previous_scrolls_len;

void clay_clips_begin(int inspector_start, bool inspecting)
{
    Clay_Context *c = Clay_GetCurrentContext();
    previous_scrolls_len = c->scrollContainerDatas.length;
    memcpy(previous_scrolls, c->scrollContainerDatas.internalArray,
        previous_scrolls_len * sizeof(*previous_scrolls));
    c->scrollContainerDatas.length = 0;
    for (int i = 0; inspecting && i < previous_scrolls_len; i++) {
        Clay__ScrollContainerDataInternal *s = &previous_scrolls[i];
        if (inspector_start > 0 && s->layoutElement >= c->layoutElements.internalArray + inspector_start)
            Clay__ScrollContainerDataInternalArray_Add(&c->scrollContainerDatas, *s);
    }
}

Clay_Vector2 clay_scroll_offset(Clay_ElementId id)
{
    for (int i = 0; i < previous_scrolls_len; i++)
        if (previous_scrolls[i].elementId == id.id)
            return previous_scrolls[i].scrollPosition;
    return (Clay_Vector2){0};
}

void clay_clip_restore(void)
{
    Clay_Context *c = Clay_GetCurrentContext();
    Clay_LayoutElement *element = Clay__GetOpenLayoutElement();
    for (int i = 0; i < c->scrollContainerDatas.length; i++) {
        Clay__ScrollContainerDataInternal *s = &c->scrollContainerDatas.internalArray[i];
        if (s->elementId != element->id) continue;
        for (int j = 0; j < previous_scrolls_len; j++) {
            if (previous_scrolls[j].elementId != element->id) continue;
            *s = previous_scrolls[j];
            s->layoutElement = element;
            s->openThisFrame = true;
            return;
        }
    }
}

bool clay_declaration_full(void)
{
    Clay_Context *c = Clay_GetCurrentContext();
    return c->layoutElements.length >= c->layoutElements.capacity - 1;
}

bool clay_capacity_failed(void)
{
    Clay_BooleanWarnings w = Clay_GetCurrentContext()->booleanWarnings;
    return w.maxElementsExceeded || w.hashMapCapacityExceeded
        || w.maxTextMeasureCacheExceeded || w.maxRenderCommandsExceeded;
}

bool clay_inspector_fits(int *elements, int *strings)
{
    Clay_Context *c = Clay_GetCurrentContext();
    /* Budget eighteen elements and twenty integer-string bytes per authored
     * element, with a fixed reserve for the panel and selected details.
     * Existing element strings are borrowed by the inspector. */
    *elements = 18 * c->layoutElements.length + 2048;
    *strings = 20 * c->layoutElements.length + 2048;
    int live = c->layoutElementsHashMapInternal.length - c->layoutElementsHashMapFreeList.length;
    return *elements < c->maxElementCount
        && *strings < c->dynamicStringData.capacity
        && live + *elements < c->maxElementCount;
}

bool clay_inspector_duplicate(int first_inspector_element)
{
    Clay_Context *c = Clay_GetCurrentContext();
    if (first_inspector_element <= 0 || c->layoutElements.length <= first_inspector_element) return false;
    Clay_LayoutElement *last = &c->layoutElements.internalArray[c->layoutElements.length - 1];
    Clay_LayoutElementHashMapItem *old = Clay__GetHashMapItem(last->id);
    return old != &Clay_LayoutElementHashMapItem_DEFAULT && old->layoutElement
        && old->layoutElement >= c->layoutElements.internalArray + first_inspector_element
        && old->layoutElement < c->layoutElements.internalArray + c->layoutElements.length;
}

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
