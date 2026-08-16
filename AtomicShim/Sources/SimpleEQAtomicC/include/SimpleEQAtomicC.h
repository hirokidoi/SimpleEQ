#ifndef SimpleEQAtomicC_h
#define SimpleEQAtomicC_h

#include <stddef.h>
#include <stdint.h>

size_t simpleeq_atomic_storage_size(void);
size_t simpleeq_atomic_storage_alignment(void);

void simpleeq_atomic_init(void *storage, uint64_t initial);

void simpleeq_atomic_store_release(void *storage, uint64_t value);
uint64_t simpleeq_atomic_load_acquire(const void *storage);

#endif /* SimpleEQAtomicC_h */
