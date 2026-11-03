#import "TX6.h"
#import "Localization.h"
#import <math.h>
#import <float.h>
#import <libproc.h>
#import <stdarg.h>
#import <time.h>
#import <mach/mach_time.h>

static AudioObjectPropertyAddress Addr(AudioObjectPropertySelector selector,AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector,scope,kAudioObjectPropertyElementMain};
}
static UInt32 ReadUInt(AudioObjectID obj,AudioObjectPropertySelector selector) {
    UInt32 value=0,size=sizeof(value); AudioObjectPropertyAddress a=Addr(selector,kAudioObjectPropertyScopeGlobal);
    AudioObjectGetPropertyData(obj,&a,0,NULL,&size,&value); return value;
}
static NSString *ReadString(AudioObjectID obj,AudioObjectPropertySelector selector) {
    CFStringRef value=NULL; UInt32 size=sizeof(value); AudioObjectPropertyAddress a=Addr(selector,kAudioObjectPropertyScopeGlobal);
    if(AudioObjectGetPropertyData(obj,&a,0,NULL,&size,&value)!=noErr||!value)return @"";
    return CFBridgingRelease(value);
}
static NSArray<NSNumber*> *ReadIDs(AudioObjectID obj,AudioObjectPropertySelector selector,AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a=Addr(selector,scope); UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(obj,&a,0,NULL,&size)!=noErr||!size)return @[];
    AudioObjectID *ids=malloc(size); NSMutableArray *result=[NSMutableArray array];
    if(AudioObjectGetPropertyData(obj,&a,0,NULL,&size,ids)==noErr)for(UInt32 i=0;i<size/sizeof(*ids);i++)[result addObject:@(ids[i])];
    free(ids);return result;
}
static UInt32 Channels(AudioObjectID obj,AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a=Addr(kAudioDevicePropertyStreamConfiguration,scope); UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(obj,&a,0,NULL,&size)!=noErr||!size)return 0;
    AudioBufferList *list=malloc(size); UInt32 total=0;
    if(AudioObjectGetPropertyData(obj,&a,0,NULL,&size,list)==noErr)for(UInt32 i=0;i<list->mNumberBuffers;i++)total+=list->mBuffers[i].mNumberChannels;
    free(list);return total;
}
static BOOL IsSystemSoundProcess(NSString *executablePath,NSString *bundleID) {
    return [executablePath isEqualToString:@"/usr/sbin/systemsoundserverd"] ||
        (!executablePath.length && [bundleID isEqualToString:@"systemsoundserverd"]);
}
static BOOL LayoutTraceEnabled(void) {
    const char *value=getenv("TX6_LAYOUT_TRACE");return value&&strcmp(value,"1")==0;
}
static void LayoutTrace(const char *format,...) __attribute__((format(printf,1,2)));
static void LayoutTrace(const char *format,...) {
    if(!LayoutTraceEnabled())return;
    fprintf(stderr,"[TX6_LAYOUT_TRACE] ");va_list arguments;va_start(arguments,format);vfprintf(stderr,format,arguments);va_end(arguments);fputc('\n',stderr);
}
static void TraceStreams(AudioDeviceID device,AudioObjectPropertyScope scope) {
    if(!LayoutTraceEnabled())return;
    NSArray<NSNumber*> *streams=ReadIDs(device,kAudioDevicePropertyStreams,scope);
    LayoutTrace("streams device=%u scope=%s count=%lu",device,scope==kAudioDevicePropertyScopeInput?"input":"output",(unsigned long)streams.count);
    for(NSUInteger i=0;i<streams.count;i++){
        AudioObjectID stream=streams[i].unsignedIntValue;UInt32 start=0,size=sizeof(start);AudioStreamBasicDescription format={0};
        AudioObjectPropertyAddress a=Addr(kAudioStreamPropertyStartingChannel,kAudioObjectPropertyScopeGlobal);
        OSStatus startStatus=AudioObjectGetPropertyData(stream,&a,0,NULL,&size,&start);
        a=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);size=sizeof(format);
        OSStatus formatStatus=AudioObjectGetPropertyData(stream,&a,0,NULL,&size,&format);
        LayoutTrace("stream device=%u index=%lu id=%u start=%u startStatus=%d formatChannels=%u formatStatus=%d formatID=0x%08x flags=0x%08x bits=%u rate=%.6f",device,(unsigned long)i,stream,start,(int)startStatus,format.mChannelsPerFrame,(int)formatStatus,(unsigned)format.mFormatID,(unsigned)format.mFormatFlags,format.mBitsPerChannel,format.mSampleRate);
    }
}
static BOOL InputStreamUsage(const UInt32 *starts,const UInt32 *widths,UInt32 count,UInt32 physical,UInt32 total,UInt32 *base,UInt32 *usage) {
    if(!starts||!widths||!count||!base||!usage||physical>total||!starts[0])return NO;
    // HAL logical input channels may have a common offset from the packed IO buffers.
    *base=starts[0]-1;UInt32 covered=0;
    for(UInt32 i=0;i<count;i++){
        if(starts[i]<=*base||starts[i]-*base-1!=covered||!widths[i]||widths[i]>total-covered||
           (covered<physical&&widths[i]>physical-covered)||(uint64_t)starts[i]+widths[i]-1>UINT32_MAX)return NO;
        usage[i]=covered>=physical;covered+=widths[i];
    }
    return covered==total;
}
static OSStatus UseOnlyTapInputs(AudioDeviceID device,AudioDeviceIOProcID proc,UInt32 physical,UInt32 total) {
    LayoutTrace("tap-input begin device=%u physical=%u total=%u proc=%p",device,physical,total,(void*)proc);
    TraceStreams(device,kAudioDevicePropertyScopeInput);
    NSArray<NSNumber*> *streams=ReadIDs(device,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeInput);
    if(!streams.count||streams.count>(UINT32_MAX-offsetof(AudioHardwareIOProcStreamUsage,mStreamIsOn))/sizeof(UInt32)){LayoutTrace("tap-input failure device=%u stage=stream-list status=%d",device,(int)kAudioHardwareBadStreamError);return kAudioHardwareBadStreamError;}
    UInt32 bytes=(UInt32)(offsetof(AudioHardwareIOProcStreamUsage,mStreamIsOn)+streams.count*sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage=calloc(1,bytes);
    if(!usage){LayoutTrace("tap-input failure device=%u stage=usage-allocation status=%d",device,(int)kAudioHardwareUnspecifiedError);return kAudioHardwareUnspecifiedError;}
    UInt32 *ranges=calloc(streams.count,2*sizeof(UInt32));
    if(!ranges){free(usage);LayoutTrace("tap-input failure device=%u stage=range-allocation status=%d",device,(int)kAudioHardwareUnspecifiedError);return kAudioHardwareUnspecifiedError;}
    UInt32 *starts=ranges,*widths=ranges+streams.count,base=0;
    usage->mIOProc=(void*)proc;usage->mNumberStreams=(UInt32)streams.count;
    OSStatus status=noErr;const char *stage="stream-ranges";
    for(NSUInteger i=0;i<streams.count;i++){
        AudioObjectID stream=streams[i].unsignedIntValue;UInt32 start=0,size=sizeof(start);AudioStreamBasicDescription format={0};
        AudioObjectPropertyAddress address=Addr(kAudioStreamPropertyStartingChannel,kAudioObjectPropertyScopeGlobal);
        status=AudioObjectGetPropertyData(stream,&address,0,NULL,&size,&start);
        if(status!=noErr){stage="stream-start";LayoutTrace("tap-input stream-failure index=%lu id=%u status=%d",(unsigned long)i,stream,(int)status);break;}
        address=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);size=sizeof(format);
        status=AudioObjectGetPropertyData(stream,&address,0,NULL,&size,&format);
        if(status!=noErr){stage="stream-format";LayoutTrace("tap-input stream-failure index=%lu id=%u status=%d",(unsigned long)i,stream,(int)status);break;}
        starts[i]=start;widths[i]=format.mChannelsPerFrame;
    }
    if(status==noErr&&!InputStreamUsage(starts,widths,(UInt32)streams.count,physical,total,&base,usage->mStreamIsOn)){
        stage="stream-ranges";status=kAudioHardwareBadStreamError;
        LayoutTrace("tap-input ranges-rejected base=%u physical=%u total=%u",base,physical,total);
    }
    if(status==noErr){
        LayoutTrace("tap-input ranges-valid base=%u physical=%u total=%u",base,physical,total);
        for(NSUInteger i=0;i<streams.count;i++)LayoutTrace("tap-input usage-planned index=%lu id=%u start=%u relativeStart=%u channels=%u on=%u",(unsigned long)i,streams[i].unsignedIntValue,starts[i],starts[i]-base,widths[i],usage->mStreamIsOn[i]);
    }
    AudioObjectPropertyAddress address=Addr(kAudioDevicePropertyIOProcStreamUsage,kAudioDevicePropertyScopeInput);
    if(status==noErr&&physical){
        stage="usage-write";status=AudioObjectSetPropertyData(device,&address,0,NULL,bytes,usage);
        LayoutTrace("tap-input usage-write device=%u bytes=%u streams=%u status=%d",device,bytes,usage->mNumberStreams,(int)status);
    }
    if(status==noErr&&physical){
        AudioHardwareIOProcStreamUsage *actual=calloc(1,bytes);
        if(!actual){stage="readback-allocation";status=kAudioHardwareUnspecifiedError;}
        else{actual->mIOProc=(void*)proc;UInt32 size=bytes;stage="usage-read";status=AudioObjectGetPropertyData(device,&address,0,NULL,&size,actual);
            LayoutTrace("tap-input usage-read device=%u bytes=%u expectedBytes=%u streams=%u expectedStreams=%u status=%d",device,size,bytes,actual->mNumberStreams,usage->mNumberStreams,(int)status);
            if(LayoutTraceEnabled())for(NSUInteger i=0;i<MIN(streams.count,(NSUInteger)actual->mNumberStreams);i++)LayoutTrace("tap-input usage-readback index=%lu id=%u expected=%u actual=%u",(unsigned long)i,streams[i].unsignedIntValue,usage->mStreamIsOn[i],actual->mStreamIsOn[i]);
            if(status==noErr&&(size!=bytes||actual->mNumberStreams!=usage->mNumberStreams)){stage="readback-shape";status=kAudioHardwareBadStreamError;}
            if(status==noErr)for(NSUInteger i=0;i<streams.count;i++)if(!!actual->mStreamIsOn[i]!=!!usage->mStreamIsOn[i]){stage="readback-usage";status=kAudioHardwareBadStreamError;break;}
            free(actual);
        }
    }
    LayoutTrace("tap-input %s device=%u stage=%s status=%d base=%u physical=%u total=%u",status==noErr?"complete":"failure",device,stage,(int)status,base,physical,total);
    free(ranges);free(usage);return status;
}
static BOOL OutputLayout(NSArray<NSString*> *order,NSString *primary,NSString *monitor,NSString *meter,NSDictionary<NSString*,NSDictionary*> *counts,UInt32 *primaryOffset,UInt32 *monitorOffset,UInt32 *meterOffset,UInt32 *inputs,UInt32 *outputs) {
    NSUInteger expected=1+(monitor.length?1:0)+(meter.length?1:0);
    if(!primary.length||order.count!=expected||counts.count!=expected||[[NSSet setWithArray:order] count]!=expected||
       ![order containsObject:primary]||(monitor.length&&(![order containsObject:monitor]||[monitor isEqualToString:primary]))||
       (meter.length&&(![order containsObject:meter]||[meter isEqualToString:primary]||[meter isEqualToString:monitor])))return NO;
    *inputs=0;*outputs=0;*primaryOffset=0;*monitorOffset=0;*meterOffset=0;
    for(NSString *uid in order){NSDictionary *count=counts[uid];
        if(![count isKindOfClass:NSDictionary.class]||![count[@"out"] isKindOfClass:NSNumber.class]||![count[@"in"] isKindOfClass:NSNumber.class])return NO;
        double outValue=[count[@"out"] doubleValue],inValue=[count[@"in"] doubleValue];
        if(!isfinite(outValue)||!isfinite(inValue)||outValue<2||outValue>UINT32_MAX||inValue<0||inValue>UINT32_MAX||floor(outValue)!=outValue||floor(inValue)!=inValue)return NO;
        UInt32 out=(UInt32)outValue,in=(UInt32)inValue;
        if([uid isEqualToString:primary])*primaryOffset=*outputs;
        else if([uid isEqualToString:monitor])*monitorOffset=*outputs;
        else if([uid isEqualToString:meter]){if(out!=12)return NO;*meterOffset=*outputs;}
        else return NO;
        if(in>UINT32_MAX-*inputs||out>UINT32_MAX-*outputs)return NO;
        *inputs+=in;*outputs+=out;
    }return YES;
}
static BOOL AddStreamRange(NSMutableIndexSet *covered,UInt32 start,UInt32 count,UInt32 total,UInt32 boundary) {
    if(!start||start>total||!count||count>total-(start-1)||(start-1<boundary&&count>boundary-(start-1)))return NO;
    NSRange range=NSMakeRange(start-1,count);if([covered intersectsIndexesInRange:range])return NO;
    [covered addIndexesInRange:range];return YES;
}
static BOOL OutputStreamsValid(AudioDeviceID device,UInt32 total) {
    NSMutableIndexSet *covered=[NSMutableIndexSet indexSet];
    for(NSNumber *stream in ReadIDs(device,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput)){
        UInt32 start=0,size=sizeof(start);AudioStreamBasicDescription format={0};
        AudioObjectPropertyAddress a=Addr(kAudioStreamPropertyStartingChannel,kAudioObjectPropertyScopeGlobal);
        if(AudioObjectGetPropertyData(stream.unsignedIntValue,&a,0,NULL,&size,&start)!=noErr)return NO;
        a=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);size=sizeof(format);
        if(AudioObjectGetPropertyData(stream.unsignedIntValue,&a,0,NULL,&size,&format)!=noErr||!AddStreamRange(covered,start,format.mChannelsPerFrame,total,0))return NO;
    }return covered.count==total;
}
static BOOL PreferredStereo(AudioDeviceID device,UInt32 count,UInt32 *left,UInt32 *right) {
    UInt32 pair[2]={1,2},size=sizeof(pair);AudioObjectPropertyAddress a=Addr(kAudioDevicePropertyPreferredChannelsForStereo,kAudioDevicePropertyScopeOutput);
    OSStatus status=AudioObjectGetPropertyData(device,&a,0,NULL,&size,pair);
    if(status!=noErr){pair[0]=1;pair[1]=2;}
    else if(size!=sizeof(pair))return NO;
    if(!pair[0]||!pair[1]||pair[0]>count||pair[1]>count||pair[0]==pair[1])return NO;
    *left=pair[0]-1;*right=pair[1]-1;return YES;
}
static BOOL RatesMatch(AudioDeviceID primary,AudioDeviceID other) {
    Float64 a=0,b=0;UInt32 size=sizeof(a);AudioObjectPropertyAddress p=Addr(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal);
    if(AudioObjectGetPropertyData(primary,&p,0,NULL,&size,&a)!=noErr)return NO;
    size=sizeof(b);if(AudioObjectGetPropertyData(other,&p,0,NULL,&size,&b)!=noErr)return NO;
    return isfinite(a)&&isfinite(b)&&a>=8000&&b>=8000&&fabs(a-b)<=.001;
}
static void SetFilter(TXFilter *f,int band,double db,double rate) {
    double frequency=band==0?120:(band==1?1000:8000);
    frequency=fmin(frequency,rate*0.4);
    double A=pow(10,db/40),w=2*M_PI*frequency/rate,c=cos(w),s=sin(w),alpha=s/(2*0.70710678);
    double b0,b1,b2,a0,a1,a2;
    if(band==1){b0=1+alpha*A;b1=-2*c;b2=1-alpha*A;a0=1+alpha/A;a1=-2*c;a2=1-alpha/A;}
    else {
        double q=2*sqrt(A)*alpha;
        if(band==0){b0=A*((A+1)-(A-1)*c+q);b1=2*A*((A-1)-(A+1)*c);b2=A*((A+1)-(A-1)*c-q);a0=(A+1)+(A-1)*c+q;a1=-2*((A-1)+(A+1)*c);a2=(A+1)+(A-1)*c-q;}
        else {b0=A*((A+1)+(A-1)*c+q);b1=-2*A*((A-1)+(A+1)*c);b2=A*((A+1)+(A-1)*c-q);a0=(A+1)-(A-1)*c+q;a1=2*((A-1)-(A+1)*c);a2=(A+1)-(A-1)*c-q;}
    }
    f->b0=b0/a0;f->b1=b1/a0;f->b2=b2/a0;f->a1=a1/a0;f->a2=a2/a0;
}
static float FilterSample(TXFilter *f,int ch,float input) {
    double output=f->b0*input+f->z1[ch];
    f->z1[ch]=f->b1*input-f->a1*output+f->z2[ch];
    f->z2[ch]=f->b2*input-f->a2*output;
    if(fabs(f->z1[ch])<1e-24)f->z1[ch]=0;
    if(fabs(f->z2[ch])<1e-24)f->z2[ch]=0;
    if(!isfinite(output)){f->z1[ch]=f->z2[ch]=0;return 0;}
    return (float)output;
}
static BOOL ChannelPointer(const AudioBufferList *list,UInt32 channel,float **ptr,UInt32 *stride,UInt32 *frames) {
    UInt32 offset=0;
    for(UInt32 b=0;b<list->mNumberBuffers;b++) {
        const AudioBuffer *buf=&list->mBuffers[b];
        if(channel>=offset&&channel<offset+buf->mNumberChannels&&buf->mNumberChannels) {
            if(!buf->mData)return NO;
            *ptr=(float*)buf->mData+(channel-offset);*stride=buf->mNumberChannels;
            *frames=buf->mDataByteSize/(sizeof(float)*buf->mNumberChannels);return YES;
        }offset+=buf->mNumberChannels;
    }return NO;
}
// +3 dB applies only to USB meter audio, excluding calibrated reference tones.
static const float USBMeterGain=1.41253754f;
static void ReadSyncFrame(TXSyncDelay *delay,const float raw[2],float main[2],float monitor[2]) {
    if(!delay->samples||!delay->capacity){for(int c=0;c<2;c++)main[c]=monitor[c]=raw[c];return;}
    UInt32 available=MIN(delay->validFrames+1,delay->capacity);
    for(int c=0;c<2;c++){
        delay->samples[2*delay->writeIndex+c]=raw[c];
        main[c]=delay->mainFrames<available?delay->samples[2*((delay->writeIndex+delay->capacity-delay->mainFrames)%delay->capacity)+c]:0;
        monitor[c]=delay->monitorFrames<available?delay->samples[2*((delay->writeIndex+delay->capacity-delay->monitorFrames)%delay->capacity)+c]:0;
    }
    delay->writeIndex=(delay->writeIndex+1)%delay->capacity;delay->validFrames=available;
}
static void InvalidateSyncHistory(TXRenderState *s) {
    for(int slot=0;slot<TX_SLOTS;slot++){s->syncDelay[slot].writeIndex=0;s->syncDelay[slot].validFrames=0;}
}
static void RecordSyncTimestamps(TXRenderState *s,const AudioTimeStamp *now,const AudioTimeStamp *input,const AudioTimeStamp *output) {
    UInt32 nf=now?now->mFlags:0,inf=input?input->mFlags:0,of=output?output->mFlags:0;
    uint64_t nh=now?now->mHostTime:0,ih=input?input->mHostTime:0,oh=output?output->mHostTime:0;
    atomic_store_explicit(&s->syncNowFlags,nf,memory_order_relaxed);atomic_store_explicit(&s->syncInputFlags,inf,memory_order_relaxed);atomic_store_explicit(&s->syncOutputFlags,of,memory_order_relaxed);
    atomic_store_explicit(&s->syncNowHostTime,nh,memory_order_relaxed);atomic_store_explicit(&s->syncInputHostTime,ih,memory_order_relaxed);atomic_store_explicit(&s->syncOutputHostTime,oh,memory_order_relaxed);
    double io=0,no=0;
    if((inf&of&kAudioTimeStampHostTimeValid)&&s->syncHostTickMS>0)io=(oh>=ih?(double)(oh-ih):-(double)(ih-oh))*s->syncHostTickMS;
    if((nf&of&kAudioTimeStampHostTimeValid)&&s->syncHostTickMS>0)no=(oh>=nh?(double)(oh-nh):-(double)(nh-oh))*s->syncHostTickMS;
    atomic_store_explicit(&s->syncInputToOutputMS,isfinite(io)?io:0,memory_order_relaxed);atomic_store_explicit(&s->syncNowToOutputMS,isfinite(no)?no:0,memory_order_relaxed);
}
static float MeterReference(uint64_t frame,double rate) {
    uint64_t length=(uint64_t)(rate*4),step=frame/length,position=frame%length;
    if(step>=3)return 0;
    double db[3]={-18,-9,-3},fade=rate*.01;
    double envelope=fmax(0,fmin(1,fmin(position/fade,(length-1-position)/fade)));
    return pow(10,db[step]/20)*envelope*sin(2*M_PI*440*frame/rate);
}
uint64_t TXRequestLevelPeakReset(TXRenderState *state) {
    return state?atomic_fetch_add_explicit(&state->levelResetRequested,1,memory_order_acq_rel)+1:0;
}
static void ClearLevelHolds(TXRenderState *s) {
    for(int slot=0;slot<TX_SLOTS;slot++){
        atomic_store_explicit(&s->channelPeakHold[slot],0,memory_order_relaxed);
        atomic_store_explicit(&s->channelOver[slot],false,memory_order_relaxed);
    }
    atomic_store_explicit(&s->mainPreLimiterHold,0,memory_order_relaxed);
    atomic_store_explicit(&s->monitorPreLimiterHold,0,memory_order_relaxed);
}
static void ApplyLevelPeakReset(TXRenderState *s) {
    uint64_t requested=atomic_load_explicit(&s->levelResetRequested,memory_order_acquire);
    if(requested==atomic_load_explicit(&s->levelResetApplied,memory_order_relaxed))return;
    ClearLevelHolds(s);atomic_store_explicit(&s->levelResetApplied,requested,memory_order_release);
}
static void ClearLevelCurrent(TXRenderState *s) {
    for(int slot=0;slot<TX_SLOTS;slot++)atomic_store_explicit(&s->peak[slot],0,memory_order_relaxed);
    for(int slot=0;slot<6;slot++){atomic_store_explicit(&s->usbPeak[slot],0,memory_order_relaxed);atomic_store_explicit(&s->usbRMS[slot],0,memory_order_relaxed);}
    atomic_store_explicit(&s->outputPeak,0,memory_order_relaxed);atomic_store_explicit(&s->monitorPeak,0,memory_order_relaxed);
    atomic_store_explicit(&s->mainPreLimiterPeak,0,memory_order_relaxed);atomic_store_explicit(&s->monitorPreLimiterPeak,0,memory_order_relaxed);
    atomic_store_explicit(&s->mainGainReductionDB,0,memory_order_relaxed);atomic_store_explicit(&s->monitorGainReductionDB,0,memory_order_relaxed);
}
static void ResetLevelRecords(TXRenderState *s) {
    uint64_t requested=atomic_load_explicit(&s->levelResetRequested,memory_order_acquire);
    ClearLevelCurrent(s);ClearLevelHolds(s);atomic_store_explicit(&s->levelResetApplied,requested,memory_order_release);
}
static OSStatus LevelLayoutFault(TXRenderState *s,int fault) {
    atomic_store(&s->layoutFault,fault);ClearLevelCurrent(s);InvalidateSyncHistory(s);return noErr;
}
static float LevelReductionDB(float gain) {
    return -20*log10f(fminf(1,fmaxf(1e-9f,gain)));
}
static OSStatus Render(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    TXRenderState *s=context;ApplyLevelPeakReset(s);RecordSyncTimestamps(s,now,it,ot);
    if(!input||!output){return LevelLayoutFault(s,4);}
    for(UInt32 b=0;b<output->mNumberBuffers;b++)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    UInt32 channels=0;for(UInt32 b=0;b<input->mNumberBuffers;b++)channels+=input->mBuffers[b].mNumberChannels;
    if(channels!=s->physicalInputChannels+2*s->tapCount){return LevelLayoutFault(s,1);}
    float *out[2];UInt32 os[2],of[2];
    if(!ChannelPointer(output,s->outputLeft,&out[0],&os[0],&of[0])||!ChannelPointer(output,s->outputRight,&out[1],&os[1],&of[1])){return LevelLayoutFault(s,2);}
    UInt32 frames=MIN(of[0],of[1]);float *monitor[2];UInt32 mos[2];
    if(s->monitorEnabled)for(int c=0;c<2;c++){
        UInt32 n=0;if(!ChannelPointer(output,c?s->monitorRight:s->monitorLeft,&monitor[c],&mos[c],&n)){return LevelLayoutFault(s,6);}frames=MIN(frames,n);
    }
    float *in[TX_SLOTS][2];UInt32 stride[TX_SLOTS][2];
    float *meter[6][2];UInt32 ms[6][2];
    if(s->meterEnabled)for(int slot=0;slot<6;slot++)for(int c=0;c<2;c++){
        UInt32 n=0;if(!ChannelPointer(output,s->meterOutputOffset+slot*2+c,&meter[slot][c],&ms[slot][c],&n)){return LevelLayoutFault(s,5);}frames=MIN(frames,n);
    }
    for(int t=0;t<s->tapCount;t++)for(int c=0;c<2;c++){
        UInt32 n=0;if(!ChannelPointer(input,s->physicalInputChannels+t*2+c,&in[t][c],&stride[t][c],&n)){return LevelLayoutFault(s,3);}frames=MIN(frames,n);
    }
    uint64_t sourceCommand=atomic_load_explicit(&s->sourceUpdateCommand,memory_order_acquire);
    UInt32 updating=(UInt32)sourceCommand;
    for(int slot=0;slot<TX_SLOTS;slot++){
        uint64_t command=atomic_load_explicit(&s->syncCommand[slot],memory_order_acquire);
        if(command==s->syncAppliedCommand[slot])continue;
        s->syncAppliedCommand[slot]=command;s->syncDelay[slot].mainFrames=command&0xFFFFF;s->syncDelay[slot].monitorFrames=(command>>20)&0xFFFFF;
        s->syncDelay[slot].validFrames=0;s->syncDelay[slot].writeIndex=0;
        for(int b=0;b<TX_EQ;b++){s->filters[slot][b].z1[0]=s->filters[slot][b].z1[1]=s->filters[slot][b].z2[0]=s->filters[slot][b].z2[1]=0;s->syncMonitorFilters[slot][b].z1[0]=s->syncMonitorFilters[slot][b].z1[1]=s->syncMonitorFilters[slot][b].z2[0]=s->syncMonitorFilters[slot][b].z2[1]=0;}
    }
    atomic_store_explicit(&s->sourceUpdateApplied,sourceCommand,memory_order_release);
    // Validate live IO while suppressing every output during a protected transition.
    if(atomic_load(&s->transitionMuted)){
        ClearLevelCurrent(s);InvalidateSyncHistory(s);
        atomic_fetch_add(&s->callbacks,1);atomic_fetch_add(&s->frames,frames);return noErr;
    }
    float target[TX_SLOTS],peaks[TX_SLOTS]={0},outputPeak=0,monitorPeak=0,usbPeak[6]={0};
    UInt32 routes[TX_SLOTS];BOOL muted[TX_SLOTS];double usbEnergy[6]={0};float busPeaks[2]={0};
    BOOL reference=atomic_load(&s->meterReference);
    for(int t=0;t<s->tapCount;t++){
        int slot=s->tapSlots[t];float rawGain=atomic_load(&s->gain[slot]);muted[slot]=atomic_load(&s->muted[slot])||((updating>>slot)&1);target[t]=muted[slot]||!isfinite(rawGain)?0:fmaxf(0,fminf(1,rawGain));
        for(int b=0;b<TX_EQ;b++){
            double requested=atomic_load(&s->eq[slot][b]);requested=isfinite(requested)?fmax(-18,fmin(18,requested)):0;double delta=requested-s->currentEQ[slot][b];
            if(fabs(delta)>0.00001){s->currentEQ[slot][b]+=fmax(-0.25,fmin(0.25,delta));SetFilter(&s->filters[slot][b],b,s->currentEQ[slot][b],s->sampleRate);SetFilter(&s->syncMonitorFilters[slot][b],b,s->currentEQ[slot][b],s->sampleRate);}
        }
    }
    for(int slot=0;slot<TX_SLOTS;slot++)routes[slot]=slot==6?TXOutputMain:atomic_load(&s->route[slot]);
    float rawMaster=atomic_load(&s->master),rawMonitor=atomic_load(&s->monitorGain);
    BOOL masterMuted=atomic_load(&s->masterMuted);
    float master=masterMuted||!isfinite(rawMaster)?0:fmaxf(0,fminf(1,rawMaster));
    float monitorTarget=isfinite(rawMonitor)?fmaxf(0,fminf(1,rawMonitor)):0;
    float smoothing=1-expf(-1/(0.015*s->sampleRate));
    float limiterRelease=1-expf(-1/(0.080*s->sampleRate));
    for(UInt32 f=0;f<frames;f++) {
        float mix[2]={0},monitorMix[2]={0},slotPCM[6][2]={0};
        for(int t=0;t<s->tapCount;t++){
            int slot=s->tapSlots[t];s->smoothGain[slot]+=smoothing*(target[t]-s->smoothGain[slot]);
            float raw[2]={in[t][0][f*stride[t][0]],in[t][1][f*stride[t][1]]},mainRaw[2],monitorRaw[2];
            TXSyncDelay *delay=&s->syncDelay[slot];ReadSyncFrame(delay,raw,mainRaw,monitorRaw);
            BOOL split=s->monitorEnabled&&delay->mainFrames!=delay->monitorFrames;
            for(int c=0;c<2;c++){
                float value=mainRaw[c],monitorValue=monitorRaw[c];
                for(int b=0;b<TX_EQ;b++)value=FilterSample(&s->filters[slot][b],c,value);
                if(split)for(int b=0;b<TX_EQ;b++)monitorValue=FilterSample(&s->syncMonitorFilters[slot][b],c,monitorValue);
                value*=s->smoothGain[slot];if(!isfinite(value)||muted[slot])value=0;
                if(split){monitorValue*=s->smoothGain[slot];if(!isfinite(monitorValue)||muted[slot])monitorValue=0;}else monitorValue=value;
                peaks[slot]=fmaxf(peaks[slot],fmaxf(fabsf(value),fabsf(monitorValue)));
                if(routes[slot]==TXOutputMain||routes[slot]==TXOutputBoth)mix[c]+=value;
                if(s->monitorEnabled&&(routes[slot]==TXOutputMonitor||routes[slot]==TXOutputBoth))monitorMix[c]+=monitorValue;
                if(s->meterEnabled&&slot<6)slotPCM[slot][c]=routes[slot]==TXOutputMonitor?monitorValue:value;
            }
        }
        s->smoothMaster+=smoothing*(master-s->smoothMaster);
        if(monitorTarget>0)s->smoothMonitorGain+=smoothing*(monitorTarget-s->smoothMonitorGain);
        else s->smoothMonitorGain=0;
        float masterGain=masterMuted?0:s->smoothMaster;
        float monitorGain=monitorTarget>0?s->smoothMonitorGain:0;
        float test=reference?MeterReference(s->meterReferenceFrame,s->sampleRate):0;
        if(s->meterEnabled)for(int slot=0;slot<6;slot++){
            float mirrorGain=0;
            if(routes[slot]==TXOutputMain||routes[slot]==TXOutputBoth)mirrorGain=masterGain;
            else if(routes[slot]==TXOutputMonitor&&s->monitorEnabled)mirrorGain=masterGain*monitorGain;
            float l=slotPCM[slot][0]*mirrorGain,r=slotPCM[slot][1]*mirrorGain;
            if(reference)l=r=slot==1&&!masterMuted?test:0;
            else{l*=USBMeterGain;r*=USBMeterGain;}
            if(!isfinite(l))l=0;if(!isfinite(r))r=0;
            float p=fmaxf(fabsf(l),fabsf(r)),g=p>0.98f?0.98f/p:1;
            meter[slot][0][f*ms[slot][0]]=l*g;meter[slot][1][f*ms[slot][1]]=r*g;
            usbPeak[slot]=fmaxf(usbPeak[slot],p*g);usbEnergy[slot]+=(double)(l*g)*(l*g)+(double)(r*g)*(r*g);
        }
        if(reference)s->meterReferenceFrame++;
        BOOL limited=NO;
        for(int bus=0;bus<(s->monitorEnabled?2:1);bus++){
            float *pcm=bus?monitorMix:mix;float gain=masterGain*(bus?monitorGain:1);
            float peak=fmaxf(fabsf(pcm[0]),fabsf(pcm[1]))*gain;
            busPeaks[bus]=fmaxf(busPeaks[bus],fminf(FLT_MAX,peak));
            float required=peak>0.98f?0.98f/peak:1;
            float *limiter=bus?&s->monitorLimiterGain:&s->limiterGain;
            if(required<*limiter)*limiter=required;
            else *limiter+=limiterRelease*(required-*limiter);
            if(*limiter<0.999f)limited=YES;
            for(int c=0;c<2;c++){
                float value=fmaxf(-0.98f,fminf(0.98f,pcm[c]*gain*(*limiter)));
                if(bus){monitor[c][f*mos[c]]=value;monitorPeak=fmaxf(monitorPeak,fabsf(value));}
                else{out[c][f*os[c]]=value;outputPeak=fmaxf(outputPeak,fabsf(value));}
            }
        }
        if(limited)atomic_fetch_add_explicit(&s->limitedFrames,1,memory_order_relaxed);
    }
    for(int slot=0;slot<TX_SLOTS;slot++){
        atomic_store(&s->peak[slot],peaks[slot]);
        atomic_store_explicit(&s->channelPeakHold[slot],fmaxf(atomic_load_explicit(&s->channelPeakHold[slot],memory_order_relaxed),peaks[slot]),memory_order_relaxed);
        if(peaks[slot]>1)atomic_store_explicit(&s->channelOver[slot],true,memory_order_relaxed);
    }
    atomic_store_explicit(&s->mainPreLimiterPeak,busPeaks[0],memory_order_relaxed);
    atomic_store_explicit(&s->monitorPreLimiterPeak,busPeaks[1],memory_order_relaxed);
    atomic_store_explicit(&s->mainPreLimiterHold,fmaxf(atomic_load_explicit(&s->mainPreLimiterHold,memory_order_relaxed),busPeaks[0]),memory_order_relaxed);
    atomic_store_explicit(&s->monitorPreLimiterHold,fmaxf(atomic_load_explicit(&s->monitorPreLimiterHold,memory_order_relaxed),busPeaks[1]),memory_order_relaxed);
    atomic_store_explicit(&s->mainGainReductionDB,frames?LevelReductionDB(s->limiterGain):0,memory_order_relaxed);
    atomic_store_explicit(&s->monitorGainReductionDB,s->monitorEnabled&&frames?LevelReductionDB(s->monitorLimiterGain):0,memory_order_relaxed);
    atomic_store(&s->outputPeak,outputPeak);atomic_store(&s->monitorPeak,monitorPeak);
    for(int slot=0;slot<6;slot++){atomic_store(&s->usbPeak[slot],usbPeak[slot]);atomic_store(&s->usbRMS[slot],frames?sqrt(usbEnergy[slot]/(2*frames)):0);}
    atomic_fetch_add(&s->callbacks,1);atomic_fetch_add(&s->frames,frames);return noErr;
}

