#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "node.h"

static uint64_t next_id = 1;
static struct node **nodes;
static size_t nodes_cap;

static void *
node_alloc(size_t size)
{
	void *p = malloc(size);
	if (!p)
		abort();
	return p;
}

static void
node_init(struct node *n, struct node_tree *t, enum node_kind kind)
{
	/* Exhaustion must not wrap the counter and reuse an existing id. */
	if (next_id > UINT32_MAX || next_id >= SIZE_MAX / sizeof(*nodes))
		abort();
	if (next_id >= nodes_cap) {
		size_t limit = SIZE_MAX / sizeof(*nodes);
		size_t cap = nodes_cap ? nodes_cap : 32;
		while (cap <= next_id)
			cap = cap > limit / 2 ? limit : cap * 2;
		struct node **grown = realloc(nodes, cap * sizeof(*nodes));
		if (!grown)
			abort();
		memset(grown + nodes_cap, 0, (cap - nodes_cap) * sizeof(*nodes));
		nodes = grown;
		nodes_cap = cap;
	}
	*n = (struct node){ .id = next_id++, .kind = kind, .tree = t };
	n->words.opacity = 1.0f;
	wl_list_init(&n->link);
	wl_list_init(&n->children);
	nodes[n->id] = n;
}

struct node *
node_by_id(uint32_t id)
{
	return id < nodes_cap ? nodes[id] : NULL;
}

static bool
node_list_valid(const struct wl_list *list)
{
	return list->next && list->prev && list->next->prev == list &&
		list->prev->next == list;
}

static bool
node_check_subtree(const struct node *n, const struct node_tree *tree, bool *seen)
{
	if (!n || !n->id || node_by_id(n->id) != n || seen[n->id] ||
		n->tree != tree || !node_list_valid(&n->link) ||
		!node_list_valid(&n->children))
		return false;
	seen[n->id] = true;
	const struct node *child;
	wl_list_for_each(child, &n->children, link) {
		if (child->parent != n || !node_check_subtree(child, tree, seen))
			return false;
	}
	return true;
}

bool
node_check_integrity(const struct node *root)
{
	if (!root || !root->tree || !nodes_cap)
		return false;
	bool *seen = node_alloc(nodes_cap * sizeof(*seen));
	memset(seen, 0, nodes_cap * sizeof(*seen));
	bool valid = node_check_subtree(root, root->tree, seen);
	free(seen);
	return valid;
}

static void
node_changed(struct node_tree *t)
{
	t->dirty = true;
	assert(node_check_integrity(&t->root));
}

struct node_tree *
node_tree_create(Monitor *m)
{
	struct node_tree *t = node_alloc(sizeof(*t));
	*t = (struct node_tree){ .m = m };
	node_init(&t->root, t, NODE_OUTPUT);
	node_changed(t);
	return t;
}

struct node *
node_create(struct node_tree *t, enum node_kind kind)
{
	struct node *n = node_alloc(sizeof(*n));
	node_init(n, t, kind);
	node_changed(t);
	assert(node_check_integrity(n));
	return n;
}

static void
node_unlink(struct node *n)
{
	wl_list_remove(&n->link);
	wl_list_init(&n->link);
	n->parent = NULL;
}

static void
node_free_subtree(struct node *n)
{
	/* Destruction also releases protected nodes during output teardown. */
	node_unlink(n);
	while (!wl_list_empty(&n->children)) {
		struct node *child = wl_container_of(n->children.next, child, link);
		node_free_subtree(child);
	}
	nodes[n->id] = NULL;
	free((void *)n->label);
	free(n);
}

void
node_tree_destroy(struct node_tree *t)
{
	if (!t)
		return;
	/* Detached nodes still belong to their output and must not outlive it. */
	for (size_t id = 1; id < nodes_cap; ++id) {
		struct node *n = nodes[id];
		if (n && n != &t->root && n->tree == t)
			node_destroy(n);
	}
	node_changed(t);
	nodes[t->root.id] = NULL;
	free((void *)t->root.label);
	free(t);
}

void
node_destroy(struct node *n)
{
	if (!n)
		return;
	struct node_tree *t = n->tree;
	if (n == &t->root) {
		node_tree_destroy(t);
		return;
	}
	node_free_subtree(n);
	node_changed(t);
}

static bool
node_contains(const struct node *ancestor, const struct node *n)
{
	for (; n; n = n->parent)
		if (n == ancestor)
			return true;
	return false;
}

static void
node_set_tree(struct node *n, struct node_tree *t)
{
	n->tree = t;
	struct node *child;
	wl_list_for_each(child, &n->children, link)
		node_set_tree(child, t);
}

