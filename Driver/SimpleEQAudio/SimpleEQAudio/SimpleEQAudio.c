#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/syslog.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "SimpleEQRingLayout.h"

//==================================================================================================
#pragma mark -
#pragma mark Macros
//==================================================================================================

#ifndef __MAC_12_0
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#if DEBUG

    #define DebugMsg(inFormat, ...) syslog(LOG_NOTICE, inFormat, ## __VA_ARGS__)

    #define FailIf(inCondition, inHandler, inMessage)                            \
    if(inCondition)                                                              \
    {                                                                            \
        DebugMsg(inMessage);                                                     \
        goto inHandler;                                                          \
    }

    #define FailWithAction(inCondition, inAction, inHandler, inMessage)          \
    if(inCondition)                                                              \
    {                                                                            \
        DebugMsg(inMessage);                                                     \
        { inAction; }                                                            \
        goto inHandler;                                                          \
    }

#else

    #define DebugMsg(inFormat, ...)

    #define FailIf(inCondition, inHandler, inMessage)                           \
    if(inCondition)                                                             \
    {                                                                           \
        goto inHandler;                                                        \
    }

    #define FailWithAction(inCondition, inAction, inHandler, inMessage)         \
    if(inCondition)                                                            \
    {                                                                          \
        { inAction; }                                                         \
        goto inHandler;                                                       \
    }

#endif

//==================================================================================================
#pragma mark -
#pragma mark SimpleEQAudio State
//==================================================================================================

enum
{
    kObjectID_PlugIn               = kAudioObjectPlugInObject,
    kObjectID_Box                  = 2,
    kObjectID_Device                = 3,
    kObjectID_Stream_Output         = 4,
    kObjectID_Volume_Output_Master  = 5,
    kObjectID_Mute_Output_Master    = 6,
};

enum
{
    ChangeAction_SetSampleRate = 1,
};

enum ObjectType
{
    kObjectType_Stream,
    kObjectType_Control
};

struct ObjectInfo
{
    AudioObjectID             id;
    enum ObjectType           type;
    AudioObjectPropertyScope  scope;
};

#define kPlugIn_BundleID "com.hirokidoi.simpleeq.driver"

#define kPlugIn_Icon "SimpleEQAudio.icns"

#define kBox_UID  "SimpleEQAudioBox_UID"
#define kDevice_ModelUID "SimpleEQAudio" kSimpleEQ_STRINGIFY(kSimpleEQRingChannelsValue) "ch_ModelUID"

#define kManufacturer_Name "SimpleEQ"

#define kNumber_Of_Channels kSimpleEQRingChannelsValue
#define kBits_Per_Channel  32
#define kBytes_Per_Channel (kBits_Per_Channel / 8)
#define kBytes_Per_Frame   (kNumber_Of_Channels * kBytes_Per_Channel)
#define kSafetyMargin_Frame_Size 0

#define kCanBeDefaultDevice       true
#define kCanBeDefaultSystemDevice true

static pthread_mutex_t          gPlugIn_StateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32                   gPlugIn_RefCount   = 0;
static AudioServerPlugInHostRef gPlugIn_Host       = NULL;

static CFStringRef gBox_Name     = NULL;
static Boolean     gBox_Acquired = true;

static Boolean     gDevice_IsHidden     = true;
static CFStringRef gDevice_NameOverride = NULL;

static pthread_mutex_t gDevice_IOMutex = PTHREAD_MUTEX_INITIALIZER;

static Float64 gDevice_SampleRate          = 48000.0;
static Float64 gDevice_RequestedSampleRate = 0.0;
static UInt64  gDevice_IOIsRunning         = 0;

static Float64 gDevice_AdjustedTicksPerFrame = 0.0;
static Float64 gDevice_PreviousTicks         = 0.0;
static UInt64  gDevice_NumberTimeStamps      = 0;
static UInt64  gDevice_AnchorHostTime        = 0;

static bool gStream_Output_IsActive = true;

static Float32 gVolume_Master_Value = 1.0;
static bool    gMute_Master_Value   = false;

static Float64 gDriftCompositionPpm = 0.0;

static const struct ObjectInfo kDevice_ObjectList[] = {
    { kObjectID_Stream_Output,        kObjectType_Stream,  kAudioObjectPropertyScopeOutput },
    { kObjectID_Volume_Output_Master, kObjectType_Control, kAudioObjectPropertyScopeOutput },
    { kObjectID_Mute_Output_Master,   kObjectType_Control, kAudioObjectPropertyScopeOutput },
};
static const UInt32 kDevice_ObjectListSize = sizeof(kDevice_ObjectList) / sizeof(struct ObjectInfo);

static const Float64 kDevice_SampleRates[]     = { 44100.0, 48000.0, 88200.0, 96000.0 };
static const UInt32  kDevice_SampleRatesSize   = sizeof(kDevice_SampleRates) / sizeof(Float64);

//==================================================================================================
#pragma mark -
#pragma mark SimpleEQ Shared Memory
//==================================================================================================

static SimpleEQRingHeader *gSimpleEQRing_Header = NULL;
static float              *gSimpleEQRing_Body   = NULL;
static UInt32               gSimpleEQRing_Frames = 0;
static int                  gSimpleEQRing_Fd     = -1;

static uint64_t gWriteAnchor                      = 0;
static bool     gWriteAnchorValid                 = false;
static uint64_t gWritePreviousPresentedFrames      = 0;
static bool     gWritePreviousPresentedFramesValid = false;
static uint32_t gWriteLastObservedEpoch            = 0;
static bool     gWriteLastObservedEpochValid       = false;

#define kRingBaseSampleRate    ((Float64)48000.0)
#define kRingTargetFramesAtBase ((uint32_t)16384)

static UInt32 SimpleEQRing_ComputeRingFrames(void)
{
    Float64 theMaxRate = kDevice_SampleRates[0];
    for(UInt32 i = 1; i < kDevice_SampleRatesSize; i++)
    {
        if(kDevice_SampleRates[i] > theMaxRate)
        {
            theMaxRate = kDevice_SampleRates[i];
        }
    }
    Float64 theTargetSeconds = (Float64)kRingTargetFramesAtBase / kRingBaseSampleRate;
    return (UInt32)ceil(theMaxRate * theTargetSeconds);
}

