#ifndef SimpleEQRingLayout_h
#define SimpleEQRingLayout_h

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define kSimpleEQRingLayoutVersion ((uint32_t)3)

#define kSimpleEQDriverVersionMajor ((uint16_t)2)
#define kSimpleEQDriverVersionMinor ((uint16_t)1)

#define kSimpleEQRingMagic ((uint32_t)0x53455152u)

#define kSimpleEQRingDirectoryPath "/Library/Application Support/SimpleEQ"
#define kSimpleEQRingFileName      "SimpleEQAudioRing.shm"

#define kSimpleEQRingChannelsValue 2
#define kSimpleEQRingChannels ((uint32_t)kSimpleEQRingChannelsValue)

#define kSimpleEQ_STRINGIFY2(x) #x
#define kSimpleEQ_STRINGIFY(x) kSimpleEQ_STRINGIFY2(x)

#define kSimpleEQDeviceUID  "SimpleEQAudio" kSimpleEQ_STRINGIFY(kSimpleEQRingChannelsValue) "ch_UID"
#define kSimpleEQDeviceName "SimpleEQ Audio " kSimpleEQ_STRINGIFY(kSimpleEQRingChannelsValue) "ch"

#define kSimpleEQVisibilityOverrideSelector ((uint32_t)'seqV')

#define kSimpleEQNameOverrideSelector ((uint32_t)'seqN')

/// UTF-16 コードユニット数。
#define kSimpleEQNameOverrideMaxLength ((uint32_t)64)

#define kSimpleEQDriftCompositionSelector ((uint32_t)'seqD')

#define kSimpleEQVolumeMinDB ((float)-64.0)
#define kSimpleEQVolumeMaxDB ((float)0.0)

//==================================================================================================
#pragma mark Mixer (client table / per-client gain)
//==================================================================================================

#define kSimpleEQMixerClientSlotCount ((uint32_t)64)

/// NUL 終端込みのバイト数。
#define kSimpleEQMixerBundleIDMaxBytes ((size_t)96)

#define kSimpleEQMixerMatchKeyBundlePrefix "bundle:"
#define kSimpleEQMixerMatchKeyPIDPrefix    "pid:"

/// NUL 終端込みのバイト数。
#define kSimpleEQMixerMatchKeyMaxBytes \
    ((size_t)(sizeof(kSimpleEQMixerMatchKeyBundlePrefix) - 1 + kSimpleEQMixerBundleIDMaxBytes))

#define kSimpleEQMixerGainEntryMax ((uint32_t)128)

#define kSimpleEQMixerGainSelector ((uint32_t)'seqG')

#define kSimpleEQMixerControlLeaseSeconds ((double)6.0)

typedef struct
{
    _Atomic uint32_t clientID;
    uint32_t         processID;
    char             bundleID[kSimpleEQMixerBundleIDMaxBytes];
    _Atomic uint32_t outputCycleSeq;
    _Atomic uint32_t clipEventCount;
    _Atomic uint32_t lastCyclePeakBits;
    _Atomic uint32_t appliedGainBits;
} SimpleEQMixerClientSlot;

// float を整数で運ぶのは、_Atomic float の lock-free 性が実装依存で、
// リアルタイム経路に暗黙のロックが生じうるため。
static inline uint32_t SimpleEQMixerFloatToBits(float inValue)
{
    uint32_t theBits;
    memcpy(&theBits, &inValue, sizeof(theBits));
    return theBits;
}

static inline float SimpleEQMixerFloatFromBits(uint32_t inBits)
{
    float theValue;
    memcpy(&theValue, &inBits, sizeof(theValue));
    return theValue;
}

/// 成功時は outKey を NUL 終端する。失敗時は outKey を空文字にする。
static inline bool SimpleEQMixerBuildMatchKey(
    char *outKey, size_t inCapacity, const char *inBundleID, uint32_t inProcessID)
{
    if(outKey == NULL || inCapacity == 0) { return false; }
    outKey[0] = '\0';

    // uint32 の 10 進表記は最長 10 桁。
    char theDigits[16];
    const char *thePrefix;
    const char *theBody;
    size_t thePrefixLength;
    size_t theBodyLength;

    size_t theBundleLength = (inBundleID != NULL) ? strlen(inBundleID) : 0;
    // 切り詰めた鍵を作らない。切り詰めると別アプリが同一の鍵になりうるので、収まらなければ pid へ落とす。
    bool theUseBundle = (theBundleLength > 0)
        && ((sizeof(kSimpleEQMixerMatchKeyBundlePrefix) - 1 + theBundleLength + 1) <= kSimpleEQMixerMatchKeyMaxBytes);

    if(theUseBundle)
    {
        thePrefix = kSimpleEQMixerMatchKeyBundlePrefix;
        thePrefixLength = sizeof(kSimpleEQMixerMatchKeyBundlePrefix) - 1;
        theBody = inBundleID;
        theBodyLength = theBundleLength;
    }
    else
    {
        int theWritten = snprintf(theDigits, sizeof(theDigits), "%u", inProcessID);
        if(theWritten < 0 || (size_t)theWritten >= sizeof(theDigits)) { return false; }
        thePrefix = kSimpleEQMixerMatchKeyPIDPrefix;
        thePrefixLength = sizeof(kSimpleEQMixerMatchKeyPIDPrefix) - 1;
        theBody = theDigits;
        theBodyLength = (size_t)theWritten;
    }

    if((thePrefixLength + theBodyLength + 1) > inCapacity) { return false; }

    memcpy(outKey, thePrefix, thePrefixLength);
    memcpy(outKey + thePrefixLength, theBody, theBodyLength);
    outKey[thePrefixLength + theBodyLength] = '\0';
    return true;
}

