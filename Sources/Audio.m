#import "TX6.h"
#import "Localization.h"
#import <math.h>
#import <libproc.h>
#import <stdarg.h>

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
static float MeterReference(uint64_t frame,double rate) {
    uint64_t length=(uint64_t)(rate*4),step=frame/length,position=frame%length;
    if(step>=3)return 0;
    double db[3]={-18,-9,-3},fade=rate*.01;
    double envelope=fmax(0,fmin(1,fmin(position/fade,(length-1-position)/fade)));
    return pow(10,db[step]/20)*envelope*sin(2*M_PI*440*frame/rate);
}
static OSStatus Render(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    TXRenderState *s=context;
    if(!input||!output){atomic_store(&s->layoutFault,4);return noErr;}
    for(UInt32 b=0;b<output->mNumberBuffers;b++)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    UInt32 channels=0;for(UInt32 b=0;b<input->mNumberBuffers;b++)channels+=input->mBuffers[b].mNumberChannels;
    if(channels!=s->physicalInputChannels+2*s->tapCount){atomic_store(&s->layoutFault,1);return noErr;}
    float *out[2];UInt32 os[2],of[2];
    if(!ChannelPointer(output,s->outputLeft,&out[0],&os[0],&of[0])||!ChannelPointer(output,s->outputRight,&out[1],&os[1],&of[1])){atomic_store(&s->layoutFault,2);return noErr;}
    UInt32 frames=MIN(of[0],of[1]);float *monitor[2];UInt32 mos[2];
    if(s->monitorEnabled)for(int c=0;c<2;c++){
        UInt32 n=0;if(!ChannelPointer(output,c?s->monitorRight:s->monitorLeft,&monitor[c],&mos[c],&n)){atomic_store(&s->layoutFault,6);return noErr;}frames=MIN(frames,n);
    }
    float *in[TX_SLOTS][2];UInt32 stride[TX_SLOTS][2];
    float *meter[6][2];UInt32 ms[6][2];
    if(s->meterEnabled)for(int slot=0;slot<6;slot++)for(int c=0;c<2;c++){
        UInt32 n=0;if(!ChannelPointer(output,s->meterOutputOffset+slot*2+c,&meter[slot][c],&ms[slot][c],&n)){atomic_store(&s->layoutFault,5);return noErr;}frames=MIN(frames,n);
    }
    for(int t=0;t<s->tapCount;t++)for(int c=0;c<2;c++){
        UInt32 n=0;if(!ChannelPointer(input,s->physicalInputChannels+t*2+c,&in[t][c],&stride[t][c],&n)){atomic_store(&s->layoutFault,3);return noErr;}frames=MIN(frames,n);
    }
    float target[TX_SLOTS],peaks[TX_SLOTS]={0},outputPeak=0,monitorPeak=0,usbPeak[6]={0};
    UInt32 routes[TX_SLOTS];BOOL muted[TX_SLOTS];double usbEnergy[6]={0};
    BOOL reference=atomic_load(&s->meterReference);
    for(int t=0;t<s->tapCount;t++){
        int slot=s->tapSlots[t];float rawGain=atomic_load(&s->gain[slot]);muted[slot]=atomic_load(&s->muted[slot]);target[t]=muted[slot]||!isfinite(rawGain)?0:fmaxf(0,fminf(1,rawGain));
        for(int b=0;b<TX_EQ;b++){
            double requested=atomic_load(&s->eq[slot][b]);requested=isfinite(requested)?fmax(-18,fmin(18,requested)):0;double delta=requested-s->currentEQ[slot][b];
            if(fabs(delta)>0.00001){s->currentEQ[slot][b]+=fmax(-0.25,fmin(0.25,delta));SetFilter(&s->filters[slot][b],b,s->currentEQ[slot][b],s->sampleRate);}
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
            for(int c=0;c<2;c++){
                float value=in[t][c][f*stride[t][c]];
                for(int b=0;b<TX_EQ;b++)value=FilterSample(&s->filters[slot][b],c,value);
                value*=s->smoothGain[slot];if(!isfinite(value)||muted[slot])value=0;
                peaks[slot]=fmaxf(peaks[slot],fabsf(value));
                if(routes[slot]==TXOutputMain||routes[slot]==TXOutputBoth)mix[c]+=value;
                if(s->monitorEnabled&&(routes[slot]==TXOutputMonitor||routes[slot]==TXOutputBoth))monitorMix[c]+=value;
                if(s->meterEnabled&&slot<6)slotPCM[slot][c]=value;
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
    for(int slot=0;slot<TX_SLOTS;slot++)atomic_store(&s->peak[slot],peaks[slot]);atomic_store(&s->outputPeak,outputPeak);atomic_store(&s->monitorPeak,monitorPeak);
    for(int slot=0;slot<6;slot++){atomic_store(&s->usbPeak[slot],usbPeak[slot]);atomic_store(&s->usbRMS[slot],frames?sqrt(usbEnergy[slot]/(2*frames)):0);}
    atomic_fetch_add(&s->callbacks,1);atomic_fetch_add(&s->frames,frames);return noErr;
}

@implementation TXAudio {
    TXRenderState *_state;
    NSMutableArray<NSNumber*> *_taps;
    AudioDeviceID _aggregate,_device;
    AudioDeviceIOProcID _proc;
    CATapDescription *_globalDescription;
    AudioObjectID _globalTap;
    BOOL _running;
}
- (instancetype)init {if((self=[super init])){_state=calloc(1,sizeof(*_state));_taps=[NSMutableArray array];atomic_store(&_state->master,1);atomic_store(&_state->monitorGain,1);for(int i=0;i<TX_SLOTS;i++)atomic_store(&_state->gain[i],1);}return self;}
- (TXRenderState*)state{return _state;}
- (BOOL)running{return _running;}
- (AudioDeviceID)device{return _device;}
- (BOOL)metering{return _running&&_state->meterEnabled;}
- (BOOL)monitoring{return _running&&_state->monitorEnabled;}
+ (AudioDeviceID)defaultOutput{return ReadUInt(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice);}
+ (NSString*)uid:(AudioDeviceID)device{return ReadString(device,kAudioDevicePropertyDeviceUID);}
+ (NSArray<NSDictionary*>*)outputs {
    NSMutableArray *result=[NSMutableArray array];
    for(NSNumber *n in ReadIDs(kAudioObjectSystemObject,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal)){
        AudioDeviceID d=n.unsignedIntValue;UInt32 count=Channels(d,kAudioDevicePropertyScopeOutput);
        NSString *uid=[self uid:d];if(count<2||[uid hasPrefix:@"local.tx6mac."])continue;
        [result addObject:@{@"id":n,@"name":ReadString(d,kAudioObjectPropertyName),@"uid":uid,@"channels":@(count),@"transport":@(ReadUInt(d,kAudioDevicePropertyTransportType))}];
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
    NSMutableArray *excluded=[NSMutableArray array];
    // Exclude this process from the global tap to prevent feedback.
    for(NSNumber *n in ReadIDs(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal))if((pid_t)ReadUInt(n.unsignedIntValue,kAudioProcessPropertyPID)==getpid())[excluded addObject:n];
    for(NSArray *group in groups)[excluded addObjectsFromArray:group];
    NSMutableArray *tapList=[NSMutableArray array];
    for(int slot=0;slot<TX_SLOTS;slot++){
        NSArray *ids=slot<6?groups[slot]:excluded;if(slot<6&&!ids.count)continue;
        CATapDescription *desc=slot==6?[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:ids]:[[CATapDescription alloc] initStereoMixdownOfProcesses:ids];
        desc.name=[NSString stringWithFormat:TXL(@"TX6Mac 채널 %d"),slot+1];desc.privateTap=YES;desc.muteBehavior=CATapMutedWhenTapped;
        if(@available(macOS 26.0,*)){
            NSMutableOrderedSet<NSString*> *bundles=[NSMutableOrderedSet orderedSet];
            for(NSNumber *process in ids){NSString *bundle=ReadString(process.unsignedIntValue,kAudioProcessPropertyBundleID);if(bundle.length)[bundles addObject:bundle];}
            if(slot==6){NSString *ownBundle=NSBundle.mainBundle.bundleIdentifier;if(ownBundle.length)[bundles addObject:ownBundle];else return [self fail:TXL(@"앱 식별자가 없어 피드백 방지를 보장할 수 없습니다") status:-7];}
            desc.bundleIDs=bundles.array;desc.processRestoreEnabled=YES;
        }
        AudioObjectID tap=0;OSStatus status=AudioHardwareCreateProcessTap(desc,&tap);if(status!=noErr)return [self fail:TXL(@"프로그램 오디오 탭 생성") status:status];
        [_taps addObject:@(tap)];_state->tapSlots[_state->tapCount++]=slot;
        if(slot==6){_globalDescription=desc;_globalTap=tap;}
        AudioStreamBasicDescription tapFormat={0};UInt32 tapFormatSize=sizeof(tapFormat);AudioObjectPropertyAddress tapFormatAddr=Addr(kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal);
        status=AudioObjectGetPropertyData(tap,&tapFormatAddr,0,NULL,&tapFormatSize,&tapFormat);
        if(status!=noErr||tapFormat.mChannelsPerFrame!=2||tapFormat.mFormatID!=kAudioFormatLinearPCM||!(tapFormat.mFormatFlags&kAudioFormatFlagIsFloat)||tapFormat.mBitsPerChannel!=32)return [self fail:TXL(@"지원하지 않는 프로그램 오디오 탭 형식") status:status?:-8];
        [tapList addObject:@{@kAudioSubTapUIDKey:desc.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}];
    }
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
    for(int slot=0;slot<TX_SLOTS;slot++){_state->smoothGain[slot]=0;for(int b=0;b<TX_EQ;b++){memset(&_state->filters[slot][b],0,sizeof(TXFilter));_state->currentEQ[slot][b]=atomic_load(&_state->eq[slot][b]);SetFilter(&_state->filters[slot][b],b,_state->currentEQ[slot][b],rate);}}
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
    for(NSNumber *n in _taps)AudioHardwareDestroyProcessTap(n.unsignedIntValue);[_taps removeAllObjects];_globalDescription=nil;_globalTap=0;_running=NO;
    _state->meterEnabled=NO;_state->meterOutputOffset=0;_state->monitorEnabled=NO;_state->monitorLeft=0;_state->monitorRight=0;
    _state->tapCount=0;_state->physicalInputChannels=0;
    _state->meterReferenceFrame=0;
    atomic_store(&_state->monitorPeak,0);atomic_store(&_state->callbacks,0);atomic_store(&_state->frames,0);atomic_store(&_state->limitedFrames,0);atomic_store(&_state->layoutFault,0);
    for(int slot=0;slot<TX_SLOTS;slot++)atomic_store(&_state->peak[slot],0);atomic_store(&_state->outputPeak,0);
    for(int slot=0;slot<6;slot++){atomic_store(&_state->usbPeak[slot],0);atomic_store(&_state->usbRMS[slot],0);}
}
- (void)dealloc{[self stop];free(_state);}
@end

typedef struct {double rate;uint64_t frame;_Atomic(uint64_t) frames;_Atomic(int) fault;} TXUSBReferenceState;
static OSStatus DirectReference(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    TXUSBReferenceState *s=context;if(!output){atomic_store(&s->fault,1);return noErr;}
    for(UInt32 b=0;b<output->mNumberBuffers;b++)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    float *left,*right;UInt32 ls,rs,lf,rf;
    if(!ChannelPointer(output,2,&left,&ls,&lf)||!ChannelPointer(output,3,&right,&rs,&rf)){atomic_store(&s->fault,2);return noErr;}
    UInt32 frames=MIN(lf,rf);for(UInt32 f=0;f<frames;f++){float value=MeterReference(s->frame++,s->rate);left[f*ls]=value;right[f*rs]=value;}
    atomic_fetch_add(&s->frames,frames);return noErr;
}
int TXCheckUSBMeterRoute(BOOL direct) {
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier])if(app.processIdentifier!=getpid()){fprintf(stderr,"Quit the mixer before the USB route diagnostic; its process taps can intercept the test signal.\n");return 2;}
    __block int result=0;
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{@try{
        NSMutableArray *matches=[NSMutableArray array];AudioDeviceID primary=TXAudio.defaultOutput;
        for(NSDictionary *d in TXAudio.outputs){NSString *name=[d[@"name"] uppercaseString];if(([name containsString:@"TX-6"]||[name containsString:@"TX6"])&&[d[@"transport"] unsignedIntValue]==kAudioDeviceTransportTypeUSB&&[d[@"channels"] unsignedIntValue]==12&&Channels([d[@"id"] unsignedIntValue],kAudioDevicePropertyScopeInput)==2)[matches addObject:d];}
        if(matches.count!=1||primary==[matches.firstObject[@"id"] unsignedIntValue]){fprintf(stderr,"Requires one USB 12 IN TX-6 and a separate default output.\n");result=2;return;}
        if(direct){
            AudioDeviceID device=[matches.firstObject[@"id"] unsignedIntValue];TXUSBReferenceState *state=calloc(1,sizeof(*state));if(!state){result=3;return;}UInt32 bytes=sizeof(state->rate);
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
            if(started){printf("USB direct IOProc reference: track 2, -18 / -9 / -3 dBFS, four seconds each.\n");fflush(stdout);uint64_t last=0;for(int i=0;i<28;i++){[NSThread sleepForTimeInterval:.5];uint64_t frames=atomic_load(&state->frames);if(frames==last||atomic_load(&state->fault)){result=4;break;}last=frames;}}
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

BOOL TXRunSelfCheck(void) {
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
    for(int slot=0;slot<6;slot++)if(fabsf(multi[slot*2]-.01f*(slot+1))>1e-6||fabsf(multi[slot*2+1]+.005f*(slot+1))>1e-6)return NO;
    if(fabsf(multi[12]-.28f)>1e-6)return NO; // Remainder reaches only primary output.
    mi.buf[0].mData=NULL;Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    if(atomic_load(&m.layoutFault)||fabsf(multi[0]-.01f)>1e-6||fabsf(multi[12]-.28f)>1e-6)return NO;
    float primaryL=multi[12],primaryR=multi[13];
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&mainOnly);
    if(multi[12]!=primaryL||multi[13]!=primaryR)return NO; // Mirror does not change main DSP.
    atomic_store(&m.master,.5f);m.smoothMaster=.5f;atomic_store(&m.gain[0],.5f);m.smoothGain[0]=.5f;
    atomic_store(&m.eq[0][1],18);m.currentEQ[0][1]=18;SetFilter(&m.filters[0][1],1,18,48000);
    float expectedEQ=.01f*.25f*m.filters[0][1].b0;
    Render(0,NULL,(AudioBufferList*)&mi,NULL,(AudioBufferList*)&mout,NULL,&m);
    if(fabsf(multi[0]-expectedEQ)>1e-6||fabsf(multi[2]-.01f)>1e-6)return NO;
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
    UInt32 routeCases[]={TXOutputMain,TXOutputMonitor,TXOutputBoth,TXOutputOff,UINT32_MAX};
    float mainCases[]={.3f,.2f,.3f,.2f,.2f},monitorCases[]={0,.1f,.1f,0,0},mirrorCases[]={.1f,.1f,.1f,0,0};
    for(int i=0;i<5;i++){
        atomic_store(&routed.route[0],routeCases[i]);Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
        for(int f=0;f<64;f++){
            if(fabsf(buses[2*f]-mainCases[i])>1e-6||fabsf(buses[2*f+1]+mainCases[i]*.5f)>1e-6||fabsf(buses[128+2*f]-monitorCases[i])>1e-6||fabsf(buses[129+2*f]+monitorCases[i]*.5f)>1e-6||fabsf(buses[256+12*f]-mirrorCases[i])>1e-6)return NO;
            for(int c=2;c<12;c++)if(buses[256+12*f+c]!=0)return NO;
        }
    }
    atomic_store(&routed.route[0],TXOutputMonitor);
    atomic_store(&routed.monitorGain,1);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[128]-.1f)>1e-6||fabsf(buses[256]-.1f)>1e-6)return NO;
    atomic_store(&routed.monitorGain,0);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int f=0;f<64;f++)if(fabsf(buses[2*f]-.2f)>1e-6||fabsf(buses[2*f+1]+.1f)>1e-6||buses[128+2*f]!=0||buses[129+2*f]!=0||buses[256+12*f]!=0||buses[257+12*f]!=0)return NO;
    atomic_store(&routed.monitorGain,.01f);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    for(int f=0;f<64;f++){
        if(fabsf(buses[2*f]-.2f)>1e-6||fabsf(buses[2*f+1]+.1f)>1e-6||fabsf(buses[128+2*f])>.001000001f||fabsf(buses[129+2*f])>.000500001f||fabsf(buses[256+12*f])>.001000001f||fabsf(buses[257+12*f])>.000500001f){
            fprintf(stderr,"Monitor trim zero recovery exceeded .01: monitor=%f mirror=%f\n",buses[128+2*f],buses[256+12*f]);return NO;
        }
    }
    float firstRecovery=.001f*(1-expf(-1/(.015f*48000)));
    if(fabsf(buses[128]-firstRecovery)>1e-9||fabsf(buses[256]-firstRecovery)>1e-9||buses[254]<=buses[128]||atomic_load(&routed.monitorPeak)>.001000001f||atomic_load(&routed.usbPeak[0])>.001000001f)return NO;
    routed.monitorEnabled=NO;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.2f)>1e-6||buses[128]!=0||buses[256]!=0||atomic_load(&routed.monitorPeak)!=0)return NO;
    routed.monitorEnabled=YES;atomic_store(&routed.route[0],TXOutputBoth);atomic_store(&routed.monitorGain,.5f);routed.smoothMonitorGain=.5f;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.3f)>1e-6||fabsf(buses[128]-.05f)>1e-6||fabsf(buses[256]-.1f)>1e-6||fabsf(atomic_load(&routed.monitorPeak)-.05f)>1e-6)return NO;
    atomic_store(&routed.master,.5f);routed.smoothMaster=.5f;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.15f)>1e-6||fabsf(buses[128]-.025f)>1e-6)return NO;
    atomic_store(&routed.master,1);routed.smoothMaster=1;atomic_store(&routed.route[0],TXOutputMonitor);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(fabsf(buses[0]-.2f)>1e-6||fabsf(buses[256]-.05f)>1e-6)return NO;
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
        if(fabsf(buses[0]-.2f)>1e-6||fabsf(buses[128]-(trim.floatValue>1?.1f:0))>1e-6)return NO;
    }
    atomic_store(&routed.monitorGain,1);routed.smoothMonitorGain=1;atomic_store(&routed.route[0],TXOutputBoth);
    atomic_store(&routed.eq[0][1],18);routed.currentEQ[0][1]=18;
    memset(&routed.filters[0][1],0,sizeof(TXFilter));SetFilter(&routed.filters[0][1],1,18,48000);
    TXRenderState eqMain;memcpy(&eqMain,&routed,sizeof(routed));eqMain.monitorEnabled=NO;eqMain.meterEnabled=NO;
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    float expectedFirst=.1f*routed.filters[0][1].b0;
    if(fabsf(buses[0]-(.2f+expectedFirst))>1e-6||fabsf(buses[128]-expectedFirst)>1e-6||fabsf(buses[256]-expectedFirst)>1e-6)return NO;
    float bothLast=buses[126];
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&eqMain);
    if(fabsf(buses[126]-bothLast)>1e-6)return NO;
    routed.monitorRight=16;atomic_store(&routed.layoutFault,0);
    Render(0,NULL,(AudioBufferList*)&ri,NULL,(AudioBufferList*)&ro,NULL,&routed);
    if(atomic_load(&routed.layoutFault)!=6)return NO;
    for(int i=0;i<16*64;i++)if(buses[i]!=0)return NO;
    TXAudio *controls=[TXAudio new];if(atomic_load(&controls.state->monitorGain)!=1||controls.monitoring)return NO;
    atomic_store(&controls.state->route[0],TXOutputBoth);atomic_store(&controls.state->monitorGain,.4f);atomic_store(&controls.state->master,.7f);atomic_store(&controls.state->gain[0],.6f);
    atomic_store(&controls.state->monitorPeak,.9f);atomic_store(&controls.state->usbPeak[0],.8f);[controls stop];
    if(controls.monitoring||controls.state->monitorEnabled||controls.state->meterEnabled||atomic_load(&controls.state->monitorPeak)!=0||atomic_load(&controls.state->usbPeak[0])!=0||atomic_load(&controls.state->route[0])!=TXOutputBoth||atomic_load(&controls.state->monitorGain)!=.4f||atomic_load(&controls.state->master)!=.7f||atomic_load(&controls.state->gain[0])!=.6f)return NO;
    TXUSBReferenceState direct={.rate=48000,.frame=1000};DirectReference(0,NULL,NULL,NULL,(AudioBufferList*)&mout,NULL,&direct);
    if(atomic_load(&direct.frames)!=64||atomic_load(&direct.fault))return NO;
    for(int f=0;f<64;f++){float expected=pow(10,-18.0/20)*sin(2*M_PI*440*(1000+f)/48000);if(fabsf(multi[f*14+2]-expected)>1e-6||multi[f*14+2]!=multi[f*14+3])return NO;for(int c=0;c<14;c++)if(c!=2&&c!=3&&multi[f*14+c]!=0)return NO;}
    return YES;
}
