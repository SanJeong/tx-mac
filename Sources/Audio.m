#import "TX6.h"
#import "Localization.h"
#import <math.h>
#import <libproc.h>

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
static OSStatus Render(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    TXRenderState *s=context;
    if(!input||!output){atomic_store(&s->layoutFault,4);return noErr;}
    for(UInt32 b=0;b<output->mNumberBuffers;b++)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    UInt32 channels=0;for(UInt32 b=0;b<input->mNumberBuffers;b++)channels+=input->mBuffers[b].mNumberChannels;
    if(channels!=s->physicalInputChannels+2*s->tapCount){atomic_store(&s->layoutFault,1);return noErr;}
    float *out[2];UInt32 os[2],of[2];
    if(!ChannelPointer(output,s->outputLeft,&out[0],&os[0],&of[0])||!ChannelPointer(output,s->outputRight,&out[1],&os[1],&of[1])){atomic_store(&s->layoutFault,2);return noErr;}
    UInt32 frames=MIN(of[0],of[1]);float *in[TX_SLOTS][2];UInt32 stride[TX_SLOTS][2];
    for(int t=0;t<s->tapCount;t++)for(int c=0;c<2;c++){
        UInt32 n=0;if(!ChannelPointer(input,s->physicalInputChannels+t*2+c,&in[t][c],&stride[t][c],&n)){atomic_store(&s->layoutFault,3);return noErr;}frames=MIN(frames,n);
    }
    float target[TX_SLOTS],peaks[TX_SLOTS]={0},outputPeak=0;
    for(int t=0;t<s->tapCount;t++){
        int slot=s->tapSlots[t];float rawGain=atomic_load(&s->gain[slot]);target[t]=atomic_load(&s->muted[slot])||!isfinite(rawGain)?0:fmaxf(0,fminf(1,rawGain));
        for(int b=0;b<TX_EQ;b++){
            double requested=atomic_load(&s->eq[slot][b]);requested=isfinite(requested)?fmax(-18,fmin(18,requested)):0;double delta=requested-s->currentEQ[slot][b];
            if(fabs(delta)>0.00001){s->currentEQ[slot][b]+=fmax(-0.25,fmin(0.25,delta));SetFilter(&s->filters[slot][b],b,s->currentEQ[slot][b],s->sampleRate);}
        }
    }
    float rawMaster=atomic_load(&s->master);
    float master=atomic_load(&s->masterMuted)||!isfinite(rawMaster)?0:fmaxf(0,fminf(1,rawMaster));
    float smoothing=1-expf(-1/(0.015*s->sampleRate));
    float limiterRelease=1-expf(-1/(0.080*s->sampleRate));
    for(UInt32 f=0;f<frames;f++) {
        float mix[2]={0};
        for(int t=0;t<s->tapCount;t++){
            int slot=s->tapSlots[t];s->smoothGain[slot]+=smoothing*(target[t]-s->smoothGain[slot]);
            for(int c=0;c<2;c++){
                float value=in[t][c][f*stride[t][c]];
                for(int b=0;b<TX_EQ;b++)value=FilterSample(&s->filters[slot][b],c,value);
                value*=s->smoothGain[slot];if(!isfinite(value))value=0;
                peaks[slot]=fmaxf(peaks[slot],fabsf(value));mix[c]+=value;
            }
        }
        s->smoothMaster+=smoothing*(master-s->smoothMaster);
        float peak=fmaxf(fabsf(mix[0]),fabsf(mix[1]))*s->smoothMaster;
        float required=peak>0.98f?0.98f/peak:1;
        // Share limiter gain across both channels to preserve the stereo image.
        if(required<s->limiterGain)s->limiterGain=required;
        else s->limiterGain+=limiterRelease*(required-s->limiterGain);
        if(s->limiterGain<0.999f)atomic_fetch_add_explicit(&s->limitedFrames,1,memory_order_relaxed);
        for(int c=0;c<2;c++){float value=fmaxf(-0.98f,fminf(0.98f,mix[c]*s->smoothMaster*s->limiterGain));out[c][f*os[c]]=value;outputPeak=fmaxf(outputPeak,fabsf(value));}
    }
    for(int slot=0;slot<TX_SLOTS;slot++)atomic_store(&s->peak[slot],peaks[slot]);atomic_store(&s->outputPeak,outputPeak);
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
- (instancetype)init {if((self=[super init])){_state=calloc(1,sizeof(*_state));_taps=[NSMutableArray array];atomic_store(&_state->master,1);for(int i=0;i<TX_SLOTS;i++)atomic_store(&_state->gain[i],1);}return self;}
- (TXRenderState*)state{return _state;}
- (BOOL)running{return _running;}
- (AudioDeviceID)device{return _device;}
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
    self.lastError=[NSString stringWithFormat:TXL(@"%@ 오류: %d (시스템 오디오 접근 권한과 출력 장치를 확인하세요)"),stage,(int)status];[self stop];return NO;
}
- (BOOL)startOnDevice:(AudioDeviceID)device groups:(NSArray<NSArray<NSNumber*>*>*)groups {
    NSAssert(!NSThread.isMainThread,@"HAL startup must not block the main thread");
    [self stop];self.lastError=@"";_device=device;
    if(groups.count!=6)return [self fail:TXL(@"6개 트랙 그룹이 필요합니다") status:-4];
    NSMutableSet *uniqueProcesses=[NSMutableSet set];
    for(NSArray *group in groups)for(NSNumber *process in group){
        if(![process isKindOfClass:NSNumber.class]||!process.unsignedIntValue||[uniqueProcesses containsObject:process])return [self fail:TXL(@"프로그램 중복 매핑") status:-5];
        if((pid_t)ReadUInt(process.unsignedIntValue,kAudioProcessPropertyPID)==getpid())return [self fail:TXL(@"믹서 자체 출력은 트랙에 지정할 수 없습니다") status:-6];
        [uniqueProcesses addObject:process];
    }
    NSString *uid=[TXAudio uid:device];if(!uid.length)return [self fail:TXL(@"출력 장치 없음") status:-1];
    if(Channels(device,kAudioDevicePropertyScopeOutput)<2)return [self fail:TXL(@"스테레오 출력 장치가 필요합니다") status:-12];
    _state->physicalInputChannels=Channels(device,kAudioDevicePropertyScopeInput);_state->tapCount=0;
    _state->outputLeft=0;_state->outputRight=1;
    UInt32 stereo[2]={1,2},size=sizeof(stereo);AudioObjectPropertyAddress stereoAddr=Addr(kAudioDevicePropertyPreferredChannelsForStereo,kAudioDevicePropertyScopeOutput);
    if(AudioObjectGetPropertyData(device,&stereoAddr,0,NULL,&size,stereo)==noErr&&stereo[0]&&stereo[1]){_state->outputLeft=stereo[0]-1;_state->outputRight=stereo[1]-1;}
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
    NSDictionary *description=@{@kAudioAggregateDeviceUIDKey:[@"local.tx6mac." stringByAppendingString:NSUUID.UUID.UUIDString],@kAudioAggregateDeviceNameKey:@"TX6Mac Mixer",@kAudioAggregateDeviceIsPrivateKey:@YES,@kAudioAggregateDeviceIsStackedKey:@NO,@kAudioAggregateDeviceMainSubDeviceKey:uid,@kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:uid}],@kAudioAggregateDeviceTapListKey:tapList,@kAudioAggregateDeviceTapAutoStartKey:@NO};
    OSStatus status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description,&_aggregate);
    if(status!=noErr)return [self fail:TXL(@"믹서 오디오 장치 생성") status:status];
    CFArrayRef activeTapUIDs=NULL;size=sizeof(activeTapUIDs);AudioObjectPropertyAddress tapOrderAddr=Addr(kAudioAggregateDevicePropertyTapList,kAudioObjectPropertyScopeGlobal);
    status=AudioObjectGetPropertyData(_aggregate,&tapOrderAddr,0,NULL,&size,&activeTapUIDs);
    NSArray *actualOrder=CFBridgingRelease(activeTapUIDs);NSMutableArray *expectedOrder=[NSMutableArray array];for(NSDictionary *entry in tapList)[expectedOrder addObject:entry[@kAudioSubTapUIDKey]];
    if(status!=noErr||![actualOrder isEqualToArray:expectedOrder])return [self fail:TXL(@"프로그램 오디오 채널 순서 확인") status:status?:-9];
    if(Channels(_aggregate,kAudioDevicePropertyScopeInput)!=_state->physicalInputChannels+2*_state->tapCount)return [self fail:TXL(@"프로그램 오디오 입력 레이아웃 확인") status:-10];
    for(NSNumber *stream in [ReadIDs(_aggregate,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeInput) arrayByAddingObjectsFromArray:ReadIDs(_aggregate,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput)]){
        AudioStreamBasicDescription f={0};size=sizeof(f);AudioObjectPropertyAddress a=Addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);
        status=AudioObjectGetPropertyData(stream.unsignedIntValue,&a,0,NULL,&size,&f);
        if(status!=noErr||f.mFormatID!=kAudioFormatLinearPCM||!(f.mFormatFlags&kAudioFormatFlagIsFloat)||f.mBitsPerChannel!=32)return [self fail:TXL(@"지원하지 않는 오디오 형식") status:status?:-2];
    }
    Float64 rate=48000;size=sizeof(rate);AudioObjectPropertyAddress rateAddr=Addr(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal);
    status=AudioObjectGetPropertyData(_aggregate,&rateAddr,0,NULL,&size,&rate);if(status!=noErr||rate<8000)return [self fail:TXL(@"샘플레이트 확인") status:status?:-3];_state->sampleRate=rate;
    atomic_store(&_state->layoutFault,0);atomic_store(&_state->callbacks,0);atomic_store(&_state->frames,0);
    atomic_store(&_state->outputPeak,0);_state->smoothMaster=0;_state->limiterGain=1;atomic_store(&_state->limitedFrames,0);
    for(int slot=0;slot<TX_SLOTS;slot++){_state->smoothGain[slot]=0;for(int b=0;b<TX_EQ;b++){memset(&_state->filters[slot][b],0,sizeof(TXFilter));_state->currentEQ[slot][b]=atomic_load(&_state->eq[slot][b]);SetFilter(&_state->filters[slot][b],b,_state->currentEQ[slot][b],rate);}}
    status=AudioDeviceCreateIOProcID(_aggregate,Render,_state,&_proc);if(status!=noErr)return [self fail:TXL(@"오디오 처리 연결") status:status];
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
    for(int slot=0;slot<TX_SLOTS;slot++)atomic_store(&_state->peak[slot],0);atomic_store(&_state->outputPeak,0);
}
- (void)dealloc{[self stop];free(_state);}
@end

BOOL TXRunSelfCheck(void) {
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
    return YES;
}
