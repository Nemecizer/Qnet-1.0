/*
 * event_queue.c - Binary min-heap event list
 *
 * Events are ordered by (time, type).  At equal times, EVENT_UNBLOCK
 * is processed before EVENT_SERVICE_COMPLETE, which is processed
 * before EVENT_ARRIVAL.  This ensures that freed buffer slots are
 * claimed by blocked stations before new arrivals.
 */

#include "event_queue.h"
#include <stdlib.h>
#include <string.h>

/* Return non-zero if a should be scheduled before b. */
static inline int event_less(const Event *a, const Event *b)
{
    if (a->time != b->time)
        return a->time < b->time;
    return a->type < b->type;   /* enum values encode priority */
}

static void swap(Event *a, Event *b)
{
    Event tmp = *a;
    *a = *b;
    *b = tmp;
}

static void sift_up(EventQueue *eq, int i)
{
    while (i > 0) {
        int parent = (i - 1) / 2;
        if (event_less(&eq->heap[i], &eq->heap[parent])) {
            swap(&eq->heap[i], &eq->heap[parent]);
            i = parent;
        } else {
            break;
        }
    }
}

static void sift_down(EventQueue *eq, int i)
{
    for (;;) {
        int smallest = i;
        int left  = 2 * i + 1;
        int right = 2 * i + 2;

        if (left < eq->size && event_less(&eq->heap[left], &eq->heap[smallest]))
            smallest = left;
        if (right < eq->size && event_less(&eq->heap[right], &eq->heap[smallest]))
            smallest = right;

        if (smallest == i)
            break;

        swap(&eq->heap[i], &eq->heap[smallest]);
        i = smallest;
    }
}

void eq_init(EventQueue *eq, int initial_capacity)
{
    eq->capacity = initial_capacity > 16 ? initial_capacity : 16;
    eq->heap = (Event *)malloc(sizeof(Event) * (size_t)eq->capacity);
    eq->size = 0;
}

void eq_free(EventQueue *eq)
{
    free(eq->heap);
    eq->heap = NULL;
    eq->size = eq->capacity = 0;
}

void eq_push(EventQueue *eq, Event e)
{
    if (eq->size == eq->capacity) {
        eq->capacity *= 2;
        eq->heap = (Event *)realloc(eq->heap, sizeof(Event) * (size_t)eq->capacity);
    }
    eq->heap[eq->size] = e;
    sift_up(eq, eq->size);
    eq->size++;
}

Event eq_pop(EventQueue *eq)
{
    Event top = eq->heap[0];
    eq->size--;
    if (eq->size > 0) {
        eq->heap[0] = eq->heap[eq->size];
        sift_down(eq, 0);
    }
    return top;
}

int eq_is_empty(const EventQueue *eq)
{
    return eq->size == 0;
}
