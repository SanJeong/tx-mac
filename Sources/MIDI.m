#import "TX6.h"
#import <CoreBluetooth/CoreBluetooth.h>

static BOOL TXBLEInspectorName(NSString *name) {
    return name && ([name caseInsensitiveCompare:@"TX-6"]==NSOrderedSame || [name caseInsensitiveCompare:@"TX6"]==NSOrderedSame);
}
// Keep BLE diagnostics separate from the mixer's connection.
@interface TXBLEServiceInspector : NSObject<CBCentralManagerDelegate,CBPeripheralDelegate>
@property(nonatomic,strong) CBCentralManager *central;
@property(nonatomic,strong) CBPeripheral *peripheral;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary*> *services;
@property(nonatomic,strong) NSMutableDictionary<NSValue*,NSMutableDictionary*> *rows;
@property(nonatomic,copy) NSString *result;
@property(nonatomic) BOOL started,done,ownsConnection;
@property(nonatomic) NSUInteger pending;
@property(nonatomic) BOOL observe;
@property(nonatomic,strong) CBCharacteristic *observedCharacteristic;
@property(nonatomic,strong) NSMutableArray *samples;
@property(nonatomic) NSUInteger packetCount,byteCount;
@property(nonatomic) NSTimeInterval observeUntil;
@property(nonatomic,strong) NSMutableDictionary *deviceInfo;
@property(nonatomic,strong) CBCharacteristic *midiCharacteristic;
@property(nonatomic,strong) NSMutableArray *midiSamples,*events;
@property(nonatomic) NSUInteger midiPackets,midiBytes;
@property(nonatomic) NSTimeInterval startTime;
@property(nonatomic) BOOL privateSubscribed,midiSubscribed;
@property(nonatomic) BOOL pingRequested,pingAttempted,pingSubmitted;
@property(nonatomic) BOOL pingRadio;
@end

