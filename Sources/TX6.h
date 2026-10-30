#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMIDI/CoreMIDI.h>
#import <stdatomic.h>

#define TX_SLOTS 7
#define TX_EQ 3

typedef struct { double b0,b1,b2,a1,a2,z1[2],z2[2]; } TXFilter;
typedef struct {
    _Atomic(float) gain[TX_SLOTS], eq[TX_SLOTS][TX_EQ], master;
    _Atomic(bool) muted[TX_SLOTS], masterMuted;
    _Atomic(float) peak[TX_SLOTS], outputPeak;
    _Atomic(uint64_t) callbacks, frames, limitedFrames;
    _Atomic(int) layoutFault;
    float smoothGain[TX_SLOTS], smoothMaster, limiterGain;
    double currentEQ[TX_SLOTS][TX_EQ];
    TXFilter filters[TX_SLOTS][TX_EQ];
    _Atomic(double) sampleRate;
    _Atomic(UInt32) physicalInputChannels;
    UInt32 outputLeft, outputRight;
    int tapSlots[TX_SLOTS];
    _Atomic(int) tapCount;
} TXRenderState;

@interface TXAudio : NSObject
@property(nonatomic,readonly) TXRenderState *state;
@property(nonatomic,readonly) BOOL running;
@property(atomic,copy) NSString *lastError;
@property(nonatomic,readonly) AudioDeviceID device;
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
BOOL TXRunMIDISelfCheck(void);
