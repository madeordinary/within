#include "WithinAudioBuffer.h"
#include <pthread.h>
#include <assert.h>
#include <sched.h>
#include <stdio.h>
#include <stdatomic.h>

#define COUNT 1000000
static WithinRing *ring;
static _Atomic int close_early;
static void *produce(void *unused) {
    (void)unused;
    for (size_t index = 0; index < COUNT;) {
        float values[64];
        for (size_t i = 0; i < 64; i++) values[i] = (float)(index + i);
        if (within_ring_status(ring) != 0) break;
        if (within_ring_pending(ring) + 64 > 4096) { sched_yield(); continue; }
        if (within_ring_push(ring, values, 64) != 0) break;
        index += 64;
    }
    within_ring_close(ring);
    return NULL;
}
static void *consume(void *unused) {
    (void)unused;
    size_t index = 0;
    while (within_ring_status(ring) == 0 || within_ring_pending(ring) != 0) {
        float values[137];
        size_t read = within_ring_pop(ring, values, 137);
        for (size_t i = 0; i < read; i++) { assert(values[i] == (float)index); index++; }
        if (atomic_load(&close_early) && index >= 10000) within_ring_close(ring);
        if (!read) sched_yield();
    }
    assert(index == within_ring_count(ring));
    if (!atomic_load(&close_early)) assert(index == COUNT);
    return NULL;
}
int main(void) {
    for (int trial = 0; trial < 20; trial++) {
        atomic_store(&close_early, trial % 2);
        ring = within_ring_create(4096, COUNT);
        assert(ring);
        pthread_t producer, consumer;
        assert(!pthread_create(&producer, NULL, produce, NULL));
        assert(!pthread_create(&consumer, NULL, consume, NULL));
        pthread_join(producer, NULL); pthread_join(consumer, NULL);
        within_ring_destroy(ring);
    }
    puts("20 concurrent ring trials passed, including close during production.");
}