static NSDictionary *GuardAggregateDescription(NSString *tapUUID) {
    return @{@kAudioAggregateDeviceUIDKey:[@"local.tx6mac.guard-probe." stringByAppendingString:NSUUID.UUID.UUIDString],@kAudioAggregateDeviceNameKey:@"TX6Mac Guard Probe",@kAudioAggregateDeviceIsPrivateKey:@YES,@kAudioAggregateDeviceSubDeviceListKey:@[],@kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:tapUUID,@kAudioSubTapDriftCompensationKey:@YES}],@kAudioAggregateDeviceTapAutoStartKey:@YES};
}
typedef OSStatus (^TXGuardCreate)(CATapDescription*,AudioObjectID*);
typedef OSStatus (^TXGuardDestroy)(AudioObjectID);
typedef OSStatus (^TXGuardCreateAggregate)(NSDictionary*,AudioDeviceID*);
typedef NSArray<NSNumber*>* (^TXGuardOwners)(NSError**);
static NSError *GuardError(NSString *stage,OSStatus status) {
    return [NSError errorWithDomain:@"local.tx6mac.audio-mute-guard" code:status userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@: %d",stage,(int)status]}];
}
static NSArray<NSNumber*> *GuardOwnProcesses(NSError **error) {
    AudioObjectPropertyAddress a=Addr(kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal);UInt32 size=0;
    OSStatus status=AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&size);
    if(status!=noErr||size%sizeof(AudioObjectID)){if(error)*error=GuardError(@"Process list",status?:kAudioHardwareBadObjectError);return nil;}
    if(!size)return @[];
    AudioObjectID *ids=malloc(size);if(!ids){if(error)*error=GuardError(@"Process allocation",kAudioHardwareUnspecifiedError);return nil;}
    UInt32 capacity=size;status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,ids);
    NSMutableArray *owners=[NSMutableArray array];
    if(status==noErr&&(size>capacity||size%sizeof(AudioObjectID)))status=kAudioHardwareBadObjectError;
    if(status==noErr)for(UInt32 i=0;i<size/sizeof(*ids);i++){
        pid_t pid=0;UInt32 bytes=sizeof(pid);AudioObjectPropertyAddress p=Addr(kAudioProcessPropertyPID,kAudioObjectPropertyScopeGlobal);
        status=AudioObjectGetPropertyData(ids[i],&p,0,NULL,&bytes,&pid);
        if(status!=noErr||bytes!=sizeof(pid)){if(status==noErr)status=kAudioHardwareBadObjectError;break;}
        if(pid==getpid())[owners addObject:@(ids[i])];
    }
    free(ids);if(status!=noErr){if(error)*error=GuardError(@"Process ownership",status);return nil;}return owners;
}
@interface TXAudioMuteGuard ()
- (instancetype)initWithCreate:(TXGuardCreate)create destroy:(TXGuardDestroy)destroy createAggregate:(TXGuardCreateAggregate)createAggregate destroyAggregate:(TXGuardDestroy)destroyAggregate owners:(TXGuardOwners)owners;
@end
@implementation TXAudioMuteGuard {
    AudioObjectID _tap;
    AudioDeviceID _aggregate;
    NSString *_tapUUID;
    TXGuardCreate _create;
    TXGuardDestroy _destroy,_destroyAggregate;
    TXGuardCreateAggregate _createAggregate;
    TXGuardOwners _owners;
}
- (instancetype)init {
    return [self initWithCreate:^OSStatus(CATapDescription *description,AudioObjectID *tap){return AudioHardwareCreateProcessTap(description,tap);}
                       destroy:^OSStatus(AudioObjectID tap){return AudioHardwareDestroyProcessTap(tap);}
               createAggregate:^OSStatus(NSDictionary *description,AudioDeviceID *aggregate){return AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description,aggregate);}
              destroyAggregate:^OSStatus(AudioObjectID aggregate){return AudioHardwareDestroyAggregateDevice(aggregate);}
                        owners:^NSArray<NSNumber*>*(NSError **error){return GuardOwnProcesses(error);}];
}
- (instancetype)initWithCreate:(TXGuardCreate)create destroy:(TXGuardDestroy)destroy createAggregate:(TXGuardCreateAggregate)createAggregate destroyAggregate:(TXGuardDestroy)destroyAggregate owners:(TXGuardOwners)owners {
    if((self=[super init])){_create=[create copy];_destroy=[destroy copy];_createAggregate=[createAggregate copy];_destroyAggregate=[destroyAggregate copy];_owners=[owners copy];}return self;
}
- (BOOL)active{return _tap!=kAudioObjectUnknown||_aggregate!=kAudioObjectUnknown;}
- (BOOL)begin:(NSError**)error {
    NSAssert(!NSThread.isMainThread,@"Mute guard must run on the serial HAL worker");
    if(error)*error=nil;if(_tap&&_aggregate)return YES;
    if(!_tap){
        NSError *ownerError=nil;NSArray<NSNumber*> *owners=_owners(&ownerError);
        if(!owners){if(error)*error=ownerError?:GuardError(@"Process ownership",kAudioHardwareBadObjectError);return NO;}
        CATapDescription *description=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:owners];
        description.name=@"TX6Mac Transition Guard";description.privateTap=YES;description.muteBehavior=CATapMuted;
        AudioObjectID tap=kAudioObjectUnknown;OSStatus status=_create(description,&tap);
        if(status!=noErr||tap==kAudioObjectUnknown){if(error)*error=GuardError(@"Create mute guard",status?:kAudioHardwareBadObjectError);return NO;}
        _tap=tap;_tapUUID=description.UUID.UUIDString;
    }
    // A private tap-only aggregate keeps the source gate attached without an IOProc.
    AudioDeviceID aggregate=0;OSStatus status=_createAggregate(GuardAggregateDescription(_tapUUID),&aggregate);
    if(status==noErr&&aggregate){_aggregate=aggregate;return YES;}
    NSError *creationError=GuardError(@"Create guard aggregate",status?:kAudioHardwareBadObjectError),*cleanupError=nil;
    [self end:&cleanupError];
    if(cleanupError){NSMutableDictionary *info=[creationError.userInfo mutableCopy];info[NSUnderlyingErrorKey]=cleanupError;creationError=[NSError errorWithDomain:creationError.domain code:creationError.code userInfo:info];}
    if(error)*error=creationError;return NO;
}
- (BOOL)end:(NSError**)error {
    NSAssert(!NSThread.isMainThread,@"Mute guard must run on the serial HAL worker");
    if(error)*error=nil;
    if(_aggregate){OSStatus status=_destroyAggregate(_aggregate);if(status!=noErr){if(error)*error=GuardError(@"Destroy guard aggregate",status);return NO;}_aggregate=0;}
    if(_tap){OSStatus status=_destroy(_tap);if(status!=noErr){if(error)*error=GuardError(@"Destroy mute guard",status);return NO;}_tap=0;_tapUUID=nil;}
    return YES;
}
- (void)dealloc {
    if(_aggregate){OSStatus status=_destroyAggregate(_aggregate);if(status!=noErr)fprintf(stderr,"Mute guard aggregate cleanup failed: %d\n",(int)status);}
    if(_tap){OSStatus status=_destroy(_tap);if(status!=noErr)fprintf(stderr,"Mute guard cleanup failed: %d\n",(int)status);}
}
@end

static void GuardEvent(NSString *event,TXAudioMuteGuard *guard,NSError *error) {
    struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);
    NSMutableDictionary *entry=[@{@"event":event,@"monotonicSeconds":@(now.tv_sec+now.tv_nsec/1e9),@"active":@(guard.active)} mutableCopy];
    if(error){entry[@"error"]=error.localizedDescription;entry[@"errorCode"]=@(error.code);}
    NSData *data=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
}
int TXHoldAudioMuteGuard(void) {
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier])if(app.processIdentifier!=getpid()){
        GuardEvent(@"refused",nil,GuardError(@"Quit the mixer before the mute guard diagnostic",2));return 2;
    }
    __block int result=0;dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_queue_t worker=dispatch_queue_create("local.tx6mac.mute-guard-diagnostic",DISPATCH_QUEUE_SERIAL);
    dispatch_async(worker,^{@autoreleasepool{
        TXAudioMuteGuard *guard=[TXAudioMuteGuard new];NSError *error=nil;
        @try{
            GuardEvent(@"waiting",guard,nil);[NSThread sleepForTimeInterval:3];GuardEvent(@"begin_requested",guard,nil);
            if(![guard begin:&error]){GuardEvent(@"begin_failed",guard,error);result=3;}
            else{GuardEvent(@"began",guard,nil);[NSThread sleepForTimeInterval:5];}
        }@catch(NSException *exception){GuardEvent(@"exception",guard,GuardError(exception.reason?:exception.name,4));result=4;}
        @finally{
            if(guard.active){GuardEvent(@"end_requested",guard,nil);if([guard end:&error])GuardEvent(@"ended",guard,nil);else{GuardEvent(@"end_failed",guard,error);result=4;}}
            GuardEvent(result?@"failed":@"completed",guard,nil);dispatch_semaphore_signal(finished);
        }
    }});
    dispatch_semaphore_wait(finished,DISPATCH_TIME_FOREVER);return result;
}

typedef struct {
    _Atomic(uint64_t) callbacks,frames,samples,nonfinite;
    _Atomic(double) energy;
    _Atomic(float) peak;
    _Atomic(int) fault;
} TXGuardProbePCM;
_Static_assert(__atomic_always_lock_free(sizeof(double),0)&&__atomic_always_lock_free(sizeof(uint64_t),0)&&__atomic_always_lock_free(sizeof(float),0),"Guard probe statistics must be lock-free");
static OSStatus GuardProbeInput(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    TXGuardProbePCM *s=context;
    if(output)for(UInt32 b=0;b<output->mNumberBuffers;b++)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    if(!input){atomic_store(&s->fault,1);return noErr;}
    UInt32 channels=0,frames=UINT32_MAX;
    for(UInt32 b=0;b<input->mNumberBuffers;b++){
        const AudioBuffer *buffer=&input->mBuffers[b];
        if(!buffer->mData||!buffer->mNumberChannels||buffer->mNumberChannels>2||buffer->mDataByteSize%(sizeof(float)*buffer->mNumberChannels)){atomic_store(&s->fault,2);return noErr;}
        channels+=buffer->mNumberChannels;frames=MIN(frames,buffer->mDataByteSize/(sizeof(float)*buffer->mNumberChannels));
    }
    if(channels!=2){atomic_store(&s->fault,3);return noErr;}
    float peak=atomic_load_explicit(&s->peak,memory_order_relaxed);double energy=atomic_load_explicit(&s->energy,memory_order_relaxed);uint64_t finite=0,bad=0;
    for(UInt32 b=0;b<input->mNumberBuffers;b++){
        const AudioBuffer *buffer=&input->mBuffers[b];const float *pcm=buffer->mData;
        for(UInt32 f=0;f<frames;f++)for(UInt32 c=0;c<buffer->mNumberChannels;c++){
            float value=pcm[f*buffer->mNumberChannels+c];if(!isfinite(value)){bad++;continue;}
            peak=fmaxf(peak,fabsf(value));energy+=(double)value*value;finite++;
        }
    }
    atomic_store_explicit(&s->peak,peak,memory_order_relaxed);atomic_store_explicit(&s->energy,energy,memory_order_relaxed);
    atomic_fetch_add_explicit(&s->samples,finite,memory_order_relaxed);atomic_fetch_add_explicit(&s->nonfinite,bad,memory_order_relaxed);
    atomic_fetch_add_explicit(&s->frames,frames,memory_order_relaxed);atomic_fetch_add_explicit(&s->callbacks,1,memory_order_relaxed);return noErr;
}
static NSDictionary *ProbeIDs(AudioObjectID object,AudioObjectPropertySelector selector,AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a=Addr(selector,scope);UInt32 size=0;OSStatus status=AudioObjectGetPropertyDataSize(object,&a,0,NULL,&size);
    if(status==noErr&&size%sizeof(AudioObjectID))status=kAudioHardwareBadObjectError;
    NSMutableArray *values=[NSMutableArray array];
    if(status==noErr&&size){
        AudioObjectID *ids=malloc(size);UInt32 capacity=size;
        if(!ids)status=kAudioHardwareUnspecifiedError;
        else{status=AudioObjectGetPropertyData(object,&a,0,NULL,&size,ids);
            if(status==noErr&&(size>capacity||size%sizeof(*ids)))status=kAudioHardwareBadObjectError;
            if(status==noErr)for(UInt32 i=0;i<size/sizeof(*ids);i++)[values addObject:@(ids[i])];free(ids);}
    }
    return @{@"status":@(status),@"objects":values};
}
static NSDictionary *ProbeUInt(AudioObjectID object,AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a=Addr(selector,kAudioObjectPropertyScopeGlobal);UInt32 value=0,size=sizeof(value);
    OSStatus status=AudioObjectGetPropertyData(object,&a,0,NULL,&size,&value);if(status==noErr&&size!=sizeof(value))status=kAudioHardwareBadObjectError;
    return @{@"status":@(status),@"value":status==noErr?@(value):NSNull.null};
}
static NSDictionary *ProbeProcesses(void) {
    NSDictionary *list=ProbeIDs(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal);NSMutableArray *processes=[NSMutableArray array];
    for(NSNumber *object in list[@"objects"]){AudioObjectID process=object.unsignedIntValue;
        [processes addObject:@{@"objectID":object,@"pid":ProbeUInt(process,kAudioProcessPropertyPID),@"bundleID":ReadString(process,kAudioProcessPropertyBundleID),
            @"runningOutput":ProbeUInt(process,kAudioProcessPropertyIsRunningOutput),@"outputDevices":ProbeIDs(process,kAudioProcessPropertyDevices,kAudioDevicePropertyScopeOutput),@"inputDevices":ProbeIDs(process,kAudioProcessPropertyDevices,kAudioDevicePropertyScopeInput)}];
    }
    return @{@"status":list[@"status"],@"processes":processes};
}
static NSDictionary *ProbeTapReadback(AudioObjectID tap) {
    if(!tap)return @{@"present":@NO};
    CFTypeRef raw=NULL;UInt32 size=sizeof(raw);AudioObjectPropertyAddress a=Addr(kAudioTapPropertyDescription,kAudioObjectPropertyScopeGlobal);
    OSStatus status=AudioObjectGetPropertyData(tap,&a,0,NULL,&size,&raw);CATapDescription *description=CFBridgingRelease(raw);
    NSMutableDictionary *result=[@{@"present":@YES,@"status":@(status),@"tapUID":ReadString(tap,kAudioTapPropertyUID)} mutableCopy];
    if(status==noErr&&[description isKindOfClass:CATapDescription.class]){
        result[@"description"]=@{@"muteBehavior":@(description.muteBehavior),@"processes":description.processes?:@[],@"exclusive":@(description.exclusive),@"private":@(description.privateTap),@"deviceUID":description.deviceUID?:NSNull.null,@"stream":description.stream?:NSNull.null,@"bundleIDs":description.bundleIDs?:@[],@"uuid":description.UUID.UUIDString?:@""};
    }
    AudioStreamBasicDescription format={0};size=sizeof(format);a=Addr(kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal);
    OSStatus formatStatus=AudioObjectGetPropertyData(tap,&a,0,NULL,&size,&format);
    result[@"format"]=@{@"status":@(formatStatus),@"sampleRate":isfinite(format.mSampleRate)?@(format.mSampleRate):NSNull.null,@"channels":@(format.mChannelsPerFrame),@"formatID":@(format.mFormatID),@"flags":@(format.mFormatFlags),@"bits":@(format.mBitsPerChannel)};
    return result;
}

