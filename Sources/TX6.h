#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMIDI/CoreMIDI.h>
#import <stdatomic.h>

#define TX_SLOTS 7
#define TX_EQ 3

typedef NS_ENUM(UInt32, TXOutputRoute) { TXOutputMain=0, TXOutputMonitor=1, TXOutputBoth=2, TXOutputOff=3 };

typedef struct {
    float *samples;
    UInt32 capacity, writeIndex, validFrames, mainFrames, monitorFrames;
} TXSyncDelay;

typedef struct { double b0,b1,b2,a1,a2,z1[2],z2[2]; } TXFilter;
typedef struct {
    _Atomic(float) gain[TX_SLOTS], eq[TX_SLOTS][TX_EQ], master;
    _Atomic(bool) muted[TX_SLOTS], masterMuted;
    _Atomic(UInt32) route[TX_SLOTS];
    _Atomic(float) monitorGain, monitorPeak;
    _Atomic(float) peak[TX_SLOTS], outputPeak;
    // Channel DSP/mute sample peaks, before master and routing.
    _Atomic(float) channelPeakHold[TX_SLOTS];
    _Atomic(bool) channelOver[TX_SLOTS];
    // Bus peaks before limiting; GR is positive dB attenuation, independent of USB.
    _Atomic(float) mainPreLimiterPeak, mainPreLimiterHold, mainGainReductionDB;
    _Atomic(float) monitorPreLimiterPeak, monitorPreLimiterHold, monitorGainReductionDB;
    _Atomic(uint64_t) levelResetRequested, levelResetApplied;
    _Atomic(float) usbPeak[6], usbRMS[6];
    _Atomic(bool) meterReference, transitionMuted;
    uint64_t meterReferenceFrame;
    _Atomic(uint64_t) callbacks, frames, limitedFrames;
    _Atomic(int) layoutFault;
    float smoothGain[TX_SLOTS], smoothMaster, limiterGain;
    float smoothMonitorGain, monitorLimiterGain;
    double currentEQ[TX_SLOTS][TX_EQ];
    TXFilter filters[TX_SLOTS][TX_EQ], syncMonitorFilters[TX_SLOTS][TX_EQ];
    TXSyncDelay syncDelay[TX_SLOTS];
    _Atomic(UInt32) syncNowFlags, syncInputFlags, syncOutputFlags;
    _Atomic(uint64_t) syncNowHostTime, syncInputHostTime, syncOutputHostTime;
    _Atomic(double) syncInputToOutputMS, syncNowToOutputMS;
    double syncHostTickMS;
    _Atomic(double) sampleRate;
    _Atomic(UInt32) physicalInputChannels;
    UInt32 outputLeft, outputRight;
    // Immutable while the IOProc runs; configured only by the serial HAL worker.
    BOOL monitorEnabled;
    UInt32 monitorLeft, monitorRight;
    BOOL meterEnabled;
    UInt32 meterOutputOffset;
    int tapSlots[TX_SLOTS];
    _Atomic(int) tapCount;
} TXRenderState;

// Requests only hold/OVER reset; the render callback owns the recorded values.
uint64_t TXRequestLevelPeakReset(TXRenderState *state);

// Own this guard independently of TXAudio; begin/end belong on the serial HAL worker.
@interface TXAudioMuteGuard : NSObject
// Tracks retained resources, including partial cleanup; it is not proof of source silence.
@property(nonatomic,readonly) BOOL active;
- (BOOL)begin:(NSError**)error;
- (BOOL)end:(NSError**)error;
@end

@interface TXAudio : NSObject
@property(nonatomic,readonly) TXRenderState *state;
@property(nonatomic,readonly) BOOL running;
@property(atomic,copy) NSString *lastError;
@property(nonatomic,readonly) AudioDeviceID device;
@property(nonatomic) AudioDeviceID monitorOutputDevice;
@property(nonatomic,readonly) BOOL monitoring;
// Configure and read diagnostics on the HAL worker; changes apply on the next guarded rebuild.
@property(nonatomic) BOOL syncCompensationEnabled;
@property(nonatomic,readonly) NSDictionary *syncDiagnostics;
@property(nonatomic) AudioDeviceID meterOutputDevice;
@property(nonatomic,readonly) BOOL metering;
// Six native bundle-ID rows, deeply copied on the HAL worker; nil preserves existing planning.
@property(nonatomic,copy) NSArray<NSArray<NSString*>*> *slotBundleIDs;
// HAL lifecycle and discovery are synchronous; call only on the app's serial HAL queue.
- (BOOL)startOnDevice:(AudioDeviceID)device groups:(NSArray<NSArray<NSNumber*>*>*)groups;
- (void)stop;
+ (NSArray<NSDictionary*>*)outputs;
+ (NSArray<NSDictionary*>*)processes;
+ (AudioDeviceID)defaultOutput;
+ (NSString*)uid:(AudioDeviceID)device;
+ (NSDictionary*)diagnostics;
@end

@interface TXMIDI : NSObject
@property(nonatomic,copy) void (^received)(NSString *source, UInt8 channel, UInt8 cc, UInt8 value);
@property(nonatomic,copy) void (^changed)(void);
@property(nonatomic,readonly) NSArray<NSString*> *sources;
@property(nonatomic,readonly) NSDictionary *diagnostics;
@property(nonatomic,copy) NSString *transport;
- (void)start;
- (void)refresh;
- (void)stop;
@end

BOOL TXRunSelfCheck(void);
int TXCheckUSBMeterRoute(BOOL direct);
int TXHoldAudioMuteGuard(void);
int TXProbeAudioMuteGuard(void);
int TXQuietUSBSource(void);
int TXMeasureUSBReturn(BOOL requestMicrophone);
BOOL TXRunMIDISelfCheck(void);
void TXPrintBLEServices(BOOL requestAccess,BOOL observe,NSUInteger pingTarget);
