/* Clay upstream pin e6cc36941ab2af5d81107617039d6f527a1c660b.
 * Pin provenance and application readback helpers: third_party/README.clay.md. */

/* The single production translation unit that compiles Clay itself. Clay is a
 * header-only library: every other production file includes clay.h for the
 * declarations, and CLAY_IMPLEMENTATION is defined here and nowhere else. */

#define CLAY_IMPLEMENTATION
#include "clay.h"

#include "clay_impl.h"
#include <string.h>
#include <stdlib.h>

Clay_Dimensions clay_measure_text(Clay_String text, int32_t font)
{
    Clay_TextElementConfig config = {.fontId = (uint16_t)font};
    Clay__MeasureTextCacheItem *measured;
    int32_t lines = 0;

    if (text.length == 0) return (Clay_Dimensions){0};
    measured = Clay__MeasureTextCached(&text, &config);
    /* Unbounded, the wrap pass only breaks at newlines, one line each and
     * none after a trailing one; every line is the run's height
     * (clay.h:2589-2636). */
    for (int32_t i = 0; i < text.length; i++)
        lines += text.chars[i] == '\n';
    if (text.chars[text.length - 1] != '\n') lines++;
    return (Clay_Dimensions){measured->unwrappedDimensions.width,
        measured->unwrappedDimensions.height * lines};
}

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

size_t
clay_transition_snapshot(struct clay_transition_baseline **states, size_t *capacity)
{
    Clay_Context *context = Clay_GetCurrentContext();
    size_t needed = (size_t)context->layoutElementsHashMapInternal.length;
    if (needed > *capacity) {
        void *next = realloc(*states, needed * sizeof(**states));
        if (!next) return 0;
        *states = next;
        *capacity = needed;
    }
    size_t len = 0;
    for (int32_t i = 0; i < context->layoutElementsHashMapInternal.length; i++) {
        Clay_LayoutElementHashMapItem *item = &context->layoutElementsHashMapInternal.internalArray[i];
        if (item->generation != context->generation + 1 || !item->layoutElement || item->layoutElement->isTextElement)
            continue;
        Clay_ElementDeclaration *config = &item->layoutElement->config;
        (*states)[len++] = (struct clay_transition_baseline){item->elementId.id,
            {item->boundingBox, config->backgroundColor, config->overlayColor, config->border.color, config->border.width}};
    }
    return len;
}

bool
clay_transition_admit(const struct clay_transition_baseline *states, size_t len)
{
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_ElementId id = {.id = Clay__GetOpenLayoutElement()->id};
    for (int32_t i = 0; i < context->transitionDatas.length; i++)
        if (context->transitionDatas.internalArray[i].elementId == id.id) return true;
    if (context->transitionDatas.length >= context->transitionDatas.capacity) return false;
    for (size_t i = 0; i < len; i++) {
        if (states[i].id != id.id) continue;
        Clay_LayoutElement *parent = Clay__GetParentElement();
        Clay__TransitionDataInternalArray_Add(&context->transitionDatas, (Clay__TransitionDataInternal){
            .elementId = id.id, .parentId = parent->id,
            .initialState = states[i].state, .currentState = states[i].state, .targetState = states[i].state,
        });
        break;
    }
    return true;
}

void
clay_exit_initial(Clay_TransitionCallbackArguments *arguments)
{
    if (arguments->transitionState != CLAY_TRANSITION_STATE_EXITING || arguments->elapsedTime != 0) return;
    Clay_Context *context = Clay_GetCurrentContext();
    for (int32_t i = 0; i < context->transitionDatas.length; i++) {
        Clay__TransitionDataInternal *record = &context->transitionDatas.internalArray[i];
        if (&record->currentState != arguments->current) continue;
        record->initialState = record->currentState;
        arguments->initial = record->initialState;
        return;
    }
}

void *
clay_transition_userdata(const Clay_TransitionCallbackArguments *arguments)
{
    Clay_Context *context = Clay_GetCurrentContext();
    for (int32_t i = 0; i < context->transitionDatas.length; i++) {
        Clay__TransitionDataInternal *record = &context->transitionDatas.internalArray[i];
        if (&record->currentState == arguments->current)
            return record->elementThisFrame->config.userData;
    }
    return NULL;
}

void
clay_entrances_first(void)
{
    Clay_Context *context = Clay_GetCurrentContext();
    Clay__TransitionDataInternal *records = context->transitionDatas.internalArray;
    int32_t first = 0;
    for (int32_t i = 0; i < context->transitionDatas.length; i++) {
        Clay_LayoutElementHashMapItem *item = Clay__GetHashMapItem(records[i].elementId);
        if (!item->appearedThisFrame || !records[i].elementThisFrame->config.transition.enter.setInitialState)
            continue;
        Clay__TransitionDataInternal entering = records[i];
        memmove(&records[first + 1], &records[first], (size_t)(i - first) * sizeof(*records));
        records[first++] = entering;
    }
}

void
clay_reenter(Clay_ElementId id, bool appearing)
{
    Clay_LayoutElementHashMapItem *item = Clay__GetHashMapItem(id.id);
    if (item == &Clay_LayoutElementHashMapItem_DEFAULT) return;
    if (appearing) item->appearedThisFrame = true;
    Clay_Context *context = Clay_GetCurrentContext();
    for (int32_t i = 0; i < context->transitionDatas.length; i++) {
        Clay__TransitionDataInternal *data = Clay__TransitionDataInternalArray_Get(&context->transitionDatas, i);
        if (data->elementId == id.id) data->elapsedTime = 0;
    }
}

void
clay_exit_transition(Clay_ElementId id, Clay_TransitionElementConfig transition)
{
    Clay_LayoutElementHashMapItem *item = Clay__GetHashMapItem(id.id);
    if (item == &Clay_LayoutElementHashMapItem_DEFAULT
            || item->generation != Clay_GetCurrentContext()->generation + 1
            || !item->layoutElement || item->layoutElement->isTextElement)
        return;
    item->layoutElement->config.transition = transition;
    Clay_Context *context = Clay_GetCurrentContext();
    for (int32_t i = 0; i < context->transitionDatas.length; i++) {
        Clay__TransitionDataInternal *data = Clay__TransitionDataInternalArray_Get(&context->transitionDatas, i);
        if (data->elementId != id.id) continue;
        data->elementThisFrame->config.transition = transition;
        data->transitionOut = transition.exit.setFinalState != NULL;
    }
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
        if (el->config.transition.handler) {
            Clay_Context *context = Clay_GetCurrentContext();
            for (int32_t i = 0; i < context->transitionDatas.length; i++) {
                Clay__TransitionDataInternal *transition = &context->transitionDatas.internalArray[i];
                if (transition->elementId == el->id) {
                    out->entering = transition->state == CLAY_TRANSITION_STATE_ENTERING;
                    break;
                }
            }
        }
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