@implementation TXBLEServiceInspector
- (instancetype)init {
    if((self=[super init])){_services=[NSMutableArray new];_rows=[NSMutableDictionary new];_samples=[NSMutableArray new];_midiSamples=[NSMutableArray new];_events=[NSMutableArray new];_deviceInfo=[NSMutableDictionary new];_startTime=NSProcessInfo.processInfo.systemUptime;_result=@"pending";}return self;
}
- (void)record:(NSString*)event error:(NSError*)error {
    NSMutableDictionary *entry=[@{@"event":event,@"ms":@((NSProcessInfo.processInfo.systemUptime-self.startTime)*1000)} mutableCopy];
    if(error){entry[@"domain"]=error.domain;entry[@"code"]=@(error.code);entry[@"description"]=error.localizedDescription;}
    if(self.events.count<80)[self.events addObject:entry];
    fprintf(stderr,"TX-6 BLE %.0f ms: %s\n",[entry[@"ms"] doubleValue],event.UTF8String);
}
- (void)submitPingIfReady {
    if(!self.pingRequested||self.pingAttempted||!self.privateSubscribed||!self.midiSubscribed||self.done)return;
    self.pingAttempted=YES;
    if(self.peripheral.state!=CBPeripheralStateConnected||!self.observedCharacteristic.isNotifying||!self.midiCharacteristic.isNotifying||!(self.observedCharacteristic.properties&CBCharacteristicPropertyWriteWithoutResponse)||!self.peripheral.canSendWriteWithoutResponse){[self record:@"ping-not-submitted" error:nil];[self finish:@"ping-write-unavailable"];return;}
    // One fixed candidate ping; never send configuration or update commands.
    const UInt8 frame[]={0x02,0x61,0x08,0x01,0x04,0x54,0x58,0x36,0x4d,0x67,0x00};
    const UInt8 radio[]={0x02,0x63,0x08,0x01,0x04,0x54,0x58,0x36,0x4d,0x1f,0x00};
    if([self.peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse]<sizeof(frame)){[self finish:@"ping-exceeds-mtu"];return;}
    [self.peripheral writeValue:[NSData dataWithBytes:self.pingRadio?radio:frame length:sizeof(frame)] forCharacteristic:self.observedCharacteristic type:CBCharacteristicWriteWithoutResponse];self.pingSubmitted=YES;
    [self record:@"candidate-ping-submitted" error:nil];
}
- (void)finish:(NSString*)result {if(self.done)return;self.result=result;self.done=YES;}
- (void)inspect:(CBPeripheral*)peripheral {
    if(self.done||self.peripheral)return;
    self.peripheral=peripheral;peripheral.delegate=self;
    [self.central stopScan];self.ownsConnection=YES;
    [self record:@"connect-requested" error:nil];
    [self.central connectPeripheral:peripheral options:nil];
}
- (void)centralManagerDidUpdateState:(CBCentralManager*)central {
    if(self.done)return;
    if(CBManager.authorization==CBManagerAuthorizationNotDetermined)return;
    if(CBManager.authorization!=CBManagerAuthorizationAllowedAlways){[self finish:@"authorization-unavailable"];return;}
    if(central.state==CBManagerStateUnknown||central.state==CBManagerStateResetting)return;
    if(central.state!=CBManagerStatePoweredOn){[self finish:@"bluetooth-unavailable"];return;}
    if(self.started)return;self.started=YES;
    CBUUID *midi=[CBUUID UUIDWithString:@"03B80E5A-EDE8-4B33-A751-6CE34EC4C700"];
    for(CBPeripheral *p in [central retrieveConnectedPeripheralsWithServices:@[midi]])if(TXBLEInspectorName(p.name)){[self inspect:p];return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"TX6Mac.BLEPeripheral"];
    NSUUID *identifier=saved.length?[[NSUUID alloc] initWithUUIDString:saved]:nil;
    if(identifier)for(CBPeripheral *p in [central retrievePeripheralsWithIdentifiers:@[identifier]])if(TXBLEInspectorName(p.name)){[self inspect:p];return;}
    [central scanForPeripheralsWithServices:nil options:nil];
}
- (void)centralManager:(CBCentralManager*)central didDiscoverPeripheral:(CBPeripheral*)peripheral advertisementData:(NSDictionary<NSString*,id>*)advertisementData RSSI:(NSNumber*)RSSI {
    NSString *name=advertisementData[CBAdvertisementDataLocalNameKey];
    if(TXBLEInspectorName(peripheral.name)||([name isKindOfClass:NSString.class]&&TXBLEInspectorName(name)))[self inspect:peripheral];
}
- (void)centralManager:(CBCentralManager*)central didConnectPeripheral:(CBPeripheral*)peripheral {
    if(!self.done&&peripheral==self.peripheral){[self record:@"connected" error:nil];[peripheral discoverServices:nil];}
}
- (void)centralManager:(CBCentralManager*)central didFailToConnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
    if(peripheral==self.peripheral){[self record:@"connect-failed" error:error];[self finish:error.localizedDescription?:@"connection-failed"];}
}
- (void)centralManager:(CBCentralManager*)central didDisconnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
    if(peripheral==self.peripheral){[self record:@"disconnected" error:error];[self finish:error.localizedDescription?:@"disconnected"];}
}
- (void)peripheral:(CBPeripheral*)peripheral didDiscoverServices:(NSError*)error {
    if(self.done||peripheral!=self.peripheral)return;
    if(error){[self finish:error.localizedDescription];return;}
    self.pending=peripheral.services.count;
    if(!self.pending){[self finish:@"complete"];return;}
    for(CBService *service in peripheral.services){
        NSMutableDictionary *row=[@{@"uuid":service.UUID.UUIDString,@"primary":@(service.isPrimary),@"characteristics":[NSMutableArray new]} mutableCopy];
        [self.services addObject:row];self.rows[[NSValue valueWithNonretainedObject:service]]=row;
        [peripheral discoverCharacteristics:nil forService:service];
    }
}
- (void)peripheral:(CBPeripheral*)peripheral didDiscoverCharacteristicsForService:(CBService*)service error:(NSError*)error {
    if(self.done||peripheral!=self.peripheral)return;
    NSValue *key=[NSValue valueWithNonretainedObject:service];NSMutableDictionary *row=self.rows[key];
    if(!row)return;[self.rows removeObjectForKey:key];
    if(error)row[@"error"]=error.localizedDescription;
    else for(CBCharacteristic *characteristic in service.characteristics){
        NSMutableArray *names=[NSMutableArray new];CBCharacteristicProperties properties=characteristic.properties;
        const CBCharacteristicProperties flags[]={CBCharacteristicPropertyBroadcast,CBCharacteristicPropertyRead,CBCharacteristicPropertyWriteWithoutResponse,CBCharacteristicPropertyWrite,CBCharacteristicPropertyNotify,CBCharacteristicPropertyIndicate,CBCharacteristicPropertyAuthenticatedSignedWrites,CBCharacteristicPropertyExtendedProperties,CBCharacteristicPropertyNotifyEncryptionRequired,CBCharacteristicPropertyIndicateEncryptionRequired};
        NSArray *labels=@[@"broadcast",@"read",@"writeWithoutResponse",@"write",@"notify",@"indicate",@"authenticatedSignedWrites",@"extendedProperties",@"notifyEncryptionRequired",@"indicateEncryptionRequired"];
        for(NSUInteger i=0;i<sizeof(flags)/sizeof(flags[0]);i++)if(properties&flags[i])[names addObject:labels[i]];
        [row[@"characteristics"] addObject:@{@"uuid":characteristic.UUID.UUIDString,@"properties":@(properties),@"propertyNames":names}];
        if(self.observe&&[service.UUID isEqual:[CBUUID UUIDWithString:@"180A"]]&&([characteristic.UUID isEqual:[CBUUID UUIDWithString:@"2A24"]]||[characteristic.UUID isEqual:[CBUUID UUIDWithString:@"2A26"]]||[characteristic.UUID isEqual:[CBUUID UUIDWithString:@"2A29"]])&&(properties&CBCharacteristicPropertyRead))[peripheral readValueForCharacteristic:characteristic];
        if(self.observe&&[service.UUID isEqual:[CBUUID UUIDWithString:@"10A6E10A-6E00-4DE3-ABBA-DABBAD000000"]]&&[characteristic.UUID isEqual:[CBUUID UUIDWithString:@"C1832AEB-6409-4B97-9575-208525A8213B"]]&&(properties&CBCharacteristicPropertyNotify)){
            self.observedCharacteristic=characteristic;[peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
        if(self.observe&&[service.UUID isEqual:[CBUUID UUIDWithString:@"03B80E5A-EDE8-4B33-A751-6CE34EC4C700"]]&&[characteristic.UUID isEqual:[CBUUID UUIDWithString:@"7772E5DB-3868-4112-A1A9-F2669D106BF3"]]&&(properties&CBCharacteristicPropertyNotify)){
            self.midiCharacteristic=characteristic;[peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
    }
    if(self.pending)self.pending--;if(!self.pending&&(!self.observe||!self.observedCharacteristic))[self finish:self.observe?@"notification-characteristic-not-found":@"complete"];
}
- (void)peripheral:(CBPeripheral*)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if(self.done||peripheral!=self.peripheral)return;
    if(characteristic==self.midiCharacteristic){self.midiSubscribed=characteristic.isNotifying&&!error;[self record:self.midiSubscribed?@"midi-subscribed":@"midi-subscription-failed" error:error];[self submitPingIfReady];return;}
    if(characteristic!=self.observedCharacteristic)return;
    if(error||!characteristic.isNotifying)[self finish:error.localizedDescription?:@"notification-unavailable"];
    else {
        self.privateSubscribed=YES;[self record:@"private-subscribed" error:nil];
        [self submitPingIfReady];
        if(self.observeUntil)return;self.observeUntil=NSProcessInfo.processInfo.systemUptime+40;
    }
}
- (void)peripheral:(CBPeripheral*)peripheral didUpdateValueForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if(self.done||peripheral!=self.peripheral||error)return;
    if([characteristic.service.UUID isEqual:[CBUUID UUIDWithString:@"180A"]]){NSString *value=[[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];if(value)self.deviceInfo[characteristic.UUID.UUIDString]=value;return;}
    BOOL midi=characteristic==self.midiCharacteristic;if(!midi&&characteristic!=self.observedCharacteristic)return;
    NSData *data=characteristic.value;if(!data)return;
    if(midi){self.midiPackets++;self.midiBytes+=data.length;}else{self.packetCount++;self.byteCount+=data.length;}
    NSMutableArray *samples=midi?self.midiSamples:self.samples;
    if(samples.count<8){NSMutableString *hex=[NSMutableString new];const UInt8 *bytes=data.bytes;for(NSUInteger i=0;i<MIN(data.length,96);i++)[hex appendFormat:@"%02X",bytes[i]];
        [samples addObject:@{@"ms":@((NSProcessInfo.processInfo.systemUptime-self.startTime)*1000),@"length":@(data.length),@"hex":hex}];}
}
@end

void TXPrintBLEServices(BOOL requestAccess,BOOL observe,NSUInteger pingTarget) {
    @autoreleasepool {
        CBManagerAuthorization authorization=CBManager.authorization;
        NSMutableDictionary *output=[@{@"authorization":@(authorization),@"services":@[]} mutableCopy];
        if(authorization!=CBManagerAuthorizationAllowedAlways&&!(requestAccess&&authorization==CBManagerAuthorizationNotDetermined))output[@"result"]=@"authorization-not-granted";
        else {
            TXBLEServiceInspector *inspector=[TXBLEServiceInspector new];
            inspector.observe=observe;inspector.pingRequested=pingTarget==1||pingTarget==3;inspector.pingRadio=pingTarget==3;
            inspector.central=[[CBCentralManager alloc] initWithDelegate:inspector queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey:@NO}];
            NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+(requestAccess?120:(observe?70:20));
            while(!inspector.done&&NSProcessInfo.processInfo.systemUptime<deadline){[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                if(inspector.observeUntil&&NSProcessInfo.processInfo.systemUptime>=inspector.observeUntil)[inspector finish:@"observed"];}
            if(!inspector.done)[inspector finish:@"timeout"];
            output[@"result"]=inspector.result;output[@"centralState"]=@(inspector.central.state);output[@"services"]=inspector.services;
            output[@"authorization"]=@(CBManager.authorization);
            output[@"events"]=inspector.events;
            output[@"pingAttempted"]=@(inspector.pingAttempted);output[@"pingSubmitted"]=@(inspector.pingSubmitted);
            output[@"pingTarget"]=@(pingTarget);
            if(observe){output[@"packets"]=@(inspector.packetCount);output[@"bytes"]=@(inspector.byteCount);output[@"samples"]=inspector.samples;output[@"deviceInfo"]=inspector.deviceInfo;output[@"subscribed"]=@(inspector.privateSubscribed);output[@"midiSubscribed"]=@(inspector.midiSubscribed);output[@"midiPackets"]=@(inspector.midiPackets);output[@"midiBytes"]=@(inspector.midiBytes);output[@"midiSamples"]=inspector.midiSamples;}
            if(inspector.peripheral){output[@"peripheralUUID"]=inspector.peripheral.identifier.UUIDString;output[@"name"]=inspector.peripheral.name?:@"";}
            [inspector.central stopScan];inspector.peripheral.delegate=nil;
            if(inspector.ownsConnection)[inspector.central cancelPeripheralConnection:inspector.peripheral];
            inspector.central.delegate=nil;
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted error:nil];
        if(json)fwrite(json.bytes,1,json.length,stdout);puts("");
    }
}

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

// Drivers publish Offline on devices; endpoints inherit it. Unknown state is not online.
static BOOL TXMIDIOnline(MIDIEndpointRef endpoint,MIDIObjectRef owner,OSStatus (^read)(MIDIObjectRef,SInt32*)) {
    SInt32 endpointOffline=0,ownerOffline=0;
    OSStatus endpointStatus=read(endpoint,&endpointOffline),ownerStatus=owner?read(owner,&ownerOffline):kMIDIUnknownProperty;
    if((endpointStatus==noErr&&endpointOffline)||(ownerStatus==noErr&&ownerOffline))return NO;
    return endpointStatus==noErr||ownerStatus==noErr;
}
// Preserve BLE until a USB source has actually connected, rather than merely appeared.
static void TXMIDIReconcile(NSArray *candidates,NSString *transport,NSMutableDictionary *connected,
                           OSStatus (^connect)(NSNumber*),void (^disconnect)(NSNumber*)) {
    NSMutableDictionary *eligible=[NSMutableDictionary dictionary];
    for(NSDictionary *candidate in candidates){BOOL ble=[candidate[@"ble"] boolValue];
        if(([transport isEqual:@"usb"]&&ble)||([transport isEqual:@"ble"]&&!ble))continue;
        eligible[candidate[@"endpoint"]]=candidate;
    }
    for(NSNumber *source in connected.allKeys)if(!eligible[source]){disconnect(source);[connected removeObjectForKey:source];}
    for(NSNumber *source in eligible)if(![eligible[source][@"ble"] boolValue]){
        if(connected[source]||connect(source)==noErr)connected[source]=eligible[source];
    }
    BOOL usb=NO;for(NSDictionary *candidate in connected.allValues)if(![candidate[@"ble"] boolValue])usb=YES;
    for(NSNumber *source in eligible)if([eligible[source][@"ble"] boolValue]){
        if([transport isEqual:@"auto"]&&usb){if(connected[source]){disconnect(source);[connected removeObjectForKey:source];}}
        else if(connected[source]||connect(source)==noErr)connected[source]=eligible[source];
    }
}

static BOOL TXBLEMatchesDiscovery(NSString *cachedName,NSString *advertisedName) {
    return TXIsMixerName(cachedName)||TXIsMixerName(advertisedName);
}
static BOOL TXBLECanReplacePending(CBPeripheralState state,BOOL activating,BOOL direct,NSUUID *current,NSUUID *discovered) {
    return state==CBPeripheralStateConnecting&&!activating&&!direct&&current&&discovered&&![current isEqual:discovered];
}

// Reset running status per packet and retain only SysEx continuation state.
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
            while(i+1<n&&(bytes[i]&0x80)&&bytes[i+1]>=0xF8)i+=2;
            if(i>=n||(bytes[i]&0x80))return;values[j]=bytes[i++];
        }
        if((status&0xF0)==0xB0&&receive)receive(status&0x0F,values[0],values[1]);
    }
}