static void SimpleEQRing_Init(void)
{
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s", kSimpleEQRingDirectoryPath, kSimpleEQRingFileName);

    int fd = open(path, O_CREAT | O_RDWR, 0666);
    if(fd < 0)
    {
        DebugMsg("SimpleEQRing_Init: open(%s) failed errno=%d", path, errno);
        return;
    }

    UInt32 theRingFrames = SimpleEQRing_ComputeRingFrames();
    size_t theTotalBytes = (size_t)kSimpleEQRingHeaderBytes
                          + (size_t)theRingFrames * kSimpleEQRingChannelsValue * sizeof(float);

    if(ftruncate(fd, (off_t)theTotalBytes) != 0)
    {
        DebugMsg("SimpleEQRing_Init: ftruncate failed errno=%d", errno);
        close(fd);
        return;
    }

    void *theMappedMemory = mmap(NULL, theTotalBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if(theMappedMemory == MAP_FAILED)
    {
        DebugMsg("SimpleEQRing_Init: mmap failed errno=%d", errno);
        close(fd);
        return;
    }

    gSimpleEQRing_Fd     = fd;
    gSimpleEQRing_Header = (SimpleEQRingHeader *)theMappedMemory;
    gSimpleEQRing_Frames = theRingFrames;

    atomic_store_explicit(&gSimpleEQRing_Header->magic, 0, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);

    gSimpleEQRing_Header->layoutVersion = kSimpleEQRingLayoutVersion;
    gSimpleEQRing_Header->driverVersionMajor = kSimpleEQDriverVersionMajor;
    gSimpleEQRing_Header->driverVersionMinor = kSimpleEQDriverVersionMinor;
    gSimpleEQRing_Header->headerBytes   = kSimpleEQRingHeaderBytes;
    gSimpleEQRing_Header->ringFrames    = theRingFrames;
    gSimpleEQRing_Header->channels      = kSimpleEQRingChannels;
    gSimpleEQRing_Header->sampleRate    = gDevice_SampleRate;
    atomic_store_explicit(&gSimpleEQRing_Header->ioCycleFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->writeCounter, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->epoch, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->writerIOIsRunning, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->tsSeq, 0, memory_order_relaxed);
    gSimpleEQRing_Header->tsWriteCounter = 0;
    gSimpleEQRing_Header->tsHostTime     = 0;
    atomic_store_explicit(&gSimpleEQRing_Header->presentationStallCount, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->presentationDeltaUnexpectedCount, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->writeDeadlineMissedCount, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->silenceFilledGapCount, 0, memory_order_relaxed);
    memset(gSimpleEQRing_Header->reserved, 0, sizeof(gSimpleEQRing_Header->reserved));
    atomic_store_explicit(&gSimpleEQRing_Header->mixerTableGeneration, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->mixerControlLeaseDeadlineHostTime, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->mixerSlotOverflowCount, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->mixerNeutralizedCount, 0, memory_order_relaxed);
    atomic_store_explicit(&gSimpleEQRing_Header->mixerGainEntryDroppedCount, 0, memory_order_relaxed);
    memset(gSimpleEQRing_Header->mixerClients, 0, sizeof(gSimpleEQRing_Header->mixerClients));

    gSimpleEQRing_Body = SimpleEQRingBody(theMappedMemory);

    atomic_store_explicit(&gSimpleEQRing_Header->magic, kSimpleEQRingMagic, memory_order_release);
}

static void SimpleEQRing_WriteWrapped(float *inBody, UInt32 inRingFrames, uint64_t inStartPos,
                                       const float *inSrc, UInt32 inFrameCount)
{
    uint32_t theStartIndex = (uint32_t)(inStartPos % inRingFrames);
    uint32_t theFirstPartFrames = inRingFrames - theStartIndex;
    if(theFirstPartFrames > inFrameCount) { theFirstPartFrames = inFrameCount; }

    float *theFirstDst = inBody + (size_t)theStartIndex * kSimpleEQRingChannelsValue;
    size_t theFirstBytes = (size_t)theFirstPartFrames * kSimpleEQRingChannelsValue * sizeof(float);
    if(inSrc != NULL) { memcpy(theFirstDst, inSrc, theFirstBytes); } else { memset(theFirstDst, 0, theFirstBytes); }

    if(theFirstPartFrames < inFrameCount)
    {
        size_t theRestBytes = (size_t)(inFrameCount - theFirstPartFrames) * kSimpleEQRingChannelsValue * sizeof(float);
        if(inSrc != NULL)
        {
            memcpy(inBody, inSrc + (size_t)theFirstPartFrames * kSimpleEQRingChannelsValue, theRestBytes);
        }
        else
        {
            memset(inBody, 0, theRestBytes);
        }
    }
}

static void RecordDeadlineMissedSkip(void)
{
    if(gSimpleEQRing_Header == NULL) { return; }
    atomic_fetch_add_explicit(&gSimpleEQRing_Header->writeDeadlineMissedCount, 1, memory_order_relaxed);
}

static void SimpleEQRing_PublishTimeSnapshot(SimpleEQRingHeader *inHeader, uint64_t inWriteCounter,
                                              uint64_t inHostTime)
{
    atomic_fetch_add_explicit(&inHeader->tsSeq, 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    inHeader->tsWriteCounter = inWriteCounter;
    inHeader->tsHostTime     = inHostTime;
    atomic_fetch_add_explicit(&inHeader->tsSeq, 1, memory_order_release);
}

static void SimpleEQRing_WriteAudio(const float *inInterleaved, UInt32 inFrames, Float64 inPresentationSampleTime)
{
    SimpleEQRingHeader *theHeader = gSimpleEQRing_Header;
    if(theHeader == NULL || gSimpleEQRing_Body == NULL || gSimpleEQRing_Frames == 0) { return; }
    if(inFrames > gSimpleEQRing_Frames) { return; }

    uint32_t theCurrentEpoch = atomic_load_explicit(&theHeader->epoch, memory_order_relaxed);
    if(!gWriteLastObservedEpochValid || theCurrentEpoch != gWriteLastObservedEpoch)
    {
        gWriteAnchorValid = false;
        gWritePreviousPresentedFramesValid = false;
    }
    gWriteLastObservedEpoch = theCurrentEpoch;
    gWriteLastObservedEpochValid = true;

    uint64_t theCounter = atomic_load_explicit(&theHeader->writeCounter, memory_order_relaxed);

    SimpleEQRingWritePlan thePlan = SimpleEQRingComputeWritePlan(
        gWriteAnchor, gWriteAnchorValid,
        gWritePreviousPresentedFrames, gWritePreviousPresentedFramesValid,
        inPresentationSampleTime, theCounter, gSimpleEQRing_Frames, inFrames
    );
    gWriteAnchor = thePlan.anchor;
    gWriteAnchorValid = true;
    gWritePreviousPresentedFrames = thePlan.presentedFrames;
    gWritePreviousPresentedFramesValid = true;

    if(thePlan.gapFrames > 0)
    {
        SimpleEQRing_WriteWrapped(gSimpleEQRing_Body, gSimpleEQRing_Frames, theCounter, NULL,
                                   thePlan.gapFrames);
        atomic_fetch_add_explicit(&theHeader->silenceFilledGapCount, 1, memory_order_relaxed);
    }

    SimpleEQRing_WriteWrapped(gSimpleEQRing_Body, gSimpleEQRing_Frames, thePlan.absolutePosition, inInterleaved, inFrames);

    atomic_store_explicit(&theHeader->writeCounter, thePlan.publishedCounter, memory_order_release);

    SimpleEQRing_PublishTimeSnapshot(theHeader, thePlan.publishedCounter, mach_absolute_time());

    atomic_store_explicit(&theHeader->ioCycleFrames, inFrames, memory_order_relaxed);

    if(thePlan.presentationTimeStalled)
    {
        atomic_fetch_add_explicit(&theHeader->presentationStallCount, 1, memory_order_relaxed);
    }
    if(thePlan.presentationTimeUnexpected)
    {
        atomic_fetch_add_explicit(&theHeader->presentationDeltaUnexpectedCount, 1, memory_order_relaxed);
    }
}

//==================================================================================================
#pragma mark -
#pragma mark SimpleEQ Mixer
//==================================================================================================

// どちらも実測値。2 つは独立で、片方の根拠をもう片方へ流用しない。
#define kMixer_GainRampSeconds    ((Float64)0.010)
#define kMixer_SilenceRampSeconds ((Float64)0.030)

typedef struct
{
    char  matchKey[kSimpleEQMixerMatchKeyMaxBytes];
    float gain;
} MixerGainEntry;

static pthread_mutex_t gMixer_TableMutex = PTHREAD_MUTEX_INITIALIZER;
static MixerGainEntry  gMixer_GainTable[kSimpleEQMixerGainEntryMax];
static UInt32          gMixer_GainTableCount = 0;

static _Atomic uint32_t gMixer_SlotTargetGainBits[kSimpleEQMixerClientSlotCount];
static float            gMixer_SlotCurrentGain[kSimpleEQMixerClientSlotCount];

static _Atomic uint32_t gMixer_GainRampStepBits    = 0;
static _Atomic uint32_t gMixer_SilenceRampStepBits = 0;

static Float64 gMixer_HostTicksPerSecond = 0.0;

static void SimpleEQMixer_Init(void)
{
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    gMixer_HostTicksPerSecond = ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1000000000.0;

    for(uint32_t i = 0; i < kSimpleEQMixerClientSlotCount; i++)
    {
        atomic_store_explicit(&gMixer_SlotTargetGainBits[i], SimpleEQMixerFloatToBits(1.0f), memory_order_relaxed);
        gMixer_SlotCurrentGain[i] = 1.0f;
    }
}

static void SimpleEQMixer_RecalculateRampSteps(Float64 inSampleRate)
{
    Float64 theGainStep    = 1.0 / (kMixer_GainRampSeconds * inSampleRate);
    Float64 theSilenceStep = 1.0 / (kMixer_SilenceRampSeconds * inSampleRate);
    atomic_store_explicit(&gMixer_GainRampStepBits, SimpleEQMixerFloatToBits((float)theGainStep), memory_order_relaxed);
    atomic_store_explicit(&gMixer_SilenceRampStepBits, SimpleEQMixerFloatToBits((float)theSilenceStep), memory_order_relaxed);
}

static bool SimpleEQMixer_LeaseIsArmed(SimpleEQRingHeader *inHeader)
{
    uint64_t theDeadline = atomic_load_explicit(&inHeader->mixerControlLeaseDeadlineHostTime, memory_order_acquire);
    if(theDeadline == 0) { return false; }
    if(mach_absolute_time() < theDeadline) { return true; }

    // 数えるのは非 0 から 0 への交換に成功したときだけ。0 から 0 の交換は毎サイクル成功するため、
    // 数えると「リース失効で戻した回数」という診断の意味が失われる。
    uint64_t theExpected = theDeadline;
    if(atomic_compare_exchange_strong_explicit(&inHeader->mixerControlLeaseDeadlineHostTime,
                                                &theExpected, 0,
                                                memory_order_acq_rel, memory_order_relaxed))
    {
        atomic_fetch_add_explicit(&inHeader->mixerNeutralizedCount, 1, memory_order_relaxed);
    }
    return false;
}

static float SimpleEQMixer_LookupGain_Locked(const char *inBundleID, uint32_t inProcessID)
{
    char theKey[kSimpleEQMixerMatchKeyMaxBytes];
    if(!SimpleEQMixerBuildMatchKey(theKey, sizeof(theKey), inBundleID, inProcessID)) { return 1.0f; }

    for(UInt32 i = 0; i < gMixer_GainTableCount; i++)
    {
        if(strcmp(gMixer_GainTable[i].matchKey, theKey) == 0) { return gMixer_GainTable[i].gain; }
    }
    return 1.0f;
}

static void SimpleEQMixer_AcquireSlot(const AudioServerPlugInClientInfo *inClientInfo)
{
    SimpleEQRingHeader *theHeader = gSimpleEQRing_Header;
    if(theHeader == NULL || inClientInfo == NULL) { return; }

    uint32_t theClientID = (uint32_t)inClientInfo->mClientID;

    char theBundleID[kSimpleEQMixerBundleIDMaxBytes];
    memset(theBundleID, 0, sizeof(theBundleID));
    if(inClientInfo->mBundleID != NULL
       && !CFStringGetCString(inClientInfo->mBundleID, theBundleID, sizeof(theBundleID), kCFStringEncodingUTF8))
    {
        // 収まらないバンドル ID は切り詰めず空文字にする。スロットの値を「完全な値か空文字か」の
        // どちらかに閉じることで、ドライバとアプリが同じ入力から同じ鍵を得ることを構造で保証する。
        memset(theBundleID, 0, sizeof(theBundleID));
    }

    pthread_mutex_lock(&gMixer_TableMutex);

    uint32_t theSlotIndex = kSimpleEQMixerClientSlotCount;
    // 識別値 0 は空きの印なので、0 を名乗るクライアントには席を用意できない。
    if(theClientID != 0)
    {
        for(uint32_t i = 0; i < kSimpleEQMixerClientSlotCount; i++)
        {
            if(atomic_load_explicit(&theHeader->mixerClients[i].clientID, memory_order_relaxed) == 0)
            {
                theSlotIndex = i;
                break;
            }
        }
    }

    if(theSlotIndex == kSimpleEQMixerClientSlotCount)
    {
        pthread_mutex_unlock(&gMixer_TableMutex);
        atomic_fetch_add_explicit(&theHeader->mixerSlotOverflowCount, 1, memory_order_relaxed);
        return;
    }

    SimpleEQMixerClientSlot *theSlot = &theHeader->mixerClients[theSlotIndex];
    theSlot->processID = (uint32_t)inClientInfo->mProcessID;
    memcpy(theSlot->bundleID, theBundleID, sizeof(theSlot->bundleID));
    // ここで 0 へ戻すことで、「席を取ってから一度でも音を出したか」が outputCycleSeq != 0 だけで読める。
    atomic_store_explicit(&theSlot->outputCycleSeq, 0, memory_order_relaxed);
    atomic_store_explicit(&theSlot->clipEventCount, 0, memory_order_relaxed);
    atomic_store_explicit(&theSlot->lastCyclePeakBits, SimpleEQMixerFloatToBits(0.0f), memory_order_relaxed);

    // リースが立っていない間の目標は 1.0。押し込んだ側が居ないのに保存された表が効くと、
    // 席を取った瞬間だけ古いゲインが乗る。
    float theGain = SimpleEQMixer_LeaseIsArmed(theHeader)
        ? SimpleEQMixer_LookupGain_Locked(theBundleID, theSlot->processID)
        : 1.0f;
    // まだ 1 サンプルも出していないクライアントに継ぎ目は無い。ランプを掛けると
    // 「既定ゲインで始まる窓」を自分で作ることになるので、現在ゲインも目標へ揃える。
    atomic_store_explicit(&gMixer_SlotTargetGainBits[theSlotIndex], SimpleEQMixerFloatToBits(theGain), memory_order_relaxed);
    gMixer_SlotCurrentGain[theSlotIndex] = theGain;
    atomic_store_explicit(&theSlot->appliedGainBits, SimpleEQMixerFloatToBits(theGain), memory_order_relaxed);

    atomic_store_explicit(&theSlot->clientID, theClientID, memory_order_release);
    atomic_fetch_add_explicit(&theHeader->mixerTableGeneration, 1, memory_order_relaxed);

    pthread_mutex_unlock(&gMixer_TableMutex);
}

static void SimpleEQMixer_ReleaseSlot(const AudioServerPlugInClientInfo *inClientInfo)
{
    SimpleEQRingHeader *theHeader = gSimpleEQRing_Header;
    if(theHeader == NULL || inClientInfo == NULL) { return; }

    uint32_t theClientID = (uint32_t)inClientInfo->mClientID;
    if(theClientID == 0) { return; }

    pthread_mutex_lock(&gMixer_TableMutex);
    for(uint32_t i = 0; i < kSimpleEQMixerClientSlotCount; i++)
    {
        SimpleEQMixerClientSlot *theSlot = &theHeader->mixerClients[i];
        if(atomic_load_explicit(&theSlot->clientID, memory_order_relaxed) == theClientID)
        {
            atomic_store_explicit(&theSlot->clientID, 0, memory_order_release);
            atomic_fetch_add_explicit(&theHeader->mixerTableGeneration, 1, memory_order_relaxed);
            break;
        }
    }
    pthread_mutex_unlock(&gMixer_TableMutex);
}

static void SimpleEQMixer_ProcessOutput(UInt32 inClientID, float *ioBuffer, UInt32 inFrameCount)
{
    SimpleEQRingHeader *theHeader = gSimpleEQRing_Header;
    if(theHeader == NULL || ioBuffer == NULL || inFrameCount == 0 || inClientID == 0) { return; }

    // クライアント ID は Host 採番で添字に使えない。
    uint32_t theSlotIndex = kSimpleEQMixerClientSlotCount;
    for(uint32_t i = 0; i < kSimpleEQMixerClientSlotCount; i++)
    {
        if(atomic_load_explicit(&theHeader->mixerClients[i].clientID, memory_order_acquire) == inClientID)
        {
            theSlotIndex = i;
            break;
        }
    }
    if(theSlotIndex == kSimpleEQMixerClientSlotCount) { return; }

    SimpleEQMixerClientSlot *theSlot = &theHeader->mixerClients[theSlotIndex];
    size_t theSampleCount = (size_t)inFrameCount * kSimpleEQRingChannelsValue;

    float thePeak = 0.0f;
    for(size_t i = 0; i < theSampleCount; i++)
    {
        float theMagnitude = fabsf(ioBuffer[i]);
        if(theMagnitude > thePeak) { thePeak = theMagnitude; }
    }
    atomic_store_explicit(&theSlot->lastCyclePeakBits, SimpleEQMixerFloatToBits(thePeak), memory_order_relaxed);
    if(thePeak >= 1.0f)
    {
        atomic_fetch_add_explicit(&theSlot->clipEventCount, 1, memory_order_relaxed);
    }

    // 期限を先に読むことで、リースが見えているときは目標ゲインも見えている。
    float theTargetGain = 1.0f;
    if(SimpleEQMixer_LeaseIsArmed(theHeader))
    {
        theTargetGain = SimpleEQMixerFloatFromBits(
            atomic_load_explicit(&gMixer_SlotTargetGainBits[theSlotIndex], memory_order_relaxed));
    }

    float theCurrentGain = gMixer_SlotCurrentGain[theSlotIndex];
    bool theSilenceSeam = (theTargetGain <= 0.0f) || (theCurrentGain <= 0.0f);
    float theStep = SimpleEQMixerFloatFromBits(atomic_load_explicit(
        theSilenceSeam ? &gMixer_SilenceRampStepBits : &gMixer_GainRampStepBits, memory_order_relaxed));

    for(UInt32 theFrame = 0; theFrame < inFrameCount; theFrame++)
    {
        if(theCurrentGain < theTargetGain)
        {
            theCurrentGain += theStep;
            if(theCurrentGain > theTargetGain) { theCurrentGain = theTargetGain; }
        }
        else if(theCurrentGain > theTargetGain)
        {
            theCurrentGain -= theStep;
            if(theCurrentGain < theTargetGain) { theCurrentGain = theTargetGain; }
        }

        float *theSamples = ioBuffer + (size_t)theFrame * kSimpleEQRingChannelsValue;
        for(UInt32 theChannel = 0; theChannel < kSimpleEQRingChannelsValue; theChannel++)
        {
            theSamples[theChannel] *= theCurrentGain;
        }
    }

    gMixer_SlotCurrentGain[theSlotIndex] = theCurrentGain;
    atomic_store_explicit(&theSlot->appliedGainBits, SimpleEQMixerFloatToBits(theCurrentGain), memory_order_relaxed);

    // 0 は「まだ鳴っていない」の印なので、巻き戻っても 0 にしない。
    uint32_t theNextSeq = atomic_load_explicit(&theSlot->outputCycleSeq, memory_order_relaxed) + 1;
    if(theNextSeq == 0) { theNextSeq = 1; }
    atomic_store_explicit(&theSlot->outputCycleSeq, theNextSeq, memory_order_relaxed);
}

typedef struct
{
    MixerGainEntry entries[kSimpleEQMixerGainEntryMax];
    UInt32         count;
    UInt64         dropped;
    bool           hasNonNeutral;
} MixerGainTableBuild;

static void SimpleEQMixer_GainTableApplier(const void *inKey, const void *inValue, void *inContext)
{
    MixerGainTableBuild *theBuild = (MixerGainTableBuild *)inContext;

    if(inKey == NULL || CFGetTypeID(inKey) != CFStringGetTypeID()
       || inValue == NULL || CFGetTypeID(inValue) != CFNumberGetTypeID()
       || theBuild->count >= kSimpleEQMixerGainEntryMax)
    {
        theBuild->dropped += 1;
        return;
    }

    char theKey[kSimpleEQMixerMatchKeyMaxBytes];
    memset(theKey, 0, sizeof(theKey));
    if(!CFStringGetCString((CFStringRef)inKey, theKey, sizeof(theKey), kCFStringEncodingUTF8))
    {
        theBuild->dropped += 1;
        return;
    }

    Float64 theGain = 0.0;
    if(!CFNumberGetValue((CFNumberRef)inValue, kCFNumberDoubleType, &theGain) || !isfinite(theGain))
    {
        theBuild->dropped += 1;
        return;
    }

    // 上限が 1.0 であることが「減衰のみ」という要件そのもの。
    if(theGain < 0.0) { theGain = 0.0; }
    if(theGain > 1.0) { theGain = 1.0; }

    memcpy(theBuild->entries[theBuild->count].matchKey, theKey, sizeof(theKey));
    theBuild->entries[theBuild->count].gain = (float)theGain;
    theBuild->count += 1;
    if(theGain < 1.0) { theBuild->hasNonNeutral = true; }
}

static void SimpleEQMixer_ApplyGainTable(CFDictionaryRef inTable)
{
    SimpleEQRingHeader *theHeader = gSimpleEQRing_Header;
    if(theHeader == NULL) { return; }

    MixerGainTableBuild theBuild;
    memset(&theBuild, 0, sizeof(theBuild));
    CFDictionaryApplyFunction(inTable, SimpleEQMixer_GainTableApplier, &theBuild);

    pthread_mutex_lock(&gMixer_TableMutex);

    memcpy(gMixer_GainTable, theBuild.entries, sizeof(gMixer_GainTable));
    gMixer_GainTableCount = theBuild.count;

    for(uint32_t i = 0; i < kSimpleEQMixerClientSlotCount; i++)
    {
        SimpleEQMixerClientSlot *theSlot = &theHeader->mixerClients[i];
        if(atomic_load_explicit(&theSlot->clientID, memory_order_acquire) == 0) { continue; }

        float theGain = SimpleEQMixer_LookupGain_Locked(theSlot->bundleID, theSlot->processID);
        atomic_store_explicit(&gMixer_SlotTargetGainBits[i], SimpleEQMixerFloatToBits(theGain), memory_order_relaxed);
    }

    pthread_mutex_unlock(&gMixer_TableMutex);

    if(theBuild.dropped > 0)
    {
        atomic_fetch_add_explicit(&theHeader->mixerGainEntryDroppedCount, theBuild.dropped, memory_order_relaxed);
    }

    if(theBuild.hasNonNeutral)
    {
        // 目標ゲインを全部書き終えてから release でリースを張る。リースが見えているのに目標ゲインが
        // 古い、という観測を作らない。
        uint64_t theDeadline = mach_absolute_time()
            + (uint64_t)(kSimpleEQMixerControlLeaseSeconds * gMixer_HostTicksPerSecond);
        atomic_store_explicit(&theHeader->mixerControlLeaseDeadlineHostTime, theDeadline, memory_order_release);
    }
    else
    {
        atomic_store_explicit(&theHeader->mixerControlLeaseDeadlineHostTime, 0, memory_order_release);
    }
}

static CFDictionaryRef SimpleEQMixer_CopyGainTable(void)
{
    MixerGainEntry theEntries[kSimpleEQMixerGainEntryMax];
    UInt32 theCount;

    pthread_mutex_lock(&gMixer_TableMutex);
    theCount = gMixer_GainTableCount;
    memcpy(theEntries, gMixer_GainTable, sizeof(theEntries));
    pthread_mutex_unlock(&gMixer_TableMutex);

    CFMutableDictionaryRef theTable = CFDictionaryCreateMutable(NULL, (CFIndex)theCount,
                                                                &kCFTypeDictionaryKeyCallBacks,
                                                                &kCFTypeDictionaryValueCallBacks);
    if(theTable == NULL) { return NULL; }

    for(UInt32 i = 0; i < theCount; i++)
    {
        CFStringRef theKey = CFStringCreateWithCString(NULL, theEntries[i].matchKey, kCFStringEncodingUTF8);
        Float64 theGain = (Float64)theEntries[i].gain;
        CFNumberRef theValue = CFNumberCreate(NULL, kCFNumberDoubleType, &theGain);
        if(theKey != NULL && theValue != NULL) { CFDictionarySetValue(theTable, theKey, theValue); }
        if(theKey != NULL) { CFRelease(theKey); }
        if(theValue != NULL) { CFRelease(theValue); }
    }
    return theTable;
}

//==================================================================================================
#pragma mark -
#pragma mark Helpers
//==================================================================================================

static Float32 VolumeToDecibel(Float32 inVolume)
{
    if(inVolume <= powf(10.0f, kSimpleEQVolumeMinDB / 20.0f)) { return kSimpleEQVolumeMinDB; }
    return 20.0f * log10f(inVolume);
}

static Float32 VolumeFromDecibel(Float32 inDecibel)
{
    if(inDecibel <= kSimpleEQVolumeMinDB) { return 0.0f; }
    return powf(10.0f, inDecibel / 20.0f);
}

static Float32 VolumeToScalar(Float32 inVolume)
{
    Float32 theDecibel = VolumeToDecibel(inVolume);
    return (theDecibel - kSimpleEQVolumeMinDB) / (kSimpleEQVolumeMaxDB - kSimpleEQVolumeMinDB);
}

static Float32 VolumeFromScalar(Float32 inScalar)
{
    Float32 theDecibel = inScalar * (kSimpleEQVolumeMaxDB - kSimpleEQVolumeMinDB) + kSimpleEQVolumeMinDB;
    return VolumeFromDecibel(theDecibel);
}

static bool IsValidSampleRate(Float64 inSampleRate)
{
    for(UInt32 i = 0; i < kDevice_SampleRatesSize; i++)
    {
        if(inSampleRate == kDevice_SampleRates[i]) { return true; }
    }
    return false;
}

static void RecalculateTicksPerFrame_Locked(void)
{
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
    theHostClockFrequency *= 1000000000.0;
    Float64 theHostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
    pthread_mutex_lock(&gDevice_IOMutex);
    gDevice_AdjustedTicksPerFrame = theHostTicksPerFrame * (1.0 - gDriftCompositionPpm * 1e-6);
    pthread_mutex_unlock(&gDevice_IOMutex);
    SimpleEQMixer_RecalculateRampSteps(gDevice_SampleRate);
}

typedef Boolean (*ObjectPredicate)(const struct ObjectInfo *inInfo, AudioObjectPropertyScope inScope);

static Boolean IsStreamInScope(const struct ObjectInfo *inInfo, AudioObjectPropertyScope inScope)
{
    return (inInfo->type == kObjectType_Stream)
        && (inInfo->scope == inScope || inScope == kAudioObjectPropertyScopeGlobal);
}

static Boolean IsControlInScope(const struct ObjectInfo *inInfo, AudioObjectPropertyScope inScope)
{
    return (inInfo->type == kObjectType_Control)
        && (inInfo->scope == inScope || inScope == kAudioObjectPropertyScopeGlobal);
}

static Boolean IsAnyInScope(const struct ObjectInfo *inInfo, AudioObjectPropertyScope inScope)
{
    return (inInfo->scope == inScope || inScope == kAudioObjectPropertyScopeGlobal);
}

static UInt32 WalkDeviceObjectList(ObjectPredicate inPredicate, AudioObjectPropertyScope inScope,
                                    AudioObjectID *outIDs, UInt32 inMaxIDsToWrite)
{
    UInt32 theMatched = 0;
    for(UInt32 i = 0; i < kDevice_ObjectListSize; i++)
    {
        if(inPredicate(&kDevice_ObjectList[i], inScope))
        {
            if(outIDs != NULL && theMatched < inMaxIDsToWrite)
            {
                outIDs[theMatched] = kDevice_ObjectList[i].id;
            }
            theMatched++;
        }
    }
    return theMatched;
}

static CFStringRef CurrentDeviceName_Locked(void)
{
    // オーバーライドは差し替わりうるため +1 で返す。
    return (CFStringRef)CFRetain(gDevice_NameOverride != NULL ? gDevice_NameOverride : CFSTR(kSimpleEQDeviceName));
}

//==================================================================================================
#pragma mark -
#pragma mark AudioServerPlugInDriverInterface Implementation
//==================================================================================================

#pragma mark Prototypes

void*           SimpleEQAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
static HRESULT  SimpleEQAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    SimpleEQAudio_AddRef(void* inDriver);
static ULONG    SimpleEQAudio_Release(void* inDriver);
static OSStatus SimpleEQAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SimpleEQAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus SimpleEQAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SimpleEQAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SimpleEQAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SimpleEQAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus SimpleEQAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  SimpleEQAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SimpleEQAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SimpleEQAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SimpleEQAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SimpleEQAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus SimpleEQAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SimpleEQAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SimpleEQAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus SimpleEQAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus SimpleEQAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus SimpleEQAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus SimpleEQAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static Boolean  SimpleEQAudio_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SimpleEQAudio_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SimpleEQAudio_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SimpleEQAudio_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SimpleEQAudio_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean  SimpleEQAudio_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SimpleEQAudio_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SimpleEQAudio_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SimpleEQAudio_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SimpleEQAudio_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean  SimpleEQAudio_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SimpleEQAudio_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SimpleEQAudio_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SimpleEQAudio_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SimpleEQAudio_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean  SimpleEQAudio_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SimpleEQAudio_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SimpleEQAudio_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SimpleEQAudio_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SimpleEQAudio_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean  SimpleEQAudio_HasControlProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SimpleEQAudio_IsControlPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SimpleEQAudio_GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SimpleEQAudio_GetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SimpleEQAudio_SetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

#pragma mark The Interface

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface =
{
    NULL,
    SimpleEQAudio_QueryInterface,
    SimpleEQAudio_AddRef,
    SimpleEQAudio_Release,
    SimpleEQAudio_Initialize,
    SimpleEQAudio_CreateDevice,
    SimpleEQAudio_DestroyDevice,
    SimpleEQAudio_AddDeviceClient,
    SimpleEQAudio_RemoveDeviceClient,
    SimpleEQAudio_PerformDeviceConfigurationChange,
    SimpleEQAudio_AbortDeviceConfigurationChange,
    SimpleEQAudio_HasProperty,
    SimpleEQAudio_IsPropertySettable,
    SimpleEQAudio_GetPropertyDataSize,
    SimpleEQAudio_GetPropertyData,
    SimpleEQAudio_SetPropertyData,
    SimpleEQAudio_StartIO,
    SimpleEQAudio_StopIO,
    SimpleEQAudio_GetZeroTimeStamp,
    SimpleEQAudio_WillDoIOOperation,
    SimpleEQAudio_BeginIOOperation,
    SimpleEQAudio_DoIOOperation,
    SimpleEQAudio_EndIOOperation
};
static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef        gAudioServerPlugInDriverRef          = &gAudioServerPlugInDriverInterfacePtr;

#pragma mark Factory

void* SimpleEQAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
        theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

#pragma mark Inheritance

static HRESULT SimpleEQAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    HRESULT theAnswer = 0;
    CFUUIDRef theRequestedUUID = NULL;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_QueryInterface: bad driver reference");
    FailWithAction(outInterface == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_QueryInterface: no place to store the returned interface");

    theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    FailWithAction(theRequestedUUID == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_QueryInterface: failed to create the CFUUIDRef");

    if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
    }
    else
    {
        theAnswer = E_NOINTERFACE;
    }

    CFRelease(theRequestedUUID);

Done:
    return theAnswer;
}

static ULONG SimpleEQAudio_AddRef(void* inDriver)
{
    ULONG theAnswer = 0;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_AddRef: bad driver reference");

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount < UINT32_MAX) { ++gPlugIn_RefCount; }
    theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

static ULONG SimpleEQAudio_Release(void* inDriver)
{
    ULONG theAnswer = 0;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_Release: bad driver reference");

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount > 0) { --gPlugIn_RefCount; }
    theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

#pragma mark Basic Operations

static OSStatus SimpleEQAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    OSStatus theAnswer = 0;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_Initialize: bad driver reference");

    gPlugIn_Host = inHost;

    SimpleEQMixer_Init();
    SimpleEQRing_Init();

    gBox_Name = CFSTR("SimpleEQ Audio Box");

    pthread_mutex_lock(&gPlugIn_StateMutex);
    RecalculateTicksPerFrame_Locked();
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDescription, inClientInfo, outDeviceObjectID)
    OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_CreateDevice: bad driver reference");
Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    #pragma unused(inDeviceObjectID)
    OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_DestroyDevice: bad driver reference");
Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_AddDeviceClient: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_AddDeviceClient: bad device ID");

    SimpleEQMixer_AcquireSlot(inClientInfo);

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_RemoveDeviceClient: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_RemoveDeviceClient: bad device ID");

    SimpleEQMixer_ReleaseSlot(inClientInfo);

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeInfo)
    OSStatus theAnswer = 0;
    Float64 theNewSampleRate = 0.0;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_PerformDeviceConfigurationChange: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_PerformDeviceConfigurationChange: bad device ID");

    switch(inChangeAction)
    {
        case ChangeAction_SetSampleRate:
            pthread_mutex_lock(&gPlugIn_StateMutex);
            theNewSampleRate = gDevice_RequestedSampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            FailWithAction(!IsValidSampleRate(theNewSampleRate), theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_PerformDeviceConfigurationChange: bad sample rate");

            pthread_mutex_lock(&gPlugIn_StateMutex);
            gDevice_SampleRate = theNewSampleRate;
            RecalculateTicksPerFrame_Locked();

            if(gSimpleEQRing_Header != NULL)
            {
                gSimpleEQRing_Header->sampleRate = gDevice_SampleRate;

                uint32_t theEpoch = atomic_load_explicit(&gSimpleEQRing_Header->epoch, memory_order_relaxed);
                atomic_store_explicit(&gSimpleEQRing_Header->epoch, theEpoch + 1, memory_order_release);
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                AudioObjectPropertyAddress theAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &theAddress);
            });
            break;

        default:
            break;
    }

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_AbortDeviceConfigurationChange: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_AbortDeviceConfigurationChange: bad device ID");
Done:
    return theAnswer;
}

