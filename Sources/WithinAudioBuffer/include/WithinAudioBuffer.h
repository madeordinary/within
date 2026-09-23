#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct WithinRing WithinRing;
// Single producer / single consumer. All storage allocated before capture begins.
WithinRing *within_ring_create(size_t capacity, uint64_t max_samples);
void within_ring_destroy(WithinRing *ring);
int within_ring_push(WithinRing *ring, const float *samples, size_t count);
size_t within_ring_pop(WithinRing *ring, float *output, size_t capacity);
void within_ring_close(WithinRing *ring);
int within_ring_status(const WithinRing *ring); // 0 running, 1 closed, 2 overflow, 3 duration limit
uint64_t within_ring_count(const WithinRing *ring);
size_t within_ring_pending(const WithinRing *ring);
float within_ring_level(const WithinRing *ring);
double within_ring_mean_energy(const WithinRing *ring);
