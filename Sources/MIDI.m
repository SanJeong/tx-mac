#import "TX6.h"
#import <CoreBluetooth/CoreBluetooth.h>

static NSString *MIDIString(MIDIObjectRef object,CFStringRef property) {
    CFStringRef s=NULL;if(MIDIObjectGetStringProperty(object,property,&s)!=noErr||!s)return @"";return CFBridgingRelease(s);
}
static MIDIObjectRef OwnerDevice(MIDIEndpointRef endpoint) {
    MIDIEntityRef entity=0;MIDIDeviceRef device=0;
    if(MIDIEndpointGetEntity(endpoint,&entity)==noErr&&entity)MIDIEntityGetDevice(entity,&device);
    return device;
}
static BOOL TXIsMixerName(NSString *name) {
    NSString *n=name.lowercaseString;
    return [n containsString:@"tx-6"]||[n containsString:@"tx–6"]||[n containsString:@"tx6"];
}

// BLE-MIDI 1.0의 패킷 헤더·이벤트 타임스탬프를 제거하고 CC만 전달합니다.
// 러닝 상태는 패킷마다 초기화하고, SysEx 본문은 제어값으로 해석하지 않습니다.
static void TXDecodeBLECC(NSData *packet,BOOL *inSysEx,void (^receive)(UInt8,UInt8,UInt8)) {
    const UInt8 *bytes=packet.bytes;NSUInteger n=packet.length,i=1;UInt8 running=0;
    if(n<2||n>512||(bytes[0]&0xC0)!=0x80)return;
    while(i<n){
        if(*inSysEx){if(bytes[i]&0x80){if(i+1>=n)return;if(bytes[i+1]==0xF7)*inSysEx=NO;i+=2;}else i++;continue;}
        if(bytes[i]&0x80)i++;else if(i==1||!running)return;if(i>=n)return;
        UInt8 status=bytes[i];
        if(status&0x80){i++;if(status>=0xF8)continue;if(status==0xF0){*inSysEx=YES;running=0;continue;}if(status==0xF7){running=0;continue;}running=status<0xF0?status:0;}
        else {status=running;if(!status)return;}
        NSUInteger count=status<0xF0?(((status&0xF0)==0xC0||(status&0xF0)==0xD0)?1:2):(status==0xF2?2:((status==0xF1||status==0xF3)?1:0));
        UInt8 values[2]={0};for(NSUInteger j=0;j<count;j++){
            // 실시간 메시지는 진행 중인 채널 메시지와 러닝 상태를 취소하지 않습니다.
            while(i+1<n&&(bytes[i]&0x80)&&bytes[i+1]>=0xF8)i+=2;
            if(i>=n||(bytes[i]&0x80))return;values[j]=bytes[i++];
        }
        if((status&0xF0)==0xB0&&receive)receive(status&0x0F,values[0],values[1]);
    }
}