#pragma mark Property Operations

static Boolean SimpleEQAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    Boolean theAnswer = false;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_HasProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "SimpleEQAudio_HasProperty: no address");

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = SimpleEQAudio_HasPlugInProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Box:
            theAnswer = SimpleEQAudio_HasBoxProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Device:
            theAnswer = SimpleEQAudio_HasDeviceProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Stream_Output:
            theAnswer = SimpleEQAudio_HasStreamProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            theAnswer = SimpleEQAudio_HasControlProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsPropertySettable: no place to put the return value");

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = SimpleEQAudio_IsPlugInPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;
        case kObjectID_Box:
            theAnswer = SimpleEQAudio_IsBoxPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;
        case kObjectID_Device:
            theAnswer = SimpleEQAudio_IsDevicePropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;
        case kObjectID_Stream_Output:
            theAnswer = SimpleEQAudio_IsStreamPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            theAnswer = SimpleEQAudio_IsControlPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;
        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPropertyDataSize: no place to put the return value");

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = SimpleEQAudio_GetPlugInPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Box:
            theAnswer = SimpleEQAudio_GetBoxPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Device:
            theAnswer = SimpleEQAudio_GetDevicePropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Stream_Output:
            theAnswer = SimpleEQAudio_GetStreamPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            theAnswer = SimpleEQAudio_GetControlPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPropertyData: no place to put the return value");

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = SimpleEQAudio_GetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Box:
            theAnswer = SimpleEQAudio_GetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Device:
            theAnswer = SimpleEQAudio_GetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Stream_Output:
            theAnswer = SimpleEQAudio_GetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            theAnswer = SimpleEQAudio_GetControlPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    OSStatus theAnswer = 0;
    UInt32 theNumberPropertiesChanged = 0;
    AudioObjectPropertyAddress theChangedAddresses[2];

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetPropertyData: no address");

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = SimpleEQAudio_SetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;
        case kObjectID_Box:
            theAnswer = SimpleEQAudio_SetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;
        case kObjectID_Device:
            theAnswer = SimpleEQAudio_SetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;
        case kObjectID_Stream_Output:
            theAnswer = SimpleEQAudio_SetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            theAnswer = SimpleEQAudio_SetControlPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;
        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

    if(theNumberPropertiesChanged > 0)
    {
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theNumberPropertiesChanged, theChangedAddresses);
    }

