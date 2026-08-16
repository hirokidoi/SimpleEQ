#include "SimpleEQRingC.h"
#include "SimpleEQRingLayout.h"

const char *simpleeq_ring_directory_path(void)
{
    return kSimpleEQRingDirectoryPath;
}

const char *simpleeq_ring_file_name(void)
{
    return kSimpleEQRingFileName;
}

size_t simpleeq_ring_header_size(void)
{
    return sizeof(SimpleEQRingHeader);
}

uint32_t simpleeq_ring_load_magic_acquire(const void *inHeader)
{
    return atomic_load_explicit(&((const SimpleEQRingHeader *)inHeader)->magic, memory_order_acquire);
}

uint32_t simpleeq_ring_layout_version(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->layoutVersion;
}

uint32_t simpleeq_ring_expected_magic(void)
{
    return kSimpleEQRingMagic;
}

uint32_t simpleeq_ring_expected_layout_version(void)
{
    return kSimpleEQRingLayoutVersion;
}

uint16_t simpleeq_ring_driver_version_major(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->driverVersionMajor;
}

uint16_t simpleeq_ring_driver_version_minor(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->driverVersionMinor;
}

uint16_t simpleeq_driver_version_major(void)
{
    return kSimpleEQDriverVersionMajor;
}

uint16_t simpleeq_driver_version_minor(void)
{
    return kSimpleEQDriverVersionMinor;
}

uint32_t simpleeq_ring_header_bytes(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->headerBytes;
}

uint32_t simpleeq_ring_frames(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->ringFrames;
}

uint32_t simpleeq_ring_channels(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->channels;
}

uint64_t simpleeq_ring_load_counter_acquire(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->writeCounter, memory_order_acquire);
}

uint32_t simpleeq_ring_load_epoch_acquire(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->epoch, memory_order_acquire);
}

uint32_t simpleeq_ring_load_writer_io_is_running_acquire(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->writerIOIsRunning, memory_order_acquire);
}

double simpleeq_ring_sample_rate(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->sampleRate;
}

uint32_t simpleeq_ring_io_cycle_frames(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->ioCycleFrames, memory_order_relaxed);
}

void simpleeq_ring_acquire_fence(void)
{
    atomic_thread_fence(memory_order_acquire);
}

uint32_t simpleeq_ring_load_ts_seq_acquire(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->tsSeq, memory_order_acquire);
}

uint64_t simpleeq_ring_ts_write_counter(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->tsWriteCounter;
}

uint64_t simpleeq_ring_ts_host_time(const void *inHeader)
{
    return ((const SimpleEQRingHeader *)inHeader)->tsHostTime;
}

uint64_t simpleeq_ring_presentation_stall_count(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->presentationStallCount, memory_order_relaxed);
}

uint64_t simpleeq_ring_presentation_delta_unexpected_count(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->presentationDeltaUnexpectedCount, memory_order_relaxed);
}

uint64_t simpleeq_ring_write_deadline_missed_count(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->writeDeadlineMissedCount, memory_order_relaxed);
}

uint64_t simpleeq_ring_silence_filled_gap_count(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->silenceFilledGapCount, memory_order_relaxed);
}

SimpleEQRingWritePlanResult simpleeq_ring_compute_write_plan(
    uint64_t inAnchor, bool inAnchorValid,
    uint64_t inPreviousPresentedFrames, bool inPreviousPresentedFramesValid,
    double inPresentationSampleTime,
    uint64_t inCurrentCounter, uint32_t inRingFrames, uint32_t inFramesThisCycle)
{
    SimpleEQRingWritePlan plan = SimpleEQRingComputeWritePlan(
        inAnchor, inAnchorValid, inPreviousPresentedFrames, inPreviousPresentedFramesValid,
        inPresentationSampleTime, inCurrentCounter, inRingFrames, inFramesThisCycle
    );
    SimpleEQRingWritePlanResult result;
    result.absolutePosition = plan.absolutePosition;
    result.anchor = plan.anchor;
    result.publishedCounter = plan.publishedCounter;
    result.presentedFrames = plan.presentedFrames;
    result.presentationTimeStalled = plan.presentationTimeStalled;
    result.presentationTimeUnexpected = plan.presentationTimeUnexpected;
    result.gapFrames = plan.gapFrames;
    return result;
}

const float *simpleeq_ring_data_ptr(const void *inHeader)
{
    return SimpleEQRingBody((void *)inHeader);
}

float simpleeq_ring_volume_min_db(void)
{
    return kSimpleEQVolumeMinDB;
}

float simpleeq_ring_volume_max_db(void)
{
    return kSimpleEQVolumeMaxDB;
}

const char *simpleeq_driver_device_uid(void)
{
    return kSimpleEQDeviceUID;
}

const char *simpleeq_driver_device_name(void)
{
    return kSimpleEQDeviceName;
}

uint32_t simpleeq_driver_visibility_override_selector(void)
{
    return kSimpleEQVisibilityOverrideSelector;
}

uint32_t simpleeq_driver_name_override_selector(void)
{
    return kSimpleEQNameOverrideSelector;
}

uint32_t simpleeq_driver_name_override_max_length(void)
{
    return kSimpleEQNameOverrideMaxLength;
}
