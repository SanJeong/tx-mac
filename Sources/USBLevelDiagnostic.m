#import "TX6.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioUnit/AudioUnit.h>
#import <math.h>
#import <time.h>

_Static_assert(__atomic_always_lock_free(sizeof(double),0)&&__atomic_always_lock_free(sizeof(uint64_t),0)&&__atomic_always_lock_free(sizeof(float),0),"Diagnostic render statistics must be lock-free");

// This explicit CLI diagnostic never installs a tap, plays audio, or writes audio files.
typedef struct {
    AudioUnit unit;
    float *samples;
    UInt32 capacity;
    double sum[2];
    float peak[2];
    uint64_t frames,nonfinite;
    _Atomic(uint64_t) requested,published,totalFrames;
    _Atomic(uint64_t) windowFrames,windowNonfinite;
    _Atomic(double) windowSum[2];
    _Atomic(float) windowPeak[2];
    _Atomic(int32_t) fault;
} TXUSBMeasureState;

static double MeasureTime(void) {
    struct timespec time;clock_gettime(CLOCK_MONOTONIC,&time);
    return time.tv_sec+time.tv_nsec/1e9;
}
static void MeasurePrint(NSDictionary *object) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if(json){fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);fflush(stdout);}
}
static id MeasureDB(double amplitude) {return amplitude>0&&isfinite(amplitude)?@(20*log10(amplitude)):NSNull.null;}
static OSStatus MeasureInput(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *unused) {
    TXUSBMeasureState *s=context;
    if(!frames)return noErr;
    if(frames>s->capacity||frames>UINT32_MAX/(2*sizeof(float))){atomic_store(&s->fault,kAudio_ParamError);return kAudio_ParamError;}
    UInt32 bytes=frames*2*sizeof(float);
    AudioBufferList buffers={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=bytes,.mData=s->samples}}};
    OSStatus status=AudioUnitRender(s->unit,flags,time,1,frames,&buffers);
    if(status!=noErr){atomic_store(&s->fault,status);return status;}
    if(buffers.mNumberBuffers!=1||buffers.mBuffers[0].mNumberChannels!=2||buffers.mBuffers[0].mData!=s->samples||buffers.mBuffers[0].mDataByteSize!=bytes){atomic_store(&s->fault,kAudio_ParamError);return kAudio_ParamError;}
    for(UInt32 f=0;f<frames;f++)for(int c=0;c<2;c++){
        float value=s->samples[f*2+c];
        if(!isfinite(value)){s->nonfinite++;continue;}
        s->peak[c]=fmaxf(s->peak[c],fabsf(value));s->sum[c]+=(double)value*value;
    }
    s->frames+=frames;atomic_fetch_add_explicit(&s->totalFrames,frames,memory_order_relaxed);
    uint64_t requested=atomic_load_explicit(&s->requested,memory_order_acquire);
    if(requested!=atomic_load_explicit(&s->published,memory_order_relaxed)){
        atomic_store_explicit(&s->windowFrames,s->frames,memory_order_relaxed);
        atomic_store_explicit(&s->windowNonfinite,s->nonfinite,memory_order_relaxed);
        for(int c=0;c<2;c++){
            atomic_store_explicit(&s->windowSum[c],s->sum[c],memory_order_relaxed);
            atomic_store_explicit(&s->windowPeak[c],s->peak[c],memory_order_relaxed);
            s->sum[c]=0;s->peak[c]=0;
        }
        s->frames=0;s->nonfinite=0;
        atomic_store_explicit(&s->published,requested,memory_order_release);
    }
    return noErr;
}
static UInt32 MeasureChannels(AudioDeviceID device,AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address={kAudioDevicePropertyStreamConfiguration,scope,kAudioObjectPropertyElementMain};UInt32 bytes=0;
    if(AudioObjectGetPropertyDataSize(device,&address,0,NULL,&bytes)!=noErr||bytes<offsetof(AudioBufferList,mBuffers))return 0;
    AudioBufferList *list=calloc(1,bytes);if(!list)return 0;UInt32 capacity=bytes,channels=0;
    if(AudioObjectGetPropertyData(device,&address,0,NULL,&bytes,list)==noErr&&bytes>=offsetof(AudioBufferList,mBuffers)&&bytes<=capacity&&list->mNumberBuffers<=(bytes-offsetof(AudioBufferList,mBuffers))/sizeof(AudioBuffer))for(UInt32 b=0;b<list->mNumberBuffers;b++)channels+=list->mBuffers[b].mNumberChannels;
    free(list);return channels;
}
static BOOL MeasureDevice(AudioDeviceID *selected,double *rate) {
    NSMutableArray *matches=[NSMutableArray array];
    for(NSDictionary *output in TXAudio.outputs){
        NSString *name=[output[@"name"] uppercaseString];AudioDeviceID device=[output[@"id"] unsignedIntValue];
        if(([name containsString:@"TX-6"]||[name containsString:@"TX6"])&&[output[@"transport"] unsignedIntValue]==kAudioDeviceTransportTypeUSB&&[output[@"channels"] unsignedIntValue]==12&&MeasureChannels(device,kAudioDevicePropertyScopeInput)==2)[matches addObject:output];
    }
    if(matches.count!=1){MeasurePrint(@{@"type":@"error",@"stage":@"device-selection",@"matches":@(matches.count),@"message":@"Exactly one USB TX-6 with 12 output and 2 input channels is required. Select USB 12 IN mode."});return NO;}
    NSDictionary *device=matches.firstObject;*selected=[device[@"id"] unsignedIntValue];UInt32 bytes=sizeof(*rate);
    AudioObjectPropertyAddress address={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    OSStatus status=AudioObjectGetPropertyData(*selected,&address,0,NULL,&bytes,rate);
    if(status!=noErr||!isfinite(*rate)||*rate<8000||*rate>384000){MeasurePrint(@{@"type":@"error",@"stage":@"sample-rate",@"status":@(status)});return NO;}
    MeasurePrint(@{@"type":@"device",@"id":@(*selected),@"uid":device[@"uid"],@"name":device[@"name"],@"sampleRate":@(*rate),@"inputChannels":@2,@"outputChannels":@12});return YES;
}

int TXMeasureUSBReturn(BOOL requestMicrophone) {
    setvbuf(stdout,NULL,_IOLBF,0);
    AVAuthorizationStatus authorization=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    MeasurePrint(@{@"type":@"authorization",@"status":@(authorization),@"requestAllowed":@(requestMicrophone)});
    if(authorization==AVAuthorizationStatusNotDetermined&&requestMicrophone){
        __block _Atomic(bool) replied=false;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted){atomic_store_explicit(&replied,true,memory_order_release);}];
        double until=MeasureTime()+60;
        while(!atomic_load_explicit(&replied,memory_order_acquire)&&MeasureTime()<until)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        if(!atomic_load(&replied)){MeasurePrint(@{@"type":@"error",@"stage":@"authorization-timeout"});return 2;}
        authorization=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        MeasurePrint(@{@"type":@"authorization",@"status":@(authorization)});
    }
    if(authorization!=AVAuthorizationStatusAuthorized){MeasurePrint(@{@"type":@"error",@"stage":@"authorization",@"message":authorization==AVAuthorizationStatusNotDetermined?@"No microphone permission request was made. Run with --request-microphone to request USB audio input access.":@"Audio input permission is denied or restricted. Check System Settings > Privacy & Security > Microphone."});return 2;}
    AudioDeviceID device=0;double rate=0;if(!MeasureDevice(&device,&rate))return 3;
    AudioComponentDescription description={.componentType=kAudioUnitType_Output,.componentSubType=kAudioUnitSubType_HALOutput,.componentManufacturer=kAudioUnitManufacturer_Apple};
    AudioComponent component=AudioComponentFindNext(NULL,&description);AudioUnit unit=NULL;
    OSStatus status=component?AudioComponentInstanceNew(component,&unit):kAudio_ParamError;
    TXUSBMeasureState *state=NULL;BOOL initialized=NO,started=NO,disposed=unit==NULL;NSString *stage=@"create-auhal";int result=4;
    if(status!=noErr)goto cleanup;
    UInt32 enabled=1,disabled=0;
    stage=@"enable-input";status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&enabled,sizeof(enabled));if(status!=noErr)goto cleanup;
    stage=@"disable-output";status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&disabled,sizeof(disabled));if(status!=noErr)goto cleanup;
    stage=@"bind-device";status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof(device));if(status!=noErr)goto cleanup;
    AudioDeviceID actualDevice=0;UInt32 verifyBytes=sizeof(actualDevice);stage=@"verify-device";
    status=AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actualDevice,&verifyBytes);if(status!=noErr)goto cleanup;if(actualDevice!=device){status=kAudio_ParamError;goto cleanup;}
    UInt32 actualOutput=1,actualInput=0;verifyBytes=sizeof(UInt32);stage=@"verify-input-only";
    status=AudioUnitGetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&actualOutput,&verifyBytes);if(status!=noErr)goto cleanup;verifyBytes=sizeof(UInt32);
    status=AudioUnitGetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&actualInput,&verifyBytes);if(status!=noErr)goto cleanup;if(actualOutput||!actualInput){status=kAudio_ParamError;goto cleanup;}
    AudioStreamBasicDescription hardware={0};UInt32 bytes=sizeof(hardware);
    stage=@"input-format";status=AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,1,&hardware,&bytes);if(status!=noErr)goto cleanup;
    if(hardware.mChannelsPerFrame!=2||!isfinite(hardware.mSampleRate)||fabs(hardware.mSampleRate-rate)>.001){status=kAudio_ParamError;goto cleanup;}
    AudioStreamBasicDescription format={.mSampleRate=rate,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagsNativeEndian,.mBytesPerPacket=8,.mFramesPerPacket=1,.mBytesPerFrame=8,.mChannelsPerFrame=2,.mBitsPerChannel=32};
    stage=@"client-format";status=AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&format,sizeof(format));if(status!=noErr)goto cleanup;
    UInt32 maximum=0;bytes=sizeof(maximum);stage=@"maximum-frames";
    status=AudioUnitGetProperty(unit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maximum,&bytes);if(status!=noErr)goto cleanup;
    if(!maximum||maximum>1048576){status=kAudio_ParamError;goto cleanup;}
    state=calloc(1,sizeof(*state));if(!state){status=memFullErr;goto cleanup;}
    state->capacity=maximum;state->unit=unit;state->samples=calloc(maximum,2*sizeof(float));if(!state->samples){status=memFullErr;goto cleanup;}
    UInt32 allocate=0;stage=@"disable-render-allocation";status=AudioUnitSetProperty(unit,kAudioUnitProperty_ShouldAllocateBuffer,kAudioUnitScope_Output,1,&allocate,sizeof(allocate));if(status!=noErr)goto cleanup;
    AURenderCallbackStruct callback={.inputProc=MeasureInput,.inputProcRefCon=state};stage=@"input-callback";
    status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,0,&callback,sizeof(callback));if(status!=noErr)goto cleanup;
    stage=@"initialize";status=AudioUnitInitialize(unit);if(status!=noErr)goto cleanup;initialized=YES;
    stage=@"start";status=AudioOutputUnitStart(unit);if(status!=noErr)goto cleanup;started=YES;
    MeasurePrint(@{@"type":@"start",@"durationSeconds":@20,@"windowSeconds":@.5,@"format":@"float32-interleaved-stereo",@"audioFilesWritten":@NO,@"playbackEnabled":@NO});
    double began=MeasureTime();result=0;
    for(uint64_t window=1;window<=40;window++){
        double boundary=began+window*.5;
        while(MeasureTime()<boundary)[NSThread sleepForTimeInterval:fmax(0,fmin(.01,boundary-MeasureTime()))];
        atomic_store_explicit(&state->requested,window,memory_order_release);
        double deadline=MeasureTime()+.5;
        while(atomic_load_explicit(&state->published,memory_order_acquire)!=window&&!atomic_load(&state->fault)&&MeasureTime()<deadline)[NSThread sleepForTimeInterval:.001];
        if(atomic_load(&state->fault)){stage=@"capture";status=atomic_load(&state->fault);result=4;goto cleanup;}
        if(atomic_load(&state->published)!=window){stage=@"callback-timeout";status=kAudioHardwareUnspecifiedError;result=4;goto cleanup;}
        uint64_t frames=atomic_load(&state->windowFrames);NSMutableArray *peaks=[NSMutableArray array],*rms=[NSMutableArray array];
        for(int c=0;c<2;c++){[peaks addObject:MeasureDB(atomic_load(&state->windowPeak[c]))];[rms addObject:MeasureDB(frames?sqrt(atomic_load(&state->windowSum[c])/frames):0)];}
        MeasurePrint(@{@"type":@"window",@"index":@(window),@"elapsedSeconds":@(MeasureTime()-began),@"frames":@(frames),@"peakDBFS":peaks,@"rmsDBFS":rms,@"nonfiniteSamples":@(atomic_load(&state->windowNonfinite)),@"silenceDBFS":@"null"});
    }
cleanup:
    if(result)MeasurePrint(@{@"type":@"error",@"stage":stage,@"status":@(status)});
    // Stop/uninitialize/dispose complete before releasing callback-owned memory.
    if(started){OSStatus end=AudioOutputUnitStop(unit);if(end!=noErr){MeasurePrint(@{@"type":@"error",@"stage":@"stop",@"status":@(end)});result=4;}}
    if(initialized){OSStatus end=AudioUnitUninitialize(unit);if(end!=noErr){MeasurePrint(@{@"type":@"error",@"stage":@"uninitialize",@"status":@(end)});result=4;}}
    if(unit){OSStatus end=AudioComponentInstanceDispose(unit);disposed=end==noErr;if(end!=noErr){MeasurePrint(@{@"type":@"error",@"stage":@"dispose",@"status":@(end)});result=4;}}
    // On a failed dispose retain the buffers until CLI process exit rather than risk a live callback.
    if(state){MeasurePrint(@{@"type":@"complete",@"totalFrames":@(atomic_load(&state->totalFrames)),@"result":@(result)});if(disposed){free(state->samples);free(state);}}
    return result;
}
