#include "SimpleEQAtomicC.h"
#include <stdatomic.h>

typedef struct {
    _Atomic uint64_t value;
} SimpleEQAtomicStorage;

size_t simpleeq_atomic_storage_size(void)
{
    return sizeof(SimpleEQAtomicStorage);
}

size_t simpleeq_atomic_storage_alignment(void)
{
    return _Alignof(SimpleEQAtomicStorage);
}

void simpleeq_atomic_init(void *storage, uint64_t initial)
{
    atomic_init(&((SimpleEQAtomicStorage *)storage)->value, initial);
}

void simpleeq_atomic_store_release(void *storage, uint64_t value)
{
    atomic_store_explicit(&((SimpleEQAtomicStorage *)storage)->value, value, memory_order_release);
}

uint64_t simpleeq_atomic_load_acquire(const void *storage)
{
    return atomic_load_explicit(&((const SimpleEQAtomicStorage *)storage)->value, memory_order_acquire);
}
