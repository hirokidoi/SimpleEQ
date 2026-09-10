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

uint32_t simpleeq_mixer_slot_count(void)
{
    return kSimpleEQMixerClientSlotCount;
}

size_t simpleeq_mixer_bundle_id_max_bytes(void)
{
    return kSimpleEQMixerBundleIDMaxBytes;
}

size_t simpleeq_mixer_match_key_max_bytes(void)
{
    return kSimpleEQMixerMatchKeyMaxBytes;
}

uint32_t simpleeq_mixer_gain_selector(void)
{
    return kSimpleEQMixerGainSelector;
}

const char *simpleeq_mixer_match_key_bundle_prefix(void)
{
    return kSimpleEQMixerMatchKeyBundlePrefix;
}

const char *simpleeq_mixer_match_key_pid_prefix(void)
{
    return kSimpleEQMixerMatchKeyPIDPrefix;
}

double simpleeq_mixer_control_lease_seconds(void)
{
    return kSimpleEQMixerControlLeaseSeconds;
}

uint32_t simpleeq_mixer_load_table_generation_relaxed(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->mixerTableGeneration, memory_order_relaxed);
}

uint64_t simpleeq_mixer_slot_overflow_count(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->mixerSlotOverflowCount, memory_order_relaxed);
}

uint64_t simpleeq_mixer_neutralized_count(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->mixerNeutralizedCount, memory_order_relaxed);
}

uint64_t simpleeq_mixer_gain_entry_dropped_count(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->mixerGainEntryDroppedCount, memory_order_relaxed);
}

uint64_t simpleeq_mixer_load_control_lease_deadline_host_time(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->mixerControlLeaseDeadlineHostTime, memory_order_acquire);
}

static const SimpleEQMixerClientSlot *simpleeq_mixer_slot(const void *inHeader, uint32_t inIndex)
{
    if(inHeader == NULL || inIndex >= kSimpleEQMixerClientSlotCount) { return NULL; }
    return &((const SimpleEQRingHeader *)inHeader)->mixerClients[inIndex];
}

uint32_t simpleeq_mixer_load_slot_client_id_acquire(const void *inHeader, uint32_t inIndex)
{
    const SimpleEQMixerClientSlot *slot = simpleeq_mixer_slot(inHeader, inIndex);
    if(slot == NULL) { return 0; }
    return atomic_load_explicit(&slot->clientID, memory_order_acquire);
}

uint32_t simpleeq_mixer_slot_process_id(const void *inHeader, uint32_t inIndex)
{
    const SimpleEQMixerClientSlot *slot = simpleeq_mixer_slot(inHeader, inIndex);
    if(slot == NULL) { return 0; }
    return slot->processID;
}

size_t simpleeq_mixer_slot_bundle_id(const void *inHeader, uint32_t inIndex,
                                     char *outBundleID, size_t inCapacity)
{
    if(outBundleID == NULL || inCapacity == 0) { return 0; }
    outBundleID[0] = '\0';

    const SimpleEQMixerClientSlot *slot = simpleeq_mixer_slot(inHeader, inIndex);
    if(slot == NULL) { return 0; }

    size_t limit = sizeof(slot->bundleID);
    if(limit > inCapacity - 1) { limit = inCapacity - 1; }

    size_t length = 0;
    while(length < limit && slot->bundleID[length] != '\0') { length++; }

    memcpy(outBundleID, slot->bundleID, length);
    outBundleID[length] = '\0';
    return length;
}

uint32_t simpleeq_mixer_load_slot_output_cycle_seq(const void *inHeader, uint32_t inIndex)
{
    const SimpleEQMixerClientSlot *slot = simpleeq_mixer_slot(inHeader, inIndex);
    if(slot == NULL) { return 0; }
    return atomic_load_explicit(&slot->outputCycleSeq, memory_order_relaxed);
}

uint32_t simpleeq_mixer_load_slot_clip_event_count(const void *inHeader, uint32_t inIndex)
{
    const SimpleEQMixerClientSlot *slot = simpleeq_mixer_slot(inHeader, inIndex);
    if(slot == NULL) { return 0; }
    return atomic_load_explicit(&slot->clipEventCount, memory_order_relaxed);
}

float simpleeq_mixer_load_slot_last_cycle_peak(const void *inHeader, uint32_t inIndex)
{
    const SimpleEQMixerClientSlot *slot = simpleeq_mixer_slot(inHeader, inIndex);
    if(slot == NULL) { return 0.0f; }
    return SimpleEQMixerFloatFromBits(atomic_load_explicit(&slot->lastCyclePeakBits, memory_order_relaxed));
}

float simpleeq_mixer_load_slot_applied_gain(const void *inHeader, uint32_t inIndex)
{
    const SimpleEQMixerClientSlot *slot = simpleeq_mixer_slot(inHeader, inIndex);
    if(slot == NULL) { return 0.0f; }
    return SimpleEQMixerFloatFromBits(atomic_load_explicit(&slot->appliedGainBits, memory_order_relaxed));
}