typedef OSStatus (^TXProbeOperation)(NSString*);
typedef void (^TXProbeEvent)(NSString*,OSStatus);
typedef void (^TXProbeWait)(double);
static int RunGuardProbeStages(TXProbeOperation operation,TXProbeEvent event,TXProbeWait wait) {
    int result=0;
    @try{
        event(@"waiting",noErr);wait(1);
        NSArray *actions=@[@"begin",@"aggregate_create",@"validate_input",@"io_create",@"io_start",@"io_stop"];
        double holds[]={2,2,0,0,3,2};
        for(NSUInteger i=0;i<actions.count;i++){
            NSString *action=actions[i];event([action stringByAppendingString:@"_requested"],noErr);OSStatus status=operation(action);event(action,status);
            if(status!=noErr){result=3;break;}if(holds[i]){wait(holds[i]);event([action stringByAppendingString:@"_observed"],noErr);}
        }
    }@catch(NSException *exception){event(@"exception",kAudioHardwareUnspecifiedError);result=3;}
    @finally{
        for(NSString *action in @[@"io_stop",@"io_destroy",@"aggregate_destroy",@"end"]){
            for(int attempt=0;attempt<2;attempt++){
                OSStatus status=operation(action);event([@"cleanup_" stringByAppendingString:action],status);
                if(status==noErr)break;result=4;
            }
        }
        event(result?@"failed":@"completed",result?kAudioHardwareUnspecifiedError:noErr);
    }
    return result;
}
int TXProbeAudioMuteGuard(void) {
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier])if(app.processIdentifier!=getpid()){
        GuardEvent(@"refused",nil,GuardError(@"Quit the mixer before the mute guard probe",2));return 2;
    }
    __block int result=0;dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_queue_t worker=dispatch_queue_create("local.tx6mac.mute-guard-stages",DISPATCH_QUEUE_SERIAL);
    dispatch_source_t watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
    dispatch_source_set_timer(watchdog,dispatch_time(DISPATCH_TIME_NOW,18*NSEC_PER_SEC),DISPATCH_TIME_FOREVER,0);
    dispatch_source_set_event_handler(watchdog,^{_Exit(5);});dispatch_resume(watchdog);
    dispatch_async(worker,^{@autoreleasepool{
        TXGuardProbePCM *pcm=calloc(1,sizeof(*pcm));
        if(!pcm){result=3;dispatch_semaphore_signal(finished);return;}
        __block AudioObjectID tap=0;__block AudioDeviceID aggregate=0;__block AudioDeviceIOProcID proc=NULL;__block BOOL started=NO;__block NSString *tapUUID=nil;
        TXProbeEvent event=^(NSString *stage,OSStatus status){
            struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);uint64_t samples=atomic_load(&pcm->samples);double energy=atomic_load(&pcm->energy);float peak=atomic_load(&pcm->peak);
            NSDictionary *entry=@{@"event":stage,@"status":@(status),@"monotonicSeconds":@(now.tv_sec+now.tv_nsec/1e9),@"ownPID":@(getpid()),@"tapID":@(tap),@"aggregateID":@(aggregate),@"ioStarted":@(started),@"active":@(tap!=0),@"activeIsNotProofOfSilence":@YES,@"tap":ProbeTapReadback(tap),@"rawHAL":ProbeProcesses(),@"aggregateInputChannels":@(aggregate?Channels(aggregate,kAudioDevicePropertyScopeInput):0),@"aggregateOutputChannels":@(aggregate?Channels(aggregate,kAudioDevicePropertyScopeOutput):0),@"capture":@{@"callbacks":@(atomic_load(&pcm->callbacks)),@"frames":@(atomic_load(&pcm->frames)),@"finiteSamples":@(samples),@"nonfinite":@(atomic_load(&pcm->nonfinite)),@"peak":@(peak),@"rms":@(samples?sqrt(energy/samples):0),@"fault":@(atomic_load(&pcm->fault))}};
            NSData *json=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);fflush(stdout);
        };
        TXProbeOperation operation=^OSStatus(NSString *action){
            if([action isEqualToString:@"begin"]){
                NSError *error=nil;NSArray *owners=GuardOwnProcesses(&error);if(!owners)return (OSStatus)error.code;
                CATapDescription *description=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:owners];
                description.name=@"TX6Mac Transition Guard";description.privateTap=YES;description.muteBehavior=CATapMuted;
                AudioObjectID created=0;OSStatus status=AudioHardwareCreateProcessTap(description,&created);
                if(status==noErr&&created){tap=created;tapUUID=description.UUID.UUIDString;}return status?:created?noErr:kAudioHardwareBadObjectError;
            }
            if([action isEqualToString:@"aggregate_create"]){
                if(!tapUUID.length)return kAudioHardwareBadObjectError;AudioDeviceID created=0;
                OSStatus status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)GuardAggregateDescription(tapUUID),&created);
                if(status==noErr&&created)aggregate=created;return status?:created?noErr:kAudioHardwareBadObjectError;
            }
            if([action isEqualToString:@"validate_input"]){
                if(Channels(aggregate,kAudioDevicePropertyScopeInput)!=2||Channels(aggregate,kAudioDevicePropertyScopeOutput)!=0)return kAudioHardwareBadStreamError;
                NSArray *streams=ReadIDs(aggregate,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeInput);if(!streams.count)return kAudioHardwareBadStreamError;
                for(NSNumber *stream in streams){AudioStreamBasicDescription format={0};UInt32 size=sizeof(format);AudioObjectPropertyAddress a=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);OSStatus status=AudioObjectGetPropertyData(stream.unsignedIntValue,&a,0,NULL,&size,&format);
                    if(status!=noErr)return status;if(format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||(format.mFormatFlags&kAudioFormatFlagIsBigEndian)||format.mBitsPerChannel!=32||!format.mChannelsPerFrame||format.mBytesPerFrame!=sizeof(float)*((format.mFormatFlags&kAudioFormatFlagIsNonInterleaved)?1:format.mChannelsPerFrame)||!isfinite(format.mSampleRate)||format.mSampleRate<8000)return kAudioHardwareUnsupportedOperationError;}
                return noErr;
            }
            if([action isEqualToString:@"io_create"]){AudioDeviceIOProcID created=NULL;OSStatus status=AudioDeviceCreateIOProcID(aggregate,GuardProbeInput,pcm,&created);if(status==noErr&&created)proc=created;return status?:created?noErr:kAudioHardwareBadObjectError;}
            if([action isEqualToString:@"io_start"]){OSStatus status=AudioDeviceStart(aggregate,proc);if(status==noErr)started=YES;return status;}
            if([action isEqualToString:@"io_stop"]){if(!started)return noErr;OSStatus status=AudioDeviceStop(aggregate,proc);if(status==noErr)started=NO;return status;}
            if([action isEqualToString:@"io_destroy"]){if(!proc)return noErr;OSStatus status=AudioDeviceDestroyIOProcID(aggregate,proc);if(status==noErr){proc=NULL;started=NO;}return status;}
            if([action isEqualToString:@"aggregate_destroy"]){if(!aggregate)return noErr;OSStatus status=AudioHardwareDestroyAggregateDevice(aggregate);if(status==noErr)aggregate=0;return status;}
            if([action isEqualToString:@"end"]){if(!tap)return noErr;OSStatus status=AudioHardwareDestroyProcessTap(tap);if(status==noErr)tap=0;return status;}
            return kAudioHardwareUnsupportedOperationError;
        };
        result=RunGuardProbeStages(operation,event,^(double seconds){[NSThread sleepForTimeInterval:seconds];});
        if(!proc)free(pcm);
        else{fprintf(stderr,"Guard probe IOProc cleanup failed; retaining callback state until process exit.\n");result=4;}
        dispatch_semaphore_signal(finished);
    }});
    dispatch_semaphore_wait(finished,DISPATCH_TIME_FOREVER);dispatch_source_cancel(watchdog);return result;
}

typedef NSString* (^TXTapBundleReader)(AudioObjectID);
typedef OSStatus (^TXTapFormatReader)(AudioObjectID,AudioStreamBasicDescription*);
static NSArray *CopySlotBundleIDs(id value) {
    if(!value)return nil;if(![value isKindOfClass:NSArray.class]||[value count]!=6)return @[];
    NSMutableArray *rows=[NSMutableArray array];
    for(id row in value){if(![row isKindOfClass:NSArray.class])return @[];NSMutableArray *members=[NSMutableArray array];
        for(id member in row){if(![member isKindOfClass:NSString.class])return @[];[members addObject:[member copy]];}[rows addObject:[members copy]];}
    return [rows copy];
}
static NSError *TapPlanError(NSString *stage,OSStatus status) {return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey:stage}];}
static NSArray<NSDictionary*> *PlanProcessTaps(NSArray *groups,NSArray *metadata,NSArray *ownProcesses,NSString *ownBundle,TXTapBundleReader bundleForProcess,NSError **error) {
    if(error)*error=nil;
    if(groups.count!=6||(metadata&&metadata.count!=6)){if(error)*error=TapPlanError(TXL(@"6개 트랙 그룹이 필요합니다"),-4);return nil;}
    if(!ownBundle.length){if(error)*error=TapPlanError(TXL(@"앱 식별자가 없어 피드백 방지를 보장할 수 없습니다"),-7);return nil;}
    NSMutableArray *excluded=[ownProcesses mutableCopy],*slotBundles=[NSMutableArray array];NSMutableSet *assignedBundles=[NSMutableSet set];
    NSMutableCharacterSet *invalid=[NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];[invalid formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];[invalid addCharactersInString:@":/"];
    for(int slot=0;slot<6;slot++){
        NSMutableOrderedSet *bundles=[NSMutableOrderedSet orderedSet];
        for(NSNumber *process in groups[slot]){NSString *bundle=bundleForProcess(process.unsignedIntValue);if(bundle.length)[bundles addObject:bundle];}
        if(metadata){id row=metadata[slot];if(![row isKindOfClass:NSArray.class]){if(error)*error=TapPlanError(TXL(@"프로그램 중복 매핑"),-5);return nil;}
            for(id bundle in row){if(![bundle isKindOfClass:NSString.class]||![bundle length]||[bundle isEqual:@"local.tx6mac.system-sounds"]||[bundle isEqual:ownBundle]||[bundle rangeOfCharacterFromSet:invalid].location!=NSNotFound){if(error)*error=TapPlanError(TXL(@"프로그램 중복 매핑"),-5);return nil;}[bundles addObject:bundle];}
            for(NSString *bundle in bundles){if([bundle isEqual:ownBundle]||[assignedBundles containsObject:bundle]){if(error)*error=TapPlanError(TXL(@"프로그램 중복 매핑"),-5);return nil;}[assignedBundles addObject:bundle];}
        }
        [slotBundles addObject:bundles.array];[excluded addObjectsFromArray:groups[slot]];
    }
    NSMutableOrderedSet *excludedBundles=[NSMutableOrderedSet orderedSet];
    for(NSNumber *process in excluded){NSString *bundle=bundleForProcess(process.unsignedIntValue);if(bundle.length)[excludedBundles addObject:bundle];}
    if(metadata)for(NSArray *row in slotBundles)[excludedBundles addObjectsFromArray:row];[excludedBundles addObject:ownBundle];
    NSMutableArray *plan=[NSMutableArray array];
    for(int slot=0;slot<TX_SLOTS;slot++){
        NSArray *ids=slot<6?groups[slot]:excluded,*bundles=slot<6?slotBundles[slot]:excludedBundles.array;
        if(slot<6&&!metadata&&!ids.count)continue;
        CATapDescription *description=slot==6?[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:ids]:[[CATapDescription alloc] initStereoMixdownOfProcesses:ids];
        description.name=[NSString stringWithFormat:TXL(@"TX6Mac 채널 %d"),slot+1];description.privateTap=YES;description.muteBehavior=CATapMutedWhenTapped;
        if(@available(macOS 26.0,*)){description.bundleIDs=bundles;description.processRestoreEnabled=YES;}
        else if(metadata){if(error)*error=TapPlanError(TXL(@"지원하지 않는 프로그램 오디오 탭 형식"),-8);return nil;}
        [plan addObject:@{@"slot":@(slot),@"description":description}];
    }
    return plan;
}
static NSArray<NSDictionary*> *CreateProcessTapSet(NSArray<NSDictionary*> *plan,NSMutableArray<NSNumber*> *owned,TXGuardCreate create,TXTapFormatReader readFormat,NSError **error) {
    if(error)*error=nil;NSMutableArray *created=[NSMutableArray array];
    for(NSDictionary *entry in plan){CATapDescription *description=entry[@"description"];AudioObjectID tap=0;OSStatus status=create(description,&tap);
        if(status!=noErr||!tap){if(error)*error=TapPlanError(TXL(@"프로그램 오디오 탭 생성"),status?:kAudioHardwareBadObjectError);return nil;}
        [owned addObject:@(tap)];AudioStreamBasicDescription format={0};status=readFormat(tap,&format);
        if(status!=noErr||format.mChannelsPerFrame!=2||format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||format.mBitsPerChannel!=32){if(error)*error=TapPlanError(TXL(@"지원하지 않는 프로그램 오디오 탭 형식"),status?:-8);return nil;}
        [created addObject:@{@"slot":entry[@"slot"],@"description":description,@"tap":@(tap),@"subtap":@{@kAudioSubTapUIDKey:description.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}}];
    }
    return created;
}
static void DestroyProcessTapSet(NSMutableArray<NSNumber*> *owned,TXGuardDestroy destroy) {for(NSNumber *tap in owned)destroy(tap.unsignedIntValue);[owned removeAllObjects];}

static BOOL SameTapSources(CATapDescription *a,CATapDescription *b) {
    return [[NSSet setWithArray:a.processes] isEqual:[NSSet setWithArray:b.processes]]&&[[NSSet setWithArray:a.bundleIDs] isEqual:[NSSet setWithArray:b.bundleIDs]];
}
typedef OSStatus (^TXTapWriter)(NSUInteger,CATapDescription*);
static NSError *LiveTapError(NSString *detail,OSStatus status) {return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey:TXL(@"채널 연결 갱신 실패 · 기존 재생은 유지합니다."),NSDebugDescriptionErrorKey:detail}];}
static BOOL RetargetTapSet(NSArray *current,NSArray *desired,TXTapWriter write,BOOL *restored) {
    *restored=YES;CATapDescription *oldGlobal=current[6][@"description"],*nextGlobal=desired[6][@"description"];
    NSMutableOrderedSet *ids=[NSMutableOrderedSet orderedSetWithArray:oldGlobal.processes],*bundles=[NSMutableOrderedSet orderedSetWithArray:oldGlobal.bundleIDs];[ids addObjectsFromArray:nextGlobal.processes];[bundles addObjectsFromArray:nextGlobal.bundleIDs];
    CATapDescription *excluded=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:ids.array];excluded.bundleIDs=bundles.array;excluded.privateTap=YES;excluded.processRestoreEnabled=YES;excluded.muteBehavior=CATapMutedWhenTapped;excluded.UUID=oldGlobal.UUID;excluded.name=oldGlobal.name;
    UInt32 changed=0;for(int slot=0;slot<6;slot++)if(!SameTapSources(current[slot][@"description"],desired[slot][@"description"]))changed|=1U<<slot;
    if(!changed&&SameTapSources(oldGlobal,nextGlobal))return YES;
    BOOL ok=write(6,excluded)==noErr;
    for(int slot=0;ok&&slot<6;slot++)if((changed>>slot)&1)ok=write(slot,desired[slot][@"description"])==noErr;
    if(ok)ok=write(6,nextGlobal)==noErr;
    if(ok)return YES;
    for(int slot=0;slot<6;slot++)if((changed>>slot)&1)if(write(slot,current[slot][@"description"])!=noErr)*restored=NO;
    if(write(6,*restored?oldGlobal:excluded)!=noErr)*restored=NO;
    return NO;
}

