#ifndef SimpleEQRingLayout_h
#define SimpleEQRingLayout_h

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define kSimpleEQRingLayoutVersion ((uint32_t)2)

#define kSimpleEQDriverVersionMajor ((uint16_t)2)
#define kSimpleEQDriverVersionMinor ((uint16_t)0)

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

// float を整数で運ぶのは、_Atomic float の lock-free 性が実装依存で、リアルタイム経路に
// 暗黙のロックが生じうるため。
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