static bool
node_place(struct node *parent, struct node *n, struct wl_list *after)
{
	if (n == &n->tree->root || node_contains(n, parent) ||
		(n->protected && parent != n->parent))
		return false;
	struct node_tree *old = n->tree;
	/* An already adjacent node can itself be the insertion anchor. */
	if (after != &n->link) {
		node_unlink(n);
		wl_list_insert(after, &n->link);
		n->parent = parent;
	}
	if (old != parent->tree)
		node_set_tree(n, parent->tree);
	node_changed(old);
	node_changed(n->tree);
	return true;
}

bool
node_append(struct node *parent, struct node *n)
{
	return node_place(parent, n, parent->children.prev);
}

bool
node_push(struct node *parent, struct node *n)
{
	return node_place(parent, n, &parent->children);
}

bool
node_insert_before(struct node *sibling, struct node *n)
{
	if (!sibling->parent || sibling == n)
		return false;
	return node_place(sibling->parent, n, sibling->link.prev);
}

bool
node_insert_after(struct node *sibling, struct node *n)
{
	if (!sibling->parent || sibling == n)
		return false;
	return node_place(sibling->parent, n, &sibling->link);
}

bool
node_swap(struct node *a, struct node *b)
{
	if (a == &a->tree->root || b == &b->tree->root ||
		node_contains(a, b) || node_contains(b, a) ||
		((a->protected || b->protected) && a->parent != b->parent))
		return false;
	struct node_tree *at = a->tree, *bt = b->tree;
	struct node *ap = a->parent, *bp = b->parent;
	struct wl_list aslot, bslot;
	wl_list_init(&aslot);
	wl_list_init(&bslot);
	/* Placeholders preserve adjacent positions as well as detached ones. */
	if (ap)
		wl_list_insert(a->link.prev, &aslot);
	if (bp)
		wl_list_insert(b->link.prev, &bslot);
	node_unlink(a);
	node_unlink(b);
	if (bp)
		wl_list_insert(&bslot, &a->link);
	if (ap)
		wl_list_insert(&aslot, &b->link);
	wl_list_remove(&aslot);
	wl_list_remove(&bslot);
	a->parent = bp;
	b->parent = ap;
	if (at != bt) {
		node_set_tree(a, bt);
		node_set_tree(b, at);
	}
	node_changed(at);
	node_changed(bt);
	assert(node_check_integrity(a));
	assert(node_check_integrity(b));
	return true;
}

bool
node_detach(struct node *n)
{
	if (n->protected || n == &n->tree->root)
		return false;
	node_unlink(n);
	node_changed(n->tree);
	assert(node_check_integrity(n));
	return true;
}

bool
node_join(struct node *n)
{
	if (n->protected || !n->parent)
		return false;
	struct node_tree *t = n->tree;
	struct node *parent = n->parent;
	while (!wl_list_empty(&n->children)) {
		struct node *child = wl_container_of(n->children.next, child, link);
		node_unlink(child);
		wl_list_insert(n->link.prev, &child->link);
		child->parent = parent;
	}
	node_destroy(n);
	node_changed(t);
	return true;
}

bool
node_raise(struct node *n)
{
	return n->parent && node_append(n->parent, n);
}

bool
node_lower(struct node *n)
{
	return n->parent && node_push(n->parent, n);
}

void
node_set_label(struct node *n, const char *label)
{
	char *copy = NULL;
	if (label) {
		size_t size = strlen(label) + 1;
		copy = node_alloc(size);
		memcpy(copy, label, size);
	}
	free((void *)n->label);
	n->label = copy;
	node_changed(n->tree);
	assert(node_check_integrity(n));
}

#ifndef NDEBUG
static void
node_selftest_order(struct node *parent, struct node **order, size_t count)
{
	assert(node_check_integrity(&parent->tree->root));
	size_t i = 0;
	struct node *child;
	wl_list_for_each(child, &parent->children, link) {
		assert(i < count && child == order[i]);
		++i;
	}
	assert(i == count);
}