static const double SyncMaxSeconds=2;
static const size_t SyncMaxBytes=16*1024*1024;
static BOOL SyncReadU32(AudioObjectID object,AudioObjectPropertySelector selector,AudioObjectPropertyScope scope,UInt32 *value) {
    UInt32 size=sizeof(*value);AudioObjectPropertyAddress address=Addr(selector,scope);
    return AudioObjectGetPropertyData(object,&address,0,NULL,&size,value)==noErr&&size==sizeof(*value);
}
static NSDictionary *SyncDeviceTiming(AudioDeviceID device) {
    NSString *uid=device?ReadString(device,kAudioDevicePropertyDeviceUID):@"";NSString *reason=@"missing-device";
    Float64 rate=0;UInt32 deviceFrames=0,streamFrames=0,safety=0,buffer=0,alive=0;BOOL supported=NO;
    do{
        if(!uid.length||[uid hasPrefix:@"local.tx6mac."])break;
        reason=@"missing-device-timing";UInt32 size=sizeof(rate);AudioObjectPropertyAddress address=Addr(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal);
        if(AudioObjectGetPropertyData(device,&address,0,NULL,&size,&rate)!=noErr||size!=sizeof(rate)||!isfinite(rate)||rate<8000||rate>384000)break;
        if(!SyncReadU32(device,kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,&alive)||!alive)break;
        if(!SyncReadU32(device,kAudioDevicePropertyLatency,kAudioDevicePropertyScopeOutput,&deviceFrames))break;
        reason=@"missing-safety-offset";if(!SyncReadU32(device,kAudioDevicePropertySafetyOffset,kAudioDevicePropertyScopeOutput,&safety)||safety>rate*60)break;
        SyncReadU32(device,kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,&buffer);
        NSArray *streams=ReadIDs(device,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput);UInt32 channels=Channels(device,kAudioDevicePropertyScopeOutput);
        reason=@"invalid-output-streams";if(!streams.count||channels<2)break;
        NSMutableIndexSet *covered=[NSMutableIndexSet indexSet];BOOL valid=YES,first=YES;
        for(NSNumber *stream in streams){UInt32 latency=0,start=0;AudioStreamBasicDescription format={0};size=sizeof(format);address=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);
            if(AudioObjectGetPropertyData(stream.unsignedIntValue,&address,0,NULL,&size,&format)!=noErr||size!=sizeof(format)||!isfinite(format.mSampleRate)||fabs(format.mSampleRate-rate)>.001||!SyncReadU32(stream.unsignedIntValue,kAudioStreamPropertyStartingChannel,kAudioObjectPropertyScopeGlobal,&start)||!AddStreamRange(covered,start,format.mChannelsPerFrame,channels,0)){valid=NO;break;}
            reason=@"missing-stream-latency";if(!SyncReadU32(stream.unsignedIntValue,kAudioStreamPropertyLatency,kAudioObjectPropertyScopeGlobal,&latency)){valid=NO;break;}
            if(!first&&latency!=streamFrames){reason=@"multiple-stream-latencies";valid=NO;break;}streamFrames=latency;first=NO;
        }
        if(!valid||covered.count!=channels)break;
        reason=@"invalid-latency";if(((double)deviceFrames+streamFrames)/rate>60)break;
        supported=YES;reason=@"known";
    }while(0);
    double seconds=supported?((double)deviceFrames+streamFrames)/rate:0;
    NSString *signature=[NSString stringWithFormat:@"%@|%.6f|%u|%u|%d|%@",uid,isfinite(rate)?rate:0,deviceFrames,streamFrames,supported,reason];
    return @{@"id":@(device),@"uid":uid,@"supported":@(supported),@"reason":reason,@"sampleRate":isfinite(rate)?@(rate):@0,@"deviceFrames":@(deviceFrames),@"streamFrames":@(streamFrames),@"safetyFrames":@(safety),@"bufferFrames":@(buffer),@"seconds":@(seconds),@"signature":signature};
}
static NSDictionary *SyncCachedTiming(AudioDeviceID device,NSMutableDictionary *cache) {
    NSNumber *key=@(device);NSDictionary *timing=cache[key];if(!timing){timing=SyncDeviceTiming(device);cache[key]=timing;}return timing;
}
static NSArray *SyncProcessDevices(AudioObjectID process) {
    AudioObjectPropertyAddress address=Addr(kAudioProcessPropertyDevices,kAudioDevicePropertyScopeOutput);UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(process,&address,0,NULL,&size)!=noErr||!size||size%sizeof(AudioDeviceID)||size>256*sizeof(AudioDeviceID))return @[];
    AudioDeviceID *devices=malloc(size);if(!devices)return @[];UInt32 capacity=size;NSMutableArray *result=[NSMutableArray array];
    OSStatus status=AudioObjectGetPropertyData(process,&address,0,NULL,&size,devices);
    if(status==noErr&&size<=capacity&&!(size%sizeof(*devices)))for(UInt32 i=0;i<size/sizeof(*devices);i++)[result addObject:@(devices[i])];free(devices);return result;
}
static NSDictionary *SyncMergeSources(NSArray<NSDictionary*> *snapshots) {
    NSMutableSet *uids=[NSMutableSet set];NSMutableArray *signatures=[NSMutableArray array];NSDictionary *selected=nil;NSString *reason=@"inactive-source";BOOL invalid=NO;NSUInteger active=0;
    for(NSDictionary *snapshot in snapshots){NSNumber *process=snapshot[@"process"];
        if(![snapshot[@"known"] boolValue]){invalid=YES;reason=@"unknown-process-state";[signatures addObject:[NSString stringWithFormat:@"%@:unknown",process]];continue;}
        if(![snapshot[@"active"] boolValue]){[signatures addObject:[NSString stringWithFormat:@"%@:inactive",process]];continue;}
        active++;NSArray *devices=snapshot[@"timings"];NSMutableArray *parts=[NSMutableArray array];
        if(devices.count!=1){invalid=YES;reason=devices.count?@"multiple-source-devices":@"unknown-source-device";}
        for(NSDictionary *timing in devices){[parts addObject:timing[@"signature"]];NSString *uid=timing[@"uid"];if(uid.length)[uids addObject:uid];
            if(![timing[@"supported"] boolValue]){invalid=YES;reason=timing[@"reason"];}
            else{if(selected&&[selected[@"uid"] isEqual:uid]&&fabs([selected[@"seconds"] doubleValue]-[timing[@"seconds"] doubleValue])>1e-9){invalid=YES;reason=@"inconsistent-source-timing";}selected=timing;}
        }
        [signatures addObject:[NSString stringWithFormat:@"%@:%@",process,[[parts sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]]];
    }
    if(uids.count>1){invalid=YES;reason=@"multiple-source-devices";}
    BOOL supported=active&&!invalid&&uids.count==1&&selected;
    if(supported)reason=@"known";
    return @{@"supported":@(supported),@"reason":reason,@"uid":supported?selected[@"uid"]:@"",@"deviceUIDs":[uids.allObjects sortedArrayUsingSelector:@selector(compare:)],@"seconds":supported?selected[@"seconds"]:@0,@"timing":selected?:@{},@"signature":[[signatures sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@";"]};
}
static NSDictionary *SyncGroupSource(NSArray<NSNumber*> *processes,NSMutableDictionary *cache) {
    NSMutableArray *snapshots=[NSMutableArray array];
    for(NSNumber *process in processes){UInt32 running=0;BOOL known=SyncReadU32(process.unsignedIntValue,kAudioProcessPropertyIsRunningOutput,kAudioObjectPropertyScopeGlobal,&running);NSMutableArray *timings=[NSMutableArray array];
        if(known&&running)for(NSNumber *device in SyncProcessDevices(process.unsignedIntValue))[timings addObject:SyncCachedTiming(device.unsignedIntValue,cache)];
        [snapshots addObject:@{@"process":process,@"known":@(known),@"active":@(running!=0),@"timings":timings}];
    }
    return SyncMergeSources(snapshots);
}
static NSDictionary *SyncDelayPlan(NSDictionary *source,NSDictionary *target,double rate,BOOL enabled) {
    double desired=0;UInt32 frames=0;NSString *reason=@"disabled";BOOL supported=YES;
    if(enabled){
        if(![source[@"supported"] boolValue]){reason=[@"source-" stringByAppendingString:source[@"reason"]?:@"unknown"];supported=NO;}
        else if(![target[@"supported"] boolValue]){reason=[@"target-" stringByAppendingString:target[@"reason"]?:@"unknown"];supported=NO;}
        else if([source[@"uid"] isEqual:target[@"uid"]])reason=@"same-device";
        else if(!isfinite(rate)||rate<8000||rate>384000){reason=@"invalid-render-rate";supported=NO;}
        else{
            double sourceSeconds=[source[@"seconds"] doubleValue],targetSeconds=[target[@"seconds"] doubleValue];
            desired=sourceSeconds-targetSeconds;
            if(!isfinite(desired)||sourceSeconds<0||targetSeconds<0){desired=0;reason=@"invalid-latency";supported=NO;}
            else if(desired<=0){reason=@"target-not-faster";supported=NO;}
            else{frames=(UInt32)llround(fmin(SyncMaxSeconds,desired)*rate);reason=desired>SyncMaxSeconds?@"delay-clamped":@"compensated-estimate";supported=desired<=SyncMaxSeconds;}
        }
    }
    return @{@"supported":@(supported),@"reason":reason,@"requestedMs":@(desired*1000),@"frames":@(frames),@"delayMs":@(frames&&rate>0?1000.0*frames/rate:0)};
}
static NSString *AllocateSyncBuffer(TXSyncDelay *delay,UInt32 mainFrames,UInt32 monitorFrames,size_t *allocated) {
    UInt32 maximum=MAX(mainFrames,monitorFrames);if(!maximum)return nil;
    if(maximum>384000*SyncMaxSeconds||*allocated>SyncMaxBytes)return @"memory-limit";
    size_t bytes=((size_t)maximum+1)*2*sizeof(float);if(bytes>SyncMaxBytes-*allocated)return @"memory-limit";
    delay->samples=calloc(1,bytes);if(!delay->samples)return @"allocation-failed";
    volatile float *warm=delay->samples;for(size_t i=0;i<bytes/sizeof(float);i+=1024)warm[i]=0;warm[bytes/sizeof(float)-1]=0;
    *allocated+=bytes;delay->capacity=maximum+1;delay->mainFrames=mainFrames;delay->monitorFrames=monitorFrames;return nil;
}
static NSDictionary *SyncRejectPlan(NSDictionary *plan,NSString *reason) {
    NSMutableDictionary *result=[plan mutableCopy];result[@"supported"]=@NO;result[@"reason"]=reason;result[@"frames"]=@0;result[@"delayMs"]=@0;return [result copy];
}
@implementation TXAudio {
    TXRenderState *_state;
    NSArray<NSArray<NSString*>*> *_slotBundleIDs;
    NSMutableArray<NSNumber*> *_taps;
    AudioDeviceID _aggregate,_device;
    AudioDeviceIOProcID _proc;
    CATapDescription *_globalDescription;
    AudioObjectID _globalTap;
    BOOL _running;
    NSDictionary *_syncPlan;
    NSArray *_liveTaps;
    uint64_t _sourceRevision,_syncRevision;
    UInt32 _resetSourceSlots;
    BOOL _liveSourcesCoherent;
}
- (instancetype)init {if((self=[super init])){_state=calloc(1,sizeof(*_state));_taps=[NSMutableArray array];_syncCompensationEnabled=YES;atomic_store(&_state->master,1);atomic_store(&_state->monitorGain,1);for(int i=0;i<TX_SLOTS;i++)atomic_store(&_state->gain[i],1);}return self;}
- (TXRenderState*)state{return _state;}
- (NSArray<NSArray<NSString*>*>*)slotBundleIDs{return _slotBundleIDs;}
- (void)setSlotBundleIDs:(NSArray<NSArray<NSString*>*>*)value {_slotBundleIDs=CopySlotBundleIDs(value);}
- (BOOL)running{return _running;}
- (AudioDeviceID)device{return _device;}
- (BOOL)metering{return _running&&_state->meterEnabled;}
- (BOOL)monitoring{return _running&&_state->monitorEnabled;}
- (BOOL)liveUpdatesAvailable{return _running&&_liveSourcesCoherent&&_liveTaps.count==TX_SLOTS;}
- (NSDictionary*)syncDiagnostics {
    NSMutableDictionary *result=[(_syncPlan?:@{@"enabled":@(_syncCompensationEnabled),@"slots":@[]}) mutableCopy];result[@"running"]=@(_running);result[@"requestedEnabled"]=@(_syncCompensationEnabled);
    result[@"timestamp"]=@{@"nowFlags":@(atomic_load(&_state->syncNowFlags)),@"inputFlags":@(atomic_load(&_state->syncInputFlags)),@"outputFlags":@(atomic_load(&_state->syncOutputFlags)),@"nowHostTime":@(atomic_load(&_state->syncNowHostTime)),@"inputHostTime":@(atomic_load(&_state->syncInputHostTime)),@"outputHostTime":@(atomic_load(&_state->syncOutputHostTime)),@"inputToOutputMs":@(atomic_load(&_state->syncInputToOutputMS)),@"nowToOutputMs":@(atomic_load(&_state->syncNowToOutputMS))};return [result copy];
}
- (BOOL)updateGroups:(NSArray*)groups bundleIDs:(NSArray*)bundles error:(NSError**)error {
    NSAssert(!NSThread.isMainThread,@"Tap updates belong on the HAL worker");if(error)*error=nil;
    if(!self.liveUpdatesAvailable||!bundles){if(error)*error=LiveTapError(@"Live channel update unavailable",-30);return NO;}
    NSMutableArray *owners=[NSMutableArray array];NSMutableSet *unique=[NSMutableSet set];
    for(NSNumber *n in ReadIDs(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal))if((pid_t)ReadUInt(n.unsignedIntValue,kAudioProcessPropertyPID)==getpid())[owners addObject:n];
    for(NSArray *row in groups)for(NSNumber *n in row){if(![n isKindOfClass:NSNumber.class]||!n.unsignedIntValue||[unique containsObject:n]||[owners containsObject:n]){if(error)*error=LiveTapError(@"Invalid live channel sources",-31);return NO;}[unique addObject:n];}
    NSArray *plan=PlanProcessTaps(groups,bundles,owners,NSBundle.mainBundle.bundleIdentifier,^NSString*(AudioObjectID n){return ReadString(n,kAudioProcessPropertyBundleID);},error);if(plan.count!=TX_SLOTS)return NO;
    UInt32 mask=0;for(int slot=0;slot<TX_SLOTS;slot++){CATapDescription *next=plan[slot][@"description"],*previous=_liveTaps[slot][@"description"];next.UUID=previous.UUID;if(slot<6&&!SameTapSources(previous,next))mask|=1U<<slot;}
    uint64_t command=(++_sourceRevision<<32)|mask;atomic_store_explicit(&_state->sourceUpdateCommand,command,memory_order_release);
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:.5];while(atomic_load_explicit(&_state->sourceUpdateApplied,memory_order_acquire)!=command&&deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.002];
    if(atomic_load(&_state->sourceUpdateApplied)!=command){atomic_store(&_state->sourceUpdateCommand,++_sourceRevision<<32);if(error)*error=LiveTapError(@"Channel update acknowledgement timed out",-32);return NO;}
    BOOL restored=NO;__block OSStatus failure=noErr;
    BOOL ok=RetargetTapSet(_liveTaps,plan,^OSStatus(NSUInteger slot,CATapDescription *description){
        AudioObjectID tap=[self->_liveTaps[slot][@"tap"] unsignedIntValue];AudioObjectPropertyAddress a=Addr(kAudioTapPropertyDescription,kAudioObjectPropertyScopeGlobal);OSStatus status=AudioObjectSetPropertyData(tap,&a,0,NULL,sizeof(description),&description);
        if(status==noErr){AudioStreamBasicDescription format={0};UInt32 size=sizeof(format);a=Addr(kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal);status=AudioObjectGetPropertyData(tap,&a,0,NULL,&size,&format);if(status==noErr&&(format.mChannelsPerFrame!=2||format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||format.mBitsPerChannel!=32))status=kAudioHardwareUnsupportedOperationError;}
        if(status!=noErr)failure=status;return status;
    },&restored);
    if(ok){NSMutableArray *updated=[NSMutableArray array];for(int slot=0;slot<TX_SLOTS;slot++){NSMutableDictionary *entry=[_liveTaps[slot] mutableCopy];entry[@"description"]=plan[slot][@"description"];[updated addObject:entry];}_liveTaps=updated;_globalDescription=_liveTaps[6][@"description"];self.slotBundleIDs=bundles;_resetSourceSlots=mask;[self configureSyncGroups:groups taps:_liveTaps main:_device monitor:self.monitorOutputDevice rate:_state->sampleRate];_resetSourceSlots=0;}
    if(!ok&&restored)for(int slot=0;slot<6;slot++)if((mask>>slot)&1){NSDictionary *row=_syncPlan[@"slots"][slot];uint64_t reset=((++_syncRevision&0xFFFFFF)<<40)|((uint64_t)[row[@"monitor"][@"frames"] unsignedIntValue]<<20)|[row[@"main"][@"frames"] unsignedIntValue];atomic_store_explicit(&_state->syncCommand[slot],reset,memory_order_release);}
    if(ok||restored)atomic_store_explicit(&_state->sourceUpdateCommand,++_sourceRevision<<32,memory_order_release);
    else {_liveSourcesCoherent=NO;atomic_store_explicit(&_state->sourceUpdateCommand,(++_sourceRevision<<32)|mask|(1U<<6),memory_order_release);}
    if(!ok&&error)*error=LiveTapError(restored?@"Channel update failed; previous playback retained":@"Channel update failed; affected channels held silent",failure?:-33);
    return ok;
}
- (void)configureSyncGroups:(NSArray*)groups taps:(NSArray*)created main:(AudioDeviceID)main monitor:(AudioDeviceID)monitor rate:(double)rate {
    NSMutableDictionary *cache=[NSMutableDictionary dictionary];NSDictionary *mainTiming=SyncCachedTiming(main,cache),*monitorTiming=monitor?SyncCachedTiming(monitor,cache):@{};
    NSMutableArray *rows=[NSMutableArray array];NSMutableDictionary *descriptions=[NSMutableDictionary dictionary];for(NSDictionary *entry in created)descriptions[entry[@"slot"]]=entry[@"description"];
    NSArray *allProcesses=ReadIDs(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal);size_t allocated=0;
    mach_timebase_info_data_t timebase={0};if(!_running&&mach_timebase_info(&timebase)==KERN_SUCCESS&&timebase.denom)_state->syncHostTickMS=(double)timebase.numer/timebase.denom/1000000;
    for(int slot=0;slot<TX_SLOTS;slot++){
        CATapDescription *description=descriptions[@(slot)];NSMutableOrderedSet *sources=[NSMutableOrderedSet orderedSetWithArray:slot<6?groups[slot]:@[]];
        if(slot<6&&description.bundleIDs.count)for(NSNumber *process in allProcesses)if([description.bundleIDs containsObject:ReadString(process.unsignedIntValue,kAudioProcessPropertyBundleID)])[sources addObject:process];
        NSDictionary *source=slot<6&&description?SyncGroupSource(sources.array,cache):@{@"supported":@NO,@"uid":@"",@"reason":slot==6?@"global-remainder":@"no-tap",@"seconds":@0};
        // System alerts have no video clock and must not acquire A/V sync delay.
        BOOL compensate=_syncCompensationEnabled&&slot!=0;
        NSDictionary *mainPlan=SyncDelayPlan(source,mainTiming,rate,compensate),*monitorPlan=monitor?SyncDelayPlan(source,monitorTiming,rate,compensate):SyncRejectPlan(SyncDelayPlan(source,@{},rate,NO),@"monitor-disabled");
        UInt32 mainFrames=[mainPlan[@"frames"] unsignedIntValue],monitorFrames=[monitorPlan[@"frames"] unsignedIntValue];
        TXSyncDelay *delay=&_state->syncDelay[slot];NSString *allocationReason=nil;
        if(!_running){
            UInt32 reserve=slot>0&&slot<6?MIN((UInt32)(rate*SyncMaxSeconds),(UInt32)(SyncMaxBytes/(5*2*sizeof(float)))-1):0;
            allocationReason=AllocateSyncBuffer(delay,reserve,reserve,&allocated);
            atomic_store(&_state->syncCommand[slot],0);_state->syncAppliedCommand[slot]=0;
        }else allocated+=(size_t)delay->capacity*2*sizeof(float);
        if(MAX(mainFrames,monitorFrames)&&MAX(mainFrames,monitorFrames)>=delay->capacity)allocationReason=@"memory-limit";
        if(allocationReason){mainPlan=SyncRejectPlan(mainPlan,allocationReason);monitorPlan=SyncRejectPlan(monitorPlan,allocationReason);}
        if(!_running){delay->mainFrames=[mainPlan[@"frames"] unsignedIntValue];delay->monitorFrames=[monitorPlan[@"frames"] unsignedIntValue];}
        else {
            NSDictionary *previous=(NSUInteger)slot<[_syncPlan[@"slots"] count]?_syncPlan[@"slots"][slot]:@{};
            BOOL changed=slot>0&&slot<6&&(![(previous[@"source"][@"signature"]?:@"") isEqual:(source[@"signature"]?:@"")]||[previous[@"main"][@"frames"] unsignedIntValue]!=[mainPlan[@"frames"] unsignedIntValue]||[previous[@"monitor"][@"frames"] unsignedIntValue]!=[monitorPlan[@"frames"] unsignedIntValue]);
            if(changed||((_resetSourceSlots>>slot)&1)){
                uint64_t command=((++_syncRevision&0xFFFFFF)<<40)|((uint64_t)[monitorPlan[@"frames"] unsignedIntValue]<<20)|[mainPlan[@"frames"] unsignedIntValue];
                atomic_store_explicit(&_state->syncCommand[slot],command,memory_order_release);
            }
        }
        [rows addObject:@{@"slot":@(slot),@"sourceUID":source[@"uid"]?:@"",@"source":source,@"mainTargetUID":mainTiming[@"uid"]?:@"",@"monitorTargetUID":monitorTiming[@"uid"]?:@"",@"mainDelayMs":mainPlan[@"delayMs"],@"monitorDelayMs":monitorPlan[@"delayMs"],@"main":mainPlan,@"monitor":monitorPlan}];
    }
    _syncPlan=@{@"enabled":@(_syncCompensationEnabled),@"model":@"device-stream-estimate",@"timestampCompensation":@"not-inferred",@"mainTarget":mainTiming,@"monitorTarget":monitorTiming,@"slots":[rows copy],@"memoryBytes":@(allocated),@"maxDelayMs":@(SyncMaxSeconds*1000)};
}
+ (AudioDeviceID)defaultOutput{return ReadUInt(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice);}
+ (NSString*)uid:(AudioDeviceID)device{return ReadString(device,kAudioDevicePropertyDeviceUID);}
+ (NSArray<NSDictionary*>*)outputs {
    NSMutableArray *result=[NSMutableArray array];
    for(NSNumber *n in ReadIDs(kAudioObjectSystemObject,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal)){
        AudioDeviceID d=n.unsignedIntValue;UInt32 count=Channels(d,kAudioDevicePropertyScopeOutput);
        NSString *uid=[self uid:d];if(count<2||[uid hasPrefix:@"local.tx6mac."])continue;
        [result addObject:@{@"id":n,@"name":ReadString(d,kAudioObjectPropertyName),@"uid":uid,@"channels":@(count),@"transport":@(ReadUInt(d,kAudioDevicePropertyTransportType)),@"timingSignature":SyncDeviceTiming(d)[@"signature"]}];
    }return result;
}
+ (NSArray<NSDictionary*>*)processes {
    NSMutableDictionary<NSString*,NSMutableDictionary*> *groups=[NSMutableDictionary dictionary];
    for(NSNumber *n in ReadIDs(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal)){
        AudioObjectID obj=n.unsignedIntValue;pid_t pid=(pid_t)ReadUInt(obj,kAudioProcessPropertyPID);if(pid==getpid())continue;
        NSString *bundle=ReadString(obj,kAudioProcessPropertyBundleID);if(bundle.length&&[bundle isEqualToString:NSBundle.mainBundle.bundleIdentifier])continue;NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *key=app.bundleIdentifier?:bundle;
        NSString *path=app.bundleURL.path;
        char executable[PROC_PIDPATHINFO_MAXSIZE]={0};
        if(proc_pidpath(pid,executable,sizeof(executable))>0){NSString *actualPath=[NSString stringWithUTF8String:executable];if(actualPath.length)path=actualPath;}
        NSRange appEnd=path.length?[path rangeOfString:@".app/"]:NSMakeRange(NSNotFound,0);
        if(appEnd.location!=NSNotFound){NSString *outer=[path substringToIndex:appEnd.location+4];NSBundle *parent=[NSBundle bundleWithPath:outer];if(parent.bundleIdentifier.length){key=parent.bundleIdentifier;app=nil;}}
        BOOL systemSound=IsSystemSoundProcess(path,bundle);
        if(systemSound)key=@"local.tx6mac.system-sounds";
        if(!key.length)key=[NSString stringWithFormat:@"pid:%d",pid];
        NSMutableDictionary *g=groups[key];
        if(!g){NSString *name=app.localizedName; if(!name.length){NSURL *url=[[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:key];name=url?[[NSFileManager defaultManager] displayNameAtPath:url.path]:key;}
            g=[@{@"key":key,@"name":systemSound?TXL(@"시스템 사운드"):(name?:key),@"isSystemSound":@(systemSound),@"ids":[NSMutableArray array],@"bundles":[NSMutableArray array],@"active":@NO} mutableCopy];groups[key]=g;}
        [g[@"ids"] addObject:n];if(bundle.length&&![g[@"bundles"] containsObject:bundle])[g[@"bundles"] addObject:bundle];
        if(ReadUInt(obj,kAudioProcessPropertyIsRunningOutput))g[@"active"]=@YES;
    }
    NSMutableDictionary *timings=[NSMutableDictionary dictionary];for(NSMutableDictionary *group in groups.allValues){NSDictionary *source=SyncGroupSource(group[@"ids"],timings);group[@"sourceSinkSignature"]=source[@"signature"];}
    return [groups.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];}];
}
+ (NSDictionary*)diagnostics {return @{@"outputs":[self outputs],@"processes":[self processes],@"defaultOutput":@([self defaultOutput])};}
- (BOOL)fail:(NSString*)stage status:(OSStatus)status {
    LayoutTrace("startup failure stage=%s status=%d primary=%u monitor=%u meter=%u aggregate=%u physical=%u taps=%d",stage.UTF8String,(int)status,_device,self.monitorOutputDevice,self.meterOutputDevice,_aggregate,atomic_load(&_state->physicalInputChannels),atomic_load(&_state->tapCount));
    self.lastError=[NSString stringWithFormat:TXL(@"%@ 오류: %d (시스템 오디오 접근 권한과 출력 장치를 확인하세요)"),stage,(int)status];[self stop];return NO;
}
- (BOOL)startOnDevice:(AudioDeviceID)device groups:(NSArray<NSArray<NSNumber*>*>*)groups {
    NSAssert(!NSThread.isMainThread,@"HAL startup must not block the main thread");
    [self stop];self.lastError=@"";_device=device;
    LayoutTrace("startup begin primary=%u monitor=%u meter=%u",device,self.monitorOutputDevice,self.meterOutputDevice);
    if(groups.count!=6)return [self fail:TXL(@"6개 트랙 그룹이 필요합니다") status:-4];
    NSMutableSet *uniqueProcesses=[NSMutableSet set];
    for(NSArray *group in groups)for(NSNumber *process in group){
        if(![process isKindOfClass:NSNumber.class]||!process.unsignedIntValue||[uniqueProcesses containsObject:process])return [self fail:TXL(@"프로그램 중복 매핑") status:-5];
        if((pid_t)ReadUInt(process.unsignedIntValue,kAudioProcessPropertyPID)==getpid())return [self fail:TXL(@"믹서 자체 출력은 트랙에 지정할 수 없습니다") status:-6];
        [uniqueProcesses addObject:process];
    }
    NSString *uid=[TXAudio uid:device];if(!uid.length)return [self fail:TXL(@"출력 장치 없음") status:-1];
    if(Channels(device,kAudioDevicePropertyScopeOutput)<2)return [self fail:TXL(@"스테레오 출력 장치가 필요합니다") status:-12];
    AudioDeviceID monitor=self.monitorOutputDevice,meter=self.meterOutputDevice;
    NSString *monitorUID=monitor?[TXAudio uid:monitor]:@"",*meterUID=meter?[TXAudio uid:meter]:@"";
    if(monitor){
        if(monitor==device||!monitorUID.length||[monitorUID isEqualToString:uid]||Channels(monitor,kAudioDevicePropertyScopeOutput)<2)return [self fail:TXL(@"서로 다른 스테레오 모니터 장치가 필요합니다") status:-24];
        if(!RatesMatch(device,monitor))return [self fail:TXL(@"메인과 모니터 샘플레이트가 일치해야 합니다") status:-26];
    }
    if(meter){
        NSString *name=ReadString(meter,kAudioObjectPropertyName).uppercaseString;
        if(meter==device||meter==monitor||!meterUID.length||[meterUID isEqualToString:uid]||[meterUID isEqualToString:monitorUID]||ReadUInt(meter,kAudioDevicePropertyTransportType)!=kAudioDeviceTransportTypeUSB||Channels(meter,kAudioDevicePropertyScopeOutput)!=12||(![name containsString:@"TX-6"]&&![name containsString:@"TX6"]))return [self fail:TXL(@"출력 장치 없음") status:-20];
        if(!RatesMatch(device,meter))return [self fail:TXL(@"샘플레이트 확인") status:-21];
    }
    _state->physicalInputChannels=0;_state->tapCount=0;
    if(!PreferredStereo(device,Channels(device,kAudioDevicePropertyScopeOutput),&_state->outputLeft,&_state->outputRight))return [self fail:TXL(@"스테레오 출력 장치가 필요합니다") status:-23];
    if(monitor&&!PreferredStereo(monitor,Channels(monitor,kAudioDevicePropertyScopeOutput),&_state->monitorLeft,&_state->monitorRight))return [self fail:TXL(@"모니터 스테레오 채널 확인") status:-27];
    UInt32 size=0;
    NSMutableArray *ownProcesses=[NSMutableArray array];
    for(NSNumber *n in ReadIDs(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal))if((pid_t)ReadUInt(n.unsignedIntValue,kAudioProcessPropertyPID)==getpid())[ownProcesses addObject:n];
    NSError *tapError=nil;NSArray *plan=PlanProcessTaps(groups,_slotBundleIDs,ownProcesses,NSBundle.mainBundle.bundleIdentifier,^NSString*(AudioObjectID process){return ReadString(process,kAudioProcessPropertyBundleID);},&tapError);
    if(!plan)return [self fail:tapError.localizedDescription status:(OSStatus)tapError.code];
    NSArray *created=CreateProcessTapSet(plan,_taps,^OSStatus(CATapDescription *description,AudioObjectID *tap){return AudioHardwareCreateProcessTap(description,tap);},^OSStatus(AudioObjectID tap,AudioStreamBasicDescription *format){
        UInt32 bytes=sizeof(*format);AudioObjectPropertyAddress address=Addr(kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal);return AudioObjectGetPropertyData(tap,&address,0,NULL,&bytes,format);
    },&tapError);
    if(!created)return [self fail:tapError.localizedDescription status:(OSStatus)tapError.code];
    _liveTaps=created;_liveSourcesCoherent=YES;atomic_store(&_state->sourceUpdateCommand,0);atomic_store(&_state->sourceUpdateApplied,0);
    NSMutableArray *tapList=[NSMutableArray array];
    for(NSDictionary *entry in created){int slot=[entry[@"slot"] intValue];_state->tapSlots[_state->tapCount++]=slot;[tapList addObject:entry[@"subtap"]];if(slot==6){_globalDescription=entry[@"description"];_globalTap=[entry[@"tap"] unsignedIntValue];}}
    NSMutableArray *subdevices=[NSMutableArray arrayWithObject:@{@kAudioSubDeviceUIDKey:uid}];
    if(monitor)[subdevices addObject:@{@kAudioSubDeviceUIDKey:monitorUID,@kAudioSubDeviceDriftCompensationKey:@YES}];
    if(meter)[subdevices addObject:@{@kAudioSubDeviceUIDKey:meterUID,@kAudioSubDeviceDriftCompensationKey:@YES}];
    // Non-stacked outputs keep each device's channels independently addressable.
    NSDictionary *description=@{@kAudioAggregateDeviceUIDKey:[@"local.tx6mac." stringByAppendingString:NSUUID.UUID.UUIDString],@kAudioAggregateDeviceNameKey:@"TX6Mac Mixer",@kAudioAggregateDeviceIsPrivateKey:@YES,@kAudioAggregateDeviceIsStackedKey:@NO,@kAudioAggregateDeviceMainSubDeviceKey:uid,@kAudioAggregateDeviceSubDeviceListKey:subdevices,@kAudioAggregateDeviceTapListKey:tapList,@kAudioAggregateDeviceTapAutoStartKey:@NO};
    OSStatus status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description,&_aggregate);
    if(status!=noErr)return [self fail:TXL(@"믹서 오디오 장치 생성") status:status];
    CFArrayRef fullList=NULL;size=sizeof(fullList);AudioObjectPropertyAddress fullAddr=Addr(kAudioAggregateDevicePropertyFullSubDeviceList,kAudioObjectPropertyScopeGlobal);
    status=AudioObjectGetPropertyData(_aggregate,&fullAddr,0,NULL,&size,&fullList);
    NSArray *fullOrder=CFBridgingRelease(fullList);
    NSMutableDictionary *counts=[NSMutableDictionary dictionaryWithObject:@{@"in":@(Channels(device,kAudioDevicePropertyScopeInput)),@"out":@(Channels(device,kAudioDevicePropertyScopeOutput))} forKey:uid];
    if(meter)counts[meterUID]=@{@"in":@(Channels(meter,kAudioDevicePropertyScopeInput)),@"out":@(Channels(meter,kAudioDevicePropertyScopeOutput))};
    if(monitor)counts[monitorUID]=@{@"in":@(Channels(monitor,kAudioDevicePropertyScopeInput)),@"out":@(Channels(monitor,kAudioDevicePropertyScopeOutput))};
    if(LayoutTraceEnabled())LayoutTrace("aggregate device=%u fullListStatus=%d order=%s counts=%s",_aggregate,(int)status,fullOrder.description.UTF8String,counts.description.UTF8String);
    TraceStreams(_aggregate,kAudioDevicePropertyScopeOutput);
    UInt32 mainOffset=0,monitorOffset=0,meterOffset=0,totalInputs=0,totalOutputs=0;
    if(status!=noErr||!OutputLayout(fullOrder,uid,monitorUID,meterUID,counts,&mainOffset,&monitorOffset,&meterOffset,&totalInputs,&totalOutputs)||Channels(_aggregate,kAudioDevicePropertyScopeOutput)!=totalOutputs||!OutputStreamsValid(_aggregate,totalOutputs))return [self fail:TXL(@"프로그램 오디오 채널 순서 확인") status:-22];
    UInt32 mainOutputs=[counts[uid][@"out"] unsignedIntValue];
    if(_state->outputLeft>=mainOutputs||_state->outputRight>=mainOutputs||_state->outputLeft==_state->outputRight)return [self fail:TXL(@"스테레오 출력 장치가 필요합니다") status:-23];
    _state->outputLeft+=mainOffset;_state->outputRight+=mainOffset;_state->physicalInputChannels=totalInputs;
    UInt32 monitorOutputs=[counts[monitorUID][@"out"] unsignedIntValue];
    if(monitor&&(_state->monitorLeft>=monitorOutputs||_state->monitorRight>=monitorOutputs||_state->monitorLeft==_state->monitorRight))return [self fail:TXL(@"모니터 스테레오 채널 확인") status:-27];
    _state->monitorLeft+=monitorOffset;_state->monitorRight+=monitorOffset;_state->monitorEnabled=monitor!=0;
    _state->meterOutputOffset=meterOffset;_state->meterEnabled=meter!=0;
    LayoutTrace("aggregate offsets device=%u main=%u monitor=%u meter=%u physical=%u outputs=%u mainStereo=%u,%u monitorStereo=%u,%u taps=%d",_aggregate,mainOffset,monitorOffset,meterOffset,totalInputs,totalOutputs,_state->outputLeft,_state->outputRight,_state->monitorLeft,_state->monitorRight,atomic_load(&_state->tapCount));
    CFArrayRef activeTapUIDs=NULL;size=sizeof(activeTapUIDs);AudioObjectPropertyAddress tapOrderAddr=Addr(kAudioAggregateDevicePropertyTapList,kAudioObjectPropertyScopeGlobal);
    status=AudioObjectGetPropertyData(_aggregate,&tapOrderAddr,0,NULL,&size,&activeTapUIDs);
    NSArray *actualOrder=CFBridgingRelease(activeTapUIDs);NSMutableArray *expectedOrder=[NSMutableArray array];for(NSDictionary *entry in tapList)[expectedOrder addObject:entry[@kAudioSubTapUIDKey]];
    if(status!=noErr||![actualOrder isEqualToArray:expectedOrder])return [self fail:TXL(@"프로그램 오디오 채널 순서 확인") status:status?:-9];
    if(LayoutTraceEnabled())LayoutTrace("aggregate input-count device=%u actual=%u expected=%u physical=%u taps=%d",_aggregate,Channels(_aggregate,kAudioDevicePropertyScopeInput),_state->physicalInputChannels+2*_state->tapCount,atomic_load(&_state->physicalInputChannels),atomic_load(&_state->tapCount));
    if(Channels(_aggregate,kAudioDevicePropertyScopeInput)!=_state->physicalInputChannels+2*_state->tapCount)return [self fail:TXL(@"프로그램 오디오 입력 레이아웃 확인") status:-10];
    for(NSNumber *stream in [ReadIDs(_aggregate,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeInput) arrayByAddingObjectsFromArray:ReadIDs(_aggregate,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput)]){
        AudioStreamBasicDescription f={0};size=sizeof(f);AudioObjectPropertyAddress a=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);
        status=AudioObjectGetPropertyData(stream.unsignedIntValue,&a,0,NULL,&size,&f);
        if(status!=noErr||f.mFormatID!=kAudioFormatLinearPCM||!(f.mFormatFlags&kAudioFormatFlagIsFloat)||f.mBitsPerChannel!=32)return [self fail:TXL(@"지원하지 않는 오디오 형식") status:status?:-2];
    }
    Float64 rate=48000;size=sizeof(rate);AudioObjectPropertyAddress rateAddr=Addr(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal);
    status=AudioObjectGetPropertyData(_aggregate,&rateAddr,0,NULL,&size,&rate);if(status!=noErr||!isfinite(rate)||rate<8000)return [self fail:TXL(@"샘플레이트 확인") status:status?:-3];_state->sampleRate=rate;
    if(!RatesMatch(device,_aggregate))return [self fail:TXL(@"샘플레이트 확인") status:-21];
    if(meter&&!RatesMatch(device,meter))return [self fail:TXL(@"샘플레이트 확인") status:-21];
    if(monitor&&!RatesMatch(device,monitor))return [self fail:TXL(@"메인과 모니터 샘플레이트가 일치해야 합니다") status:-26];
    atomic_store(&_state->layoutFault,0);atomic_store(&_state->callbacks,0);atomic_store(&_state->frames,0);
    atomic_store(&_state->outputPeak,0);atomic_store(&_state->monitorPeak,0);_state->smoothMaster=0;_state->limiterGain=1;
    _state->smoothMonitorGain=0;_state->monitorLimiterGain=1;atomic_store(&_state->limitedFrames,0);
    for(int slot=0;slot<TX_SLOTS;slot++){_state->smoothGain[slot]=0;for(int b=0;b<TX_EQ;b++){memset(&_state->filters[slot][b],0,sizeof(TXFilter));_state->currentEQ[slot][b]=atomic_load(&_state->eq[slot][b]);SetFilter(&_state->filters[slot][b],b,_state->currentEQ[slot][b],rate);memset(&_state->syncMonitorFilters[slot][b],0,sizeof(TXFilter));SetFilter(&_state->syncMonitorFilters[slot][b],b,_state->currentEQ[slot][b],rate);}}
    [self configureSyncGroups:groups taps:created main:device monitor:monitor rate:rate];
    status=AudioDeviceCreateIOProcID(_aggregate,Render,_state,&_proc);if(status!=noErr)return [self fail:TXL(@"오디오 처리 연결") status:status];
    // Disable hardware inputs; capture only the authorized process taps.
    status=UseOnlyTapInputs(_aggregate,_proc,_state->physicalInputChannels,_state->physicalInputChannels+2*_state->tapCount);
    if(status!=noErr)return [self fail:TXL(@"프로그램 오디오 입력 레이아웃 확인") status:status];
    pid_t ownPID=getpid();AudioObjectID ownObject=0;size=sizeof(ownObject);AudioObjectPropertyAddress ownAddr=Addr(kAudioHardwarePropertyTranslatePIDToProcessObject,kAudioObjectPropertyScopeGlobal);
    status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&ownAddr,sizeof(ownPID),&ownPID,&size,&ownObject);
    if(status==noErr&&ownObject){
        if(![_globalDescription.processes containsObject:@(ownObject)]){
            _globalDescription.processes=[_globalDescription.processes arrayByAddingObject:@(ownObject)];
            CATapDescription *description=_globalDescription;size=sizeof(description);AudioObjectPropertyAddress descAddr=Addr(kAudioTapPropertyDescription,kAudioObjectPropertyScopeGlobal);
            status=AudioObjectSetPropertyData(_globalTap,&descAddr,0,NULL,size,&description);
            if(status!=noErr)return [self fail:TXL(@"자체 출력 피드백 방지 설정") status:status];
        }
    }else if(@available(macOS 26.0,*)){
    }else return [self fail:TXL(@"자체 오디오 프로세스 확인") status:status?:-11];
    status=AudioDeviceStart(_aggregate,_proc);if(status!=noErr)return [self fail:TXL(@"오디오 시작") status:status];_running=YES;return YES;
}
- (void)stop {
    NSAssert(!NSThread.isMainThread||(!_aggregate&&!_taps.count),@"HAL shutdown must not block the main thread");
    if(_aggregate&&_proc){AudioDeviceStop(_aggregate,_proc);AudioDeviceDestroyIOProcID(_aggregate,_proc);}_proc=NULL;
    if(_aggregate)AudioHardwareDestroyAggregateDevice(_aggregate);_aggregate=0;
    DestroyProcessTapSet(_taps,^OSStatus(AudioObjectID tap){return AudioHardwareDestroyProcessTap(tap);});_liveTaps=nil;_globalDescription=nil;_globalTap=0;_running=NO;
    _state->meterEnabled=NO;_state->meterOutputOffset=0;_state->monitorEnabled=NO;_state->monitorLeft=0;_state->monitorRight=0;
    _state->tapCount=0;_state->physicalInputChannels=0;
    _state->meterReferenceFrame=0;
    for(int slot=0;slot<TX_SLOTS;slot++){free(_state->syncDelay[slot].samples);memset(&_state->syncDelay[slot],0,sizeof(TXSyncDelay));}
    _syncPlan=nil;_state->syncHostTickMS=0;RecordSyncTimestamps(_state,NULL,NULL,NULL);
    ResetLevelRecords(_state);
    atomic_store(&_state->callbacks,0);atomic_store(&_state->frames,0);atomic_store(&_state->limitedFrames,0);atomic_store(&_state->layoutFault,0);
}
- (void)dealloc{[self stop];free(_state);}
@end