// Apple의 CoreBluetooth → BLE MIDI 서비스 검증 → CoreMIDI 인계 절차를 사용합니다.
@interface TXBLEReconnect:NSObject<CBCentralManagerDelegate,CBPeripheralDelegate>
@property(nonatomic,strong) CBCentralManager *central;
@property(nonatomic,strong) CBPeripheral *peripheral;
@property(nonatomic,strong) CBCharacteristic *midiCharacteristic;
@property(nonatomic) NSUInteger packets;
@property(nonatomic) CBManagerAuthorization authorization;
@property(nonatomic,copy) void (^received)(UInt8,UInt8,UInt8);
@property(nonatomic) BOOL available,allowDiscovery,enabled,activating,scanned,direct,inSysEx;
@property(nonatomic) NSTimeInterval retryAt,scanUntil,handoffUntil,connectUntil,lastActivate;
@property(nonatomic,copy) void (^changed)(void);
@property(nonatomic,copy) NSString *stage,*lastFailure;
- (void)updateAvailable:(BOOL)available allowDiscovery:(BOOL)allow enabled:(BOOL)enabled;
- (void)stop;
@end
@implementation TXBLEReconnect
- (CBUUID*)serviceUUID{return [CBUUID UUIDWithString:@"03B80E5A-EDE8-4B33-A751-6CE34EC4C700"];}
- (CBUUID*)characteristicUUID{return [CBUUID UUIDWithString:@"7772E5DB-3868-4112-A1A9-F2669D106BF3"];}
- (void)updateAvailable:(BOOL)available allowDiscovery:(BOOL)allow enabled:(BOOL)enabled {
    self.available=available;self.allowDiscovery=allow;self.enabled=enabled;
    NSString *saved=[[NSUserDefaults standardUserDefaults] stringForKey:@"TX6Mac.BLEPeripheral"];
    // 처음 USB만 사용하는 경우 Bluetooth 접근을 요청하지 않습니다.
    if(!self.central&&enabled&&(available||allow||saved.length))self.central=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey:@NO}];
    [self tick];
}
- (void)tick {
    if(!self.central)return;
    if(!self.enabled){self.direct=NO;self.midiCharacteristic=nil;[self.central stopScan];if(self.peripheral)[self.central cancelPeripheralConnection:self.peripheral];self.peripheral=nil;self.activating=NO;return;}
    if(self.central.state!=CBManagerStatePoweredOn)return;
    if(self.direct){if(self.available){self.direct=NO;CBPeripheral *p=self.peripheral;self.peripheral=nil;self.midiCharacteristic=nil;[self.central cancelPeripheralConnection:p];if(self.changed)self.changed();}else return;}
    for(CBPeripheral *p in [self.central retrieveConnectedPeripheralsWithServices:@[self.serviceUUID]])if(TXIsMixerName(p.name)){
        [[NSUserDefaults standardUserDefaults] setObject:p.identifier.UUIDString forKey:@"TX6Mac.BLEPeripheral"];
        if(self.available){[self.central stopScan];if(self.peripheral==p){[self.central cancelPeripheralConnection:p];self.peripheral=nil;self.activating=NO;}return;}
    }
    if(self.available){[self.central stopScan];return;}
    if(self.peripheral){
        if(!self.activating&&NSDate.date.timeIntervalSince1970>self.connectUntil){[self abandon:self.peripheral];return;}
        if(self.activating){
            if(NSDate.date.timeIntervalSince1970>self.handoffUntil){
                if(self.midiCharacteristic.properties&CBCharacteristicPropertyNotify){self.activating=NO;self.connectUntil=NSDate.date.timeIntervalSince1970+8;self.stage=@"subscribing-midi";[self.peripheral setNotifyValue:YES forCharacteristic:self.midiCharacteristic];}else [self abandon:self.peripheral];return;}
            if(NSDate.date.timeIntervalSince1970-self.lastActivate>=2){self.lastActivate=NSDate.date.timeIntervalSince1970;MIDIBluetoothDriverActivateAllConnections();}
            BOOL registered=NO;
            for(ItemCount i=0;i<MIDIGetNumberOfDevices();i++){MIDIDeviceRef d=MIDIGetDevice(i);SInt32 offline=1;MIDIObjectGetIntegerProperty(d,kMIDIPropertyOffline,&offline);if(!offline&&TXIsMixerName(MIDIString(d,kMIDIPropertyName))&&[MIDIString(d,kMIDIPropertyDriverOwner).lowercaseString containsString:@"bluetooth"]){registered=YES;break;}}
            if(registered){CBPeripheral *p=self.peripheral;self.peripheral=nil;self.activating=NO;[self.central cancelPeripheralConnection:p];if(self.changed)self.changed();}
        }return;
    }
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(self.central.isScanning){if(now<=self.scanUntil)return;[self.central stopScan];self.scanned=YES;}
    if(now<self.retryAt)return;
    NSString *saved=[[NSUserDefaults standardUserDefaults] stringForKey:@"TX6Mac.BLEPeripheral"];
    NSUUID *identifier=saved.length?[[NSUUID alloc] initWithUUIDString:saved]:nil;
    CBPeripheral *known=identifier?[self.central retrievePeripheralsWithIdentifiers:@[identifier]].firstObject:nil;
    if(!self.scanned&&(self.allowDiscovery||saved.length)){self.stage=@"scanning";self.scanUntil=now+8;[self.central scanForPeripheralsWithServices:@[self.serviceUUID] options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@NO}];return;}
    if(known){[self connect:known];return;}
    self.scanned=NO;self.retryAt=now+15;
}
- (void)connect:(CBPeripheral*)p {
    self.direct=NO;self.inSysEx=NO;self.midiCharacteristic=nil;self.stage=@"connecting";self.peripheral=p;p.delegate=self;self.connectUntil=NSDate.date.timeIntervalSince1970+15;self.retryAt=NSDate.date.timeIntervalSince1970+5;
    [self.central stopScan];[self.central connectPeripheral:p options:@{CBConnectPeripheralOptionEnableAutoReconnect:@YES}];
}
- (void)centralManagerDidUpdateState:(CBCentralManager*)central{self.authorization=CBManager.authorization;[self tick];}
- (void)centralManager:(CBCentralManager*)central didDiscoverPeripheral:(CBPeripheral*)p advertisementData:(NSDictionary<NSString*,id>*)data RSSI:(NSNumber*)RSSI {
    NSString *name=p.name?:data[CBAdvertisementDataLocalNameKey];
    if(self.enabled&&!self.available&&!self.peripheral&&TXIsMixerName(name))[self connect:p];
}
- (void)centralManager:(CBCentralManager*)central didConnectPeripheral:(CBPeripheral*)p {
    if(p!=self.peripheral||!self.enabled){[central cancelPeripheralConnection:p];return;}
    self.direct=NO;self.inSysEx=NO;self.midiCharacteristic=nil;self.activating=NO;self.stage=@"discovering-services";self.connectUntil=NSDate.date.timeIntervalSince1970+15;p.delegate=self;[p discoverServices:@[self.serviceUUID]];
}
- (void)peripheral:(CBPeripheral*)p didDiscoverServices:(NSError*)error {
    if(p!=self.peripheral)return;
    if(error){self.lastFailure=error.description;[self abandon:p];return;}
    for(CBService *service in p.services)if([service.UUID isEqual:self.serviceUUID]){self.stage=@"discovering-characteristics";[p discoverCharacteristics:@[self.characteristicUUID] forService:service];return;}
    [self abandon:p];
}
- (void)peripheral:(CBPeripheral*)p didDiscoverCharacteristicsForService:(CBService*)service error:(NSError*)error {
    if(p!=self.peripheral)return;
    if(error){self.lastFailure=error.description;[self abandon:p];return;}
    for(CBCharacteristic *characteristic in service.characteristics)if([characteristic.UUID isEqual:self.characteristicUUID]){
        self.midiCharacteristic=characteristic;
        if(characteristic.properties&CBCharacteristicPropertyRead)[p readValueForCharacteristic:characteristic];
        OSStatus status=MIDIBluetoothDriverActivateAllConnections();
        self.stage=[NSString stringWithFormat:@"activate:%d",(int)status];if(status==noErr){self.activating=YES;self.lastActivate=NSDate.date.timeIntervalSince1970;self.handoffUntil=self.lastActivate+12;[[NSUserDefaults standardUserDefaults] setObject:p.identifier.UUIDString forKey:@"TX6Mac.BLEPeripheral"];[self tick];return;}
    }
    [self abandon:p];
}
- (void)peripheral:(CBPeripheral*)p didUpdateNotificationStateForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if(p!=self.peripheral||characteristic!=self.midiCharacteristic)return;
    if(error||!characteristic.isNotifying){self.lastFailure=error.description?:@"notify-unavailable";[self abandon:p];return;}
    self.direct=YES;self.inSysEx=NO;self.lastFailure=@"";self.stage=@"direct-midi";if(self.changed)self.changed();
}
- (void)peripheral:(CBPeripheral*)p didUpdateValueForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if(p!=self.peripheral||!self.direct||characteristic!=self.midiCharacteristic||error)return;
    self.packets++;BOOL sysex=self.inSysEx;TXDecodeBLECC(characteristic.value,&sysex,self.received);self.inSysEx=sysex;
}
- (void)abandon:(CBPeripheral*)p {
    if(p==self.peripheral){BOOL wasDirect=self.direct;self.direct=NO;self.midiCharacteristic=nil;if(wasDirect&&self.changed)self.changed();self.lastFailure=self.lastFailure?:[NSString stringWithFormat:@"timeout-or-invalid-service:%@",self.stage?:@"unknown"];self.stage=@"retry-wait";self.scanned=NO;self.peripheral=nil;self.activating=NO;self.retryAt=NSDate.date.timeIntervalSince1970+10;}[self.central cancelPeripheralConnection:p];
}
- (void)centralManager:(CBCentralManager*)central didFailToConnectPeripheral:(CBPeripheral*)p error:(NSError*)error{[self abandon:p];}
- (void)centralManager:(CBCentralManager*)central didDisconnectPeripheral:(CBPeripheral*)p error:(NSError*)error {
    if(p==self.peripheral){self.peripheral=nil;self.midiCharacteristic=nil;self.direct=NO;self.scanned=NO;self.activating=NO;self.retryAt=NSDate.date.timeIntervalSince1970+5;if(self.changed)self.changed();}
}
- (void)centralManager:(CBCentralManager*)central didDisconnectPeripheral:(CBPeripheral*)p timestamp:(CFAbsoluteTime)timestamp isReconnecting:(BOOL)isReconnecting error:(NSError*)error {
    if(isReconnecting&&p==self.peripheral&&self.enabled&&!self.available){self.direct=NO;self.inSysEx=NO;self.midiCharacteristic=nil;self.activating=NO;self.stage=@"reconnecting";self.connectUntil=NSDate.date.timeIntervalSince1970+15;if(self.changed)self.changed();return;}
    [self centralManager:central didDisconnectPeripheral:p error:error];
}
- (void)stop {self.enabled=NO;self.direct=NO;self.midiCharacteristic=nil;[self.central stopScan];if(self.peripheral)[self.central cancelPeripheralConnection:self.peripheral];self.peripheral=nil;self.central.delegate=nil;self.central=nil;}
@end

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
    TXBLEReconnect *_ble;
}
- (instancetype)init {
    if((self=[super init])){_connected=[NSMutableDictionary dictionary];_pending=[NSMutableDictionary dictionary];_runningStatus=[NSMutableDictionary dictionary];_sources=@[];_transport=@"auto";}return self;
}
- (NSArray<NSString*>*)sources{return _sources;}
- (NSDictionary*)diagnostics{return @{@"direct":@(_ble.direct),@"packets":@(_ble.packets),@"authorization":@(_ble.authorization),@"centralState":@(_ble.central?_ble.central.state:-1),@"enabled":@(_ble.enabled),@"available":@(_ble.available),@"scanning":@(_ble.central.isScanning),@"peripheralState":@(_ble.peripheral?_ble.peripheral.state:-1),@"stage":_ble.stage?:@"idle",@"failure":_ble.lastFailure?:@"",@"knownPeripheral":@([[NSUserDefaults standardUserDefaults] stringForKey:@"TX6Mac.BLEPeripheral"].length>0)};}
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
    if(status!=noErr){NSLog(@"MIDI input error %d",(int)status);[self stop];return;}
    _ble=[TXBLEReconnect new];_ble.changed=^{dispatch_async(dispatch_get_main_queue(),^{[weakSelf refresh];});};
    _ble.received=^(UInt8 channel,UInt8 cc,UInt8 value){TXMIDI *m=weakSelf;if(m&&m->_connected.count==0&&![m.transport isEqual:@"usb"]&&m.received)m.received(@"TX-6 Bluetooth",channel,cc,value);};[self refresh];
}
- (void)setTransport:(NSString*)transport {
    if(![@[@"auto",@"usb",@"ble"] containsObject:transport])transport=@"auto";
    if([_transport isEqualToString:transport])return;_transport=[transport copy];[self refresh];
}
- (void)refresh {
    if(!_port)return;
    NSSet *previousEndpoints=[NSSet setWithArray:_connected.allKeys];
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
    if(_connected.count==0&&_ble.direct&&![_transport isEqual:@"usb"])[names addObject:@"TX-6 · Bluetooth"];
    BOOL endpointsChanged=![previousEndpoints isEqual:[NSSet setWithArray:_connected.allKeys]];
    if(![_sources isEqualToArray:names]||endpointsChanged){_sources=[names copy];if(self.changed)self.changed();}
    BOOL hasBLE=NO;for(NSDictionary *d in _connected.allValues)if([d[@"ble"] boolValue])hasBLE=YES;
    [_ble updateAvailable:_connected.count>0 allowDiscovery:[_transport isEqual:@"ble"] enabled:![_transport isEqual:@"usb"]&&([_transport isEqual:@"ble"]||hasBLE||!haveUSB)];
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
    [_ble stop];_ble=nil;if(_port)MIDIPortDispose(_port);_port=0;if(_client)MIDIClientDispose(_client);_client=0;
    [_connected removeAllObjects];[_pending removeAllObjects];[_runningStatus removeAllObjects];_sources=@[];
}
// 하드웨어 포트를 만들지 않고 실제 CoreMIDI 패킷 구조로 파서를 검사합니다.
+ (BOOL)selfCheck {
    if(!TXIsMixerName(@"TX-6 Bluetooth")||!TXIsMixerName(@"TX–6")||TXIsMixerName(@"OB-4red")||TXIsMixerName(@"EP-133"))return NO;
    NSMutableArray *decoded=[NSMutableArray array];BOOL sysex=NO;
    void (^receive)(UInt8,UInt8,UInt8)=^(UInt8 ch,UInt8 cc,UInt8 value){[decoded addObject:@[@(ch),@(cc),@(value)]];};
    UInt8 ble[]={0x80,0xB0,0xB0,1,127,2,64,0xB2,0xF8,0xB3,0xB1,7,12};
    TXDecodeBLECC([NSData dataWithBytes:ble length:sizeof(ble)],&sysex,receive);
    if(![decoded isEqual:@[@[@0,@1,@127],@[@0,@2,@64],@[@1,@7,@12]]])return NO;
    UInt8 noRunning[]={0x80,0x81,3,4};TXDecodeBLECC([NSData dataWithBytes:noRunning length:sizeof(noRunning)],&sysex,receive);if(decoded.count!=3)return NO;
    UInt8 exclusive[]={0x80,0x81,0xF0,1,2,0xB0,3,4};TXDecodeBLECC([NSData dataWithBytes:exclusive length:sizeof(exclusive)],&sysex,receive);if(!sysex||decoded.count!=3)return NO;
    UInt8 continuation[]={0x80,1,2,0x81,0xF7,0x82,0xB0,31,1};TXDecodeBLECC([NSData dataWithBytes:continuation length:sizeof(continuation)],&sysex,receive);if(sysex||decoded.count!=4)return NO;
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