@interface TXBLEReconnect:NSObject<CBCentralManagerDelegate,CBPeripheralDelegate>
@property(nonatomic,strong) CBCentralManager *central;
@property(nonatomic,strong) CBPeripheral *peripheral;
@property(nonatomic,strong) CBCharacteristic *midiCharacteristic;
@property(nonatomic) NSUInteger packets,controlMessages,discoveries,matchingDiscoveries,scanStarts,connectionAttempts,connectionTimeouts,freshReplacements;
@property(nonatomic,copy) NSDictionary *lastDiscovery;
@property(nonatomic) CBManagerAuthorization authorization;
@property(nonatomic) OSStatus lastActivateStatus;
@property(nonatomic,copy) void (^received)(UInt8,UInt8,UInt8);
@property(nonatomic) BOOL available,allowDiscovery,enabled,activating,scanned,direct,inSysEx;
@property(nonatomic) NSTimeInterval retryAt,scanUntil,nextScanAt,handoffUntil,connectUntil,lastActivate;
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
    if(!self.central&&enabled&&(available||allow||saved.length))self.central=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey:@NO}];
    [self tick];
}
- (void)maintainRecoveryScan {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"TX6Mac.BLEPeripheral"];
    if(!self.enabled||self.available||self.direct||(!self.allowDiscovery&&!saved.length)){[self.central stopScan];return;}
    if(self.central.isScanning){
        if(now>=self.scanUntil){[self.central stopScan];self.nextScanAt=now+2;}
        return;
    }
    if(now<self.nextScanAt)return;
    self.scanUntil=now+8;self.scanStarts++;
    [self.central scanForPeripheralsWithServices:@[self.serviceUUID] options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@YES}];
}
- (void)tick {
    if(!self.central)return;
    if(!self.enabled){self.direct=NO;self.midiCharacteristic=nil;[self.central stopScan];if(self.peripheral)[self.central cancelPeripheralConnection:self.peripheral];self.peripheral=nil;self.activating=NO;return;}
    if(self.central.state!=CBManagerStatePoweredOn)return;
    if(self.direct){
        if(self.available){self.direct=NO;self.activating=NO;CBPeripheral *p=self.peripheral;self.peripheral=nil;self.midiCharacteristic=nil;[self.central cancelPeripheralConnection:p];if(self.changed)self.changed();}
        else {
            NSTimeInterval now=NSDate.date.timeIntervalSince1970;
            if(self.activating&&now>=self.handoffUntil)self.activating=NO;
            if(self.activating&&now-self.lastActivate>=2){self.lastActivate=now;self.lastActivateStatus=MIDIBluetoothDriverActivateAllConnections();}
            return;
        }
    }
    for(CBPeripheral *p in [self.central retrieveConnectedPeripheralsWithServices:@[self.serviceUUID]])if(TXIsMixerName(p.name)){
        [[NSUserDefaults standardUserDefaults] setObject:p.identifier.UUIDString forKey:@"TX6Mac.BLEPeripheral"];
        if(self.available){[self.central stopScan];if(self.peripheral==p){[self.central cancelPeripheralConnection:p];self.peripheral=nil;self.activating=NO;}return;}
    }
    if(self.available){[self.central stopScan];return;}
    [self maintainRecoveryScan];
    if(self.peripheral){
        if(!self.activating&&NSDate.date.timeIntervalSince1970>self.connectUntil){self.connectionTimeouts++;self.lastFailure=[NSString stringWithFormat:@"timeout:%@",self.stage?:@"connecting"];[self abandon:self.peripheral];return;}
        if(self.activating){
            if(NSDate.date.timeIntervalSince1970>=self.handoffUntil){self.activating=NO;[self abandon:self.peripheral];return;}
            if(NSDate.date.timeIntervalSince1970-self.lastActivate>=2){self.lastActivate=NSDate.date.timeIntervalSince1970;self.lastActivateStatus=MIDIBluetoothDriverActivateAllConnections();}
            BOOL registered=NO;
            for(ItemCount i=0;i<MIDIGetNumberOfDevices();i++){MIDIDeviceRef d=MIDIGetDevice(i);SInt32 offline=1;MIDIObjectGetIntegerProperty(d,kMIDIPropertyOffline,&offline);if(!offline&&TXIsMixerName(MIDIString(d,kMIDIPropertyName))&&[MIDIString(d,kMIDIPropertyDriverOwner).lowercaseString containsString:@"bluetooth"]){registered=YES;break;}}
            if(registered){CBPeripheral *p=self.peripheral;self.peripheral=nil;self.activating=NO;[self.central cancelPeripheralConnection:p];if(self.changed)self.changed();}
        }return;
    }
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(now<self.retryAt)return;
    NSString *saved=[[NSUserDefaults standardUserDefaults] stringForKey:@"TX6Mac.BLEPeripheral"];
    NSUUID *identifier=saved.length?[[NSUUID alloc] initWithUUIDString:saved]:nil;
    CBPeripheral *known=identifier?[self.central retrievePeripheralsWithIdentifiers:@[identifier]].firstObject:nil;
    if(known){[self connect:known];return;}
    self.stage=self.central.isScanning?@"scanning":@"scan-wait";
}
- (void)connect:(CBPeripheral*)p {
    self.direct=NO;self.inSysEx=NO;self.midiCharacteristic=nil;self.stage=@"connecting";self.peripheral=p;p.delegate=self;self.connectUntil=NSDate.date.timeIntervalSince1970+15;self.retryAt=NSDate.date.timeIntervalSince1970+5;
    self.connectionAttempts++;[self.central connectPeripheral:p options:@{CBConnectPeripheralOptionEnableAutoReconnect:@YES}];
}
- (void)centralManagerDidUpdateState:(CBCentralManager*)central{self.authorization=CBManager.authorization;[self tick];}
- (void)centralManager:(CBCentralManager*)central didDiscoverPeripheral:(CBPeripheral*)p advertisementData:(NSDictionary<NSString*,id>*)data RSSI:(NSNumber*)RSSI {
    self.discoveries++;
    NSString *advertised=[data[CBAdvertisementDataLocalNameKey] isKindOfClass:NSString.class]?data[CBAdvertisementDataLocalNameKey]:@"";
    if(!TXBLEMatchesDiscovery(p.name,advertised))return;
    self.matchingDiscoveries++;
    NSMutableArray *services=[NSMutableArray array];
    for(id uuid in data[CBAdvertisementDataServiceUUIDsKey])if([uuid isKindOfClass:CBUUID.class])[services addObject:[uuid UUIDString]];
    self.lastDiscovery=@{@"cachedName":p.name?:@"",@"advertisedName":advertised,@"uuid":p.identifier.UUIDString,@"advertisedServices":services,@"rssi":RSSI?:@0,@"connectable":data[CBAdvertisementDataIsConnectable]?:@NO,@"time":@(NSDate.date.timeIntervalSince1970)};
    if(!self.enabled||self.available||self.direct)return;
    if(TXBLECanReplacePending(self.peripheral.state,self.activating,self.direct,self.peripheral.identifier,p.identifier)){
        CBPeripheral *previous=self.peripheral;self.peripheral=nil;self.freshReplacements++;[self.central cancelPeripheralConnection:previous];[self connect:p];return;
    }
    if(!self.peripheral&&NSDate.date.timeIntervalSince1970>=self.retryAt)[self connect:p];
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
        self.lastActivate=NSDate.date.timeIntervalSince1970;self.handoffUntil=self.lastActivate+12;self.activating=YES;
        self.lastActivateStatus=MIDIBluetoothDriverActivateAllConnections();
        self.stage=[NSString stringWithFormat:@"activate:%d",(int)self.lastActivateStatus];
        [[NSUserDefaults standardUserDefaults] setObject:p.identifier.UUIDString forKey:@"TX6Mac.BLEPeripheral"];
        if(characteristic.properties&CBCharacteristicPropertyNotify){self.stage=@"subscribing-midi";[p setNotifyValue:YES forCharacteristic:characteristic];}
        [self tick];return;
    }
    [self abandon:p];
}
- (void)peripheral:(CBPeripheral*)p didUpdateNotificationStateForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if(p!=self.peripheral||characteristic!=self.midiCharacteristic)return;
    if(error||!characteristic.isNotifying){
        BOOL wasDirect=self.direct;self.direct=NO;self.inSysEx=NO;if(wasDirect&&self.changed)self.changed();
        self.lastFailure=error.description?:@"notify-unavailable";
        if(self.activating&&NSDate.date.timeIntervalSince1970<self.handoffUntil){self.stage=@"waiting-core-midi";return;}
        [self abandon:p];return;
    }
    self.direct=YES;self.inSysEx=NO;self.lastFailure=@"";self.stage=@"direct-midi";[self.central stopScan];if(self.changed)self.changed();
}
- (void)peripheral:(CBPeripheral*)p didUpdateValueForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if(p!=self.peripheral||!self.direct||characteristic!=self.midiCharacteristic||error)return;
    self.packets++;BOOL sysex=self.inSysEx;
    TXDecodeBLECC(characteristic.value,&sysex,^(UInt8 channel,UInt8 cc,UInt8 value){self.controlMessages++;if(self.received)self.received(channel,cc,value);});self.inSysEx=sysex;
}
- (void)abandon:(CBPeripheral*)p {
    if(p==self.peripheral){BOOL wasDirect=self.direct;self.direct=NO;self.midiCharacteristic=nil;if(wasDirect&&self.changed)self.changed();self.lastFailure=self.lastFailure.length?self.lastFailure:[NSString stringWithFormat:@"timeout-or-invalid-service:%@",self.stage?:@"unknown"];self.stage=@"retry-wait";self.scanned=NO;self.peripheral=nil;self.activating=NO;self.retryAt=NSDate.date.timeIntervalSince1970+10;}[self.central cancelPeripheralConnection:p];
}
- (void)centralManager:(CBCentralManager*)central didFailToConnectPeripheral:(CBPeripheral*)p error:(NSError*)error{if(p==self.peripheral)self.lastFailure=error.description?:@"connect-failed";[self abandon:p];}
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
- (OSStatus)createMIDIClient:(MIDIClientRef*)client notify:(MIDINotifyBlock)notify;
- (OSStatus)createMIDIInput:(MIDIClientRef)client port:(MIDIPortRef*)port read:(MIDIReadBlock)read;
- (void)disposeMIDIInput:(MIDIPortRef)port;
- (void)disposeMIDIClient:(MIDIClientRef)client;
- (void)midiSessionReady;
- (void)attemptStartup;
- (void)cancelStartupRetry;
- (void)retryStartupForGeneration:(NSUInteger)generation;
+ (BOOL)selfCheck;
@end