static float QuietUSBSource(uint64_t frame,double rate) {
    if(!isfinite(rate)||rate<8000||frame>=rate*14)return 0;
    double fade=rate*.01,envelope=fmax(0,fmin(1,fmin(frame/fade,(rate*14-1-frame)/fade)));
    return .01584893f*envelope*sin(2*M_PI*440*frame/rate);
}
typedef struct {double rate;uint64_t frame;_Atomic(uint64_t) frames;_Atomic(int) fault;BOOL quiet;} TXUSBReferenceState;
static OSStatus DirectReference(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    TXUSBReferenceState *s=context;if(!output){atomic_store(&s->fault,1);return noErr;}
    for(UInt32 b=0;b<output->mNumberBuffers;b++)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    float *left,*right;UInt32 ls,rs,lf,rf;
    if(!ChannelPointer(output,2,&left,&ls,&lf)||!ChannelPointer(output,3,&right,&rs,&rf)){atomic_store(&s->fault,2);return noErr;}
    UInt32 frames=MIN(lf,rf);for(UInt32 f=0;f<frames;f++){float value=s->quiet?QuietUSBSource(s->frame++,s->rate):MeterReference(s->frame++,s->rate);left[f*ls]=value;right[f*rs]=value;}
    atomic_fetch_add(&s->frames,frames);return noErr;
}
static int CheckUSBMeterRoute(BOOL direct,BOOL quiet) {
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier])if(app.processIdentifier!=getpid()){fprintf(stderr,"Quit the mixer before the USB route diagnostic; its process taps can intercept the test signal.\n");return 2;}
    __block int result=0;
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{@try{
        NSMutableArray *matches=[NSMutableArray array];AudioDeviceID primary=TXAudio.defaultOutput;
        for(NSDictionary *d in TXAudio.outputs){NSString *name=[d[@"name"] uppercaseString];if(([name containsString:@"TX-6"]||[name containsString:@"TX6"])&&[d[@"transport"] unsignedIntValue]==kAudioDeviceTransportTypeUSB&&[d[@"channels"] unsignedIntValue]==12&&Channels([d[@"id"] unsignedIntValue],kAudioDevicePropertyScopeInput)==2)[matches addObject:d];}
        if(matches.count!=1||primary==[matches.firstObject[@"id"] unsignedIntValue]){fprintf(stderr,"Requires one USB 12 IN TX-6 and a separate default output.\n");result=2;return;}
        if(direct){
            AudioDeviceID device=[matches.firstObject[@"id"] unsignedIntValue];TXUSBReferenceState *state=calloc(1,sizeof(*state));if(!state){result=3;return;}state->quiet=quiet;UInt32 bytes=sizeof(state->rate);
            AudioObjectPropertyAddress address=Addr(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal);
            OSStatus status=AudioObjectGetPropertyData(device,&address,0,NULL,&bytes,&state->rate);
            if(status!=noErr||!isfinite(state->rate)||state->rate<8000){free(state);result=3;return;}
            for(NSNumber *stream in ReadIDs(device,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput)){
                AudioStreamBasicDescription format={0};bytes=sizeof(format);address=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);
                status=AudioObjectGetPropertyData(stream.unsignedIntValue,&address,0,NULL,&bytes,&format);
                if(status!=noErr||format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||format.mBitsPerChannel!=32){free(state);result=3;return;}
            }
            AudioDeviceIOProcID proc=NULL;status=AudioDeviceCreateIOProcID(device,DirectReference,state,&proc);
            if(status!=noErr){free(state);result=3;return;}
            status=UseOnlyTapInputs(device,proc,2,2);BOOL started=NO;
            if(status==noErr){status=AudioDeviceStart(device,proc);started=status==noErr;}
            if(started){printf("%s\n",quiet?"USB quiet source: track 2, at most -36 dBFS / 440 Hz, 14 seconds.":"USB direct IOProc reference: track 2, -18 / -9 / -3 dBFS, four seconds each.");fflush(stdout);uint64_t last=0;for(int i=0;i<28;i++){[NSThread sleepForTimeInterval:.5];uint64_t frames=atomic_load(&state->frames);if(frames==last||atomic_load(&state->fault)){result=4;break;}last=frames;}}
            if(!started||atomic_load(&state->fault)||!atomic_load(&state->frames)){fprintf(stderr,"USB direct diagnostic failed: %d/%d\n",status,atomic_load(&state->fault));result=4;}
            if(started&&AudioDeviceStop(device,proc)!=noErr)result=4;
            if(AudioDeviceDestroyIOProcID(device,proc)==noErr)free(state);else result=4;return;
        }
        NSDictionary *profile=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"TX6Mac.profile"];
        NSArray *assignments=profile[@"assignments"],*settings=profile[@"channels"];
        if(![assignments isKindOfClass:NSArray.class]||assignments.count!=6||![settings isKindOfClass:NSArray.class]||settings.count!=6||[profile[@"chromeTabs"] boolValue]){fprintf(stderr,"Requires an existing native-app mixer profile.\n");result=2;return;}
        TXAudio *audio=[TXAudio new];audio.meterOutputDevice=[matches.firstObject[@"id"] unsignedIntValue];atomic_store(&audio.state->meterReference,true);
        atomic_store(&audio.state->master,[profile[@"master"] floatValue]);NSMutableArray *groups=[NSMutableArray array];NSArray *processes=TXAudio.processes;
        for(int slot=0;slot<6;slot++){
            NSMutableArray *ids=[NSMutableArray array];for(NSDictionary *process in processes)if([process[@"key"] isEqual:assignments[slot]])[ids addObjectsFromArray:process[@"ids"]];[groups addObject:ids];
            NSDictionary *channel=settings[slot];atomic_store(&audio.state->gain[slot],[channel[@"gain"] floatValue]);atomic_store(&audio.state->muted[slot],[channel[@"muted"] boolValue]);
            NSArray *eq=channel[@"eq"];if([eq isKindOfClass:NSArray.class]&&eq.count==3)for(int band=0;band<3;band++)atomic_store(&audio.state->eq[slot][band],[eq[band] floatValue]);
        }
        if(![audio startOnDevice:primary groups:groups]){fprintf(stderr,"USB route diagnostic: %s\n",audio.lastError.UTF8String);result=3;[audio stop];return;}
        printf("USB aggregate reference: track 2 only, -18 / -9 / -3 dBFS, four seconds each; main audio passes through.\n");fflush(stdout);
        uint64_t previousFrames=0;
        for(int i=0;i<28;i++){
            [NSThread sleepForTimeInterval:.5];TXRenderState *s=audio.state;
            printf("{\"elapsed\":%.1f,\"usbPeak\":%.8f,\"usbRMS\":%.8f,\"layoutFault\":%d}\n",(i+1)*.5,atomic_load(&s->usbPeak[1]),atomic_load(&s->usbRMS[1]),atomic_load(&s->layoutFault));fflush(stdout);
            uint64_t frames=atomic_load(&s->frames);if(atomic_load(&s->layoutFault)||frames==previousFrames){result=4;break;}previousFrames=frames;
        }
        if(!atomic_load(&audio.state->callbacks))result=4;[audio stop];
    }@finally{dispatch_semaphore_signal(finished);}}});dispatch_semaphore_wait(finished,DISPATCH_TIME_FOREVER);return result;
}

int TXCheckUSBMeterRoute(BOOL direct) {return CheckUSBMeterRoute(direct,NO);}
int TXQuietUSBSource(void) {return CheckUSBMeterRoute(YES,YES);}

