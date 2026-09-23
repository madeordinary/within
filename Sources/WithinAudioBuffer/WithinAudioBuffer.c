#include "WithinAudioBuffer.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>

struct WithinRing {
    float *samples;
    size_t capacity;
    uint64_t limit;
    _Atomic uint64_t head, tail, count;
    _Atomic int status, writers;
    _Atomic float level;
    _Atomic double sum_squares;
};
WithinRing *within_ring_create(size_t capacity, uint64_t max_samples) {
    if (!capacity || !max_samples) return NULL;
    WithinRing *r = calloc(1, sizeof(WithinRing));
    if (!r) return NULL;
    r->samples = calloc(capacity, sizeof(float));
    if (!r->samples) { free(r); return NULL; }
    r->capacity = capacity; r->limit = max_samples;
    return r;
}
void within_ring_destroy(WithinRing *r) {
    if (!r) return;
    volatile float *p = r->samples;
    for (size_t i = 0; i < r->capacity; i++) p[i] = 0;
    free(r->samples); free(r);
}
int within_ring_push(WithinRing *r, const float *input, size_t count) {
    atomic_fetch_add(&r->writers, 1);
    int status = atomic_load(&r->status);
    if (status) { atomic_fetch_sub(&r->writers, 1); return status; }
    uint64_t total = atomic_load_explicit(&r->count, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    size_t length = count;
    if (length > r->limit - total) length = (size_t)(r->limit - total);
    if (length > r->capacity - (head - tail)) {
        atomic_store_explicit(&r->status, 2, memory_order_release);
        atomic_fetch_sub(&r->writers, 1);
        return 2;
    }
    double energy = 0;
    for (size_t i = 0; i < length; i++) {
        float value = isfinite(input[i]) ? input[i] : 0;
        r->samples[(head + i) % r->capacity] = value;
        energy += (double)value * value;
    }
    atomic_store_explicit(&r->sum_squares, atomic_load(&r->sum_squares) + energy, memory_order_relaxed);
    atomic_store_explicit(&r->level, length ? (float)sqrt(energy / length) : 0, memory_order_relaxed);
    atomic_store_explicit(&r->count, total + length, memory_order_relaxed);
    atomic_store_explicit(&r->head, head + length, memory_order_release);
    if (total + length >= r->limit) {
        atomic_store_explicit(&r->status, 3, memory_order_release);
        atomic_fetch_sub(&r->writers, 1);
        return 3;
    }
    atomic_fetch_sub(&r->writers, 1);
    return 0;
}
size_t within_ring_pop(WithinRing *r, float *output, size_t capacity) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t count = (size_t)(head - tail);
    if (count > capacity) count = capacity;
    for (size_t i = 0; i < count; i++) {
        size_t index = (tail + i) % r->capacity;
        output[i] = r->samples[index]; r->samples[index] = 0;
    }
    atomic_store_explicit(&r->tail, tail + count, memory_order_release);
    return count;
}
void within_ring_close(WithinRing *r) {
    int running = 0;
    atomic_compare_exchange_strong_explicit(&r->status, &running, 1, memory_order_release, memory_order_relaxed);
}
int within_ring_status(const WithinRing *r) {
    int status = atomic_load(&r->status);
    // A consumer must drain a producer already in flight before observing closure.
    return status && atomic_load(&r->writers) ? 0 : status;
}
uint64_t within_ring_count(const WithinRing *r) { return atomic_load(&r->count); }
size_t within_ring_pending(const WithinRing *r) {
    uint64_t tail = atomic_load(&r->tail);
    uint64_t head = atomic_load(&r->head);
    return head >= tail ? (size_t)(head - tail) : 0;
}
float within_ring_level(const WithinRing *r) { return atomic_load(&r->level); }
double within_ring_mean_energy(const WithinRing *r) {
    uint64_t count = atomic_load(&r->count);
    return count ? atomic_load(&r->sum_squares) / count : 0;
}