void
node_selftest(void)
{
	static bool done;
	if (done)
		return;
	done = true;
	struct node_tree *t = node_tree_create(NULL);
	uint32_t first = t->root.id;
	struct node *screen = node_create(t, NODE_SCREEN);
	struct node *a = node_create(t, NODE_BRANCH);
	struct node *b = node_create(t, NODE_BRANCH);
	struct node *c1 = node_create(t, NODE_CLIENT);
	struct node *c2 = node_create(t, NODE_CLIENT);
	struct node *c3 = node_create(t, NODE_CLIENT);
	struct node *w = node_create(t, NODE_WIBOX);
	assert(node_append(&t->root, screen));
	assert(node_append(screen, a));
	assert(node_append(screen, b));
	assert(node_append(a, c1));
	assert(node_push(a, c2));
	assert(node_insert_before(c1, c3));
	assert(node_insert_after(c3, w));
	node_selftest_order(a, (struct node *[]){c2, c3, w, c1}, 4);
	assert(node_raise(c2));
	node_selftest_order(a, (struct node *[]){c3, w, c1, c2}, 4);
	assert(node_lower(c1));
	node_selftest_order(a, (struct node *[]){c1, c3, w, c2}, 4);
	assert(node_swap(c1, c2));
	node_selftest_order(a, (struct node *[]){c2, c3, w, c1}, 4);
	assert(node_swap(c3, w));
	node_selftest_order(a, (struct node *[]){c2, w, c3, c1}, 4);
	assert(node_append(b, w));
	assert(node_swap(c1, w));
	node_selftest_order(a, (struct node *[]){c2, c3, w}, 3);
	node_selftest_order(b, (struct node *[]){c1}, 1);
	uint32_t id = c3->id;
	assert(node_detach(c3));
	assert(!c3->parent && node_by_id(id) == c3);
	assert(node_append(a, c3));
	assert(c3->id == id);
	assert(node_append(&t->root, b));
	assert(node_append(screen, w));
	a->protected = true;
	t->dirty = false;
	assert(!node_detach(a) && !node_join(a) && !t->dirty);
	assert(!node_append(b, a) && !t->dirty);
	node_selftest_order(screen, (struct node *[]){a, w}, 2);
	assert(!node_insert_before(c1, a) && !t->dirty);
	node_selftest_order(screen, (struct node *[]){a, w}, 2);
	assert(!node_swap(a, b) && !t->dirty);
	node_selftest_order(screen, (struct node *[]){a, w}, 2);
	assert(node_raise(a));
	node_selftest_order(screen, (struct node *[]){w, a}, 2);
	assert(node_lower(a));
	node_selftest_order(screen, (struct node *[]){a, w}, 2);
	a->protected = false;
	assert(node_append(screen, b));
	assert(node_insert_before(c3, w));
	node_selftest_order(a, (struct node *[]){c2, w, c3}, 3);
	node_set_label(a, "branch");
	assert(!strcmp(a->label, "branch"));
	node_set_label(a, a->label + 1);
	assert(!strcmp(a->label, "ranch"));
	node_set_label(a, NULL);
	assert(!a->label);
	node_set_label(a, "joined");
	id = a->id;
	assert(node_join(a));
	assert(!node_by_id(id));
	node_selftest_order(screen, (struct node *[]){c2, w, c3, b}, 4);
	assert(!node_append(b, screen));
	assert(!node_swap(screen, b));
	assert(!node_detach(&t->root));
	assert(!node_join(&t->root));
	assert(node_raise(b));
	assert(node_lower(c2));
	node_selftest_order(screen, (struct node *[]){c2, w, c3, b}, 4);

	struct node_tree *other = node_tree_create(NULL);
	struct node *branch = node_create(other, NODE_BRANCH);
	struct node *surface = node_create(other, NODE_SURFACE);
	assert(node_append(&other->root, branch));
	assert(node_append(branch, surface));
	t->dirty = other->dirty = false;
	assert(node_append(branch, b));
	assert(t->dirty && other->dirty && c1->tree == other);
	t->dirty = other->dirty = false;
	assert(node_swap(branch, c2));
	assert(t->dirty && other->dirty && surface->tree == t && c1->tree == t);
	node_selftest_order(screen, (struct node *[]){branch, w, c3}, 3);
	node_selftest_order(&other->root, (struct node *[]){c2}, 1);
	assert(node_detach(c3));
	assert(node_swap(c3, w));
	node_selftest_order(screen, (struct node *[]){branch, c3}, 2);
	assert(!w->parent);
	id = b->id;
	uint32_t child_id = c1->id;
	node_destroy(b);
	assert(!node_by_id(id) && !node_by_id(child_id));
	assert(node_check_integrity(&t->root));
	node_set_label(w, "detached");
	uint64_t end = next_id;
	node_tree_destroy(t);
	node_tree_destroy(other);
	for (uint64_t i = first; i < end; ++i)
		assert(!node_by_id(i));
	fprintf(stderr, "node selftest ok\n");
}
#endif
