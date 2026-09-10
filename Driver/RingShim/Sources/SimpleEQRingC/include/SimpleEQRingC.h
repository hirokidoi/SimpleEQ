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

uint32_t    simpleeq_mixer_slot_count(void);
size_t      simpleeq_mixer_bundle_id_max_bytes(void);
size_t      simpleeq_mixer_match_key_max_bytes(void);
uint32_t    simpleeq_mixer_gain_selector(void);
const char *simpleeq_mixer_match_key_bundle_prefix(void);
const char *simpleeq_mixer_match_key_pid_prefix(void);
double      simpleeq_mixer_control_lease_seconds(void);

uint32_t simpleeq_mixer_load_table_generation_relaxed(const void *inHeader);
uint64_t simpleeq_mixer_slot_overflow_count(const void *inHeader);
uint64_t simpleeq_mixer_neutralized_count(const void *inHeader);
uint64_t simpleeq_mixer_gain_entry_dropped_count(const void *inHeader);
uint64_t simpleeq_mixer_load_control_lease_deadline_host_time(const void *inHeader);

uint32_t simpleeq_mixer_load_slot_client_id_acquire(const void *inHeader, uint32_t inIndex);
uint32_t simpleeq_mixer_slot_process_id(const void *inHeader, uint32_t inIndex);

/// outBundleID を必ず NUL 終端し、書いた文字数を返す。
/// スロットの値が終端されていなくても容量を越えて読まない。
size_t simpleeq_mixer_slot_bundle_id(const void *inHeader, uint32_t inIndex,
                                     char *outBundleID, size_t inCapacity);

uint32_t simpleeq_mixer_load_slot_output_cycle_seq(const void *inHeader, uint32_t inIndex);
uint32_t simpleeq_mixer_load_slot_clip_event_count(const void *inHeader, uint32_t inIndex);
float    simpleeq_mixer_load_slot_last_cycle_peak(const void *inHeader, uint32_t inIndex);
float    simpleeq_mixer_load_slot_applied_gain(const void *inHeader, uint32_t inIndex);

bool simpleeq_mixer_build_match_key(char *outKey, size_t inCapacity,
                                    const char *inBundleID, uint32_t inProcessID);

const char *simpleeq_driver_device_uid(void);
const char *simpleeq_driver_device_name(void);
uint32_t    simpleeq_driver_visibility_override_selector(void);
uint32_t    simpleeq_driver_name_override_selector(void);
uint32_t    simpleeq_driver_name_override_max_length(void);

// --- 所有権 (セッション横断の調停) ------------------------------------------

uint32_t simpleeq_ownership_selector(void);
double   simpleeq_ownership_lease_seconds(void);
double   simpleeq_ownership_request_lease_seconds(void);

const char *simpleeq_ownership_operation_key(void);
const char *simpleeq_ownership_uid_key(void);
const char *simpleeq_ownership_operation_claim(void);
const char *simpleeq_ownership_operation_request(void);
const char *simpleeq_ownership_operation_cancel(void);
const char *simpleeq_ownership_operation_release(void);
const char *simpleeq_ownership_operation_renew(void);

/// 世代が偶数であることを確かめ、内容 (relaxed) を読み、世代を再読して一致を見るのは呼び出し側の責務。
uint32_t simpleeq_ownership_load_generation_acquire(const void *inHeader);
uint32_t simpleeq_ownership_owner_process_id_relaxed(const void *inHeader);
uint32_t simpleeq_ownership_owner_uid_relaxed(const void *inHeader);
uint64_t simpleeq_ownership_lease_deadline_host_time_relaxed(const void *inHeader);

size_t simpleeq_ownership_owner_process_id_offset(void);
size_t simpleeq_ownership_lease_deadline_host_time_offset(void);
size_t simpleeq_ownership_request_process_id_offset(void);
size_t simpleeq_ownership_request_lease_deadline_host_time_offset(void);

uint32_t simpleeq_ownership_op_unknown(void);
uint32_t simpleeq_ownership_op_claim(void);
uint32_t simpleeq_ownership_op_request(void);
uint32_t simpleeq_ownership_op_cancel(void);
uint32_t simpleeq_ownership_op_release(void);
uint32_t simpleeq_ownership_op_renew(void);

uint32_t simpleeq_ownership_outcome_denied(void);
uint32_t simpleeq_ownership_outcome_no_change(void);
uint32_t simpleeq_ownership_outcome_applied(void);

bool simpleeq_ownership_seat_is_held(
    uint32_t inProcessID, uint64_t inDeadlineHostTime, uint64_t inNowHostTime);

typedef struct
{
    uint32_t outcome;
    bool     writesOwnerSeat;
    uint32_t ownerProcessID;
    uint32_t ownerUID;
    bool     writesRequestSeat;
    uint32_t requestProcessID;
    uint32_t requestUID;
    bool     renewsOwnerLease;
    bool     renewsRequestLease;
} SimpleEQOwnershipPlanResult;

SimpleEQOwnershipPlanResult simpleeq_ownership_compute_plan(
    uint32_t inOperation, uint32_t inCallerProcessID, uint32_t inDeclaredUID,
    uint32_t inOwnerProcessID, bool inOwnerHoldsSeat,
    uint32_t inRequestProcessID, uint32_t inRequestUID, bool inRequestStands);

uint32_t simpleeq_ownership_load_request_generation_acquire(const void *inHeader);
uint32_t simpleeq_ownership_request_process_id_relaxed(const void *inHeader);
uint32_t simpleeq_ownership_request_uid_relaxed(const void *inHeader);
uint64_t simpleeq_ownership_request_lease_deadline_host_time_relaxed(const void *inHeader);

#endif /* SimpleEQRingC_h */