Done:
    return theAnswer;
}

#pragma mark PlugIn Property Operations

static Boolean SimpleEQAudio_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    Boolean theAnswer = false;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_HasPlugInProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "SimpleEQAudio_HasPlugInProperty: no address");
    FailIf(inObjectID != kObjectID_PlugIn, Done, "SimpleEQAudio_HasPlugInProperty: not the plug-in object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsPlugInPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsPlugInPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsPlugInPropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsPlugInPropertySettable: not the plug-in object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            *outIsSettable = false;
            break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetPlugInPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPlugInPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPlugInPropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetPlugInPropertyDataSize: not the plug-in object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:        *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyClass:             *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyOwner:             *outDataSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyManufacturer:      *outDataSize = sizeof(CFStringRef);   break;
        case kAudioObjectPropertyOwnedObjects:      *outDataSize = (gBox_Acquired ? 2 : 1) * sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyBoxList:           *outDataSize = sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyTranslateUIDToBox: *outDataSize = sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyDeviceList:        *outDataSize = (gBox_Acquired ? 1 : 0) * sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyResourceBundle:    *outDataSize = sizeof(CFStringRef);   break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetPlugInPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPlugInPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPlugInPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetPlugInPropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetPlugInPropertyData: not the plug-in object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: not enough space for kAudioObjectPropertyBaseClass");
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: not enough space for kAudioObjectPropertyClass");
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: not enough space for kAudioObjectPropertyOwner");
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyManufacturer:
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: not enough space for kAudioObjectPropertyManufacturer");
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
            if(theNumberItemsToFetch > (gBox_Acquired ? 2u : 1u)) { theNumberItemsToFetch = gBox_Acquired ? 2 : 1; }
            if(theNumberItemsToFetch > 1) { ((AudioObjectID*)outData)[0] = kObjectID_Box; ((AudioObjectID*)outData)[1] = kObjectID_Device; }
            else if(theNumberItemsToFetch > 0) { ((AudioObjectID*)outData)[0] = kObjectID_Box; }
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyBoxList:
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
            if(theNumberItemsToFetch > 1) { theNumberItemsToFetch = 1; }
            if(theNumberItemsToFetch > 0) { ((AudioObjectID*)outData)[0] = kObjectID_Box; }
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyTranslateUIDToBox:
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: not enough space for kAudioPlugInPropertyTranslateUIDToBox");
            FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: bad qualifier for kAudioPlugInPropertyTranslateUIDToBox");
            *((AudioObjectID*)outData) = CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kBox_UID), 0) == kCFCompareEqualTo ? kObjectID_Box : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyDeviceList:
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
            if(theNumberItemsToFetch > (gBox_Acquired ? 1u : 0u)) { theNumberItemsToFetch = gBox_Acquired ? 1 : 0; }
            if(theNumberItemsToFetch > 0) { ((AudioObjectID*)outData)[0] = kObjectID_Device; }
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyTranslateUIDToDevice:
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: not enough space for kAudioPlugInPropertyTranslateUIDToDevice");
            FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: bad qualifier for kAudioPlugInPropertyTranslateUIDToDevice");
            *((AudioObjectID*)outData) = CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kSimpleEQDeviceUID), 0) == kCFCompareEqualTo ? kObjectID_Device : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyResourceBundle:
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetPlugInPropertyData: not enough space for kAudioPlugInPropertyResourceBundle");
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData, outChangedAddresses)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetPlugInPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetPlugInPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetPlugInPropertyData: no place to return the number of properties that changed");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetPlugInPropertyData: not the plug-in object");

    *outNumberPropertiesChanged = 0;
    theAnswer = kAudioHardwareUnknownPropertyError;

