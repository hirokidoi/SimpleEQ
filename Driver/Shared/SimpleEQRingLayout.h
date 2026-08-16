#ifndef SimpleEQRingLayout_h
#define SimpleEQRingLayout_h

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#define kSimpleEQRingLayoutVersion ((uint32_t)1)

#define kSimpleEQDriverVersionMajor ((uint16_t)1)
#define kSimpleEQDriverVersionMinor ((uint16_t)3)

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