//==================================================================================================
#pragma mark Ownership (cross-session arbitration)
//==================================================================================================

#define kSimpleEQOwnershipSelector ((uint32_t)'seqO')

#define kSimpleEQOwnershipLeaseSeconds        ((double)6.0)
#define kSimpleEQOwnershipRequestLeaseSeconds ((double)6.0)

/// Set の CFDictionaryRef のキー。"op" は操作名 (kSimpleEQOwnershipOperation* のいずれか)、"uid" は申告値 (表示専用)。
#define kSimpleEQOwnershipOperationKey "op"
#define kSimpleEQOwnershipUIDKey       "uid"

#define kSimpleEQOwnershipOperationClaim   "claim"
#define kSimpleEQOwnershipOperationRequest "request"
#define kSimpleEQOwnershipOperationCancel  "cancel"
#define kSimpleEQOwnershipOperationRelease "release"
#define kSimpleEQOwnershipOperationRenew   "renew"

/// Get が返す CFDictionaryRef のキー。値は共有ヘッダの内容をそのまま映す。
#define kSimpleEQOwnershipOwnerProcessIDKey   "ownerProcessID"
#define kSimpleEQOwnershipOwnerUIDKey         "ownerUID"
#define kSimpleEQOwnershipRequestProcessIDKey "requestProcessID"
#define kSimpleEQOwnershipRequestUIDKey       "requestUID"

typedef enum
{
    kSimpleEQOwnershipOp_Unknown = 0,
    kSimpleEQOwnershipOp_Claim,
    kSimpleEQOwnershipOp_Request,
    kSimpleEQOwnershipOp_Cancel,
    kSimpleEQOwnershipOp_Release,
    kSimpleEQOwnershipOp_Renew,
} SimpleEQOwnershipOp;

typedef enum
{
    kSimpleEQOwnershipOutcome_Denied = 0,
    kSimpleEQOwnershipOutcome_NoChange,
    kSimpleEQOwnershipOutcome_Applied,
} SimpleEQOwnershipOutcome;

/// 席を書き換えるかどうかと、書き換えるなら何にするか。pid 0 は空席 (期限も 0 にする)。
/// renews* は席の中身を動かさず期限だけを延ばす。
typedef struct
{
    SimpleEQOwnershipOutcome outcome;
    bool     writesOwnerSeat;
    uint32_t ownerProcessID;
    uint32_t ownerUID;
    bool     writesRequestSeat;
    uint32_t requestProcessID;
    uint32_t requestUID;
    bool     renewsOwnerLease;
    bool     renewsRequestLease;
} SimpleEQOwnershipPlan;

/// 席が埋まっているかは期限で決める。回収は期限しか落とさないため、pid だけを見ると
/// 名乗ったまま時間の切れた席を埋まっていると読み、誰も掴めなくなる。
static inline bool SimpleEQOwnershipSeatIsHeld(
    uint32_t inProcessID, uint64_t inDeadlineHostTime, uint64_t inNowHostTime)
{
    if(inProcessID == 0) { return false; }
    return inDeadlineHostTime != 0 && inNowHostTime < inDeadlineHostTime;
}