bool simpleeq_mixer_build_match_key(char *outKey, size_t inCapacity,
                                    const char *inBundleID, uint32_t inProcessID)
{
    return SimpleEQMixerBuildMatchKey(outKey, inCapacity, inBundleID, inProcessID);
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

// --- 所有権 (セッション横断の調停) ------------------------------------------

uint32_t simpleeq_ownership_selector(void)
{
    return kSimpleEQOwnershipSelector;
}

double simpleeq_ownership_lease_seconds(void)
{
    return kSimpleEQOwnershipLeaseSeconds;
}

double simpleeq_ownership_request_lease_seconds(void)
{
    return kSimpleEQOwnershipRequestLeaseSeconds;
}

const char *simpleeq_ownership_operation_key(void)
{
    return kSimpleEQOwnershipOperationKey;
}

const char *simpleeq_ownership_uid_key(void)
{
    return kSimpleEQOwnershipUIDKey;
}

const char *simpleeq_ownership_operation_claim(void)
{
    return kSimpleEQOwnershipOperationClaim;
}

const char *simpleeq_ownership_operation_request(void)
{
    return kSimpleEQOwnershipOperationRequest;
}

const char *simpleeq_ownership_operation_cancel(void)
{
    return kSimpleEQOwnershipOperationCancel;
}

const char *simpleeq_ownership_operation_release(void)
{
    return kSimpleEQOwnershipOperationRelease;
}

const char *simpleeq_ownership_operation_renew(void)
{
    return kSimpleEQOwnershipOperationRenew;
}

uint32_t simpleeq_ownership_load_generation_acquire(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->ownershipGeneration, memory_order_acquire);
}

uint32_t simpleeq_ownership_owner_process_id_relaxed(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->ownerProcessID, memory_order_relaxed);
}

uint32_t simpleeq_ownership_owner_uid_relaxed(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->ownerUID, memory_order_relaxed);
}

uint64_t simpleeq_ownership_lease_deadline_host_time_relaxed(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->ownershipLeaseDeadlineHostTime, memory_order_relaxed);
}

size_t simpleeq_ownership_owner_process_id_offset(void)
{
    return offsetof(SimpleEQRingHeader, ownerProcessID);
}

size_t simpleeq_ownership_lease_deadline_host_time_offset(void)
{
    return offsetof(SimpleEQRingHeader, ownershipLeaseDeadlineHostTime);
}

size_t simpleeq_ownership_request_process_id_offset(void)
{
    return offsetof(SimpleEQRingHeader, requestProcessID);
}

size_t simpleeq_ownership_request_lease_deadline_host_time_offset(void)
{
    return offsetof(SimpleEQRingHeader, ownershipRequestLeaseDeadlineHostTime);
}

uint32_t simpleeq_ownership_op_unknown(void) { return (uint32_t)kSimpleEQOwnershipOp_Unknown; }
uint32_t simpleeq_ownership_op_claim(void)   { return (uint32_t)kSimpleEQOwnershipOp_Claim; }
uint32_t simpleeq_ownership_op_request(void) { return (uint32_t)kSimpleEQOwnershipOp_Request; }
uint32_t simpleeq_ownership_op_cancel(void)  { return (uint32_t)kSimpleEQOwnershipOp_Cancel; }
uint32_t simpleeq_ownership_op_release(void) { return (uint32_t)kSimpleEQOwnershipOp_Release; }
uint32_t simpleeq_ownership_op_renew(void)   { return (uint32_t)kSimpleEQOwnershipOp_Renew; }

uint32_t simpleeq_ownership_outcome_denied(void)    { return (uint32_t)kSimpleEQOwnershipOutcome_Denied; }
uint32_t simpleeq_ownership_outcome_no_change(void) { return (uint32_t)kSimpleEQOwnershipOutcome_NoChange; }
uint32_t simpleeq_ownership_outcome_applied(void)   { return (uint32_t)kSimpleEQOwnershipOutcome_Applied; }

bool simpleeq_ownership_seat_is_held(
    uint32_t inProcessID, uint64_t inDeadlineHostTime, uint64_t inNowHostTime)
{
    return SimpleEQOwnershipSeatIsHeld(inProcessID, inDeadlineHostTime, inNowHostTime);
}

SimpleEQOwnershipPlanResult simpleeq_ownership_compute_plan(
    uint32_t inOperation, uint32_t inCallerProcessID, uint32_t inDeclaredUID,
    uint32_t inOwnerProcessID, bool inOwnerHoldsSeat,
    uint32_t inRequestProcessID, uint32_t inRequestUID, bool inRequestStands)
{
    SimpleEQOwnershipPlan plan = SimpleEQOwnershipComputePlan(
        (SimpleEQOwnershipOp)inOperation, inCallerProcessID, inDeclaredUID,
        inOwnerProcessID, inOwnerHoldsSeat, inRequestProcessID, inRequestUID, inRequestStands
    );
    SimpleEQOwnershipPlanResult result;
    result.outcome = (uint32_t)plan.outcome;
    result.writesOwnerSeat = plan.writesOwnerSeat;
    result.ownerProcessID = plan.ownerProcessID;
    result.ownerUID = plan.ownerUID;
    result.writesRequestSeat = plan.writesRequestSeat;
    result.requestProcessID = plan.requestProcessID;
    result.requestUID = plan.requestUID;
    result.renewsOwnerLease = plan.renewsOwnerLease;
    result.renewsRequestLease = plan.renewsRequestLease;
    return result;
}

uint32_t simpleeq_ownership_load_request_generation_acquire(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->ownershipRequestGeneration, memory_order_acquire);
}

uint32_t simpleeq_ownership_request_process_id_relaxed(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->requestProcessID, memory_order_relaxed);
}

uint32_t simpleeq_ownership_request_uid_relaxed(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->requestUID, memory_order_relaxed);
}

uint64_t simpleeq_ownership_request_lease_deadline_host_time_relaxed(const void *inHeader)
{
    const SimpleEQRingHeader *header = (const SimpleEQRingHeader *)inHeader;
    return atomic_load_explicit(&header->ownershipRequestLeaseDeadlineHostTime, memory_order_relaxed);
}
