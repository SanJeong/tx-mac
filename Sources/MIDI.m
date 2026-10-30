#import "TX6.h"

static NSString *MIDIString(MIDIObjectRef object,CFStringRef property) {
    CFStringRef s=NULL;if(MIDIObjectGetStringProperty(object,property,&s)!=noErr||!s)return @"";return CFBridgingRelease(s);
}
static MIDIObjectRef OwnerDevice(MIDIEndpointRef endpoint) {
    MIDIEntityRef entity=0;MIDIDeviceRef device=0;
    if(MIDIEndpointGetEntity(endpoint,&entity)==noErr&&entity)MIDIEntityGetDevice(entity,&device);
    return device;
}
@interface TXMIDI ()
- (void)receivePackets:(const MIDIPacketList*)list source:(MIDIEndpointRef)source;
+ (BOOL)selfCheck;
@end

@implementation TXMIDI {
    MIDIClientRef _client;
    MIDIPortRef _port;
    NSMutableDictionary<NSNumber*,NSDictionary*> *_connected;
    NSMutableDictionary<NSNumber*,NSMutableData*> *_pending;
    NSMutableDictionary<NSNumber*,NSNumber*> *_runningStatus;
    NSArray<NSString*> *_sources;
}
- (instancetype)init {
    if((self=[super init])){_connected=[NSMutableDictionary dictionary];_pending=[NSMutableDictionary dictionary];_runningStatus=[NSMutableDictionary dictionary];_sources=@[];_transport=@"auto";}return self;
}
- (NSArray<NSString*>*)sources{return _sources;}
- (void)start {
    if(_client)return;
    __weak TXMIDI *weakSelf=self;
    OSStatus status=MIDIClientCreateWithBlock(CFSTR("TX6Mac"),&_client,^(const MIDINotification *message){dispatch_async(dispatch_get_main_queue(),^{[weakSelf refresh];});});
    if(status!=noErr){NSLog(@"MIDI client error %d",(int)status);return;}
    status=MIDIInputPortCreateWithBlock(_client,CFSTR("TX6Mac Controls"),&_port,^(const MIDIPacketList *list,void *context){
        // MIDI 수신 스레드에서 UI나 오디오 상태를 직접 변경하지 않습니다.
        MIDIEndpointRef source=(MIDIEndpointRef)(uintptr_t)context;
        size_t size=offsetof(MIDIPacketList,packet);const MIDIPacket *p=list->packet;
        for(UInt32 i=0;i<list->numPackets;i++){size=(const char*)MIDIPacketNext(p)-(const char*)list;p=MIDIPacketNext(p);}
        if(size>1024*1024)return;
        NSData *copy=[NSData dataWithBytes:list length:size];
        dispatch_async(dispatch_get_main_queue(),^{[weakSelf receivePackets:copy.bytes source:source];});
    });
    if(status!=noErr){NSLog(@"MIDI input error %d",(int)status);[self stop];return;}[self refresh];
}
- (void)setTransport:(NSString*)transport {
    if([_transport isEqualToString:transport])return;_transport=[transport copy];[self refresh];
}
- (void)refresh {
    if(!_port)return;
    NSMutableArray<NSDictionary*> *candidates=[NSMutableArray array];
    for(ItemCount i=0;i<MIDIGetNumberOfSources();i++){
        MIDIEndpointRef endpoint=MIDIGetSource(i);MIDIObjectRef owner=OwnerDevice(endpoint);
        NSString *name=MIDIString(endpoint,kMIDIPropertyDisplayName);
        NSString *model=MIDIString(owner,kMIDIPropertyModel),*manufacturer=MIDIString(owner,kMIDIPropertyManufacturer);
        NSString *driver=MIDIString(owner,kMIDIPropertyDriverOwner);
        NSString *descriptor=[[NSString stringWithFormat:@"%@ %@ %@ %@",name,model,manufacturer,driver] lowercaseString];
        if([descriptor rangeOfString:@"tx-6"].location==NSNotFound&&[descriptor rangeOfString:@"tx–6"].location==NSNotFound&&[descriptor rangeOfString:@"tx6"].location==NSNotFound)continue;
        SInt32 offline=0;MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyOffline,&offline);if(offline)continue;
        BOOL ble=[descriptor containsString:@"bluetooth"]||[descriptor containsString:@"ble midi"];
        [candidates addObject:@{@"endpoint":@(endpoint),@"name":name.length?name:@"TX-6",@"ble":@(ble),@"driver":driver}];
    }
    // 자동 모드는 USB를 우선해 유선·무선 이중 수신을 방지합니다.
    BOOL haveUSB=NO;for(NSDictionary *d in candidates)if(![d[@"ble"] boolValue])haveUSB=YES;
    NSMutableDictionary *wanted=[NSMutableDictionary dictionary];
    for(NSDictionary *d in candidates){BOOL ble=[d[@"ble"] boolValue];
        if([_transport isEqual:@"usb"]&&ble)continue;if([_transport isEqual:@"ble"]&&!ble)continue;
        if([_transport isEqual:@"auto"]&&haveUSB&&ble)continue;wanted[d[@"endpoint"]]=d;
    }
    for(NSNumber *source in _connected.allKeys)if(!wanted[source]){MIDIPortDisconnectSource(_port,source.unsignedIntValue);[_connected removeObjectForKey:source];[_pending removeObjectForKey:source];[_runningStatus removeObjectForKey:source];}
    for(NSNumber *source in wanted)if(!_connected[source]){
        OSStatus status=MIDIPortConnectSource(_port,source.unsignedIntValue,(void*)(uintptr_t)source.unsignedIntValue);
        if(status==noErr)_connected[source]=wanted[source];else NSLog(@"MIDI connect error %d",(int)status);
    }
    NSMutableArray *names=[NSMutableArray array];for(NSNumber *source in [_connected.allKeys sortedArrayUsingSelector:@selector(compare:)]){NSDictionary *d=_connected[source];[names addObject:[NSString stringWithFormat:@"%@ · %@",d[@"name"],[d[@"ble"] boolValue]?@"Bluetooth":@"USB"]];}
    if(![_sources isEqualToArray:names]){_sources=[names copy];if(self.changed)self.changed();}
}
- (void)receivePackets:(const MIDIPacketList*)list source:(MIDIEndpointRef)source {
    NSNumber *key=@(source);NSDictionary *device=_connected[key];if(!device)return;
    NSMutableData *data=_pending[key];if(!data){data=[NSMutableData data];_pending[key]=data;}
    UInt8 running=[_runningStatus[key] unsignedCharValue];const MIDIPacket *packet=list->packet;
    for(UInt32 i=0;i<list->numPackets;i++){
        for(UInt16 j=0;j<packet->length;j++){
            UInt8 byte=packet->data[j];if(byte>=0xF8)continue;
            if(byte&0x80){[data setLength:0];running=byte<0xF0?byte:0;continue;}
            if(!running)continue;[data appendBytes:&byte length:1];
            NSUInteger expected=((running&0xF0)==0xC0||(running&0xF0)==0xD0)?1:2;
            if(data.length==expected){const UInt8 *values=data.bytes;
                if((running&0xF0)==0xB0&&self.received)self.received(device[@"name"],running&0x0F,values[0],values[1]);[data setLength:0];}
        }packet=MIDIPacketNext(packet);
    }_runningStatus[key]=@(running);
}
- (void)stop {
    if(_port)MIDIPortDispose(_port);_port=0;if(_client)MIDIClientDispose(_client);_client=0;
    [_connected removeAllObjects];[_pending removeAllObjects];[_runningStatus removeAllObjects];_sources=@[];
}
// 하드웨어 포트를 만들지 않고 실제 CoreMIDI 패킷 구조로 파서를 검사합니다.
+ (BOOL)selfCheck {
    TXMIDI *m=[TXMIDI new];m->_connected[@(123)]=@{@"name":@"TX-6 fixture"};
    NSMutableArray *received=[NSMutableArray array];
    m.received=^(NSString *name,UInt8 channel,UInt8 cc,UInt8 value){[received addObject:@[@(channel),@(cc),@(value)]];};
    Byte storage[1024];MIDIPacketList *list=(MIDIPacketList*)storage;MIDIPacket *packet=MIDIPacketListInit(list);
    Byte first[]={0xB0,1,127,0xF8,2,64,0xB0,33,127};
    packet=MIDIPacketListAdd(list,sizeof(storage),packet,0,sizeof(first),first);
    Byte second[]={0xB0,34,127,0xF0,1,2,0xF7,3,4,0xB1,7,12};
    if(!MIDIPacketListAdd(list,sizeof(storage),packet,0,sizeof(second),second))return NO;
    [m receivePackets:list source:123];
    NSArray *expected=@[@[@0,@1,@127],@[@0,@2,@64],@[@0,@33,@127],@[@0,@34,@127],@[@1,@7,@12]];
    if(![received isEqual:expected])return NO;
    packet=MIDIPacketListInit(list);Byte partial[]={0xB0,31};MIDIPacketListAdd(list,sizeof(storage),packet,0,sizeof(partial),partial);[m receivePackets:list source:123];
    packet=MIDIPacketListInit(list);Byte end[]={127};MIDIPacketListAdd(list,sizeof(storage),packet,0,sizeof(end),end);[m receivePackets:list source:123];
    if(received.count!=6||![received.lastObject isEqual:@[@0,@31,@127]])return NO;
    [m receivePackets:list source:456];return received.count==6;
}
- (void)dealloc{[self stop];}
@end

BOOL TXRunMIDISelfCheck(void) { return [TXMIDI selfCheck]; }