/// 操作の可否と、席をどう書き換えるか。呼び出し元の同定は inCallerProcessID のみで行い、
/// inDeclaredUID は申告値であって権利の判定には使わない。
static inline SimpleEQOwnershipPlan SimpleEQOwnershipComputePlan(
    SimpleEQOwnershipOp inOperation, uint32_t inCallerProcessID, uint32_t inDeclaredUID,
    uint32_t inOwnerProcessID, bool inOwnerHoldsSeat,
    uint32_t inRequestProcessID, uint32_t inRequestUID, bool inRequestStands)
{
    SimpleEQOwnershipPlan plan;
    plan.outcome = kSimpleEQOwnershipOutcome_Denied;
    plan.writesOwnerSeat = false;
    plan.ownerProcessID = 0;
    plan.ownerUID = 0;
    plan.writesRequestSeat = false;
    plan.requestProcessID = 0;
    plan.requestUID = 0;
    plan.renewsOwnerLease = false;
    plan.renewsRequestLease = false;

    if(inCallerProcessID == 0) { return plan; }

    switch(inOperation)
    {
        case kSimpleEQOwnershipOp_Claim:
            if(inOwnerHoldsSeat) { return plan; }
            plan.outcome = kSimpleEQOwnershipOutcome_Applied;
            plan.writesOwnerSeat = true;
            plan.ownerProcessID = inCallerProcessID;
            plan.ownerUID = inDeclaredUID;
            return plan;

        case kSimpleEQOwnershipOp_Request:
            // 待ち枠は 1 つしかない。上書きすると、消された側は renew も cancel も自分の要求に届かず待ち続ける。
            if(inRequestStands && inRequestProcessID != inCallerProcessID) { return plan; }
            plan.outcome = kSimpleEQOwnershipOutcome_Applied;
            plan.writesRequestSeat = true;
            plan.requestProcessID = inCallerProcessID;
            plan.requestUID = inDeclaredUID;
            return plan;

        case kSimpleEQOwnershipOp_Cancel:
            if(inRequestProcessID != inCallerProcessID)
            {
                plan.outcome = kSimpleEQOwnershipOutcome_NoChange;
                return plan;
            }
            plan.outcome = kSimpleEQOwnershipOutcome_Applied;
            plan.writesRequestSeat = true;
            return plan;

        case kSimpleEQOwnershipOp_Release:
            if(inOwnerProcessID != inCallerProcessID)
            {
                plan.outcome = kSimpleEQOwnershipOutcome_NoChange;
                return plan;
            }
            plan.outcome = kSimpleEQOwnershipOutcome_Applied;
            plan.writesOwnerSeat = true;
            // 自分が出した要求へは渡さない。渡すと、満了席を掴んだ直後に終わるインスタンスが
            // 死んだ自分の pid へ所有権を戻し、次のインスタンスがリース満了まで待たされる。
            if(inRequestStands && inRequestProcessID != inCallerProcessID)
            {
                plan.ownerProcessID = inRequestProcessID;
                plan.ownerUID = inRequestUID;
                plan.writesRequestSeat = true;
            }
            return plan;

        case kSimpleEQOwnershipOp_Renew:
            // 期限を延ばすだけで所有者も要求者も動かないため、変化として扱わない。
            // 変化にすると、通知を受けた側が renew を打ち返し、往復の速さで回り続ける。
            plan.outcome = kSimpleEQOwnershipOutcome_NoChange;
            if(inOwnerProcessID == inCallerProcessID) { plan.renewsOwnerLease = true; }
            else if(inRequestProcessID == inCallerProcessID) { plan.renewsRequestLease = true; }
            return plan;

        case kSimpleEQOwnershipOp_Unknown:
        default:
            return plan;
    }
}

typedef struct
{
    _Atomic uint32_t magic;
    uint32_t         layoutVersion;
    uint16_t         driverVersionMajor;
    uint16_t         driverVersionMinor;
    uint32_t         headerBytes;
    uint32_t         ringFrames;
    uint32_t         channels;

    double   sampleRate;

    _Atomic uint32_t ioCycleFrames;

    _Atomic uint64_t writeCounter;

    _Atomic uint32_t epoch;

    _Atomic uint32_t writerIOIsRunning;

    _Atomic uint32_t tsSeq;
    uint64_t         tsWriteCounter;
    uint64_t         tsHostTime;

    _Atomic uint64_t presentationStallCount;
    _Atomic uint64_t presentationDeltaUnexpectedCount;
    _Atomic uint64_t writeDeadlineMissedCount;
    _Atomic uint64_t silenceFilledGapCount;

    uint8_t reserved[32];

    _Atomic uint32_t mixerTableGeneration;
    /// mach_absolute_time の目盛り。0 = リースなし。
    _Atomic uint64_t mixerControlLeaseDeadlineHostTime;
    _Atomic uint64_t mixerSlotOverflowCount;
    _Atomic uint64_t mixerNeutralizedCount;
    _Atomic uint64_t mixerGainEntryDroppedCount;
    SimpleEQMixerClientSlot mixerClients[kSimpleEQMixerClientSlotCount];

    _Atomic uint32_t ownerProcessID;
    _Atomic uint32_t ownerUID;
    /// mach_absolute_time の目盛り。0 = 所有者なし。
    _Atomic uint64_t ownershipLeaseDeadlineHostTime;
    _Atomic uint32_t ownershipGeneration;

    _Atomic uint32_t requestProcessID;
    _Atomic uint32_t requestUID;
    /// mach_absolute_time の目盛り。0 = 要求なし。
    _Atomic uint64_t ownershipRequestLeaseDeadlineHostTime;
    _Atomic uint32_t ownershipRequestGeneration;
} SimpleEQRingHeader;