Done:
    return theAnswer;
}

#pragma mark Box Property Operations

static Boolean SimpleEQAudio_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    Boolean theAnswer = false;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_HasBoxProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "SimpleEQAudio_HasBoxProperty: no address");
    FailIf(inObjectID != kObjectID_Box, Done, "SimpleEQAudio_HasBoxProperty: not the box object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsBoxPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsBoxPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsBoxPropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsBoxPropertySettable: not the box object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
            *outIsSettable = false;
            break;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyIdentify:
        case kAudioBoxPropertyAcquired:
            *outIsSettable = true;
            break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetBoxPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetBoxPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetBoxPropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetBoxPropertyDataSize: not the box object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:       *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyClass:            *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyOwner:            *outDataSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyName:             *outDataSize = sizeof(CFStringRef);   break;
        case kAudioObjectPropertyModelName:        *outDataSize = sizeof(CFStringRef);   break;
        case kAudioObjectPropertyManufacturer:     *outDataSize = sizeof(CFStringRef);   break;
        case kAudioObjectPropertyOwnedObjects:     *outDataSize = 0;                     break;
        case kAudioObjectPropertyIdentify:         *outDataSize = sizeof(UInt32);        break;
        case kAudioObjectPropertySerialNumber:     *outDataSize = sizeof(CFStringRef);   break;
        case kAudioObjectPropertyFirmwareVersion:  *outDataSize = sizeof(CFStringRef);   break;
        case kAudioBoxPropertyBoxUID:              *outDataSize = sizeof(CFStringRef);   break;
        case kAudioBoxPropertyTransportType:       *outDataSize = sizeof(UInt32);        break;
        case kAudioBoxPropertyHasAudio:            *outDataSize = sizeof(UInt32);        break;
        case kAudioBoxPropertyHasVideo:            *outDataSize = sizeof(UInt32);        break;
        case kAudioBoxPropertyHasMIDI:              *outDataSize = sizeof(UInt32);        break;
        case kAudioBoxPropertyIsProtected:          *outDataSize = sizeof(UInt32);        break;
        case kAudioBoxPropertyAcquired:             *outDataSize = sizeof(UInt32);        break;
        case kAudioBoxPropertyAcquisitionFailed:    *outDataSize = sizeof(UInt32);        break;
        case kAudioBoxPropertyDeviceList:
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *outDataSize = gBox_Acquired ? sizeof(AudioObjectID) : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetBoxPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetBoxPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetBoxPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetBoxPropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetBoxPropertyData: not the box object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); break;
        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioBoxClassID; *outDataSize = sizeof(AudioClassID); break;
        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kObjectID_PlugIn; *outDataSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyName:
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((CFStringRef*)outData) = gBox_Name;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            if(*((CFStringRef*)outData) != NULL) { CFRetain(*((CFStringRef*)outData)); }
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioObjectPropertyModelName:
            *((CFStringRef*)outData) = CFSTR("SimpleEQ Audio"); *outDataSize = sizeof(CFStringRef); break;
        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name); *outDataSize = sizeof(CFStringRef); break;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; break;
        case kAudioObjectPropertyIdentify:
            *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); break;
        case kAudioObjectPropertySerialNumber:
            *((CFStringRef*)outData) = CFSTR("00000001"); *outDataSize = sizeof(CFStringRef); break;
        case kAudioObjectPropertyFirmwareVersion:
            *((CFStringRef*)outData) = CFSTR("1.0"); *outDataSize = sizeof(CFStringRef); break;
        case kAudioBoxPropertyBoxUID:
            *((CFStringRef*)outData) = CFSTR(kBox_UID); *outDataSize = sizeof(CFStringRef); break;
        case kAudioBoxPropertyTransportType:
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); break;
        case kAudioBoxPropertyHasAudio:
            *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); break;
        case kAudioBoxPropertyHasVideo:
            *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); break;
        case kAudioBoxPropertyHasMIDI:
            *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); break;
        case kAudioBoxPropertyIsProtected:
            *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); break;
        case kAudioBoxPropertyAcquired:
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = gBox_Acquired ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioBoxPropertyAcquisitionFailed:
            *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); break;
        case kAudioBoxPropertyDeviceList:
            pthread_mutex_lock(&gPlugIn_StateMutex);
            if(gBox_Acquired)
            {
                FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetBoxPropertyData: not enough space for kAudioBoxPropertyDeviceList");
                *((AudioObjectID*)outData) = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
            }
            else
            {
                *outDataSize = 0;
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetBoxPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetBoxPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetBoxPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetBoxPropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetBoxPropertyData: not the box object");

    *outNumberPropertiesChanged = 0;

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyName:
        {
            FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetBoxPropertyData: NULL data for kAudioObjectPropertyName");
            FailWithAction(inDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetBoxPropertyData: wrong size for kAudioObjectPropertyName");
            CFStringRef theNewName = *((const CFStringRef*)inData);
            pthread_mutex_lock(&gPlugIn_StateMutex);
            if(theNewName != NULL) { CFRetain(theNewName); }
            if(gBox_Name != NULL) { CFRelease(gBox_Name); }
            gBox_Name = theNewName;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outNumberPropertiesChanged = 1;
            outChangedAddresses[0].mSelector = kAudioObjectPropertyName;
            outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
            outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
            break;
        }

        case kAudioObjectPropertyIdentify:
            FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetBoxPropertyData: wrong size for kAudioObjectPropertyIdentify");
            dispatch_after(dispatch_time(0, 2ULL * 1000ULL * 1000ULL * 1000ULL), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                AudioObjectPropertyAddress theAddress = { kAudioObjectPropertyIdentify, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 1, &theAddress);
            });
            break;

        case kAudioBoxPropertyAcquired:
        {
            FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetBoxPropertyData: wrong size for kAudioBoxPropertyAcquired");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            Boolean theNewAcquired = *((const UInt32*)inData) != 0;
            Boolean theChanged = (gBox_Acquired != theNewAcquired);
            gBox_Acquired = theNewAcquired;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            if(theChanged)
            {
                *outNumberPropertiesChanged = 2;
                outChangedAddresses[0].mSelector = kAudioBoxPropertyAcquired;
                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                outChangedAddresses[1].mSelector = kAudioBoxPropertyDeviceList;
                outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    AudioObjectPropertyAddress theAddress = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_PlugIn, 1, &theAddress);
                });
            }
            break;
        }

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Device Property Operations

#define kAudioDevicePropertyCustom_VisibilityOverride ((AudioObjectPropertySelector)kSimpleEQVisibilityOverrideSelector)

#define kAudioDevicePropertyCustom_NameOverride ((AudioObjectPropertySelector)kSimpleEQNameOverrideSelector)