static NSTimeInterval TXMIDIRetryDelay(NSUInteger attempt) {
    return MIN(30.0,(double)(1u<<MIN(attempt?attempt-1:0,(NSUInteger)5)));
}

// Exercise startup failures without contacting CoreMIDI or Bluetooth.
@interface TXMIDIStartupFixture : TXMIDI
@property(nonatomic) NSUInteger clientCalls,portCalls,readyCalls,refreshCalls,portDisposals,clientDisposals,badDisposals;
@property(nonatomic,copy) MIDINotifyBlock notify;
@property(nonatomic,copy) MIDIReadBlock read;
@end

@implementation TXMIDI {
    MIDIClientRef _client;
    MIDIPortRef _port;
    NSMutableDictionary<NSNumber*,NSDictionary*> *_connected;
    NSMutableDictionary<NSNumber*,NSMutableData*> *_pending;
    NSMutableDictionary<NSNumber*,NSNumber*> *_runningStatus;
    NSArray<NSString*> *_sources;
    TXBLEReconnect *_ble;
    BOOL _running;
    NSUInteger _generation,_startupAttempts,_clientAttempts;
    OSStatus _lastStartupStatus;
    NSTimeInterval _nextStartupRetry;
    dispatch_source_t _startupRetry;
}
- (instancetype)init {
    if((self=[super init])){_connected=[NSMutableDictionary dictionary];_pending=[NSMutableDictionary dictionary];_runningStatus=[NSMutableDictionary dictionary];_sources=@[];_transport=@"auto";}return self;
}
- (NSArray<NSString*>*)sources{return _sources;}
- (OSStatus)createMIDIClient:(MIDIClientRef*)client notify:(MIDINotifyBlock)notify {return MIDIClientCreateWithBlock(CFSTR("TX6Mac"),client,notify);}
- (OSStatus)createMIDIInput:(MIDIClientRef)client port:(MIDIPortRef*)port read:(MIDIReadBlock)read {return MIDIInputPortCreateWithBlock(client,CFSTR("TX6Mac Controls"),port,read);}
- (void)disposeMIDIInput:(MIDIPortRef)port {MIDIPortDispose(port);}
- (void)disposeMIDIClient:(MIDIClientRef)client {MIDIClientDispose(client);}
- (NSDictionary*)diagnostics{return @{@"running":@(_running),@"clientReady":@(_client!=0),@"portReady":@(_port!=0),@"startupAttempts":@(_startupAttempts),@"clientAttempts":@(_clientAttempts),@"lastStartupStatus":@(_lastStartupStatus),@"nextStartupRetryUptime":@(_nextStartupRetry),@"direct":@(_ble.direct),@"packets":@(_ble.packets),@"controlMessages":@(_ble.controlMessages),@"activating":@(_ble.activating),@"lastActivateStatus":@(_ble.lastActivateStatus),@"authorization":@(_ble.authorization),@"centralState":@(_ble.central?_ble.central.state:-1),@"enabled":@(_ble.enabled),@"available":@(_ble.available),@"scanning":@(_ble.central.isScanning),@"peripheralState":@(_ble.peripheral?_ble.peripheral.state:-1),@"stage":_ble.stage?:@"idle",@"failure":_ble.lastFailure?:@"",@"knownPeripheral":@([[NSUserDefaults standardUserDefaults] stringForKey:@"TX6Mac.BLEPeripheral"].length>0),@"scanStarts":@(_ble.scanStarts),@"discoveries":@(_ble.discoveries),@"matchingDiscoveries":@(_ble.matchingDiscoveries),@"connectionAttempts":@(_ble.connectionAttempts),@"connectionTimeouts":@(_ble.connectionTimeouts),@"freshReplacements":@(_ble.freshReplacements),@"lastDiscovery":_ble.lastDiscovery?:@{},@"pendingUUID":_ble.peripheral.identifier.UUIDString?:@"",@"scanFilter":@"midi-service"};}
- (void)start {
    if(_running)return;
    _running=YES;_generation++;_startupAttempts=0;_clientAttempts=0;
    [self attemptStartup];
}
- (void)cancelStartupRetry {
    if(_startupRetry)dispatch_source_cancel(_startupRetry);
    _startupRetry=nil;_nextStartupRetry=0;
}
- (void)scheduleStartupRetry:(OSStatus)status {
    _lastStartupStatus=status;
    [self cancelStartupRetry];
    if(!_running)return;
    NSTimeInterval delay=TXMIDIRetryDelay(_startupAttempts);
    _nextStartupRetry=NSProcessInfo.processInfo.systemUptime+delay;
    NSUInteger generation=_generation;__weak TXMIDI *weakSelf=self;
    _startupRetry=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(_startupRetry,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,NSEC_PER_MSEC*100);
    dispatch_source_set_event_handler(_startupRetry,^{[weakSelf retryStartupForGeneration:generation];});
    dispatch_resume(_startupRetry);
    NSLog(@"MIDI startup error %d; retry in %.0fs",(int)status,delay);
}
- (void)retryStartupForGeneration:(NSUInteger)generation {
    if(!_running||generation!=_generation)return;
    [self cancelStartupRetry];[self attemptStartup];
}
- (void)attemptStartup {
    if(!_running||_port)return;
    _startupAttempts++;NSUInteger generation=++_generation;
    __weak TXMIDI *weakSelf=self;
    if(!_client){
        MIDIClientRef client=0;_clientAttempts++;
        OSStatus status=[self createMIDIClient:&client notify:^(const MIDINotification *message){
            // The client survives stop/start; deliver topology notices only to a live session.
            dispatch_async(dispatch_get_main_queue(),^{TXMIDI *m=weakSelf;if(m&&m->_running&&m->_port)[m refresh];});
        }];
        if(status!=noErr){[self scheduleStartupRetry:status];return;}
        _client=client;
    }
    MIDIPortRef port=0;
    OSStatus status=[self createMIDIInput:_client port:&port read:^(const MIDIPacketList *list,void *context){
        MIDIEndpointRef source=(MIDIEndpointRef)(uintptr_t)context;
        size_t size=offsetof(MIDIPacketList,packet);const MIDIPacket *p=list->packet;
        for(UInt32 i=0;i<list->numPackets;i++){size=(const char*)MIDIPacketNext(p)-(const char*)list;p=MIDIPacketNext(p);}
        if(size>1024*1024)return;
        NSData *copy=[NSData dataWithBytes:list length:size];
        dispatch_async(dispatch_get_main_queue(),^{TXMIDI *m=weakSelf;if(m&&m->_running&&m->_generation==generation&&m->_port)[m receivePackets:copy.bytes source:source];});
    }];
    // Failed output parameters are undefined; adopt handles only after success.
    if(status!=noErr){[self scheduleStartupRetry:status];return;}
    _port=port;_lastStartupStatus=noErr;[self cancelStartupRetry];
    [self midiSessionReady];
}
- (void)midiSessionReady {
    __weak TXMIDI *weakSelf=self;NSUInteger generation=_generation;
    _ble=[TXBLEReconnect new];_ble.changed=^{dispatch_async(dispatch_get_main_queue(),^{TXMIDI *m=weakSelf;if(m&&m->_running&&m->_generation==generation&&m->_port)[m refresh];});};
    _ble.received=^(UInt8 channel,UInt8 cc,UInt8 value){TXMIDI *m=weakSelf;if(m&&m->_running&&m->_generation==generation&&m->_port&&m->_connected.count==0&&![m.transport isEqual:@"usb"]&&m.received)m.received(@"TX-6 Bluetooth",channel,cc,value);};[self refresh];
}
- (void)setTransport:(NSString*)transport {
    if(![@[@"auto",@"usb",@"ble"] containsObject:transport])transport=@"auto";
    if([_transport isEqualToString:transport])return;_transport=[transport copy];[self refresh];
}
- (void)refresh {
    if(!_running||!_port)return;
    NSSet *previousEndpoints=[NSSet setWithArray:_connected.allKeys];
    NSMutableArray<NSDictionary*> *candidates=[NSMutableArray array];
    for(ItemCount i=0;i<MIDIGetNumberOfSources();i++){
        MIDIEndpointRef endpoint=MIDIGetSource(i);MIDIObjectRef owner=OwnerDevice(endpoint);
        NSString *name=MIDIString(endpoint,kMIDIPropertyDisplayName);
        NSString *model=MIDIString(owner,kMIDIPropertyModel),*manufacturer=MIDIString(owner,kMIDIPropertyManufacturer);
        NSString *driver=MIDIString(owner,kMIDIPropertyDriverOwner);
        NSString *descriptor=[[NSString stringWithFormat:@"%@ %@ %@ %@",name,model,manufacturer,driver] lowercaseString];
        if([descriptor rangeOfString:@"tx-6"].location==NSNotFound&&[descriptor rangeOfString:@"tx–6"].location==NSNotFound&&[descriptor rangeOfString:@"tx6"].location==NSNotFound)continue;
        if(!TXMIDIOnline(endpoint,owner,^OSStatus(MIDIObjectRef object,SInt32 *offline){return MIDIObjectGetIntegerProperty(object,kMIDIPropertyOffline,offline);}))continue;
        BOOL ble=[descriptor containsString:@"bluetooth"]||[descriptor containsString:@"ble midi"];
        [candidates addObject:@{@"endpoint":@(endpoint),@"name":name.length?name:@"TX-6",@"ble":@(ble),@"driver":driver}];
    }
    TXMIDIReconcile(candidates,_transport,_connected,^OSStatus(NSNumber *source){
        OSStatus status=MIDIPortConnectSource(self->_port,source.unsignedIntValue,(void*)(uintptr_t)source.unsignedIntValue);
        if(status!=noErr)NSLog(@"MIDI connect error %d",(int)status);return status;
    },^(NSNumber *source){
        MIDIPortDisconnectSource(self->_port,source.unsignedIntValue);
        [self->_pending removeObjectForKey:source];[self->_runningStatus removeObjectForKey:source];
    });
    BOOL haveUSB=NO;for(NSDictionary *d in _connected.allValues)if(![d[@"ble"] boolValue])haveUSB=YES;
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
    _running=NO;_generation++;[self cancelStartupRetry];
    _ble.changed=nil;_ble.received=nil;[_ble stop];_ble=nil;
    MIDIPortRef port=_port;_port=0;if(port)[self disposeMIDIInput:port];
    // Apple discourages disposing the last client before another start in this process.
    [_connected removeAllObjects];[_pending removeAllObjects];[_runningStatus removeAllObjects];_sources=@[];
}
+ (BOOL)selfCheck {
    NSDictionary *usb=@{@"endpoint":@11,@"ble":@NO},*bleSource=@{@"endpoint":@12,@"ble":@YES};
    NSMutableDictionary *links=[@{@12:bleSource} mutableCopy];NSMutableArray *removed=[NSMutableArray array],*attempts=[NSMutableArray array];
    __block BOOL usbWorks=NO;
    OSStatus (^connect)(NSNumber*)=^OSStatus(NSNumber *source){[attempts addObject:source];return [source isEqual:@11]&&!usbWorks?-1:noErr;};
    void (^disconnect)(NSNumber*)=^(NSNumber *source){[removed addObject:source];};
    TXMIDIReconcile(@[usb,bleSource],@"auto",links,connect,disconnect);
    if(links[@11]||!links[@12]||removed.count||![attempts isEqual:@[@11]])return NO;
    usbWorks=YES;TXMIDIReconcile(@[usb,bleSource],@"auto",links,connect,disconnect);
    if(!links[@11]||links[@12]||![removed isEqual:@[@12]])return NO;
    TXMIDIReconcile(@[bleSource],@"auto",links,connect,disconnect);
    if(links[@11]||!links[@12]||![removed isEqual:@[@12,@11]])return NO;
    TXMIDIReconcile(@[usb,bleSource],@"ble",links,connect,disconnect);if(links[@11]||!links[@12])return NO;
    usbWorks=NO;TXMIDIReconcile(@[usb,bleSource],@"usb",links,connect,disconnect);if(links.count)return NO;
    TXMIDIReconcile(@[usb,bleSource],@"auto",links,connect,disconnect);if(links[@11]||!links[@12])return NO;
    for(int scenario=0;scenario<5;scenario++){
        BOOL online=TXMIDIOnline(11,21,^OSStatus(MIDIObjectRef object,SInt32 *offline){
            *offline=(scenario==1&&object==21)||(scenario==2&&object==11);
            return scenario==4||(scenario==3&&object==11)?kMIDIUnknownProperty:noErr;
        });
        if(online!=(scenario==0||scenario==3))return NO;
    }
    TXMIDIStartupFixture *cancelled=[TXMIDIStartupFixture new];TXMIDI *cancelledState=cancelled;
    [cancelled start];NSUInteger cancelledGeneration=cancelledState->_generation;
    [cancelled stop];[cancelled stop];[cancelled retryStartupForGeneration:cancelledGeneration];
    if(cancelled.clientCalls!=1||cancelled.portCalls||cancelled.badDisposals||cancelledState->_startupRetry||cancelledState->_client)return NO;
    TXMIDIStartupFixture *startup=[TXMIDIStartupFixture new];TXMIDI *state=startup;
    [startup start];[startup start];
    if(startup.clientCalls!=1||state->_client||!state->_startupRetry||startup.badDisposals)return NO;
    NSTimeInterval recoveryDeadline=NSProcessInfo.processInfo.systemUptime+5;
    while(!startup.readyCalls&&NSProcessInfo.processInfo.systemUptime<recoveryDeadline)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.005,true);
    if(startup.clientCalls!=2||startup.portCalls!=2||startup.readyCalls!=1||state->_client!=100||state->_port!=200||state->_startupRetry||startup.clientDisposals||startup.badDisposals)return NO;
    MIDIReadBlock oldRead=startup.read;dispatch_block_t oldBLE=state->_ble.changed;NSUInteger oldGeneration=state->_generation;
    [startup stop];
    [startup retryStartupForGeneration:oldGeneration];
    if(startup.clientCalls!=2||startup.portCalls!=2||startup.portDisposals!=1||startup.clientDisposals||state->_client!=100||state->_port||state->_startupRetry)return NO;
    [startup start];
    if(startup.clientCalls!=2||startup.portCalls!=3||startup.readyCalls!=2)return NO;
    state->_connected[@123]=@{@"name":@"fixture"};
    __block NSUInteger stalePackets=0;startup.received=^(NSString *name,UInt8 channel,UInt8 cc,UInt8 value){stalePackets++;};
    Byte staleStorage[128];MIDIPacketList *staleList=(MIDIPacketList*)staleStorage;Byte staleBytes[]={0xB0,1,127};
    MIDIPacketListAdd(staleList,sizeof(staleStorage),MIDIPacketListInit(staleList),0,sizeof(staleBytes),staleBytes);
    MIDINotification notification={.messageID=kMIDIMsgSetupChanged,.messageSize=sizeof(MIDINotification)};
    BOOL (^drain)(void)=^BOOL{
        __block BOOL drained=NO;dispatch_async(dispatch_get_main_queue(),^{drained=YES;});
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+1;
        while(!drained&&NSProcessInfo.processInfo.systemUptime<deadline)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.005,true);
        return drained;
    };
    oldRead(staleList,(void*)(uintptr_t)123);oldBLE();startup.notify(&notification);
    if(!drain()||stalePackets||startup.refreshCalls!=3||startup.badDisposals)return NO;
    [startup stop];startup.notify(&notification);oldBLE();
    if(!drain()||startup.refreshCalls!=3||state->_startupRetry||startup.badDisposals)return NO;
    if(TXMIDIRetryDelay(1)!=1||TXMIDIRetryDelay(2)!=2||TXMIDIRetryDelay(5)!=16||TXMIDIRetryDelay(6)!=30||TXMIDIRetryDelay(NSUIntegerMax)!=30)return NO;
    if(!TXIsMixerName(@"TX-6 Bluetooth")||!TXIsMixerName(@"TX–6")||TXIsMixerName(@"OB-4red")||TXIsMixerName(@"EP-133"))return NO;
    if(!TXBLEMatchesDiscovery(@"Cached name",@"TX-6")||!TXBLEMatchesDiscovery(@"TX-6",@"")||TXBLEMatchesDiscovery(@"OB-4red",@"EP-133"))return NO;
    NSUUID *current=NSUUID.UUID,*fresh=NSUUID.UUID;
    if(!TXBLECanReplacePending(CBPeripheralStateConnecting,NO,NO,current,fresh)||TXBLECanReplacePending(CBPeripheralStateConnected,NO,NO,current,fresh)||TXBLECanReplacePending(CBPeripheralStateConnecting,YES,NO,current,fresh)||TXBLECanReplacePending(CBPeripheralStateConnecting,NO,YES,current,fresh)||TXBLECanReplacePending(CBPeripheralStateConnecting,NO,NO,current,current))return NO;
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
- (void)dealloc{[self stop];if(_client)[self disposeMIDIClient:_client];}
@end

@implementation TXMIDIStartupFixture
- (OSStatus)createMIDIClient:(MIDIClientRef*)client notify:(MIDINotifyBlock)notify {
    self.clientCalls++;self.notify=notify;*client=self.clientCalls==1?999:100;return self.clientCalls==1?-304:noErr;
}
- (OSStatus)createMIDIInput:(MIDIClientRef)client port:(MIDIPortRef*)port read:(MIDIReadBlock)read {
    self.portCalls++;self.read=read;*port=self.portCalls==1?999:200;return self.portCalls==1?-304:noErr;
}
- (void)disposeMIDIInput:(MIDIPortRef)port {self.portDisposals++;if(port!=200)self.badDisposals++;}
- (void)disposeMIDIClient:(MIDIClientRef)client {self.clientDisposals++;if(client!=100)self.badDisposals++;}
- (void)midiSessionReady {self.readyCalls++;[super midiSessionReady];}
- (void)refresh {self.refreshCalls++;}
@end

BOOL TXRunMIDISelfCheck(void) { return [TXMIDI selfCheck]; }