#define kSimpleEQRingPageBytes ((uint32_t)16384)
#define kSimpleEQRingHeaderBytes \
    ((uint32_t)(((sizeof(SimpleEQRingHeader) + kSimpleEQRingPageBytes - 1u) / kSimpleEQRingPageBytes) * kSimpleEQRingPageBytes))

static inline float *SimpleEQRingBody(void *inHeader)
{
    const SimpleEQRingHeader *theHeader = (const SimpleEQRingHeader *)inHeader;
    return (float *)((uint8_t *)inHeader + theHeader->headerBytes);
}

typedef struct
{
    uint64_t absolutePosition;
    uint32_t gapFrames;
    uint64_t anchor;
    uint64_t publishedCounter;
    uint64_t presentedFrames;
    bool presentationTimeStalled;
    bool presentationTimeUnexpected;
} SimpleEQRingWritePlan;

static inline SimpleEQRingWritePlan SimpleEQRingComputeWritePlan(
    uint64_t inAnchor, bool inAnchorValid,
    uint64_t inPreviousPresentedFrames, bool inPreviousPresentedFramesValid,
    double inPresentationSampleTime,
    uint64_t inCurrentCounter, uint32_t inRingFrames, uint32_t inFramesThisCycle)
{
    // ここの定数を緩めると、丸めが未定義動作になる値まで通ってしまう。
    bool presentationTimeInvalid = !isfinite(inPresentationSampleTime)
        || inPresentationSampleTime < 0.0
        || inPresentationSampleTime >= 9223372036854775808.0;
    uint64_t presentedFrames = presentationTimeInvalid ? (uint64_t)0 : (uint64_t)llround(inPresentationSampleTime);

    bool reanchoredForInvalidAnchor = !inAnchorValid;
    bool reanchoredForRange = false;
    uint64_t anchor = inAnchor;

    if(!reanchoredForInvalidAnchor)
    {
        uint64_t candidatePosition = anchor + presentedFrames;
        // forwardDistance/backwardDistance は符号なしの巻き戻りを前提にした剰余距離。
        // 素の大小比較に置き換えると壊れる。
        uint64_t forwardDistance = candidatePosition - inCurrentCounter;
        uint64_t backwardDistance = inCurrentCounter - candidatePosition;
        bool outOfRange = presentationTimeInvalid
            || (forwardDistance > inRingFrames && backwardDistance > inRingFrames);
        if(outOfRange) { reanchoredForRange = true; }
    }

    bool didReanchor = reanchoredForInvalidAnchor || reanchoredForRange;
    if(didReanchor)
    {
        // 符号付きの型に寄せると、この式はラップ前提が崩れて未定義動作になる。
        anchor = inCurrentCounter - presentedFrames;
    }
    uint64_t absolutePosition = anchor + presentedFrames;

    uint64_t writtenThroughPosition = absolutePosition + (uint64_t)inFramesThisCycle;
    uint64_t publishedCounter = writtenThroughPosition > inCurrentCounter ? writtenThroughPosition : inCurrentCounter;

    uint64_t forwardGap = absolutePosition - inCurrentCounter;
    uint32_t gapFrames = forwardGap <= (uint64_t)inRingFrames ? (uint32_t)forwardGap : 0;

    bool haveDelta = inPreviousPresentedFramesValid && !presentationTimeInvalid;
    int64_t delta = haveDelta ? (int64_t)presentedFrames - (int64_t)inPreviousPresentedFrames : 0;
    bool presentationTimeStalled = haveDelta && delta == 0 && !didReanchor;
    bool deltaNotMultipleOfFramesThisCycle =
        haveDelta && inFramesThisCycle > 0 && (delta % (int64_t)inFramesThisCycle) != 0;
    bool presentationTimeUnexpected = presentationTimeInvalid
        || reanchoredForRange
        || (haveDelta && delta < 0)
        || deltaNotMultipleOfFramesThisCycle;

    SimpleEQRingWritePlan plan;
    plan.absolutePosition = absolutePosition;
    plan.gapFrames = gapFrames;
    plan.anchor = anchor;
    plan.publishedCounter = publishedCounter;
    plan.presentedFrames = presentedFrames;
    plan.presentationTimeStalled = presentationTimeStalled;
    plan.presentationTimeUnexpected = presentationTimeUnexpected;
    return plan;
}

#endif /* SimpleEQRingLayout_h */
