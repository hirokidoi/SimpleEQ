#ifndef SimpleEQRingC_h
#define SimpleEQRingC_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

const char *simpleeq_ring_directory_path(void);
const char *simpleeq_ring_file_name(void);

size_t simpleeq_ring_header_size(void);

uint32_t simpleeq_ring_load_magic_acquire(const void *inHeader);
uint32_t simpleeq_ring_layout_version(const void *inHeader);
uint32_t simpleeq_ring_expected_magic(void);
uint32_t simpleeq_ring_expected_layout_version(void);

uint16_t simpleeq_ring_driver_version_major(const void *inHeader);
uint16_t simpleeq_ring_driver_version_minor(const void *inHeader);
uint16_t simpleeq_driver_version_major(void);
uint16_t simpleeq_driver_version_minor(void);
uint32_t simpleeq_ring_header_bytes(const void *inHeader);
uint32_t simpleeq_ring_frames(const void *inHeader);
uint32_t simpleeq_ring_channels(const void *inHeader);

uint64_t simpleeq_ring_load_counter_acquire(const void *inHeader);

uint32_t simpleeq_ring_load_epoch_acquire(const void *inHeader);

uint32_t simpleeq_ring_load_writer_io_is_running_acquire(const void *inHeader);

double   simpleeq_ring_sample_rate(const void *inHeader);

uint32_t simpleeq_ring_io_cycle_frames(const void *inHeader);

void simpleeq_ring_acquire_fence(void);

uint32_t simpleeq_ring_load_ts_seq_acquire(const void *inHeader);
uint64_t simpleeq_ring_ts_write_counter(const void *inHeader);
uint64_t simpleeq_ring_ts_host_time(const void *inHeader);

uint64_t simpleeq_ring_presentation_stall_count(const void *inHeader);
uint64_t simpleeq_ring_presentation_delta_unexpected_count(const void *inHeader);
uint64_t simpleeq_ring_write_deadline_missed_count(const void *inHeader);
uint64_t simpleeq_ring_silence_filled_gap_count(const void *inHeader);

typedef struct
{
    uint64_t absolutePosition;
    uint64_t anchor;
    uint64_t publishedCounter;
    uint64_t presentedFrames;
    bool     presentationTimeStalled;
    bool     presentationTimeUnexpected;
    uint32_t gapFrames;
} SimpleEQRingWritePlanResult;

SimpleEQRingWritePlanResult simpleeq_ring_compute_write_plan(
    uint64_t inAnchor, bool inAnchorValid,
    uint64_t inPreviousPresentedFrames, bool inPreviousPresentedFramesValid,
    double inPresentationSampleTime,
    uint64_t inCurrentCounter, uint32_t inRingFrames, uint32_t inFramesThisCycle);

const float *simpleeq_ring_data_ptr(const void *inHeader);

float simpleeq_ring_volume_min_db(void);
float simpleeq_ring_volume_max_db(void);

const char *simpleeq_driver_device_uid(void);
const char *simpleeq_driver_device_name(void);
uint32_t    simpleeq_driver_visibility_override_selector(void);
uint32_t    simpleeq_driver_name_override_selector(void);
uint32_t    simpleeq_driver_name_override_max_length(void);

#endif /* SimpleEQRingC_h */
