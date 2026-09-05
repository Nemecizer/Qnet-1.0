/*
 * event_queue.h - Binary min-heap event list for discrete event simulation
 */

#ifndef EVENT_QUEUE_H
#define EVENT_QUEUE_H

typedef enum {
    EVENT_UNBLOCK,          /* priority 0 — processed first at equal time */
    EVENT_SERVICE_COMPLETE, /* priority 1 */
    EVENT_ARRIVAL           /* priority 2 — processed last at equal time */
} EventType;

typedef struct {
    double    time;           /* scheduled event time */
    EventType type;
    int       station;        /* station index (0-based) */
    int       customer_id;    /* unique customer identifier */
    int       customer_class; /* customer class (0-based) */
    double    entry_time;     /* time this customer entered the network */
} Event;

typedef struct {
    Event *heap;
    int    size;
    int    capacity;
} EventQueue;

void eq_init(EventQueue *eq, int initial_capacity);
void eq_free(EventQueue *eq);
void eq_push(EventQueue *eq, Event e);
Event eq_pop(EventQueue *eq);
int  eq_is_empty(const EventQueue *eq);

#endif /* EVENT_QUEUE_H */