static BOOL GuardProbeSelfCheck(void) {
    NSDictionary *aggregate=GuardAggregateDescription(@"fake-tap-uuid");
    if(![aggregate[@kAudioAggregateDeviceIsPrivateKey] boolValue]||![aggregate[@kAudioAggregateDeviceTapAutoStartKey] boolValue]||[aggregate[@kAudioAggregateDeviceSubDeviceListKey] count]||![aggregate[@kAudioAggregateDeviceTapListKey][0][@kAudioSubTapUIDKey] isEqualToString:@"fake-tap-uuid"])return NO;
    NSArray *failures=@[@"",@"begin",@"aggregate_create",@"validate_input",@"io_create",@"io_start",@"io_stop",@"io_destroy",@"aggregate_destroy",@"end",@"exception"];
    for(NSString *failure in failures){
        __block BOOL tap=NO,device=NO,proc=NO,running=NO,injected=NO,valid=YES;__block double waited=0;
        NSMutableArray *actions=[NSMutableArray array],*events=[NSMutableArray array];
        int result=RunGuardProbeStages(^OSStatus(NSString *action){
            [actions addObject:action];
            if(!injected&&[failure isEqualToString:@"exception"]&&[action isEqualToString:@"io_start"]){injected=YES;@throw [NSException exceptionWithName:@"ProbeSelfCheck" reason:@"Injected" userInfo:nil];}
            if(!injected&&[action isEqualToString:failure]){injected=YES;return -801;}
            if([action isEqualToString:@"begin"]){valid=valid&&!tap;tap=YES;}
            else if([action isEqualToString:@"aggregate_create"]){valid=valid&&tap&&!device;device=YES;}
            else if([action isEqualToString:@"validate_input"]){valid=valid&&device;}
            else if([action isEqualToString:@"io_create"]){valid=valid&&device&&!proc;proc=YES;}
            else if([action isEqualToString:@"io_start"]){valid=valid&&proc&&!running;running=YES;}
            else if([action isEqualToString:@"io_stop"])running=NO;
            else if([action isEqualToString:@"io_destroy"]){valid=valid&&!running;proc=NO;}
            else if([action isEqualToString:@"aggregate_destroy"]){valid=valid&&!proc;device=NO;}
            else if([action isEqualToString:@"end"]){valid=valid&&!device;tap=NO;}
            else valid=NO;return noErr;
        },^(NSString *event,OSStatus status){[events addObject:event];},^(double duration){waited+=duration;});
        BOOL cleanupFailure=[@[@"io_destroy",@"aggregate_destroy",@"end"] containsObject:failure];
        if(!valid||tap||device||proc||running||result!=(failure.length?(cleanupFailure?4:3):0))return NO;
        if(!failure.length&&(waited!=10||![actions isEqualToArray:@[@"begin",@"aggregate_create",@"validate_input",@"io_create",@"io_start",@"io_stop",@"io_stop",@"io_destroy",@"aggregate_destroy",@"end"]]||![events.lastObject isEqualToString:@"completed"]))return NO;
        if(failure.length&&(!injected||![events.lastObject isEqualToString:@"failed"]))return NO;
    }
    __block int endAttempts=0;
    int persistent=RunGuardProbeStages(^OSStatus(NSString *action){if([action isEqualToString:@"end"]){endAttempts++;return -802;}return noErr;},^(NSString *event,OSStatus status){},^(double seconds){});
    if(persistent!=4||endAttempts!=2)return NO;
    float inputPCM[]={.1f,-.2f,.3f,-.4f},outputPCM[]={1,2,3,4};
    AudioBufferList input={.mNumberBuffers=1,.mBuffers={{2,sizeof(inputPCM),inputPCM}}};
    AudioBufferList output={.mNumberBuffers=1,.mBuffers={{2,sizeof(outputPCM),outputPCM}}};TXGuardProbePCM pcm={0};
    GuardProbeInput(0,NULL,&input,NULL,&output,NULL,&pcm);
    for(int i=0;i<4;i++)if(outputPCM[i]!=0)return NO;
    if(atomic_load(&pcm.callbacks)!=1||atomic_load(&pcm.frames)!=2||atomic_load(&pcm.samples)!=4||fabsf(atomic_load(&pcm.peak)-.4f)>1e-7||fabs(atomic_load(&pcm.energy)-.3)>1e-7||atomic_load(&pcm.fault))return NO;
    float left[]={.5f,NAN},right[]={-.6f,INFINITY};
    struct{UInt32 count;AudioBuffer buffers[2];} planar={2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
    GuardProbeInput(0,NULL,(AudioBufferList*)&planar,NULL,NULL,NULL,&pcm);
    if(atomic_load(&pcm.callbacks)!=2||atomic_load(&pcm.frames)!=4||atomic_load(&pcm.samples)!=6||atomic_load(&pcm.nonfinite)!=2||fabsf(atomic_load(&pcm.peak)-.6f)>1e-7||fabs(atomic_load(&pcm.energy)-.91)>1e-7)return NO;
    input.mBuffers[0].mData=NULL;for(int i=0;i<4;i++)outputPCM[i]=1;
    GuardProbeInput(0,NULL,&input,NULL,&output,NULL,&pcm);
    for(int i=0;i<4;i++)if(outputPCM[i]!=0)return NO;
    if(atomic_load(&pcm.fault)!=2||atomic_load(&pcm.callbacks)!=2)return NO;
    return YES;
}

static BOOL GuardSelfCheck(void) {
    __block NSUInteger creates=0,destroys=0,ownersRead=0,aggregateCreates=0,aggregateDestroys=0;
    __block OSStatus createStatus=noErr,destroyStatus=noErr,aggregateCreateStatus=noErr,aggregateDestroyStatus=noErr;
    __block BOOL ownerFailure=NO,validDescription=YES;__block AudioObjectID createdID=501,createdAggregate=601,lastDestroyed=0;
    __block NSString *tapUUID=nil;NSMutableArray *order=[NSMutableArray array];
    TXGuardCreate create=^OSStatus(CATapDescription *description,AudioObjectID *tap){
        creates++;*tap=createdID;tapUUID=description.UUID.UUIDString;[order addObject:@"createTap"];
        validDescription=validDescription&&description.privateTap&&description.muteBehavior==CATapMuted&&description.exclusive&&
            [description.processes isEqualToArray:@[@101,@102]]&&!description.bundleIDs.count;return createStatus;
    };
    TXGuardDestroy destroy=^OSStatus(AudioObjectID tap){destroys++;lastDestroyed=tap;[order addObject:@"destroyTap"];return destroyStatus;};
    TXGuardCreateAggregate createAggregate=^OSStatus(NSDictionary *description,AudioDeviceID *aggregate){
        aggregateCreates++;*aggregate=createdAggregate;[order addObject:@"createAggregate"];
        validDescription=validDescription&&[description[@kAudioAggregateDeviceIsPrivateKey] boolValue]&&[description[@kAudioAggregateDeviceTapAutoStartKey] boolValue]&&[description[@kAudioAggregateDeviceSubDeviceListKey] count]==0&&[description[@kAudioAggregateDeviceTapListKey] count]==1&&[description[@kAudioAggregateDeviceTapListKey][0][@kAudioSubTapUIDKey] isEqualToString:tapUUID];
        return aggregateCreateStatus;
    };
    TXGuardDestroy destroyAggregate=^OSStatus(AudioObjectID aggregate){aggregateDestroys++;validDescription=validDescription&&aggregate==601;[order addObject:@"destroyAggregate"];return aggregateDestroyStatus;};
    TXGuardOwners owners=^NSArray<NSNumber*>*(NSError **error){ownersRead++;if(ownerFailure){if(error)*error=GuardError(@"Fake ownership",-703);return nil;}return @[@101,@102];};
    TXAudioMuteGuard *(^make)(void)=^TXAudioMuteGuard*{return [[TXAudioMuteGuard alloc] initWithCreate:create destroy:destroy createAggregate:createAggregate destroyAggregate:destroyAggregate owners:owners];};
    NSError *error=nil;
    @autoreleasepool{
        TXAudioMuteGuard *guard=make();
        if(guard.active||![guard end:&error]||destroys||aggregateDestroys||error)return NO;
        if(![guard begin:&error]||!guard.active||error||creates!=1||aggregateCreates!=1||ownersRead!=1||!validDescription)return NO;
        if(![guard begin:&error]||creates!=1||aggregateCreates!=1||ownersRead!=1)return NO;
        TXAudio *audio=[TXAudio new];atomic_store(&audio.state->transitionMuted,true);[audio stop];
        if(!guard.active||destroys||aggregateDestroys||!atomic_load(&audio.state->transitionMuted))return NO;
        aggregateDestroyStatus=-710;
        if([guard end:&error]||!guard.active||error.code!=-710||aggregateDestroys!=1||destroys)return NO;
        if(![guard begin:&error]||creates!=1||aggregateCreates!=1||error)return NO;
        aggregateDestroyStatus=noErr;destroyStatus=-701;
        if([guard end:&error]||!guard.active||error.code!=-701||aggregateDestroys!=2||destroys!=1||lastDestroyed!=501)return NO;
        if(![guard begin:&error]||creates!=1||aggregateCreates!=2||ownersRead!=1||error)return NO;
        destroyStatus=noErr;
        if(![guard end:&error]||guard.active||error||aggregateDestroys!=3||destroys!=2)return NO;
        if(![guard end:&error]||aggregateDestroys!=3||destroys!=2)return NO;
        if(![order isEqualToArray:@[@"createTap",@"createAggregate",@"destroyAggregate",@"destroyAggregate",@"destroyTap",@"createAggregate",@"destroyAggregate",@"destroyTap"]])return NO;
        createStatus=-702;createdID=999;
        if([guard begin:&error]||guard.active||error.code!=-702||creates!=2||aggregateCreates!=2||destroys!=2)return NO;
        createStatus=noErr;createdID=kAudioObjectUnknown;
        if([guard begin:&error]||guard.active||error.code!=kAudioHardwareBadObjectError||creates!=3||aggregateCreates!=2||destroys!=2)return NO;
        ownerFailure=YES;
        if([guard begin:&error]||guard.active||error.code!=-703||creates!=3)return NO;
        ownerFailure=NO;createdID=502;aggregateCreateStatus=-711;createdAggregate=999;
        if([guard begin:&error]||guard.active||error.code!=-711||aggregateCreates!=3||aggregateDestroys!=3||destroys!=3||lastDestroyed!=502)return NO;
        aggregateCreateStatus=noErr;createdAggregate=0;
        if([guard begin:&error]||guard.active||error.code!=kAudioHardwareBadObjectError||aggregateCreates!=4||aggregateDestroys!=3||destroys!=4)return NO;
        aggregateCreateStatus=-712;createdAggregate=998;destroyStatus=-713;
        if([guard begin:&error]||!guard.active||error.code!=-712||[error.userInfo[NSUnderlyingErrorKey] code]!=-713||aggregateCreates!=5||aggregateDestroys!=3||destroys!=5)return NO;
        NSUInteger previousCreates=creates,previousOwners=ownersRead;
        aggregateCreateStatus=noErr;createdAggregate=601;destroyStatus=noErr;
        if(![guard begin:&error]||!guard.active||error||creates!=previousCreates||ownersRead!=previousOwners||aggregateCreates!=6)return NO;
        [order removeAllObjects];guard=nil;
        if(aggregateDestroys!=4||destroys!=6||![order isEqualToArray:@[@"destroyAggregate",@"destroyTap"]])return NO;
    }
    @autoreleasepool{
        TXAudioMuteGuard *guard=make();createStatus=-704;createdID=998;
        if([guard begin:&error]||guard.active||error.code!=-704)return NO;
        guard=nil;if(aggregateDestroys!=4||destroys!=6)return NO;
    }
    @autoreleasepool{
        TXAudioMuteGuard *guard=make();createStatus=noErr;createdID=503;aggregateCreateStatus=-714;destroyStatus=-715;
        if([guard begin:&error]||!guard.active||error.code!=-714)return NO;
        destroyStatus=noErr;NSUInteger previousAggregates=aggregateDestroys;[order removeAllObjects];guard=nil;
        if(aggregateDestroys!=previousAggregates||lastDestroyed!=503||![order isEqualToArray:@[@"destroyTap"]])return NO;
    }
    return validDescription;
}

static BOOL TapRoutingSelfCheck(void) {
    NSArray *groups=@[@[@101],@[],@[],@[],@[],@[]],*empty=@[@[],@[],@[],@[],@[],@[]];
    NSDictionary *names=@{@101:@"org.live.app",@201:@"org.live.app",@999:@"local.tx6mac.mixer"};
    TXTapBundleReader reader=^NSString*(AudioObjectID process){return names[@(process)]?:@"";};NSError *error=nil;
    NSArray *legacy=PlanProcessTaps(groups,nil,@[@999],@"local.tx6mac.mixer",reader,&error);
    if(!legacy||error||legacy.count!=2||[legacy[0][@"slot"] intValue]!=0||[legacy[1][@"slot"] intValue]!=6)return NO;
    CATapDescription *live=legacy[0][@"description"],*remainder=legacy[1][@"description"];
    if(![live.processes isEqual:@[@101]]||![live.bundleIDs isEqual:@[@"org.live.app"]]||live.exclusive||![remainder.processes isEqual:@[@999,@101]]||![remainder.bundleIDs isEqual:@[@"local.tx6mac.mixer",@"org.live.app"]]||!remainder.exclusive)return NO;
    NSArray *metadata=@[@[@"org.live.app"],@[],@[@"org.closed.app",@"org.closed.helper"],@[],@[],@[]];
    NSArray *plan=PlanProcessTaps(groups,metadata,@[@999],@"local.tx6mac.mixer",reader,&error);
    if(!plan||error||plan.count!=7||[plan[2][@"slot"] intValue]!=2)return NO;
    CATapDescription *closed=plan[2][@"description"];remainder=plan[6][@"description"];
    if(closed.processes.count||closed.exclusive||!closed.privateTap||!closed.processRestoreEnabled||closed.muteBehavior!=CATapMutedWhenTapped||![closed.bundleIDs isEqual:metadata[2]]||![remainder.processes isEqual:@[@999,@101]])return NO;
    for(NSString *bundle in @[@"org.live.app",@"org.closed.app",@"org.closed.helper",@"local.tx6mac.mixer"])if(![remainder.bundleIDs containsObject:bundle])return NO;
    if(PlanProcessTaps(groups,@[],@[@999],@"local.tx6mac.mixer",reader,&error)||!error)return NO;
    for(id bad in @[@"pid:123",@"chrome-tab:123",@"app-group:123",@"local.tx6mac.system-sounds",@"local.tx6mac.mixer",@"contains space",@"",@7]){
        NSMutableArray *rows=[empty mutableCopy];rows[2]=@[bad];if(PlanProcessTaps(groups,rows,@[@999],@"local.tx6mac.mixer",reader,&error)||!error)return NO;
    }
    NSMutableArray *overlap=[metadata mutableCopy];overlap[4]=@[@"org.closed.app"];
    if(PlanProcessTaps(groups,overlap,@[@999],@"local.tx6mac.mixer",reader,&error)||!error)return NO;
    NSArray *currentOverlap=@[@[@101],@[@201],@[],@[],@[],@[]];
    if(PlanProcessTaps(currentOverlap,empty,@[@999],@"local.tx6mac.mixer",reader,&error)||!error)return NO;
    if(!PlanProcessTaps(currentOverlap,nil,@[@999],@"local.tx6mac.mixer",reader,&error)||error)return NO;
    NSMutableString *name=[NSMutableString stringWithString:@"org.snapshot.app"];NSMutableArray *row=[NSMutableArray arrayWithObject:name],*mutable=[empty mutableCopy];mutable[2]=row;
    TXAudio *audio=[TXAudio new];audio.slotBundleIDs=mutable;[name appendString:@".changed"];[row removeAllObjects];mutable[2]=@[];
    if(![audio.slotBundleIDs[2] isEqual:@[@"org.snapshot.app"]])return NO;[audio stop];if(![audio.slotBundleIDs[2] isEqual:@[@"org.snapshot.app"]])return NO;
    audio.slotBundleIDs=nil;if(audio.slotBundleIDs)return NO;
    audio.slotBundleIDs=(id)@[@[]];if(audio.slotBundleIDs.count)return NO;
    for(int failure=0;failure<3;failure++){
        __block int creates=0,formats=0;NSMutableArray *owned=[NSMutableArray array],*destroyed=[NSMutableArray array];
        NSArray *created=CreateProcessTapSet(plan,owned,^OSStatus(CATapDescription *description,AudioObjectID *tap){creates++;*tap=100+creates;return failure==1&&creates==2?-801:noErr;},^OSStatus(AudioObjectID tap,AudioStreamBasicDescription *format){
            formats++;*format=(AudioStreamBasicDescription){.mChannelsPerFrame=2,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat,.mBitsPerChannel=32};return failure==2&&formats==2?-802:noErr;
        },&error);
        if(failure==0){if(!created||error||created.count!=7||owned.count!=7||[created[2][@"slot"] intValue]!=2)return NO;}
        else if(created||!error||error.code!=(failure==1?-801:-802)||owned.count!=(failure==1?1:2))return NO;
        NSArray *before=[owned copy];DestroyProcessTapSet(owned,^OSStatus(AudioObjectID tap){[destroyed addObject:@(tap)];return noErr;});
        if(owned.count||![destroyed isEqual:before])return NO;
    }
    NSMutableArray *nextGroups=[groups mutableCopy],*nextMetadata=[metadata mutableCopy];nextGroups[1]=@[@202];nextMetadata[1]=@[@"org.new.app"];
    NSArray *next=PlanProcessTaps(nextGroups,nextMetadata,@[@999],@"local.tx6mac.mixer",reader,&error);if(next.count!=TX_SLOTS)return NO;
    for(int failAt=0;failAt<=3;failAt++){
        NSMutableArray *actual=[NSMutableArray array];for(NSDictionary *entry in plan)[actual addObject:entry[@"description"]];__block int writes=0;__block BOOL unrelatedTouched=NO;BOOL restored=NO;
        BOOL ok=RetargetTapSet(plan,next,^OSStatus(NSUInteger slot,CATapDescription *description){writes++;if(slot!=1&&slot!=6)unrelatedTouched=YES;if(writes==failAt)return -901;actual[slot]=description;return noErr;},&restored);
        if(unrelatedTouched||ok!=(failAt==0)||!restored)return NO;
        for(int slot=0;slot<TX_SLOTS;slot++)if(!SameTapSources(actual[slot],(failAt?plan:next)[slot][@"description"]))return NO;
    }
    BOOL restored=YES;if(RetargetTapSet(plan,next,^OSStatus(NSUInteger slot,CATapDescription *description){return -902;},&restored)||restored)return NO;
    return YES;
}

BOOL TXRunSelfCheck(void) {
    __block BOOL guardOK=NO;dispatch_semaphore_t guardFinished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{guardOK=GuardSelfCheck()&&GuardProbeSelfCheck()&&TapRoutingSelfCheck();dispatch_semaphore_signal(guardFinished);}});
    dispatch_semaphore_wait(guardFinished,DISPATCH_TIME_FOREVER);
    if(!guardOK){fprintf(stderr,"Mute guard lifecycle self-check failed.\n");return NO;}

    float syncMemory[8]={0},syncRaw[2]={.25f,-.125f},syncMain[2],syncMonitor[2];
    TXSyncDelay syncTest={.samples=syncMemory,.capacity=4,.mainFrames=2,.monitorFrames=0};
    ReadSyncFrame(&syncTest,syncRaw,syncMain,syncMonitor);
    if(syncMain[0]!=0||syncMain[1]!=0||syncMonitor[0]!=.25f||syncMonitor[1]!=-.125f){fprintf(stderr,"Raw PCM delay did not prefill silence independently per bus\n");return NO;}
    memset(syncMemory,0,sizeof(syncMemory));syncTest.writeIndex=syncTest.validFrames=0;
    for(int f=0;f<20;f++){syncRaw[0]=.01f*(f+1);syncRaw[1]=-syncRaw[0]*.5f;ReadSyncFrame(&syncTest,syncRaw,syncMain,syncMonitor);
        float expected=f<2?0:.01f*(f-1);if(fabsf(syncMain[0]-expected)>1e-7||fabsf(syncMain[1]+expected*.5f)>1e-7||syncMonitor[0]!=syncRaw[0])return NO;
    }
    syncTest.monitorFrames=3;syncRaw[0]=.21f;syncRaw[1]=-.105f;ReadSyncFrame(&syncTest,syncRaw,syncMain,syncMonitor);
    if(fabsf(syncMain[0]-.19f)>1e-7||fabsf(syncMonitor[0]-.18f)>1e-7)return NO;
    TXRenderState syncTiming={0};syncTiming.syncDelay[0]=syncTest;InvalidateSyncHistory(&syncTiming);ReadSyncFrame(&syncTiming.syncDelay[0],syncRaw,syncMain,syncMonitor);
    if(syncMain[0]!=0||syncMonitor[0]!=0)return NO;
    syncTiming.syncHostTickMS=.01;AudioTimeStamp syncNow={.mHostTime=1000,.mFlags=kAudioTimeStampHostTimeValid},syncInput={.mHostTime=900,.mFlags=kAudioTimeStampHostTimeValid},syncOutput={.mHostTime=1200,.mFlags=kAudioTimeStampHostTimeValid};
    RecordSyncTimestamps(&syncTiming,&syncNow,&syncInput,&syncOutput);
    if(atomic_load(&syncTiming.syncInputToOutputMS)!=3||atomic_load(&syncTiming.syncNowToOutputMS)!=2||syncTiming.syncDelay[0].mainFrames!=2)return NO;
    syncOutput.mHostTime=800;RecordSyncTimestamps(&syncTiming,&syncNow,&syncInput,&syncOutput);
    if(atomic_load(&syncTiming.syncInputToOutputMS)!=-1||atomic_load(&syncTiming.syncNowToOutputMS)!=-2)return NO;
    syncInput.mFlags=0;RecordSyncTimestamps(&syncTiming,&syncNow,&syncInput,&syncOutput);
    if(atomic_load(&syncTiming.syncInputToOutputMS)!=0||atomic_load(&syncTiming.syncInputFlags)!=0||atomic_load(&syncTiming.syncInputHostTime)!=900)return NO;
    NSDictionary *airTiming=@{@"uid":@"air",@"seconds":@.425,@"supported":@YES,@"reason":@"known",@"signature":@"air|48000|0|20400|1|known"};
    NSDictionary *studioTiming=@{@"uid":@"studio",@"seconds":@.022,@"supported":@YES,@"reason":@"known",@"signature":@"studio|48000|0|1056|1|known"};
    NSDictionary *sourceKnown=@{@"uid":@"air",@"seconds":@.425,@"supported":@YES},*syncPlan=SyncDelayPlan(sourceKnown,studioTiming,48000,YES);
    if([syncPlan[@"frames"] unsignedIntValue]!=19344||fabs([syncPlan[@"delayMs"] doubleValue]-403)>1e-9||![syncPlan[@"supported"] boolValue])return NO;
    if([SyncDelayPlan(sourceKnown,airTiming,48000,YES)[@"frames"] unsignedIntValue]||[SyncDelayPlan(sourceKnown,studioTiming,48000,NO)[@"frames"] unsignedIntValue])return NO;
    NSDictionary *negative=SyncDelayPlan(studioTiming,airTiming,48000,YES),*unknown=SyncDelayPlan(@{@"supported":@NO,@"reason":@"multiple-source-devices"},studioTiming,48000,YES);
    if([negative[@"frames"] unsignedIntValue]||![negative[@"reason"] isEqual:@"target-not-faster"]||[unknown[@"frames"] unsignedIntValue]||![unknown[@"reason"] isEqual:@"source-multiple-source-devices"])return NO;
    NSDictionary *clamped=SyncDelayPlan(@{@"uid":@"slow",@"seconds":@3,@"supported":@YES},studioTiming,48000,YES);
    if([clamped[@"frames"] unsignedIntValue]!=96000||[clamped[@"supported"] boolValue]||![clamped[@"reason"] isEqual:@"delay-clamped"])return NO;
    if([SyncDelayPlan(sourceKnown,studioTiming,384001,YES)[@"frames"] unsignedIntValue]||[SyncDelayPlan(@{@"uid":@"invalid",@"seconds":@(NAN),@"supported":@YES},studioTiming,48000,YES)[@"frames"] unsignedIntValue])return NO;
    NSDictionary *oneSource=@{@"process":@1,@"known":@YES,@"active":@YES,@"timings":@[airTiming]},*inactiveSource=@{@"process":@2,@"known":@YES,@"active":@NO,@"timings":@[]};
    NSDictionary *merged=SyncMergeSources(@[oneSource,inactiveSource]);if(![merged[@"supported"] boolValue]||![merged[@"uid"] isEqual:@"air"])return NO;
    NSDictionary *otherSource=@{@"process":@3,@"known":@YES,@"active":@YES,@"timings":@[studioTiming]};
    if([SyncMergeSources(@[oneSource,otherSource])[@"supported"] boolValue]||[SyncMergeSources(@[@{@"process":@1,@"known":@YES,@"active":@YES,@"timings":@[airTiming,studioTiming]}])[@"supported"] boolValue]||[SyncMergeSources(@[oneSource,@{@"process":@2,@"known":@NO}])[@"supported"] boolValue]||[SyncMergeSources(@[@{@"process":@1,@"known":@YES,@"active":@YES,@"timings":@[]}])[@"supported"] boolValue])return NO;
    TXSyncDelay allocatedSync={0};size_t syncBytes=SyncMaxBytes-8;
    if(![AllocateSyncBuffer(&allocatedSync,2,0,&syncBytes) isEqual:@"memory-limit"]||allocatedSync.samples)return NO;
    syncBytes=0;if(AllocateSyncBuffer(&allocatedSync,2,3,&syncBytes)||syncBytes!=32||allocatedSync.capacity!=4)return NO;free(allocatedSync.samples);
    UInt32 po=0,no=0,mo=0,ic=0,oc=0;NSDictionary *counts=@{@"main":@{@"in":@1,@"out":@2},@"meter":@{@"in":@12,@"out":@12}};
    if(!OutputLayout(@[@"main",@"meter"],@"main",@"",@"meter",counts,&po,&no,&mo,&ic,&oc)||po!=0||mo!=2||ic!=13||oc!=14)return NO;
    if(!OutputLayout(@[@"meter",@"main"],@"main",@"",@"meter",counts,&po,&no,&mo,&ic,&oc)||po!=12||mo!=0||ic!=13||oc!=14)return NO;
    if(OutputLayout(@[@"main",@"main"],@"main",@"",@"meter",counts,&po,&no,&mo,&ic,&oc))return NO;
    NSDictionary *three=@{@"main":@{@"in":@1,@"out":@2},@"monitor":@{@"in":@3,@"out":@4},@"meter":@{@"in":@12,@"out":@12}};
    NSArray *orders=@[@[@"main",@"monitor",@"meter"],@[@"meter",@"monitor",@"main"],@[@"monitor",@"main",@"meter"],@[@"main",@"meter",@"monitor"],@[@"monitor",@"meter",@"main"],@[@"meter",@"main",@"monitor"]];
    UInt32 offsets[6][3]={{0,2,6},{16,12,0},{4,0,6},{0,14,2},{16,0,4},{12,14,0}};
    for(int i=0;i<6;i++)if(!OutputLayout(orders[i],@"main",@"monitor",@"meter",three,&po,&no,&mo,&ic,&oc)||po!=offsets[i][0]||no!=offsets[i][1]||mo!=offsets[i][2]||ic!=16||oc!=18)return NO;
    if(OutputLayout(@[@"main",@"monitor"],@"main",@"monitor",@"meter",three,&po,&no,&mo,&ic,&oc)||
       OutputLayout(@[@"main",@"monitor",@"monitor"],@"main",@"monitor",@"meter",three,&po,&no,&mo,&ic,&oc)||
       OutputLayout(@[@"main",@"monitor",@"meter"],@"main",@"monitor",@"monitor",three,&po,&no,&mo,&ic,&oc))return NO;
    NSMutableDictionary *bad=[three mutableCopy];
    for(NSDictionary *entry in @[@{@"in":@0,@"out":@1},@{@"in":@-1,@"out":@4},@{@"in":@3,@"out":@4.5},@{@"in":@(UINT32_MAX),@"out":@4}]){
        bad[@"monitor"]=entry;if(OutputLayout(orders[0],@"main",@"monitor",@"meter",bad,&po,&no,&mo,&ic,&oc))return NO;
    }
    bad=[three mutableCopy];bad[@"meter"]=@{@"in":@12,@"out":@2};
    if(OutputLayout(orders[0],@"main",@"monitor",@"meter",bad,&po,&no,&mo,&ic,&oc))return NO;
    for(NSArray *ranges in @[@[@[@17,@2],@[@1,@12],@[@13,@4]],@[@[@13,@4],@[@17,@2],@[@1,@12]]]){
        NSMutableIndexSet *covered=[NSMutableIndexSet indexSet];
        for(NSArray *range in ranges)if(!AddStreamRange(covered,[range[0] unsignedIntValue],[range[1] unsignedIntValue],18,0))return NO;
        if(covered.count!=18||AddStreamRange(covered,1,1,18,0)||AddStreamRange(covered,19,1,18,0))return NO;
    }
    NSMutableIndexSet *inputCoverage=[NSMutableIndexSet indexSet];
    if(!AddStreamRange(inputCoverage,17,2,20,16)||!AddStreamRange(inputCoverage,1,12,20,16)||!AddStreamRange(inputCoverage,19,2,20,16)||!AddStreamRange(inputCoverage,13,4,20,16)||inputCoverage.count!=20)return NO;
    if(AddStreamRange([NSMutableIndexSet indexSet],16,2,20,16)||AddStreamRange([NSMutableIndexSet indexSet],0,2,20,16))return NO;
    UInt32 shiftedStarts[]={7,9,11,13},shiftedWidths[]={2,2,2,2},inputUsage[4]={0},inputBase=0;
    if(!InputStreamUsage(shiftedStarts,shiftedWidths,4,2,8,&inputBase,inputUsage)||inputBase!=6||inputUsage[0]!=0||inputUsage[1]!=1||inputUsage[2]!=1||inputUsage[3]!=1){
        fprintf(stderr,"Shifted input stream classification rejected: physical=2 total=8 starts=7,9,11,13\n");return NO;
    }
    UInt32 denseStarts[]={1,3,5,7};
    if(!InputStreamUsage(denseStarts,shiftedWidths,4,2,8,&inputBase,inputUsage)||inputBase!=0||inputUsage[0]!=0||inputUsage[1]!=1||inputUsage[2]!=1||inputUsage[3]!=1)return NO;
    if(!InputStreamUsage(shiftedStarts,shiftedWidths,3,0,6,&inputBase,inputUsage)||inputBase!=6||inputUsage[0]!=1||inputUsage[1]!=1||inputUsage[2]!=1)return NO;
    UInt32 multiplePhysicalStarts[]={7,10,11,13},multiplePhysicalWidths[]={3,1,2,2};
    if(!InputStreamUsage(multiplePhysicalStarts,multiplePhysicalWidths,4,4,8,&inputBase,inputUsage)||inputUsage[0]!=0||inputUsage[1]!=0||inputUsage[2]!=1||inputUsage[3]!=1)return NO;
    UInt32 badInputStarts[][4]={{7,9,12,14},{7,8,10,12},{9,7,11,13},{7,9,11,14},{0,2,4,6},{UINT32_MAX-5,UINT32_MAX-3,UINT32_MAX-1,UINT32_MAX}};
    for(int i=0;i<6;i++)if(InputStreamUsage(badInputStarts[i],shiftedWidths,4,2,8,&inputBase,inputUsage))return NO;
    UInt32 zeroWidth[]={2,0,2,2};
    if(InputStreamUsage(shiftedStarts,zeroWidth,4,2,8,&inputBase,inputUsage)||
       InputStreamUsage(shiftedStarts,shiftedWidths,4,1,8,&inputBase,inputUsage)||
       InputStreamUsage(shiftedStarts,shiftedWidths,4,3,8,&inputBase,inputUsage)||
       InputStreamUsage(shiftedStarts,shiftedWidths,4,9,8,&inputBase,inputUsage)||
       InputStreamUsage(shiftedStarts,shiftedWidths,4,2,9,&inputBase,inputUsage)||
       InputStreamUsage(shiftedStarts,shiftedWidths,4,2,7,&inputBase,inputUsage)||
       InputStreamUsage(shiftedStarts,shiftedWidths,0,2,8,&inputBase,inputUsage))return NO;
    NSDictionary *single=@{@"main":@{@"in":@2,@"out":@2}};
    if(!OutputLayout(@[@"main"],@"main",@"",@"",single,&po,&no,&mo,&ic,&oc)||po!=0||ic!=2||oc!=2)return NO;
    NSDictionary *dual=@{@"main":@{@"in":@2,@"out":@2},@"monitor":@{@"in":@4,@"out":@12}};
    if(!OutputLayout(@[@"monitor",@"main"],@"main",@"monitor",@"",dual,&po,&no,&mo,&ic,&oc)||po!=12||no!=0||ic!=6||oc!=14)return NO;
    if(!IsSystemSoundProcess(@"/usr/sbin/systemsoundserverd",@"systemsoundserverd") ||
       !IsSystemSoundProcess(nil,@"systemsoundserverd") ||
       IsSystemSoundProcess(@"/usr/sbin/coreaudiod",@"com.apple.audio.coreaudiod") ||
       IsSystemSoundProcess(@"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",@"com.google.Chrome") ||
       IsSystemSoundProcess(@"/Applications/Other.app/Contents/MacOS/Other",@"systemsoundserverd"))return NO;
    for(int band=0;band<3;band++)for(int gain=-18;gain<=18;gain+=18){
        TXFilter f={0};SetFilter(&f,band,gain,48000);double energy=0;
        for(int i=0;i<48000;i++){float x=0.1*sin(2*M_PI*1000*i/48000),y=FilterSample(&f,0,x);if(!isfinite(y)||fabs(y)>10)return NO;energy+=y*y;if(gain==0&&fabs(y-x)>0.000001)return NO;}
        if(energy<=0)return NO;
    }
    for(int band=0;band<3;band++)for(int polarity=-1;polarity<=1;polarity+=2){
        TXFilter f={0};SetFilter(&f,band,polarity*18,48000);double frequency=band==0?25:(band==1?1000:16000),inEnergy=0,outEnergy=0;
        for(int i=0;i<48000;i++){float x=0.01*sin(2*M_PI*frequency*i/48000),y=FilterSample(&f,0,x);if(i>24000){inEnergy+=x*x;outEnergy+=y*y;}}
        double ratio=sqrt(outEnergy/inEnergy);if(polarity==1?ratio<6:ratio>0.17)return NO;
    }
    TXRenderState s={0};s.sampleRate=48000;s.tapCount=2;s.tapSlots[0]=0;s.tapSlots[1]=6;s.outputLeft=0;s.outputRight=1;
    s.smoothMaster=1;s.limiterGain=1;atomic_store(&s.master,1);
    for(int slot=0;slot<TX_SLOTS;slot++){s.smoothGain[slot]=1;atomic_store(&s.gain[slot],1);for(int b=0;b<3;b++)SetFilter(&s.filters[slot][b],b,0,48000);}
    float a[128],b[128],out[512];for(int i=0;i<128;i++){a[i]=0.1;b[i]=0.2;}
    struct{UInt32 count;AudioBuffer buf[2];} input={2,{{2,sizeof(a),a},{2,sizeof(b),b}}};
    struct{UInt32 count;AudioBuffer buf[1];} output={1,{{8,sizeof(out),out}}};
    Render(0,NULL,(AudioBufferList*)&input,NULL,(AudioBufferList*)&output,NULL,&s);
    if(atomic_load(&s.frames)!=64||fabs(out[0]-0.3)>0.00001||fabs(atomic_load(&s.outputPeak)-0.3)>0.00001||out[2]!=0)return NO;
    if(fabsf(atomic_load(&s.channelPeakHold[0])-.1f)>1e-6||fabsf(atomic_load(&s.mainPreLimiterPeak)-.3f)>1e-6||fabsf(atomic_load(&s.mainPreLimiterHold)-.3f)>1e-6){fprintf(stderr,"Level hold/pre-limiter telemetry missed a render callback\n");return NO;}
    atomic_store(&s.route[0],TXOutputMonitor);
    Render(0,NULL,(AudioBufferList*)&input,NULL,(AudioBufferList*)&output,NULL,&s);
    if(fabs(out[0]-.2f)>1e-6){fprintf(stderr,"Missing monitor leaked to main: %f\n",out[0]);return NO;}
    atomic_store(&s.route[0],TXOutputMain);
    atomic_store(&s.muted[0],true);s.smoothGain[0]=0;
    Render(0,NULL,(AudioBufferList*)&input,NULL,(AudioBufferList*)&output,NULL,&s);
    if(fabs(out[0]-0.2)>0.00001)return NO;
    atomic_store(&s.masterMuted,true);s.smoothMaster=0;
    Render(0,NULL,(AudioBufferList*)&input,NULL,(AudioBufferList*)&output,NULL,&s);
    if(out[0]!=0||atomic_load(&s.outputPeak)!=0)return NO;
    atomic_store(&s.masterMuted,false);s.smoothMaster=1;
    input.count=1;Render(0,NULL,(AudioBufferList*)&input,NULL,(AudioBufferList*)&output,NULL,&s);
    if(atomic_load(&s.layoutFault)!=1||out[0]!=0)return NO;
    float mic[64],left[64],right[64];for(int i=0;i<64;i++){mic[i]=0.9;left[i]=0.15;right[i]=-0.25;}
    struct{UInt32 count;AudioBuffer buf[3];} planar={3,{{1,sizeof(mic),mic},{1,sizeof(left),left},{1,sizeof(right),right}}};
    s.physicalInputChannels=1;s.tapCount=1;s.tapSlots[0]=6;atomic_store(&s.layoutFault,0);
    Render(0,NULL,(AudioBufferList*)&planar,NULL,(AudioBufferList*)&output,NULL,&s);
    if(atomic_load(&s.layoutFault)||fabs(out[0]-0.15)>0.00001||fabs(out[1]+0.25)>0.00001)return NO;
    planar.buf[1].mData=NULL;atomic_store(&s.layoutFault,0);
    Render(0,NULL,(AudioBufferList*)&planar,NULL,(AudioBufferList*)&output,NULL,&s);
    if(atomic_load(&s.layoutFault)!=3||out[0]!=0)return NO;
    planar.buf[1].mData=left;atomic_store(&s.layoutFault,0);
    for(int i=0;i<64;i++){left[i]=8;right[i]=-4;}
    s.limiterGain=1;Render(0,NULL,(AudioBufferList*)&planar,NULL,(AudioBufferList*)&output,NULL,&s);
    for(int i=0;i<64;i++){if(fabs(out[i*8])>0.980001||fabs(out[i*8+1])>0.980001||fabs(out[i*8]+2*out[i*8+1])>0.00001)return NO;}
    if(!atomic_load(&s.limitedFrames))return NO;
    left[0]=NAN;right[0]=INFINITY;
    Render(0,NULL,(AudioBufferList*)&planar,NULL,(AudioBufferList*)&output,NULL,&s);
    for(int i=0;i<512;i++)if(!isfinite(out[i]))return NO;
    // Two hardware devices, reversed stream order, six independent stereo pairs.
    TXRenderState m={0};m.sampleRate=48000;m.tapCount=7;m.outputLeft=12;m.outputRight=13;m.meterEnabled=YES;m.meterOutputOffset=0;m.smoothMaster=1;m.limiterGain=1;atomic_store(&m.master,1);
    float samples[7][128],multi[64*14],physical[13*64];for(int i=0;i<13*64;i++)physical[i]=.9f;
    m.physicalInputChannels=13;
    struct{UInt32 count;AudioBuffer buf[8];} mi={.count=8};mi.buf[0]=(AudioBuffer){13,sizeof(physical),physical};
    struct{UInt32 count;AudioBuffer buf[1];} mout={1,{{14,sizeof(multi),multi}}};
    for(int slot=0;slot<7;slot++){m.tapSlots[slot]=slot;m.smoothGain[slot]=1;atomic_store(&m.gain[slot],1);for(int band=0;band<3;band++)SetFilter(&m.filters[slot][band],band,0,48000);
        for(int f=0;f<64;f++){samples[slot][2*f]=.01f*(slot+1);samples[slot][2*f+1]=-.005f*(slot+1);}mi.buf[slot+1]=(AudioBuffer){2,sizeof(samples[slot]),samples[slot]};}
    TXRenderState mainOnly;memcpy(&mainOnly,&m,sizeof(m));mainOnly.meterEnabled=NO;
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    for(int slot=0;slot<6;slot++)if(fabsf(multi[slot*2]-.0141253754f*(slot+1))>1e-6||fabsf(multi[slot*2+1]+.0070626877f*(slot+1))>1e-6){fprintf(stderr,"USB meter +3dB gain missing: slot=%d value=%f\n",slot,multi[slot*2]);return NO;}
    for(int slot=0;slot<6;slot++)if(fabsf(atomic_load(&m.usbPeak[slot])-.0141253754f*(slot+1))>1e-6||fabsf(atomic_load(&m.usbRMS[slot])-hypotf(.0141253754f,.0070626877f)*(slot+1)/sqrtf(2))>1e-6)return NO;
    if(fabsf(multi[12]-.28f)>1e-6)return NO; // Remainder reaches only primary output.
    mi.buf[0].mData=NULL;Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    if(atomic_load(&m.layoutFault)||fabsf(multi[0]-.0141253754f)>1e-6||fabsf(multi[12]-.28f)>1e-6)return NO;
    float primaryL=multi[12],primaryR=multi[13];
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&mainOnly);
    if(multi[12]!=primaryL||multi[13]!=primaryR)return NO; // Mirror does not change main DSP.
    atomic_store(&m.master,.5f);m.smoothMaster=.5f;atomic_store(&m.gain[0],.5f);m.smoothGain[0]=.5f;
    atomic_store(&m.eq[0][1],18);m.currentEQ[0][1]=18;SetFilter(&m.filters[0][1],1,18,48000);
    float expectedEQ=.0141253754f*.25f*m.filters[0][1].b0;
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    if(fabsf(multi[0]-expectedEQ)>1e-6||fabsf(multi[2]-.0141253754f)>1e-6)return NO;
    atomic_store(&m.master,1);m.smoothMaster=1;atomic_store(&m.gain[0],1);m.smoothGain[0]=1;
    atomic_store(&m.eq[0][1],0);m.currentEQ[0][1]=0;memset(&m.filters[0][1],0,sizeof(TXFilter));SetFilter(&m.filters[0][1],1,0,48000);
    m.tapCount=2;m.tapSlots[0]=0;m.tapSlots[1]=6;mi.count=3;mi.buf[2]=(AudioBuffer){2,sizeof(samples[6]),samples[6]};
    atomic_store(&m.muted[0],true);m.smoothGain[0]=0;
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    for(int c=0;c<12;c++)if(multi[c]!=0)return NO; // Muted and unassigned pairs are silent.
    if(fabsf(multi[12]-.07f)>1e-6)return NO;
    atomic_store(&m.masterMuted,true);m.smoothMaster=0;
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    for(int i=0;i<64*14;i++)if(multi[i]!=0)return NO;
    atomic_store(&m.masterMuted,false);atomic_store(&m.muted[0],false);m.smoothMaster=1;m.smoothGain[0]=1;
    for(int f=0;f<128;f++)samples[0][f]=f==0?NAN:8;
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    for(int i=0;i<64*14;i++)if(!isfinite(multi[i])||fabsf(multi[i])>.980001f)return NO;
    m.tapCount=1;m.tapSlots[0]=6;m.limiterGain=1;mi.count=2;mi.buf[1]=(AudioBuffer){2,sizeof(samples[6]),samples[6]};
    m.meterReferenceFrame=48000*4+1000;atomic_store(&m.meterReference,true);
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    for(int f=0;f<64;f++){
        float expected=pow(10,-9.0/20)*sin(2*M_PI*440*(48000*4+1000+f)/48000);
        if(fabsf(multi[f*14+2]-expected)>1e-6||multi[f*14+2]!=multi[f*14+3]||fabsf(multi[f*14+12]-.07f)>1e-6)return NO;
        for(int c=0;c<12;c++)if(c!=2&&c!=3&&multi[f*14+c]!=0)return NO;
    }
    if(atomic_load(&m.usbPeak[1])<=0||atomic_load(&m.usbRMS[1])<=0||atomic_load(&m.usbPeak[0])!=0)return NO;
    double referenceDB[]={-18,-9,-3};
    for(int step=0;step<3;step++){
        m.meterReferenceFrame=(uint64_t)48000*4*step+1000;
        Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
        for(int f=0;f<64;f++){
            float expected=pow(10,referenceDB[step]/20)*sin(2*M_PI*440*(48000*4*step+1000+f)/48000);
            if(fabsf(multi[f*14+2]-expected)>1e-6||multi[f*14+2]!=multi[f*14+3]||fabsf(multi[f*14+12]-.07f)>1e-6)return NO;
        }
    }
    // Main, monitor, and USB mirror share one source-processing pass.
    TXRenderState routed={0};routed.sampleRate=48000;routed.tapCount=2;routed.tapSlots[0]=0;routed.tapSlots[1]=6;
    routed.outputLeft=0;routed.outputRight=1;routed.monitorEnabled=YES;routed.monitorLeft=2;routed.monitorRight=3;
    routed.meterEnabled=YES;routed.meterOutputOffset=4;routed.smoothMaster=1;routed.smoothMonitorGain=1;routed.limiterGain=1;routed.monitorLimiterGain=1;
    atomic_store(&routed.master,1);atomic_store(&routed.monitorGain,1);atomic_store(&routed.route[6],TXOutputOff);
    for(int slot=0;slot<7;slot++){atomic_store(&routed.gain[slot],1);routed.smoothGain[slot]=1;for(int band=0;band<3;band++)SetFilter(&routed.filters[slot][band],band,0,48000);}
    float source[128],remainder[128],buses[16*64];
    for(int f=0;f<64;f++){source[2*f]=.1f;source[2*f+1]=-.05f;remainder[2*f]=.2f;remainder[2*f+1]=-.1f;}
    struct{UInt32 count;AudioBuffer buf[2];} ri={2,{{2,sizeof(source),source},{2,sizeof(remainder),remainder}}};
    struct{UInt32 count;AudioBuffer buf[3];} ro={3,{{2,64*2*sizeof(float),buses},{2,64*2*sizeof(float),buses+128},{12,64*12*sizeof(float),buses+256}}};