static const AudioServerPlugInCustomPropertyInfo kDevice_CustomPropertyList[] = {
    { kAudioDevicePropertyCustom_VisibilityOverride, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
    { kAudioDevicePropertyCustom_NameOverride,       kAudioServerPlugInCustomPropertyDataTypeCFString,       kAudioServerPlugInCustomPropertyDataTypeNone },
    { kSimpleEQDriftCompositionSelector,             kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
    { kSimpleEQMixerGainSelector,                    kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
};
static const UInt32 kDevice_CustomPropertyListBytes = sizeof(kDevice_CustomPropertyList);

static Boolean SimpleEQAudio_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    Boolean theAnswer = false;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_HasDeviceProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "SimpleEQAudio_HasDeviceProperty: no address");
    FailIf(inObjectID != kObjectID_Device, Done, "SimpleEQAudio_HasDeviceProperty: not the device object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyCustom_VisibilityOverride:
        case kAudioDevicePropertyCustom_NameOverride:
        case kSimpleEQDriftCompositionSelector:
        case kSimpleEQMixerGainSelector:
            theAnswer = true;
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            theAnswer = (inAddress->mScope == kAudioObjectPropertyScopeOutput);
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsDevicePropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsDevicePropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsDevicePropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsDevicePropertySettable: not the device object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIcon:
            *outIsSettable = false;
            break;

        case kAudioDevicePropertyIsHidden:
            *outIsSettable = false;
            break;

        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyCustom_VisibilityOverride:
        case kAudioDevicePropertyCustom_NameOverride:
        case kSimpleEQDriftCompositionSelector:
        case kSimpleEQMixerGainSelector:
            *outIsSettable = true;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetDevicePropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetDevicePropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetDevicePropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetDevicePropertyDataSize: not the device object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:   *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyClass:        *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyOwner:        *outDataSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyName:         *outDataSize = sizeof(CFStringRef);   break;
        case kAudioObjectPropertyManufacturer: *outDataSize = sizeof(CFStringRef);   break;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = WalkDeviceObjectList(IsAnyInScope, inAddress->mScope, NULL, 0) * sizeof(AudioObjectID);
            break;
        case kAudioDevicePropertyDeviceUID:  *outDataSize = sizeof(CFStringRef); break;
        case kAudioDevicePropertyModelUID:   *outDataSize = sizeof(CFStringRef); break;
        case kAudioDevicePropertyTransportType: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyRelatedDevices: *outDataSize = sizeof(AudioObjectID); break;
        case kAudioDevicePropertyClockDomain: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyDeviceIsAlive: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyDeviceIsRunning: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyLatency: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyStreams:
            *outDataSize = WalkDeviceObjectList(IsStreamInScope, inAddress->mScope, NULL, 0) * sizeof(AudioObjectID);
            break;
        case kAudioObjectPropertyControlList:
            *outDataSize = WalkDeviceObjectList(IsControlInScope, inAddress->mScope, NULL, 0) * sizeof(AudioObjectID);
            break;
        case kAudioDevicePropertySafetyOffset: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyNominalSampleRate: *outDataSize = sizeof(Float64); break;
        case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = kDevice_SampleRatesSize * sizeof(AudioValueRange); break;
        case kAudioDevicePropertyIsHidden: *outDataSize = sizeof(UInt32); break;
        case kAudioDevicePropertyIcon: *outDataSize = sizeof(CFURLRef); break;
        case kAudioObjectPropertyCustomPropertyInfoList: *outDataSize = kDevice_CustomPropertyListBytes; break;
        case kAudioDevicePropertyCustom_VisibilityOverride: *outDataSize = sizeof(CFPropertyListRef); break;
        case kAudioDevicePropertyCustom_NameOverride: *outDataSize = sizeof(CFStringRef); break;
        case kSimpleEQDriftCompositionSelector: *outDataSize = sizeof(CFPropertyListRef); break;
        case kSimpleEQMixerGainSelector: *outDataSize = sizeof(CFPropertyListRef); break;
        case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); break;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kNumber_Of_Channels * sizeof(AudioChannelDescription));
            break;
        case kAudioDevicePropertyZeroTimeStampPeriod: *outDataSize = sizeof(UInt32); break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    UInt32 theItemIndex;
    UInt32 theMaxToWrite;
    UInt32 theMatched;
    UInt32 theWritten;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetDevicePropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetDevicePropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetDevicePropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetDevicePropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetDevicePropertyData: not the device object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioObjectPropertyBaseClass");
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioObjectPropertyClass");
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioObjectPropertyOwner");
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioObjectPropertyName");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((CFStringRef*)outData) = CurrentDeviceName_Locked();
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioObjectPropertyManufacturer");
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            theMaxToWrite = inDataSize / sizeof(AudioObjectID);
            theMatched = WalkDeviceObjectList(IsAnyInScope, inAddress->mScope, (AudioObjectID*)outData, theMaxToWrite);
            theWritten = theMatched < theMaxToWrite ? theMatched : theMaxToWrite;
            *outDataSize = theWritten * sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertyDeviceUID:
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyDeviceUID");
            *((CFStringRef*)outData) = CFSTR(kSimpleEQDeviceUID);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyModelUID:
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyModelUID");
            *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
            *outDataSize = sizeof(CFStringRef);
            break;

        // 解決できない場合は代わりの URL を作らない。指し先の無い URL を返すと、原因が読み手側へ移る。
        case kAudioDevicePropertyIcon:
            FailWithAction(inDataSize < sizeof(CFURLRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyIcon");
            {
                CFBundleRef theBundle = CFBundleGetBundleWithIdentifier(CFSTR(kPlugIn_BundleID));
                FailWithAction(theBundle == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SimpleEQAudio_GetDevicePropertyData: could not get the plug-in bundle for kAudioDevicePropertyIcon");
                CFURLRef theURL = CFBundleCopyResourceURL(theBundle, CFSTR(kPlugIn_Icon), NULL, NULL);
                FailWithAction(theURL == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SimpleEQAudio_GetDevicePropertyData: could not get the URL for kAudioDevicePropertyIcon");
                *((CFURLRef*)outData) = theURL;
            }
            *outDataSize = sizeof(CFURLRef);
            break;

        case kAudioDevicePropertyTransportType:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyTransportType");
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyRelatedDevices:
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyRelatedDevices");
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertyClockDomain:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyClockDomain");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsAlive:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyDeviceIsAlive");
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsRunning:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyDeviceIsRunning");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = gDevice_IOIsRunning > 0 ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyDeviceCanBeDefaultDevice");
            *((UInt32*)outData) = kCanBeDefaultDevice;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyDeviceCanBeDefaultSystemDevice");
            *((UInt32*)outData) = kCanBeDefaultSystemDevice;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyLatency:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyLatency");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyStreams:
            theMaxToWrite = inDataSize / sizeof(AudioObjectID);
            theMatched = WalkDeviceObjectList(IsStreamInScope, inAddress->mScope, (AudioObjectID*)outData, theMaxToWrite);
            theWritten = theMatched < theMaxToWrite ? theMatched : theMaxToWrite;
            *outDataSize = theWritten * sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyControlList:
            theMaxToWrite = inDataSize / sizeof(AudioObjectID);
            theMatched = WalkDeviceObjectList(IsControlInScope, inAddress->mScope, (AudioObjectID*)outData, theMaxToWrite);
            theWritten = theMatched < theMaxToWrite ? theMatched : theMaxToWrite;
            *outDataSize = theWritten * sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertySafetyOffset:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertySafetyOffset");
            *((UInt32*)outData) = kSafetyMargin_Frame_Size;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyNominalSampleRate:
            FailWithAction(inDataSize < sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyNominalSampleRate");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((Float64*)outData) = gDevice_SampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(Float64);
            break;

        case kAudioDevicePropertyAvailableNominalSampleRates:
            theMaxToWrite = inDataSize / sizeof(AudioValueRange);
            if(theMaxToWrite > kDevice_SampleRatesSize) { theMaxToWrite = kDevice_SampleRatesSize; }
            for(UInt32 i = 0; i < theMaxToWrite; i++)
            {
                ((AudioValueRange*)outData)[i].mMinimum = kDevice_SampleRates[i];
                ((AudioValueRange*)outData)[i].mMaximum = kDevice_SampleRates[i];
            }
            *outDataSize = theMaxToWrite * sizeof(AudioValueRange);
            break;

        case kAudioDevicePropertyIsHidden:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyIsHidden");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = gDevice_IsHidden ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioObjectPropertyCustomPropertyInfoList:
            FailWithAction(inDataSize < kDevice_CustomPropertyListBytes, theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioObjectPropertyCustomPropertyInfoList");
            memcpy(outData, kDevice_CustomPropertyList, kDevice_CustomPropertyListBytes);
            *outDataSize = kDevice_CustomPropertyListBytes;
            break;

        case kAudioDevicePropertyCustom_VisibilityOverride:
            FailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyCustom_VisibilityOverride");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((CFPropertyListRef*)outData) = gDevice_IsHidden ? kCFBooleanTrue : kCFBooleanFalse;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(CFPropertyListRef);
            break;

        case kAudioDevicePropertyCustom_NameOverride:
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyCustom_NameOverride");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((CFStringRef*)outData) = CurrentDeviceName_Locked();
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kSimpleEQDriftCompositionSelector:
            FailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kSimpleEQDriftCompositionSelector");
            {
                Float64 theValue;
                pthread_mutex_lock(&gPlugIn_StateMutex);
                theValue = gDriftCompositionPpm;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                *((CFPropertyListRef*)outData) = CFNumberCreate(NULL, kCFNumberDoubleType, &theValue);
            }
            *outDataSize = sizeof(CFPropertyListRef);
            break;

        case kSimpleEQMixerGainSelector:
            FailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kSimpleEQMixerGainSelector");
            *((CFPropertyListRef*)outData) = SimpleEQMixer_CopyGainTable();
            *outDataSize = sizeof(CFPropertyListRef);
            break;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            FailWithAction(inDataSize < (2 * sizeof(UInt32)), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyPreferredChannelsForStereo");
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            break;

        case kAudioDevicePropertyPreferredChannelLayout:
        {
            UInt32 theACLSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kNumber_Of_Channels * sizeof(AudioChannelDescription));
            FailWithAction(inDataSize < theACLSize, theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyPreferredChannelLayout");
            ((AudioChannelLayout*)outData)->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            ((AudioChannelLayout*)outData)->mChannelBitmap = 0;
            ((AudioChannelLayout*)outData)->mNumberChannelDescriptions = kNumber_Of_Channels;
            for(theItemIndex = 0; theItemIndex < kNumber_Of_Channels; ++theItemIndex)
            {
                ((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mChannelLabel = kAudioChannelLabel_Left + theItemIndex;
                ((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mChannelFlags = 0;
                ((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mCoordinates[0] = 0;
                ((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mCoordinates[1] = 0;
                ((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mCoordinates[2] = 0;
            }
            *outDataSize = theACLSize;
            break;
        }

        case kAudioDevicePropertyZeroTimeStampPeriod:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetDevicePropertyData: not enough space for kAudioDevicePropertyZeroTimeStampPeriod");
            *((UInt32*)outData) = gSimpleEQRing_Frames > 0 ? gSimpleEQRing_Frames : kRingTargetFramesAtBase;
            *outDataSize = sizeof(UInt32);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    Float64 theOldSampleRate;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetDevicePropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetDevicePropertyData: not the device object");

    *outNumberPropertiesChanged = 0;

    switch(inAddress->mSelector)
    {
        case kAudioDevicePropertyNominalSampleRate:
            FailWithAction(inDataSize != sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetDevicePropertyData: wrong size for kAudioDevicePropertyNominalSampleRate");
            FailWithAction(!IsValidSampleRate(*(const Float64*)inData), theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: unsupported value for kAudioDevicePropertyNominalSampleRate");

            pthread_mutex_lock(&gPlugIn_StateMutex);
            theOldSampleRate = gDevice_SampleRate;
            gDevice_RequestedSampleRate = *((const Float64*)inData);
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            if(*((const Float64*)inData) != theOldSampleRate)
            {
                *outNumberPropertiesChanged = 1;
                outChangedAddresses[0].mSelector = kAudioDevicePropertyNominalSampleRate;
                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, ChangeAction_SetSampleRate, NULL);
                });
            }
            break;

        case kAudioDevicePropertyCustom_VisibilityOverride:
            FailWithAction(inDataSize != sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetDevicePropertyData: wrong size for kAudioDevicePropertyCustom_VisibilityOverride");
            FailWithAction(*((const CFPropertyListRef*)inData) == NULL || CFGetTypeID(*((const CFPropertyListRef*)inData)) != CFBooleanGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: kAudioDevicePropertyCustom_VisibilityOverride expects a CFBooleanRef");
            {
                Boolean theNewIsHidden = CFBooleanGetValue((CFBooleanRef)(*((const CFPropertyListRef*)inData)));
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Boolean theChanged = (gDevice_IsHidden != theNewIsHidden);
                gDevice_IsHidden = theNewIsHidden;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                if(theChanged)
                {
                    *outNumberPropertiesChanged = 2;
                    outChangedAddresses[0].mSelector = kAudioDevicePropertyCustom_VisibilityOverride;
                    outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                    outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                    outChangedAddresses[1].mSelector = kAudioDevicePropertyIsHidden;
                    outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                    outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                }
            }
            break;

        case kAudioDevicePropertyCustom_NameOverride:
            FailWithAction(inDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetDevicePropertyData: wrong size for kAudioDevicePropertyCustom_NameOverride");
            FailWithAction(*((const CFStringRef*)inData) == NULL || CFGetTypeID(*((const CFStringRef*)inData)) != CFStringGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: kAudioDevicePropertyCustom_NameOverride expects a CFStringRef");
            FailWithAction(CFStringGetLength(*((const CFStringRef*)inData)) > kSimpleEQNameOverrideMaxLength, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: kAudioDevicePropertyCustom_NameOverride exceeds the maximum length");
            {
                CFStringRef theNewName = (CFStringRef)CFRetain(*((const CFStringRef*)inData));
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Boolean theChanged = (gDevice_NameOverride == NULL) || !CFEqual(gDevice_NameOverride, theNewName);
                CFStringRef theOldName = gDevice_NameOverride;
                gDevice_NameOverride = theNewName;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                if(theOldName != NULL) { CFRelease(theOldName); }

                if(theChanged)
                {
                    *outNumberPropertiesChanged = 2;
                    outChangedAddresses[0].mSelector = kAudioDevicePropertyCustom_NameOverride;
                    outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                    outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                    outChangedAddresses[1].mSelector = kAudioObjectPropertyName;
                    outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                    outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                }
            }
            break;

        case kSimpleEQDriftCompositionSelector:
            FailWithAction(inDataSize != sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetDevicePropertyData: wrong size for kSimpleEQDriftCompositionSelector");
            FailWithAction(*((const CFPropertyListRef*)inData) == NULL || CFGetTypeID(*((const CFPropertyListRef*)inData)) != CFNumberGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: kSimpleEQDriftCompositionSelector expects a CFNumberRef");
            {
                Float64 theNewPpm = 0.0;
                CFNumberGetValue((CFNumberRef)(*((const CFPropertyListRef*)inData)), kCFNumberDoubleType, &theNewPpm);
                pthread_mutex_lock(&gPlugIn_StateMutex);
                if(gDriftCompositionPpm != theNewPpm)
                {
                    gDriftCompositionPpm = theNewPpm;
                    RecalculateTicksPerFrame_Locked();
                    *outNumberPropertiesChanged = 1;
                    outChangedAddresses[0].mSelector = kSimpleEQDriftCompositionSelector;
                    outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                    outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                }
                pthread_mutex_unlock(&gPlugIn_StateMutex);
            }
            break;

        case kSimpleEQMixerGainSelector:
            FailWithAction(inDataSize != sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetDevicePropertyData: wrong size for kSimpleEQMixerGainSelector");
            FailWithAction(*((const CFPropertyListRef*)inData) == NULL || CFGetTypeID(*((const CFPropertyListRef*)inData)) != CFDictionaryGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetDevicePropertyData: kSimpleEQMixerGainSelector expects a CFDictionaryRef");
            // 変更を告知しない。リースの更新で同じ表が周期的に押し込まれるため、告知すると
            // 中身が変わらないまま通知だけが撒かれ続ける。
            SimpleEQMixer_ApplyGainTable((CFDictionaryRef)(*((const CFPropertyListRef*)inData)));
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Stream Property Operations

static Boolean SimpleEQAudio_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    Boolean theAnswer = false;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_HasStreamProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "SimpleEQAudio_HasStreamProperty: no address");
    FailIf(inObjectID != kObjectID_Stream_Output, Done, "SimpleEQAudio_HasStreamProperty: not a stream object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsStreamPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsStreamPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsStreamPropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Stream_Output, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsStreamPropertySettable: not a stream object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outIsSettable = false;
            break;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetStreamPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetStreamPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetStreamPropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Stream_Output, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetStreamPropertyDataSize: not a stream object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:   *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyClass:        *outDataSize = sizeof(AudioClassID);  break;
        case kAudioObjectPropertyOwner:        *outDataSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0;                     break;
        case kAudioStreamPropertyIsActive:     *outDataSize = sizeof(UInt32);        break;
        case kAudioStreamPropertyDirection:    *outDataSize = sizeof(UInt32);        break;
        case kAudioStreamPropertyTerminalType: *outDataSize = sizeof(UInt32);        break;
        case kAudioStreamPropertyStartingChannel: *outDataSize = sizeof(UInt32);     break;
        case kAudioStreamPropertyLatency:      *outDataSize = sizeof(UInt32);        break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = kDevice_SampleRatesSize * sizeof(AudioStreamRangedDescription);
            break;
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetStreamPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetStreamPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetStreamPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetStreamPropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Stream_Output, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetStreamPropertyData: not a stream object");

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioObjectPropertyBaseClass");
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioObjectPropertyClass");
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioObjectPropertyOwner");
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            break;

        case kAudioStreamPropertyIsActive:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioStreamPropertyIsActive");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = gStream_Output_IsActive;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyDirection:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioStreamPropertyDirection");
            *((UInt32*)outData) = 0; // 出力ストリーム
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyTerminalType:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioStreamPropertyTerminalType");
            *((UInt32*)outData) = kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyStartingChannel:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioStreamPropertyStartingChannel");
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyLatency:
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioStreamPropertyLatency");
            *((UInt32*)outData) = kSafetyMargin_Frame_Size;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            FailWithAction(inDataSize < sizeof(AudioStreamBasicDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetStreamPropertyData: not enough space for kAudioStreamPropertyVirtualFormat");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            ((AudioStreamBasicDescription*)outData)->mSampleRate = gDevice_SampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            ((AudioStreamBasicDescription*)outData)->mFormatID = kAudioFormatLinearPCM;
            ((AudioStreamBasicDescription*)outData)->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
            ((AudioStreamBasicDescription*)outData)->mBytesPerPacket = kBytes_Per_Channel * kNumber_Of_Channels;
            ((AudioStreamBasicDescription*)outData)->mFramesPerPacket = 1;
            ((AudioStreamBasicDescription*)outData)->mBytesPerFrame = kBytes_Per_Channel * kNumber_Of_Channels;
            ((AudioStreamBasicDescription*)outData)->mChannelsPerFrame = kNumber_Of_Channels;
            ((AudioStreamBasicDescription*)outData)->mBitsPerChannel = kBits_Per_Channel;
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            theNumberItemsToFetch = inDataSize / sizeof(AudioStreamRangedDescription);
            if(theNumberItemsToFetch > kDevice_SampleRatesSize) { theNumberItemsToFetch = kDevice_SampleRatesSize; }
            for(UInt32 i = 0; i < theNumberItemsToFetch; i++)
            {
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mSampleRate = kDevice_SampleRates[i];
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFormatID = kAudioFormatLinearPCM;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBytesPerPacket = kBytes_Per_Frame;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFramesPerPacket = 1;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBytesPerFrame = kBytes_Per_Frame;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mChannelsPerFrame = kNumber_Of_Channels;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBitsPerChannel = kBits_Per_Channel;
                ((AudioStreamRangedDescription*)outData)[i].mSampleRateRange.mMinimum = kDevice_SampleRates[i];
                ((AudioStreamRangedDescription*)outData)[i].mSampleRateRange.mMaximum = kDevice_SampleRates[i];
            }
            *outDataSize = theNumberItemsToFetch * sizeof(AudioStreamRangedDescription);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    Float64 theOldSampleRate;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetStreamPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetStreamPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetStreamPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetStreamPropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_Stream_Output, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetStreamPropertyData: not a stream object");

    *outNumberPropertiesChanged = 0;

    switch(inAddress->mSelector)
    {
        case kAudioStreamPropertyIsActive:
            FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetStreamPropertyData: wrong size for kAudioStreamPropertyIsActive");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            if(gStream_Output_IsActive != (*((const UInt32*)inData) != 0))
            {
                gStream_Output_IsActive = *((const UInt32*)inData) != 0;
                *outNumberPropertiesChanged = 1;
                outChangedAddresses[0].mSelector = kAudioStreamPropertyIsActive;
                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            break;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            FailWithAction(inDataSize != sizeof(AudioStreamBasicDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetStreamPropertyData: wrong size for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(((const AudioStreamBasicDescription*)inData)->mFormatID != kAudioFormatLinearPCM, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported format ID");
            FailWithAction(((const AudioStreamBasicDescription*)inData)->mFormatFlags != (kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked), theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported format flags");
            FailWithAction(((const AudioStreamBasicDescription*)inData)->mBytesPerPacket != kBytes_Per_Frame, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported bytes per packet");
            FailWithAction(((const AudioStreamBasicDescription*)inData)->mFramesPerPacket != 1, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported frames per packet");
            FailWithAction(((const AudioStreamBasicDescription*)inData)->mBytesPerFrame != kBytes_Per_Frame, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported bytes per frame");
            FailWithAction(((const AudioStreamBasicDescription*)inData)->mChannelsPerFrame != kNumber_Of_Channels, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported channels per frame");
            FailWithAction(((const AudioStreamBasicDescription*)inData)->mBitsPerChannel != kBits_Per_Channel, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported bits per channel");
            FailWithAction(!IsValidSampleRate(((const AudioStreamBasicDescription*)inData)->mSampleRate), theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetStreamPropertyData: unsupported sample rate");

            pthread_mutex_lock(&gPlugIn_StateMutex);
            theOldSampleRate = gDevice_SampleRate;
            gDevice_RequestedSampleRate = ((const AudioStreamBasicDescription*)inData)->mSampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            if(((const AudioStreamBasicDescription*)inData)->mSampleRate != theOldSampleRate)
            {
                AudioObjectPropertyAddress theAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &theAddress);

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, ChangeAction_SetSampleRate, NULL);
                });
            }
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Control Property Operations

static Boolean SimpleEQAudio_HasControlProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    Boolean theAnswer = false;
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SimpleEQAudio_HasControlProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "SimpleEQAudio_HasControlProperty: no address");

    switch(inObjectID)
    {
        case kObjectID_Volume_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    theAnswer = true;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioBooleanControlPropertyValue:
                    theAnswer = true;
                    break;
            };
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_IsControlPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_IsControlPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsControlPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_IsControlPropertySettable: no place to put the return value");

    switch(inObjectID)
    {
        case kObjectID_Volume_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    *outIsSettable = false;
                    break;
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                    *outIsSettable = true;
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                    *outIsSettable = false;
                    break;
                case kAudioBooleanControlPropertyValue:
                    *outIsSettable = true;
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetControlPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetControlPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetControlPropertyDataSize: no place to put the return value");

    switch(inObjectID)
    {
        case kObjectID_Volume_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:    *outDataSize = sizeof(AudioClassID);   break;
                case kAudioObjectPropertyClass:         *outDataSize = sizeof(AudioClassID);   break;
                case kAudioObjectPropertyOwner:         *outDataSize = sizeof(AudioObjectID);  break;
                case kAudioObjectPropertyOwnedObjects:  *outDataSize = 0;                      break;
                case kAudioControlPropertyScope:        *outDataSize = sizeof(AudioObjectPropertyScope); break;
                case kAudioControlPropertyElement:      *outDataSize = sizeof(AudioObjectPropertyElement); break;
                case kAudioLevelControlPropertyScalarValue: *outDataSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyDecibelValue: *outDataSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyDecibelRange: *outDataSize = sizeof(AudioValueRange); break;
                case kAudioLevelControlPropertyConvertScalarToDecibels: *outDataSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyConvertDecibelsToScalar: *outDataSize = sizeof(Float32); break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:    *outDataSize = sizeof(AudioClassID);  break;
                case kAudioObjectPropertyClass:         *outDataSize = sizeof(AudioClassID);  break;
                case kAudioObjectPropertyOwner:         *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyOwnedObjects:  *outDataSize = 0;                     break;
                case kAudioControlPropertyScope:        *outDataSize = sizeof(AudioObjectPropertyScope); break;
                case kAudioControlPropertyElement:      *outDataSize = sizeof(AudioObjectPropertyElement); break;
                case kAudioBooleanControlPropertyValue: *outDataSize = sizeof(UInt32); break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID, inQualifierData, inQualifierDataSize)
    OSStatus theAnswer = 0;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetControlPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetControlPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetControlPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_GetControlPropertyData: no place to put the return value");

    switch(inObjectID)
    {
        case kObjectID_Volume_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                    FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioObjectPropertyBaseClass");
                    *((AudioClassID*)outData) = kAudioLevelControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyClass:
                    FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioObjectPropertyClass");
                    *((AudioClassID*)outData) = kAudioVolumeControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyOwner:
                    FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioObjectPropertyOwner");
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    break;

                case kAudioControlPropertyScope:
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioControlPropertyScope");
                    *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;

                case kAudioControlPropertyElement:
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioControlPropertyElement");
                    *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;

                case kAudioLevelControlPropertyScalarValue:
                    FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioLevelControlPropertyScalarValue");
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((Float32*)outData) = VolumeToScalar(gVolume_Master_Value);
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyDecibelValue:
                    FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioLevelControlPropertyDecibelValue");
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((Float32*)outData) = VolumeToDecibel(gVolume_Master_Value);
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyDecibelRange:
                    FailWithAction(inDataSize < sizeof(AudioValueRange), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioLevelControlPropertyDecibelRange");
                    ((AudioValueRange*)outData)->mMinimum = kSimpleEQVolumeMinDB;
                    ((AudioValueRange*)outData)->mMaximum = kSimpleEQVolumeMaxDB;
                    *outDataSize = sizeof(AudioValueRange);
                    break;

                case kAudioLevelControlPropertyConvertScalarToDecibels:
                    FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioLevelControlPropertyConvertScalarToDecibels");
                    {
                        Float32 theScalar = *((Float32*)outData);
                        if(theScalar < 0.0f) { theScalar = 0.0f; }
                        if(theScalar > 1.0f) { theScalar = 1.0f; }
                        *((Float32*)outData) = kSimpleEQVolumeMinDB + (theScalar * theScalar) * (kSimpleEQVolumeMaxDB - kSimpleEQVolumeMinDB);
                    }
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioLevelControlPropertyConvertDecibelsToScalar");
                    {
                        Float32 theDecibel = *((Float32*)outData);
                        if(theDecibel < kSimpleEQVolumeMinDB) { theDecibel = kSimpleEQVolumeMinDB; }
                        if(theDecibel > kSimpleEQVolumeMaxDB) { theDecibel = kSimpleEQVolumeMaxDB; }
                        Float32 theRatio = (theDecibel - kSimpleEQVolumeMinDB) / (kSimpleEQVolumeMaxDB - kSimpleEQVolumeMinDB);
                        *((Float32*)outData) = sqrtf(theRatio);
                    }
                    *outDataSize = sizeof(Float32);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                    FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioObjectPropertyBaseClass");
                    *((AudioClassID*)outData) = kAudioBooleanControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyClass:
                    FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioObjectPropertyClass");
                    *((AudioClassID*)outData) = kAudioMuteControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyOwner:
                    FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioObjectPropertyOwner");
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    break;

                case kAudioControlPropertyScope:
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioControlPropertyScope");
                    *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;

                case kAudioControlPropertyElement:
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioControlPropertyElement");
                    *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;

                case kAudioBooleanControlPropertyValue:
                    FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_GetControlPropertyData: not enough space for kAudioBooleanControlPropertyValue");
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((UInt32*)outData) = gMute_Master_Value ? 1 : 0;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(UInt32);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_SetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    Float32 theNewVolume;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_SetControlPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetControlPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetControlPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_SetControlPropertyData: no place to return the properties that changed");

    *outNumberPropertiesChanged = 0;

    switch(inObjectID)
    {
        case kObjectID_Volume_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioLevelControlPropertyScalarValue:
                    FailWithAction(inDataSize != sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetControlPropertyData: wrong size for kAudioLevelControlPropertyScalarValue");
                    theNewVolume = VolumeFromScalar(*((const Float32*)inData));
                    if(theNewVolume < 0.0f) { theNewVolume = 0.0f; }
                    else if(theNewVolume > 1.0f) { theNewVolume = 1.0f; }
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if(gVolume_Master_Value != theNewVolume)
                    {
                        gVolume_Master_Value = theNewVolume;
                        *outNumberPropertiesChanged = 2;
                        outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                        outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                        outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                        outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                        outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                        outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                    }
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    break;

                case kAudioLevelControlPropertyDecibelValue:
                    FailWithAction(inDataSize != sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetControlPropertyData: wrong size for kAudioLevelControlPropertyDecibelValue");
                    theNewVolume = *((const Float32*)inData);
                    if(theNewVolume < kSimpleEQVolumeMinDB) { theNewVolume = kSimpleEQVolumeMinDB; }
                    else if(theNewVolume > kSimpleEQVolumeMaxDB) { theNewVolume = kSimpleEQVolumeMaxDB; }
                    theNewVolume = VolumeFromDecibel(theNewVolume);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if(gVolume_Master_Value != theNewVolume)
                    {
                        gVolume_Master_Value = theNewVolume;
                        *outNumberPropertiesChanged = 2;
                        outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                        outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                        outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                        outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                        outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                        outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                    }
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioBooleanControlPropertyValue:
                    FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SimpleEQAudio_SetControlPropertyData: wrong size for kAudioBooleanControlPropertyValue");
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if(gMute_Master_Value != (*((const UInt32*)inData) != 0))
                    {
                        gMute_Master_Value = *((const UInt32*)inData) != 0;
                        *outNumberPropertiesChanged = 1;
                        outChangedAddresses[0].mSelector = kAudioBooleanControlPropertyValue;
                        outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                        outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                    }
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark IO Operations

static OSStatus SimpleEQAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_StartIO: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_StartIO: bad device ID");
    FailWithAction(gDevice_IOIsRunning == UINT64_MAX, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_StartIO: overflow error.");

    pthread_mutex_lock(&gPlugIn_StateMutex);
    gDevice_IOIsRunning += 1;
    if(gDevice_IOIsRunning == 1)
    {
        pthread_mutex_lock(&gDevice_IOMutex);
        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorHostTime = mach_absolute_time();
        gDevice_PreviousTicks = 0;
        pthread_mutex_unlock(&gDevice_IOMutex);
        if(gSimpleEQRing_Header != NULL)
        {
            SimpleEQRing_PublishTimeSnapshot(
                gSimpleEQRing_Header,
                atomic_load_explicit(&gSimpleEQRing_Header->writeCounter, memory_order_relaxed),
                mach_absolute_time());
            atomic_store_explicit(&gSimpleEQRing_Header->writerIOIsRunning, 1, memory_order_release);
            atomic_fetch_add_explicit(&gSimpleEQRing_Header->epoch, 1, memory_order_release);
        }
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_StopIO: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_StopIO: bad device ID");
    FailWithAction(gDevice_IOIsRunning == 0, theAnswer = kAudioHardwareIllegalOperationError, Done, "SimpleEQAudio_StopIO: underflow error.");

    pthread_mutex_lock(&gPlugIn_StateMutex);
    gDevice_IOIsRunning -= 1;
    if(gDevice_IOIsRunning == 0 && gSimpleEQRing_Header != NULL)
    {
        atomic_store_explicit(&gSimpleEQRing_Header->writerIOIsRunning, 0, memory_order_release);
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID, inDeviceObjectID)
    OSStatus theAnswer = 0;
    UInt64 theCurrentHostTime;
    Float64 theAdjustedTicksPerPeriod;
    Float64 theNextTickOffset;
    UInt64 theNextHostTime;
    UInt32 thePeriodFrames;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetZeroTimeStamp: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_GetZeroTimeStamp: bad device ID");

    pthread_mutex_lock(&gDevice_IOMutex);

    theCurrentHostTime = mach_absolute_time();
    thePeriodFrames = gSimpleEQRing_Frames > 0 ? gSimpleEQRing_Frames : kRingTargetFramesAtBase;
    theAdjustedTicksPerPeriod = gDevice_AdjustedTicksPerFrame * (Float64)thePeriodFrames;
    theNextTickOffset = gDevice_PreviousTicks + theAdjustedTicksPerPeriod;
    theNextHostTime = gDevice_AnchorHostTime + ((UInt64)theNextTickOffset);

    if(theNextHostTime <= theCurrentHostTime)
    {
        ++gDevice_NumberTimeStamps;
        gDevice_PreviousTicks = theNextTickOffset;
    }

    *outSampleTime = gDevice_NumberTimeStamps * thePeriodFrames;
    *outHostTime = gDevice_AnchorHostTime + gDevice_PreviousTicks;
    *outSeed = 1;

    pthread_mutex_unlock(&gDevice_IOMutex);

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID, inDeviceObjectID)
    OSStatus theAnswer = 0;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_WillDoIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_WillDoIOOperation: bad device ID");

    // MixOutput は宣言しない。宣言するとそのサイクルの以降の出力オペレーションが起きず、
    // WriteMix が来なくなる (実測で確認済みの唯一の条件)。
    bool willDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix)
               || (inOperationID == kAudioServerPlugInIOOperationProcessOutput);

    if(outWillDo != NULL) { *outWillDo = willDo; }
    if(outWillDoInPlace != NULL) { *outWillDoInPlace = true; }

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo, inDeviceObjectID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_BeginIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_BeginIOOperation: bad device ID");
Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(ioSecondaryBuffer, inDeviceObjectID)
    OSStatus theAnswer = 0;

    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_DoIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_DoIOOperation: bad device ID");
    FailWithAction(inStreamObjectID != kObjectID_Stream_Output, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_DoIOOperation: bad stream ID");

    if(inOperationID == kAudioServerPlugInIOOperationWriteMix)
    {
        FailWithAction(inIOCycleInfo->mCurrentTime.mSampleTime > inIOCycleInfo->mOutputTime.mSampleTime + inIOBufferFrameSize + kSafetyMargin_Frame_Size,
                        { theAnswer = kAudioHardwareUnspecifiedError; RecordDeadlineMissedSkip(); },
                        Done, "SimpleEQAudio_DoIOOperation: overload, missed the WriteMix deadline");

        SimpleEQRing_WriteAudio((const float*)ioMainBuffer, inIOBufferFrameSize, inIOCycleInfo->mOutputTime.mSampleTime);
    }
    else if(inOperationID == kAudioServerPlugInIOOperationProcessOutput)
    {
        // WriteMix にある締切超過のスキップをここには設けない。スキップするとその区間だけ
        // 減衰されない音が出るので、遅れても掛けるほうが実害が小さい。
        SimpleEQMixer_ProcessOutput(inClientID, (float*)ioMainBuffer, inIOBufferFrameSize);
    }

Done:
    return theAnswer;
}

static OSStatus SimpleEQAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo, inDeviceObjectID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_EndIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "SimpleEQAudio_EndIOOperation: bad device ID");
Done:
    return theAnswer;
}