#define SYNC_EXPECT(condition) do{if(!(condition)){fprintf(stderr,"A/V sync render self-check failed at line %d\n",__LINE__);return NO;}}while(0)
    TXRenderState delayed;memcpy(&delayed,&routed,sizeof(delayed));atomic_store(&delayed.route[0],TXOutputBoth);
    float delayedRing[8]={0},delayedSource[128]={0},delayedRemainder[128]={0};delayedSource[0]=.1f;delayedSource[1]=-.05f;
    delayed.syncDelay[0]=(TXSyncDelay){.samples=delayedRing,.capacity=4,.mainFrames=2};
    struct{UInt32 count;AudioBuffer buf[2];} delayedInput={2,{{2,sizeof(delayedSource),delayedSource},{2,sizeof(delayedRemainder),delayedRemainder}}};
    atomic_store(&delayed.eq[0][1],18);delayed.currentEQ[0][1]=18;
    for(int band=0;band<TX_EQ;band++){SetFilter(&delayed.filters[0][band],band,band==1?18:0,48000);SetFilter(&delayed.syncMonitorFilters[0][band],band,band==1?18:0,48000);}
    Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    float mainDelayOutput[128];memcpy(mainDelayOutput,buses,sizeof(mainDelayOutput));
    SYNC_EXPECT(fabsf(buses[0])<1e-7&&fabsf(buses[2])<1e-7&&fabsf(buses[128])>.1f);
    for(int f=2;f<64;f++)SYNC_EXPECT(fabsf(mainDelayOutput[2*f]-buses[128+2*(f-2)])<1e-6&&fabsf(mainDelayOutput[2*f+1]-buses[129+2*(f-2)])<1e-6&&fabsf(buses[256+12*f]-mainDelayOutput[2*f]*1.41253754f)<1e-6);
    memcpy(&delayed,&routed,sizeof(delayed));atomic_store(&delayed.route[0],TXOutputBoth);memset(delayedRing,0,sizeof(delayedRing));delayed.syncDelay[0]=(TXSyncDelay){.samples=delayedRing,.capacity=4,.mainFrames=2};
    for(int band=0;band<TX_EQ;band++)SetFilter(&delayed.syncMonitorFilters[0][band],band,0,48000);
    for(int f=0;f<64;f++){delayedSource[2*f]=.1f;delayedSource[2*f+1]=-.05f;}
    Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    atomic_store(&delayed.gain[0],0);
    Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    float immediateGain=expf(-1/(.015f*48000));SYNC_EXPECT(fabsf(buses[0]-.1f*immediateGain)<1e-6&&buses[0]<.1f);
    atomic_store(&delayed.muted[0],true);
    Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    for(int i=0;i<16*64;i++)SYNC_EXPECT(buses[i]==0);
    atomic_store(&delayed.muted[0],false);atomic_store(&delayed.gain[0],1);delayed.smoothGain[0]=1;atomic_store(&delayed.eq[0][1],18);
    Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    SYNC_EXPECT(delayed.currentEQ[0][1]==.25&&fabs(buses[0]-.1f*delayed.filters[0][1].b0)<1e-6&&buses[0]>.1f);
    memcpy(&delayed,&routed,sizeof(delayed));atomic_store(&delayed.route[0],TXOutputBoth);memset(delayedRing,0,sizeof(delayedRing));delayed.syncDelay[0]=(TXSyncDelay){.samples=delayedRing,.capacity=4,.mainFrames=2};
    for(int band=0;band<TX_EQ;band++)SetFilter(&delayed.syncMonitorFilters[0][band],band,0,48000);
    Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    atomic_store(&delayed.transitionMuted,true);Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    SYNC_EXPECT(delayed.syncDelay[0].validFrames==0);
    atomic_store(&delayed.transitionMuted,false);Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    SYNC_EXPECT(fabsf(buses[0])<1e-7&&fabsf(buses[2])<1e-7&&fabsf(buses[4]-.1f)<1e-6);
    delayedInput.buf[0].mData=NULL;Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    SYNC_EXPECT(atomic_load(&delayed.layoutFault)==3&&delayed.syncDelay[0].validFrames==0);
    delayedInput.buf[0].mData=delayedSource;
    memcpy(&delayed,&routed,sizeof(delayed));atomic_store(&delayed.route[0],TXOutputBoth);
    uint64_t liveCommand=(1ULL<<40)|2;delayed.syncDelay[1]=(TXSyncDelay){.samples=delayedRing,.capacity=4,.validFrames=3};
    atomic_store(&delayed.syncCommand[1],liveCommand);atomic_store(&delayed.sourceUpdateCommand,(1ULL<<32)|(1U<<1));
    Render(0,NULL,(AudioBufferList*)&delayedInput,NULL,(AudioBufferList*)&ro,NULL,&delayed);
    SYNC_EXPECT(delayed.syncAppliedCommand[1]==liveCommand&&delayed.syncDelay[1].mainFrames==2&&delayed.syncDelay[1].validFrames==0&&delayed.syncAppliedCommand[0]==0&&fabsf(buses[0]-.1f)<1e-6&&atomic_load(&delayed.sourceUpdateApplied)==((1ULL<<32)|(1U<<1)));
#undef SYNC_EXPECT
#define LEVEL_EXPECT(condition) do{if(!(condition)){fprintf(stderr,"Level telemetry self-check failed at line %d\n",__LINE__);return NO;}}while(0)
    TXRenderState levels;memcpy(&levels,&routed,sizeof(levels));atomic_store(&levels.route[0],TXOutputBoth);
    float levelSource[2]={1.25f,-.625f},levelRemainder[2]={0,0};
    struct{UInt32 count;AudioBuffer buf[2];} levelInput={2,{{2,sizeof(levelSource),levelSource},{2,sizeof(levelRemainder),levelRemainder}}};
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.frames)==1&&atomic_load(&levels.channelOver[0])&&atomic_load(&levels.channelPeakHold[0])==1.25f);
    LEVEL_EXPECT(atomic_load(&levels.mainPreLimiterPeak)==1.25f&&atomic_load(&levels.monitorPreLimiterPeak)==1.25f);
    levelSource[0]=.05f;levelSource[1]=-.025f;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.peak[0])==.05f&&atomic_load(&levels.channelPeakHold[0])==1.25f&&atomic_load(&levels.channelOver[0]));
    LEVEL_EXPECT(atomic_load(&levels.mainPreLimiterPeak)==.05f&&atomic_load(&levels.mainPreLimiterHold)==1.25f&&atomic_load(&levels.monitorPreLimiterHold)==1.25f);
    atomic_store(&levels.masterMuted,true);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.peak[0])==.05f&&atomic_load(&levels.mainPreLimiterPeak)==0&&atomic_load(&levels.monitorPreLimiterPeak)==0&&atomic_load(&levels.channelPeakHold[0])==1.25f);
    LEVEL_EXPECT(fabsf(atomic_load(&levels.mainGainReductionDB)+20*log10f(levels.limiterGain))<1e-5&&fabsf(atomic_load(&levels.monitorGainReductionDB)+20*log10f(levels.monitorLimiterGain))<1e-5);
    float requestGR=atomic_load(&levels.mainGainReductionDB);uint64_t request1=TXRequestLevelPeakReset(&levels),request2=TXRequestLevelPeakReset(&levels);
    LEVEL_EXPECT(request1==1&&request2==2&&atomic_load(&levels.levelResetApplied)==0&&atomic_load(&levels.channelPeakHold[0])==1.25f&&atomic_load(&levels.mainGainReductionDB)==requestGR);
    levelSource[0]=levelSource[1]=0;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.levelResetApplied)==request2&&fabsf(atomic_load(&levels.channelPeakHold[0]))<1e-7&&!atomic_load(&levels.channelOver[0])&&atomic_load(&levels.mainPreLimiterHold)==0&&atomic_load(&levels.monitorPreLimiterHold)==0);
    LEVEL_EXPECT(fabsf(atomic_load(&levels.mainGainReductionDB)+20*log10f(levels.limiterGain))<1e-5);
    atomic_store(&levels.masterMuted,false);levels.smoothMaster=1;levelSource[0]=.2f;levelSource[1]=-.1f;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    uint64_t request3=TXRequestLevelPeakReset(&levels);
    LEVEL_EXPECT(request3==3&&atomic_load(&levels.levelResetApplied)==request2&&atomic_load(&levels.channelPeakHold[0])==.2f);
    levelSource[0]=levelSource[1]=0;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.levelResetApplied)==request3&&fabsf(atomic_load(&levels.channelPeakHold[0]))<1e-7);
    atomic_store(&levels.route[0],TXOutputOff);levelSource[0]=1;levelSource[1]=-.5f;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.peak[0])==1&&!atomic_load(&levels.channelOver[0])&&atomic_load(&levels.mainPreLimiterPeak)==0&&atomic_load(&levels.monitorPreLimiterPeak)==0&&buses[0]==0&&buses[128]==0&&buses[256]==0);
    levelSource[0]=1.0001f;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.channelOver[0])&&atomic_load(&levels.channelPeakHold[0])==1.0001f);
    levelSource[0]=3.2f;levelSource[1]=-1.6f;atomic_store(&levels.gain[0],.25f);levels.smoothGain[0]=.25f;TXRequestLevelPeakReset(&levels);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(fabsf(atomic_load(&levels.channelPeakHold[0])-.8f)<1e-6&&!atomic_load(&levels.channelOver[0])&&atomic_load(&levels.mainPreLimiterPeak)==0);
    atomic_store(&levels.gain[0],1);levels.smoothGain[0]=1;atomic_store(&levels.route[0],TXOutputBoth);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.channelOver[0])&&fabsf(atomic_load(&levels.mainPreLimiterPeak)-3.2f)<1e-6&&fabsf(atomic_load(&levels.mainGainReductionDB)-20*log10f(3.2f/.98f))<1e-5);
    levelSource[0]=.9f;levelSource[1]=-.45f;atomic_store(&levels.eq[0][1],18);levels.currentEQ[0][1]=18;
    memset(&levels.filters[0][1],0,sizeof(TXFilter));SetFilter(&levels.filters[0][1],1,18,48000);TXRequestLevelPeakReset(&levels);
    float eqPeak=.9f*levels.filters[0][1].b0;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(eqPeak>1&&fabsf(atomic_load(&levels.channelPeakHold[0])-eqPeak)<1e-6&&atomic_load(&levels.channelOver[0]));
    atomic_store(&levels.gain[0],.25f);levels.smoothGain[0]=.25f;
    memset(&levels.filters[0][1],0,sizeof(TXFilter));SetFilter(&levels.filters[0][1],1,18,48000);TXRequestLevelPeakReset(&levels);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(fabsf(atomic_load(&levels.channelPeakHold[0])-eqPeak*.25f)<1e-6&&!atomic_load(&levels.channelOver[0]));
    float holdBeforeMute=atomic_load(&levels.channelPeakHold[0]);atomic_store(&levels.muted[0],true);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.peak[0])==0&&atomic_load(&levels.channelPeakHold[0])==holdBeforeMute);
    TXRequestLevelPeakReset(&levels);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&levels);
    LEVEL_EXPECT(atomic_load(&levels.peak[0])==0&&atomic_load(&levels.channelPeakHold[0])==0&&!atomic_load(&levels.channelOver[0]));
    TXRenderState busLevels;memcpy(&busLevels,&routed,sizeof(busLevels));atomic_store(&busLevels.route[0],TXOutputMonitor);
    levelSource[0]=.2f;levelSource[1]=-.1f;levelRemainder[0]=2;levelRemainder[1]=-1;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.mainPreLimiterPeak)==2&&atomic_load(&busLevels.monitorPreLimiterPeak)==.2f&&fabsf(atomic_load(&busLevels.mainGainReductionDB)-20*log10f(2/.98f))<1e-5&&atomic_load(&busLevels.monitorGainReductionDB)==0);
    memcpy(&busLevels,&routed,sizeof(busLevels));atomic_store(&busLevels.route[0],TXOutputMonitor);
    levelSource[0]=.75f;levelSource[1]=-.375f;levelRemainder[0]=.2f;levelRemainder[1]=-.1f;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.mainPreLimiterPeak)==.2f&&atomic_load(&busLevels.monitorPreLimiterPeak)==.75f&&atomic_load(&busLevels.mainGainReductionDB)==0&&atomic_load(&busLevels.monitorGainReductionDB)==0&&!atomic_load(&busLevels.channelOver[0])&&fabsf(buses[256]-.98f)<1e-6);
    memcpy(&busLevels,&routed,sizeof(busLevels));atomic_store(&busLevels.route[0],TXOutputMonitor);levelSource[0]=2;levelSource[1]=-1;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.mainPreLimiterPeak)==.2f&&atomic_load(&busLevels.monitorPreLimiterPeak)==2&&atomic_load(&busLevels.mainGainReductionDB)==0&&fabsf(atomic_load(&busLevels.monitorGainReductionDB)-20*log10f(2/.98f))<1e-5);
    atomic_store(&busLevels.masterMuted,true);levelRemainder[0]=2;levelRemainder[1]=-1;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.peak[0])==2&&atomic_load(&busLevels.mainPreLimiterPeak)==0&&atomic_load(&busLevels.monitorPreLimiterPeak)==0&&atomic_load(&busLevels.monitorPreLimiterHold)==2);
    atomic_store(&busLevels.muted[0],true);TXRequestLevelPeakReset(&busLevels);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.channelPeakHold[0])==0&&!atomic_load(&busLevels.channelOver[0])&&atomic_load(&busLevels.channelPeakHold[6])==2&&atomic_load(&busLevels.channelOver[6])&&atomic_load(&busLevels.mainPreLimiterHold)==0&&atomic_load(&busLevels.monitorPreLimiterHold)==0);
    atomic_store(&busLevels.masterMuted,false);atomic_store(&busLevels.muted[0],false);busLevels.smoothGain[0]=1;busLevels.smoothMaster=1;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    float gatedMainGain=busLevels.limiterGain,gatedMonitorGain=busLevels.monitorLimiterGain;
    atomic_store(&busLevels.transitionMuted,true);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.peak[0])==0&&atomic_load(&busLevels.mainPreLimiterPeak)==0&&atomic_load(&busLevels.monitorPreLimiterPeak)==0&&atomic_load(&busLevels.mainGainReductionDB)==0&&atomic_load(&busLevels.monitorGainReductionDB)==0&&atomic_load(&busLevels.channelOver[0])&&atomic_load(&busLevels.monitorPreLimiterHold)==2&&busLevels.limiterGain==gatedMainGain&&busLevels.monitorLimiterGain==gatedMonitorGain);
    uint64_t gatedReset=TXRequestLevelPeakReset(&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.channelPeakHold[0])==2);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.levelResetApplied)==gatedReset&&atomic_load(&busLevels.channelPeakHold[0])==0&&!atomic_load(&busLevels.channelOver[0])&&atomic_load(&busLevels.mainPreLimiterHold)==0&&atomic_load(&busLevels.monitorPreLimiterHold)==0&&busLevels.limiterGain==gatedMainGain);
    atomic_store(&busLevels.transitionMuted,false);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    levelInput.count=1;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.layoutFault)==1&&atomic_load(&busLevels.peak[0])==0&&atomic_load(&busLevels.mainPreLimiterPeak)==0&&atomic_load(&busLevels.monitorPreLimiterPeak)==0&&atomic_load(&busLevels.mainGainReductionDB)==0&&atomic_load(&busLevels.monitorGainReductionDB)==0&&atomic_load(&busLevels.channelPeakHold[0])==2&&atomic_load(&busLevels.channelOver[0]));
    uint64_t faultReset=TXRequestLevelPeakReset(&busLevels);
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.levelResetApplied)==faultReset&&atomic_load(&busLevels.channelPeakHold[0])==0&&!atomic_load(&busLevels.channelOver[0]));
    levelInput.count=2;atomic_store(&busLevels.layoutFault,0);busLevels.monitorEnabled=NO;levelRemainder[0]=.2f;levelRemainder[1]=-.1f;
    Render(0,NULL,(AudioBufferList*)&levelInput,NULL,(AudioBufferList*)&ro,NULL,&busLevels);
    LEVEL_EXPECT(atomic_load(&busLevels.monitorPreLimiterPeak)==0&&atomic_load(&busLevels.monitorGainReductionDB)==0&&atomic_load(&busLevels.monitorPeak)==0&&atomic_load(&busLevels.usbPeak[0])==0);
#undef LEVEL_EXPECT
    atomic_store(&routed.route[0],TXOutputBoth);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    uint64_t guardCallbacks=atomic_load(&routed.callbacks),guardFrames=atomic_load(&routed.frames);
    atomic_store(&routed.transitionMuted,true);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int i=0;i<16*64;i++)if(buses[i]!=0){fprintf(stderr,"Transition gate leaked an output sample.\n");return NO;}
    for(int slot=0;slot<TX_SLOTS;slot++)if(atomic_load(&routed.peak[slot])!=0)return NO;
    for(int slot=0;slot<6;slot++)if(atomic_load(&routed.usbPeak[slot])!=0||atomic_load(&routed.usbRMS[slot])!=0)return NO;
    if(atomic_load(&routed.outputPeak)!=0||atomic_load(&routed.monitorPeak)!=0||atomic_load(&routed.callbacks)!=guardCallbacks+1||atomic_load(&routed.frames)!=guardFrames+64||atomic_load(&routed.layoutFault))return NO;
    routed.monitorRight=16;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(atomic_load(&routed.layoutFault)!=6||atomic_load(&routed.callbacks)!=guardCallbacks+1)return NO;
    routed.monitorRight=3;atomic_store(&routed.layoutFault,0);atomic_store(&routed.transitionMuted,false);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.3f)>1e-6||fabsf(buses[128]-.1f)>1e-6||fabsf(buses[256]-.141253754f)>1e-6)return NO;
    UInt32 routeCases[]={TXOutputMain,TXOutputMonitor,TXOutputBoth,TXOutputOff,UINT32_MAX};
    float mainCases[]={.3f,.2f,.3f,.2f,.2f},monitorCases[]={0,.1f,.1f,0,0},mirrorCases[]={.141253754f,.141253754f,.141253754f,0,0};
    for(int i=0;i<5;i++){
        atomic_store(&routed.route[0],routeCases[i]);Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
        for(int f=0;f<64;f++){
            if(fabsf(buses[2*f]-mainCases[i])>1e-6||fabsf(buses[2*f+1]+mainCases[i]*.5f)>1e-6||fabsf(buses[128+2*f]-monitorCases[i])>1e-6||fabsf(buses[129+2*f]+monitorCases[i]*.5f)>1e-6||fabsf(buses[256+12*f]-mirrorCases[i])>1e-6||fabsf(buses[257+12*f]+mirrorCases[i]*.5f)>1e-6)return NO;
            for(int c=2;c<12;c++)if(buses[256+12*f+c]!=0)return NO;
        }
    }
    atomic_store(&routed.route[0],TXOutputMonitor);
    atomic_store(&routed.monitorGain,1);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[128]-.1f)>1e-6||fabsf(buses[256]-.141253754f)>1e-6)return NO;
    atomic_store(&routed.monitorGain,0);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int f=0;f<64;f++)if(fabsf(buses[2*f]-.2f)>1e-6||fabsf(buses[2*f+1]+.1f)>1e-6||buses[128+2*f]!=0||buses[129+2*f]!=0||buses[256+12*f]!=0||buses[257+12*f]!=0)return NO;
    atomic_store(&routed.monitorGain,.01f);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int f=0;f<64;f++){
        if(fabsf(buses[2*f]-.2f)>1e-6||fabsf(buses[2*f+1]+.1f)>1e-6||fabsf(buses[128+2*f])>.001000001f||fabsf(buses[129+2*f])>.000500001f||fabsf(buses[256+12*f])>.001412539f||fabsf(buses[257+12*f])>.000706270f){
            fprintf(stderr,"Monitor trim zero recovery exceeded .01: monitor=%f mirror=%f\n",buses[128+2*f],buses[256+12*f]);return NO;
        }
    }
    float firstRecovery=.001f*(1-expf(-1/(.015f*48000)));
    if(fabsf(buses[128]-firstRecovery)>1e-9||fabsf(buses[256]-firstRecovery*1.41253754f)>1e-9||buses[254]<=buses[128]||atomic_load(&routed.monitorPeak)>.001000001f||atomic_load(&routed.usbPeak[0])>.001412539f)return NO;
    routed.monitorEnabled=NO;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.2f)>1e-6||buses[128]!=0||buses[256]!=0||atomic_load(&routed.monitorPeak)!=0)return NO;
    routed.monitorEnabled=YES;atomic_store(&routed.route[0],TXOutputBoth);atomic_store(&routed.monitorGain,.5f);routed.smoothMonitorGain=.5f;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.3f)>1e-6||fabsf(buses[128]-.05f)>1e-6||fabsf(buses[256]-.141253754f)>1e-6||fabsf(atomic_load(&routed.monitorPeak)-.05f)>1e-6)return NO;
    atomic_store(&routed.master,.5f);routed.smoothMaster=.5f;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.15f)>1e-6||fabsf(buses[128]-.025f)>1e-6||fabsf(buses[256]-.070626877f)>1e-6)return NO;
    atomic_store(&routed.master,1);routed.smoothMaster=1;atomic_store(&routed.route[0],TXOutputMonitor);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.2f)>1e-6||fabsf(buses[256]-.070626877f)>1e-6)return NO;
    atomic_store(&routed.monitorGain,0);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.2f)>1e-6||buses[128]!=0||buses[256]!=0)return NO;
    atomic_store(&routed.monitorGain,1);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[128]-.1f*(1-expf(-1/(.015f*48000))))>1e-7||buses[254]<=buses[128]||buses[254]>=.1f)return NO;
    routed.smoothMonitorGain=1;atomic_store(&routed.route[0],TXOutputBoth);atomic_store(&routed.muted[0],true);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.2f)>1e-6||buses[128]!=0||buses[256]!=0)return NO;
    atomic_store(&routed.masterMuted,true);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int i=0;i<16*64;i++)if(buses[i]!=0)return NO;
    atomic_store(&routed.masterMuted,false);routed.smoothMaster=1;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(!atomic_load(&routed.muted[0])||buses[128]!=0||fabsf(buses[0]-.2f)>1e-6)return NO;
    atomic_store(&routed.muted[0],false);routed.smoothGain[0]=1;atomic_store(&routed.route[0],TXOutputMonitor);
    for(int f=0;f<64;f++){source[2*f]=.75f;source[2*f+1]=-.375f;}
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int f=0;f<64;f++)if(fabsf(buses[2*f]-.2f)>1e-6||fabsf(buses[128+2*f]-.75f)>1e-6||fabsf(buses[129+2*f]+.375f)>1e-6||fabsf(buses[256+12*f]-.98f)>1e-6||fabsf(buses[257+12*f]+.49f)>1e-6)return NO;
    for(int f=0;f<64;f++){source[2*f]=.1f;source[2*f+1]=-.05f;}
    for(int f=0;f<64;f++){remainder[2*f]=8;remainder[2*f+1]=-4;}
    routed.limiterGain=1;routed.monitorLimiterGain=1;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int f=0;f<64;f++)if(fabsf(buses[2*f]-.98f)>1e-6||fabsf(buses[2*f+1]+.49f)>1e-6||fabsf(buses[128+2*f]-.1f)>1e-6)return NO;
    for(int f=0;f<64;f++){source[2*f]=8;source[2*f+1]=-4;remainder[2*f]=.2f;remainder[2*f+1]=-.1f;}
    routed.limiterGain=1;routed.monitorLimiterGain=1;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int f=0;f<64;f++)if(fabsf(buses[2*f]-.2f)>1e-6||fabsf(buses[128+2*f]-.98f)>1e-6||fabsf(buses[129+2*f]+.49f)>1e-6)return NO;
    if(!atomic_load(&routed.limitedFrames))return NO;
    for(int f=0;f<64;f++){source[2*f]=8;source[2*f+1]=-4;remainder[2*f]=8;remainder[2*f+1]=-4;}
    routed.limiterGain=1;routed.monitorLimiterGain=1;atomic_store(&routed.frames,0);atomic_store(&routed.limitedFrames,0);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(atomic_load(&routed.limitedFrames)!=64||atomic_load(&routed.frames)!=64)return NO;
    for(int f=0;f<64;f++){source[2*f]=.1f;source[2*f+1]=-.05f;remainder[2*f]=.2f;remainder[2*f+1]=-.1f;}
    routed.limiterGain=1;routed.monitorLimiterGain=1;
    for(NSNumber *trim in @[@(NAN),@-1,@2]){
        atomic_store(&routed.monitorGain,trim.floatValue);routed.smoothMonitorGain=trim.floatValue>1?1:0;
        Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
        if(fabsf(buses[0]-.2f)>1e-6||fabsf(buses[128]-(trim.floatValue>1?.1f:0))>1e-6||fabsf(buses[256]-(trim.floatValue>1?.141253754f:0))>1e-6)return NO;
    }
    atomic_store(&routed.monitorGain,1);routed.smoothMonitorGain=1;atomic_store(&routed.route[0],TXOutputBoth);
    atomic_store(&routed.eq[0][1],18);routed.currentEQ[0][1]=18;
    memset(&routed.filters[0][1],0,sizeof(TXFilter));SetFilter(&routed.filters[0][1],1,18,48000);
    TXRenderState eqMain;memcpy(&eqMain,&routed,sizeof(routed));eqMain.monitorEnabled=NO;eqMain.meterEnabled=NO;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    float expectedFirst=.1f*routed.filters[0][1].b0;
    if(fabsf(buses[0]-(.2f+expectedFirst))>1e-6||fabsf(buses[128]-expectedFirst)>1e-6||fabsf(buses[256]-expectedFirst*1.41253754f)>1e-6)return NO;
    float bothLast=buses[126];
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&eqMain);
    if(fabsf(buses[126]-bothLast)>1e-6)return NO;
    routed.monitorRight=16;atomic_store(&routed.layoutFault,0);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(atomic_load(&routed.layoutFault)!=6)return NO;
    for(int i=0;i<16*64;i++)if(buses[i]!=0)return NO;
    TXAudio *controls=[TXAudio new];if(atomic_load(&controls.state->monitorGain)!=1||controls.monitoring)return NO;
    atomic_store(&controls.state->route[0],TXOutputBoth);atomic_store(&controls.state->monitorGain,.4f);atomic_store(&controls.state->master,.7f);atomic_store(&controls.state->gain[0],.6f);
    for(int slot=0;slot<TX_SLOTS;slot++){atomic_store(&controls.state->channelPeakHold[slot],2);atomic_store(&controls.state->channelOver[slot],true);}
    atomic_store(&controls.state->mainPreLimiterPeak,2);atomic_store(&controls.state->mainPreLimiterHold,3);atomic_store(&controls.state->mainGainReductionDB,6);
    atomic_store(&controls.state->monitorPreLimiterPeak,2);atomic_store(&controls.state->monitorPreLimiterHold,3);atomic_store(&controls.state->monitorGainReductionDB,6);
    uint64_t stoppedReset=TXRequestLevelPeakReset(controls.state);
    if(!controls.syncCompensationEnabled)return NO;controls.syncCompensationEnabled=NO;size_t ownedSyncBytes=0;
    if(AllocateSyncBuffer(&controls.state->syncDelay[0],2,1,&ownedSyncBytes))return NO;controls.state->syncDelay[0].validFrames=2;atomic_store(&controls.state->syncInputFlags,kAudioTimeStampHostTimeValid);
    atomic_store(&controls.state->monitorPeak,.9f);atomic_store(&controls.state->usbPeak[0],.8f);[controls stop];
    if(controls.monitoring||controls.state->monitorEnabled||controls.state->meterEnabled||atomic_load(&controls.state->monitorPeak)!=0||atomic_load(&controls.state->usbPeak[0])!=0||atomic_load(&controls.state->route[0])!=TXOutputBoth||atomic_load(&controls.state->monitorGain)!=.4f||atomic_load(&controls.state->master)!=.7f||atomic_load(&controls.state->gain[0])!=.6f)return NO;
    if(controls.syncCompensationEnabled||controls.state->syncDelay[0].samples||controls.state->syncDelay[0].capacity||controls.state->syncDelay[0].validFrames||atomic_load(&controls.state->syncInputFlags))return NO;
    if(atomic_load(&controls.state->levelResetApplied)!=stoppedReset||atomic_load(&controls.state->mainPreLimiterPeak)||atomic_load(&controls.state->mainPreLimiterHold)||atomic_load(&controls.state->mainGainReductionDB)||atomic_load(&controls.state->monitorPreLimiterPeak)||atomic_load(&controls.state->monitorPreLimiterHold)||atomic_load(&controls.state->monitorGainReductionDB))return NO;
    for(int slot=0;slot<TX_SLOTS;slot++)if(atomic_load(&controls.state->channelPeakHold[slot])||atomic_load(&controls.state->channelOver[slot]))return NO;
    atomic_store(&controls.state->channelPeakHold[0],4);atomic_store(&controls.state->channelOver[0],true);atomic_store(&controls.state->mainPreLimiterHold,4);
    uint64_t startedReset=TXRequestLevelPeakReset(controls.state);__block BOOL invalidStart=YES;dispatch_semaphore_t startFinished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{invalidStart=[controls startOnDevice:0 groups:@[]];dispatch_semaphore_signal(startFinished);});
    dispatch_semaphore_wait(startFinished,DISPATCH_TIME_FOREVER);
    if(invalidStart||atomic_load(&controls.state->levelResetApplied)!=startedReset||startedReset<=stoppedReset||atomic_load(&controls.state->channelPeakHold[0])||atomic_load(&controls.state->channelOver[0])||atomic_load(&controls.state->mainPreLimiterHold))return NO;
    TXUSBReferenceState direct={.rate=48000,.frame=1000};DirectReference(0,NULL,NULL,NULL,(AudioBufferList*)&mout,NULL,&direct);
    if(atomic_load(&direct.frames)!=64||atomic_load(&direct.fault))return NO;
    for(int f=0;f<64;f++){float expected=pow(10,-18.0/20)*sin(2*M_PI*440*(1000+f)/48000);if(fabsf(multi[f*14+2]-expected)>1e-6||multi[f*14+2]!=multi[f*14+3])return NO;for(int c=0;c<14;c++)if(c!=2&&c!=3&&multi[f*14+c]!=0)return NO;}
    float quietPCM[12*64];
    struct{UInt32 count;AudioBuffer buf[1];} quietOutput={1,{{12,sizeof(quietPCM),quietPCM}}};
    TXUSBReferenceState quiet={.rate=48000,.quiet=YES};float quietPeak=0;
    for(int block=0;block<48000*14/64+1;block++){
        uint64_t first=quiet.frame;DirectReference(0,NULL,NULL,NULL,(AudioBufferList*)&quietOutput,NULL,&quiet);
        for(int f=0;f<64;f++)for(int c=0;c<12;c++){
            float value=quietPCM[f*12+c];
            if(!isfinite(value)||fabsf(value)>.01584893f||(c!=2&&c!=3&&value!=0))return NO;
            if((c==2||c==3)&&value!=QuietUSBSource(first+f,48000))return NO;
            if(first+f>=48000*14&&value!=0)return NO;
            quietPeak=fmaxf(quietPeak,fabsf(value));
        }
    }
    if(quietPeak<.0158f||atomic_load(&quiet.fault)||atomic_load(&quiet.frames)!=quiet.frame||QuietUSBSource(0,48000)!=0||QuietUSBSource(48000*14-1,48000)!=0)return NO;
    return YES;
}
