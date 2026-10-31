#import "Scenes.h"
#import <math.h>

NSString * const TXSceneErrorDomain=@"local.tx6mac.scenes";
static NSString * const TXSceneDefaultsKey=@"TX6Mac.scenes";
static NSString * const TXSceneSystemKey=@"local.tx6mac.system-sounds";

static BOOL TXSceneFail(NSError **error,TXSceneErrorCode code,NSString *message) {
    if(error)*error=[NSError errorWithDomain:TXSceneErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];return NO;
}
static BOOL TXSceneNumber(id value,double low,double high) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;
    double number=[value doubleValue];return isfinite(number)&&number>=low&&number<=high;
}
static BOOL TXSceneInteger(id value,NSInteger low,NSInteger high) {
    return TXSceneNumber(value,low,high)&&floor([value doubleValue])==[value doubleValue];
}
static BOOL TXSceneBoolean(id value) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static NSString *TXSceneName(id value,NSError **error) {
    NSMutableCharacterSet *controls=[NSCharacterSet.controlCharacterSet mutableCopy];
    [controls removeCharactersInRange:NSMakeRange(0x200C,2)];
    if(![value isKindOfClass:NSString.class]||[value rangeOfCharacterFromSet:controls].location!=NSNotFound){TXSceneFail(error,TXSceneErrorInvalidName,@"Scene names must contain no control characters.");return nil;}
    NSString *name=[[[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] precomposedStringWithCanonicalMapping] copy];
    __block NSUInteger count=0;
    [name enumerateSubstringsInRange:NSMakeRange(0,name.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *part,NSRange range,NSRange enclosing,BOOL *stop){count++;if(count>32)*stop=YES;}];
    if(count==0||count>32){TXSceneFail(error,TXSceneErrorInvalidName,@"Scene names must contain 1 to 32 characters.");return nil;}return name;
}
static NSString *TXSceneID(id value) {
    if(![value isKindOfClass:NSString.class])return nil;
    return [[[NSUUID alloc] initWithUUIDString:value] UUIDString];
}

@interface TXSceneStore ()
@property(nonatomic,strong) NSUserDefaults *defaults;
@property(nonatomic,readwrite,copy) NSArray<NSDictionary*> *scenes;
@property(nonatomic,readwrite) BOOL readOnly;
@end

@implementation TXSceneStore
- (instancetype)initWithDefaults:(NSUserDefaults*)defaults {
    if((self=[super init])){_defaults=defaults;_scenes=@[];[self reload:NULL];}return self;
}
+ (NSDictionary*)canonicalSnapshot:(id)value error:(NSError**)error {
    if(error)*error=nil;
    if(![value isKindOfClass:NSDictionary.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"Scene snapshot must be a dictionary.");return nil;}
    NSDictionary *source=value;
    if(!TXSceneInteger(source[@"version"],1,NSIntegerMax)){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid snapshot version.");return nil;}
    if([source[@"version"] integerValue]!=1){TXSceneFail(error,TXSceneErrorUnsupportedVersion,@"Unsupported snapshot version.");return nil;}
    id assignments=source[@"assignments"],channels=source[@"channels"],pending=source[@"pendingSources"];
    if(![assignments isKindOfClass:NSArray.class]||[assignments count]!=6||![channels isKindOfClass:NSArray.class]||[channels count]!=6||(pending&&(![pending isKindOfClass:NSArray.class]||[pending count]!=6))){TXSceneFail(error,TXSceneErrorInvalidData,@"Scenes require six assignments and channels.");return nil;}
    if(!TXSceneBoolean(source[@"followDefaultOutput"])||!TXSceneBoolean(source[@"chromeTabs"])||![source[@"outputUID"] isKindOfClass:NSString.class]||![source[@"monitorUID"] isKindOfClass:NSString.class]||(source[@"monitorName"]&&![source[@"monitorName"] isKindOfClass:NSString.class])||!TXSceneNumber(source[@"monitorGain"],0,1)){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene output settings.");return nil;}
    NSMutableArray *cleanAssignments=[NSMutableArray arrayWithCapacity:6],*cleanChannels=[NSMutableArray arrayWithCapacity:6],*cleanPending=[NSMutableArray arrayWithCapacity:6];
    NSMutableSet *apps=[NSMutableSet set];
    for(NSUInteger i=0;i<6;i++) {
        id assignment=assignments[i],channel=channels[i],intent=pending?pending[i]:@"";
        if(![assignment isKindOfClass:NSString.class]||![intent isKindOfClass:NSString.class]||![@[@"",@"tab",@"process"] containsObject:intent]||![channel isKindOfClass:NSDictionary.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene channel data.");return nil;}
        if(i==0){assignment=TXSceneSystemKey;intent=@"";}
        else if([assignment isEqualToString:TXSceneSystemKey]){TXSceneFail(error,TXSceneErrorInvalidData,@"System sounds must use channel one.");return nil;}
        else if([assignment hasPrefix:@"chrome-tab:"]){assignment=@"";intent=@"tab";}
        else if([assignment hasPrefix:@"pid:"]){assignment=@"";intent=@"process";}
        if(([intent isEqualToString:@"tab"]&&![source[@"chromeTabs"] boolValue])||([assignment length]&&[intent length])){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid pending source intent.");return nil;}
        if([assignment length]){if([apps containsObject:assignment]){TXSceneFail(error,TXSceneErrorInvalidData,@"An app cannot occupy multiple scene channels.");return nil;}[apps addObject:assignment];}
        id eq=channel[@"eq"];
        if(!TXSceneNumber(channel[@"gain"],0,1)||!TXSceneBoolean(channel[@"muted"])||!TXSceneInteger(channel[@"route"],0,3)||![eq isKindOfClass:NSArray.class]||[eq count]!=3){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid channel controls.");return nil;}
        NSMutableArray *cleanEQ=[NSMutableArray arrayWithCapacity:3];
        for(id band in eq){if(!TXSceneNumber(band,-18,18)){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid equalizer value.");return nil;}[cleanEQ addObject:@([band doubleValue])];}
        [cleanAssignments addObject:[assignment copy]];[cleanPending addObject:[intent copy]];
        [cleanChannels addObject:@{@"gain":@([channel[@"gain"] doubleValue]),@"eq":[cleanEQ copy],@"muted":@([channel[@"muted"] boolValue]),@"route":@([channel[@"route"] integerValue])}];
    }
    NSMutableDictionary *result=[@{@"version":@1,@"assignments":[cleanAssignments copy],@"channels":[cleanChannels copy],@"pendingSources":[cleanPending copy],@"followDefaultOutput":@([source[@"followDefaultOutput"] boolValue]),@"outputUID":[source[@"followDefaultOutput"] boolValue]?@"":[source[@"outputUID"] copy],@"monitorUID":[source[@"monitorUID"] copy],@"monitorGain":@([source[@"monitorGain"] doubleValue]),@"chromeTabs":@([source[@"chromeTabs"] boolValue])} mutableCopy];
    if(source[@"monitorName"])result[@"monitorName"]=[source[@"monitorName"] copy];
    return [result copy];
}
+ (BOOL)snapshot:(NSDictionary*)a equals:(NSDictionary*)b {
    NSDictionary *left=[self canonicalSnapshot:a error:NULL],*right=[self canonicalSnapshot:b error:NULL];
    if(!left||!right)return NO;
    NSMutableDictionary *l=[left mutableCopy],*r=[right mutableCopy];[l removeObjectForKey:@"monitorName"];[r removeObjectForKey:@"monitorName"];return [l isEqual:r];
}
- (NSDictionary*)canonicalEntry:(id)value error:(NSError**)error {
    if(![value isKindOfClass:NSDictionary.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene entry.");return nil;}
    NSString *sceneID=TXSceneID(value[@"id"]);
    if(!sceneID){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene ID.");return nil;}
    NSString *name=TXSceneName(value[@"name"],error);if(!name)return nil;
    NSDictionary *snapshot=[TXSceneStore canonicalSnapshot:value[@"snapshot"] error:error];if(!snapshot)return nil;
    return @{@"id":sceneID,@"name":name,@"snapshot":snapshot};
}
- (BOOL)reload:(NSError**)error {
    if(error)*error=nil;
    id container=[self.defaults objectForKey:TXSceneDefaultsKey];
    if(!container){self.scenes=@[];self.readOnly=NO;return YES;}
    self.readOnly=YES;
    if(![container isKindOfClass:NSDictionary.class]||!TXSceneInteger(container[@"version"],1,NSIntegerMax))return TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene container.");
    if([container[@"version"] integerValue]!=1)return TXSceneFail(error,TXSceneErrorUnsupportedVersion,@"Unsupported scene container version.");
    id entries=container[@"entries"];
    if(![entries isKindOfClass:NSArray.class]||[entries count]>16)return TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene entries.");
    NSMutableArray *clean=[NSMutableArray arrayWithCapacity:[entries count]];NSMutableSet *ids=[NSMutableSet set];
    for(id value in entries){NSDictionary *entry=[self canonicalEntry:value error:error];if(!entry)return NO;
        if([ids containsObject:entry[@"id"]])return TXSceneFail(error,TXSceneErrorInvalidData,@"Duplicate scene ID.");
        for(NSDictionary *other in clean)if([entry[@"name"] caseInsensitiveCompare:other[@"name"]]==NSOrderedSame)return TXSceneFail(error,TXSceneErrorDuplicateName,@"Duplicate scene name.");
        [ids addObject:entry[@"id"]];[clean addObject:entry];
    }
    self.scenes=[clean copy];self.readOnly=NO;return YES;
}
- (NSDictionary*)sceneWithID:(NSString*)sceneID {
    NSString *normalized=TXSceneID(sceneID);if(!normalized)return nil;
    for(NSDictionary *entry in self.scenes)if([entry[@"id"] isEqual:normalized])return entry;return nil;
}
- (BOOL)canWrite:(NSError**)error {
    if(error)*error=nil;return !self.readOnly||TXSceneFail(error,TXSceneErrorReadOnly,@"Scene storage is read-only.");
}
- (BOOL)nameAvailable:(NSString*)name excluding:(NSString*)sceneID error:(NSError**)error {
    for(NSDictionary *entry in self.scenes)if(![entry[@"id"] isEqual:sceneID]&&[entry[@"name"] caseInsensitiveCompare:name]==NSOrderedSame)return TXSceneFail(error,TXSceneErrorDuplicateName,@"A scene already has this name.");return YES;
}
- (BOOL)commitEntries:(NSArray*)entries error:(NSError**)error {
    NSArray *immutable=[entries copy];
    @try{[self.defaults setObject:@{@"version":@1,@"entries":immutable} forKey:TXSceneDefaultsKey];}
    @catch(NSException *exception){return TXSceneFail(error,TXSceneErrorInvalidData,@"Unable to save scenes.");}
    self.scenes=immutable;return YES;
}
- (NSDictionary*)addSceneNamed:(NSString*)name snapshot:(NSDictionary*)snapshot error:(NSError**)error {
    if(![self canWrite:error])return nil;
    NSString *cleanName=TXSceneName(name,error);if(!cleanName||![self nameAvailable:cleanName excluding:nil error:error])return nil;
    if(self.scenes.count>=16){TXSceneFail(error,TXSceneErrorLimitReached,@"At most 16 scenes can be saved.");return nil;}
    NSDictionary *cleanSnapshot=[TXSceneStore canonicalSnapshot:snapshot error:error];if(!cleanSnapshot)return nil;
    NSDictionary *entry=@{@"id":NSUUID.UUID.UUIDString,@"name":cleanName,@"snapshot":cleanSnapshot};
    NSMutableArray *entries=[self.scenes mutableCopy];[entries addObject:entry];return [self commitEntries:entries error:error]?entry:nil;
}
- (BOOL)updateSceneID:(NSString*)sceneID snapshot:(NSDictionary*)snapshot error:(NSError**)error {
    if(![self canWrite:error])return NO;NSDictionary *entry=[self sceneWithID:sceneID];if(!entry)return TXSceneFail(error,TXSceneErrorNotFound,@"Scene not found.");
    NSDictionary *clean=[TXSceneStore canonicalSnapshot:snapshot error:error];if(!clean)return NO;
    NSMutableArray *entries=[self.scenes mutableCopy];entries[[entries indexOfObjectIdenticalTo:entry]]=@{@"id":entry[@"id"],@"name":entry[@"name"],@"snapshot":clean};return [self commitEntries:entries error:error];
}
- (BOOL)renameSceneID:(NSString*)sceneID name:(NSString*)name error:(NSError**)error {
    if(![self canWrite:error])return NO;NSDictionary *entry=[self sceneWithID:sceneID];if(!entry)return TXSceneFail(error,TXSceneErrorNotFound,@"Scene not found.");
    NSString *clean=TXSceneName(name,error);if(!clean||![self nameAvailable:clean excluding:entry[@"id"] error:error])return NO;
    NSMutableArray *entries=[self.scenes mutableCopy];entries[[entries indexOfObjectIdenticalTo:entry]]=@{@"id":entry[@"id"],@"name":clean,@"snapshot":entry[@"snapshot"]};return [self commitEntries:entries error:error];
}
- (BOOL)removeSceneID:(NSString*)sceneID error:(NSError**)error {
    if(![self canWrite:error])return NO;NSDictionary *entry=[self sceneWithID:sceneID];if(!entry)return TXSceneFail(error,TXSceneErrorNotFound,@"Scene not found.");
    NSMutableArray *entries=[self.scenes mutableCopy];[entries removeObjectIdenticalTo:entry];return [self commitEntries:entries error:error];
}
- (BOOL)restoreEntry:(NSDictionary*)entry atIndex:(NSUInteger)index error:(NSError**)error {
    if(![self canWrite:error])return NO;
    NSDictionary *clean=[self canonicalEntry:entry error:error];if(!clean)return NO;
    if([self sceneWithID:clean[@"id"]])return TXSceneFail(error,TXSceneErrorInvalidData,@"Scene ID already exists.");
    if(![self nameAvailable:clean[@"name"] excluding:nil error:error])return NO;
    if(self.scenes.count>=16)return TXSceneFail(error,TXSceneErrorLimitReached,@"At most 16 scenes can be saved.");
    if(index>self.scenes.count)return TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene position.");
    NSMutableArray *entries=[self.scenes mutableCopy];[entries insertObject:clean atIndex:index];return [self commitEntries:entries error:error];
}
@end

// This fake never creates or writes an NSUserDefaults domain.
@interface TXSceneMemoryDefaults : NSObject
@property(nonatomic,strong) id stored;
@property(nonatomic) NSUInteger writes;
- (id)objectForKey:(NSString*)key;
- (void)setObject:(id)value forKey:(NSString*)key;
@end
@implementation TXSceneMemoryDefaults
- (id)objectForKey:(NSString*)key{return [key isEqual:TXSceneDefaultsKey]?self.stored:nil;}
- (void)setObject:(id)value forKey:(NSString*)key{if([key isEqual:TXSceneDefaultsKey]){self.stored=value;self.writes++;}}
@end

static NSDictionary *TXSceneCheckSnapshot(void) {
    NSDictionary *channel=@{@"gain":@1,@"eq":@[@0,@0,@0],@"muted":@NO,@"route":@0};
    return @{@"version":@1,@"assignments":@[TXSceneSystemKey,@"com.apple.Music",@"",@"",@"",@""],@"channels":@[channel,channel,channel,channel,channel,channel],@"followDefaultOutput":@YES,@"outputUID":@"old-output",@"monitorUID":@"monitor",@"monitorName":@"Speakers",@"monitorGain":@0.5,@"chromeTabs":@NO};
}
BOOL TXRunSceneStoreSelfCheck(void) {
    __block BOOL ok=YES;
    void (^check)(BOOL,NSString*)=^(BOOL success,NSString *label){if(!success){fprintf(stderr,"Scene self-check failed: %s\n",label.UTF8String);ok=NO;}};
    NSDictionary *snapshot=TXSceneCheckSnapshot();NSError *error=nil;
    NSDictionary *canonical=[TXSceneStore canonicalSnapshot:snapshot error:&error];check(canonical!=nil&&!error,@"canonical valid snapshot");
    TXSceneMemoryDefaults *memory=[TXSceneMemoryDefaults new];TXSceneStore *store=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)memory];
    check(!store.readOnly&&store.scenes.count==0&&memory.writes==0,@"missing storage does not write");
    NSDictionary *first=[store addSceneNamed:@"  Work  " snapshot:snapshot error:&error],*second=[store addSceneNamed:@"Travel" snapshot:snapshot error:&error];
    check(first&&second&&[first[@"name"] isEqual:@"Work"]&&memory.writes==2,@"atomic add and trimmed name");
    NSString *firstID=first[@"id"],*secondID=second[@"id"];
    NSUInteger writes=memory.writes;
    check(![store addSceneNamed:@"wOrK" snapshot:snapshot error:&error]&&error.code==TXSceneErrorDuplicateName&&memory.writes==writes,@"case insensitive duplicate is unchanged");
    NSDictionary *accent=[store addSceneNamed:@"Cafe\u0301" snapshot:snapshot error:&error];
    check(accent&&[accent[@"name"] isEqual:@"Café"]&&![store addSceneNamed:@"CAFÉ" snapshot:snapshot error:&error]&&error.code==TXSceneErrorDuplicateName,@"NFC duplicate names");
    for(NSString *name in @[@" ",@"bad\nname",[@"a" stringByPaddingToLength:33 withString:@"a" startingAtIndex:0]])check(![store addSceneNamed:name snapshot:snapshot error:&error]&&error.code==TXSceneErrorInvalidName,@"invalid name");
    NSString *emoji=@"";for(NSUInteger i=0;i<32;i++)emoji=[emoji stringByAppendingString:@"👨‍👩‍👧‍👦"];
    check([store addSceneNamed:emoji snapshot:snapshot error:&error]!=nil,@"32 composed characters");
    NSMutableDictionary *changed=[snapshot mutableCopy];changed[@"monitorGain"]=@0.25;
    check([store updateSceneID:firstID snapshot:changed error:&error]&&[store renameSceneID:firstID name:@"Desk" error:&error]&&[store.scenes[0][@"id"] isEqual:firstID]&&[store.scenes[0][@"snapshot"][@"monitorGain"] isEqual:@0.25],@"update and rename preserve position and ID");
    check(![store renameSceneID:firstID name:@"Travel" error:&error]&&error.code==TXSceneErrorDuplicateName,@"rename duplicate");
    NSDictionary *deleted=[store sceneWithID:secondID];
    check([store removeSceneID:secondID error:&error]&&![store sceneWithID:secondID]&&[store restoreEntry:deleted atIndex:1 error:&error]&&[store.scenes[1][@"id"] isEqual:secondID],@"delete restore position and ID");
    TXSceneStore *reloaded=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)memory];check([reloaded.scenes isEqual:store.scenes],@"relaunch memory reload");
    writes=memory.writes;
    check(![store updateSceneID:@"missing" snapshot:snapshot error:&error]&&error.code==TXSceneErrorNotFound&&! [store removeSceneID:@"missing" error:&error]&&memory.writes==writes,@"missing mutation unchanged");
    check(![store restoreEntry:deleted atIndex:0 error:&error]&&memory.writes==writes,@"duplicate ID restore unchanged");
    while(store.scenes.count<16)[store addSceneNamed:[NSString stringWithFormat:@"Scene %lu",(unsigned long)store.scenes.count] snapshot:snapshot error:&error];
    writes=memory.writes;check(![store addSceneNamed:@"Overflow" snapshot:snapshot error:&error]&&error.code==TXSceneErrorLimitReached&&memory.writes==writes,@"16 scene limit");
    NSMutableDictionary *extra=[snapshot mutableCopy];extra[@"master"]=@0;extra[@"masterMuted"]=@YES;extra[@"midi"]=@"secret";extra[@"language"]=@"ko";extra[@"autoStart"]=@YES;extra[@"permissions"]=@{};
    NSDictionary *safe=[TXSceneStore canonicalSnapshot:extra error:&error];check([safe isEqual:canonical]&&[safe[@"outputUID"] isEqual:@""],@"global settings excluded and follow default canonical UID");
    extra=[snapshot mutableCopy];extra[@"monitorName"]=@"스피커";extra[@"outputUID"]=@"new-output";check([TXSceneStore snapshot:snapshot equals:extra],@"metadata and default UID do not dirty");extra[@"monitorGain"]=@0.2;check(![TXSceneStore snapshot:snapshot equals:extra],@"control differences dirty");
    extra=[snapshot mutableCopy];extra[@"assignments"]=@[@"wrong",@"chrome-tab:private-URL",@"pid:1234",@"closed.native.app",@"",@""];extra[@"chromeTabs"]=@YES;
    safe=[TXSceneStore canonicalSnapshot:extra error:&error];
    check([safe[@"assignments"] isEqual:@[TXSceneSystemKey,@"",@"",@"closed.native.app",@"",@""]]&&[safe[@"pendingSources"] isEqual:@[@"",@"tab",@"process",@"",@"",@""]]&&![safe.description containsString:@"private-URL"]&&![safe.description containsString:@"1234"],@"volatile identifiers removed and native retained");
    extra[@"chromeTabs"]=@NO;check(![TXSceneStore canonicalSnapshot:extra error:&error],@"tab intent requires Chrome enabled");
    NSArray *badAssignments=@[@[TXSceneSystemKey,TXSceneSystemKey,@"",@"",@"",@""],@[TXSceneSystemKey,@"duplicate",@"duplicate",@"",@"",@""],@[@"",@"",@"",@"",@""],@[TXSceneSystemKey,@1,@"",@"",@"",@""]];
    for(NSArray *assignments in badAssignments){extra=[snapshot mutableCopy];extra[@"assignments"]=assignments;check(![TXSceneStore canonicalSnapshot:extra error:&error],@"invalid assignments rejected");}
    NSArray *badControls=@[@{@"gain":@(-0.1)},@{@"gain":@1.1},@{@"gain":@(NAN)},@{@"gain":@(INFINITY)},@{@"gain":@YES},@{@"muted":@1},@{@"route":@4},@{@"route":@(-1)},@{@"route":@1.5},@{@"route":@YES},@{@"eq":@[@0,@0]},@{@"eq":@[@0,@0,@19]},@{@"eq":@[@0,@(NAN),@0]},@{@"eq":@[@0,@"0",@0]}];
    for(NSDictionary *bad in badControls){extra=[snapshot mutableCopy];NSMutableArray *channels=[snapshot[@"channels"] mutableCopy];NSMutableDictionary *channel=[channels[1] mutableCopy];[channel addEntriesFromDictionary:bad];channels[1]=channel;extra[@"channels"]=channels;check(![TXSceneStore canonicalSnapshot:extra error:&error],@"invalid channel control rejected");}
    for(NSDictionary *bad in @[@{@"channels":@[]},@{@"followDefaultOutput":@1},@{@"monitorGain":@(-1)},@{@"monitorGain":@(NAN)},@{@"outputUID":@4},@{@"monitorUID":@4},@{@"monitorName":@4},@{@"chromeTabs":@1},@{@"pendingSources":@[@"",@"unknown",@"",@"",@"",@""]}]){extra=[snapshot mutableCopy];[extra addEntriesFromDictionary:bad];check(![TXSceneStore canonicalSnapshot:extra error:&error],@"invalid output or structure rejected");}
    NSMutableString *mutableName=[@"Mutable" mutableCopy],*mutableApp=[@"closed.app" mutableCopy],*mutableMonitor=[@"Monitor" mutableCopy];
    NSMutableArray *assignments=[snapshot[@"assignments"] mutableCopy];assignments[1]=mutableApp;NSMutableArray *channels=[snapshot[@"channels"] mutableCopy];NSMutableDictionary *mutableChannel=[channels[0] mutableCopy];NSMutableArray *mutableEQ=[mutableChannel[@"eq"] mutableCopy];mutableChannel[@"eq"]=mutableEQ;channels[0]=mutableChannel;extra=[snapshot mutableCopy];extra[@"assignments"]=assignments;extra[@"channels"]=channels;extra[@"monitorName"]=mutableMonitor;
    TXSceneMemoryDefaults *mutableMemory=[TXSceneMemoryDefaults new];TXSceneStore *mutableStore=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)mutableMemory];NSDictionary *immutable=[mutableStore addSceneNamed:mutableName snapshot:extra error:&error];
    [mutableName appendString:@" changed"];[mutableApp appendString:@" changed"];[mutableMonitor appendString:@" changed"];mutableEQ[0]=@12;mutableChannel[@"gain"]=@0;[assignments removeAllObjects];[channels removeAllObjects];
    check([immutable[@"name"] isEqual:@"Mutable"]&&[immutable[@"snapshot"][@"assignments"][1] isEqual:@"closed.app"]&&[immutable[@"snapshot"][@"monitorName"] isEqual:@"Monitor"]&&[immutable[@"snapshot"][@"channels"][0][@"eq"][0] isEqual:@0]&&[immutable[@"snapshot"][@"channels"][0][@"gain"] isEqual:@1],@"deep immutable external input");
    NSMutableDictionary *lowerID=[immutable mutableCopy];lowerID[@"id"]=[immutable[@"id"] lowercaseString];
    check([mutableStore removeSceneID:lowerID[@"id"] error:&error]&&[mutableStore restoreEntry:lowerID atIndex:0 error:&error]&&[mutableStore.scenes[0][@"id"] isEqual:immutable[@"id"]],@"UUID normalization");
    writes=mutableMemory.writes;check(![mutableStore restoreEntry:deleted atIndex:9 error:&error]&&mutableMemory.writes==writes,@"restore index validation");
    writes=mutableMemory.writes;NSArray *beforeInvalid=mutableStore.scenes;
    NSDictionary *invalidSnapshot=@{@"version":@1};
    check(![mutableStore addSceneNamed:@"Invalid" snapshot:invalidSnapshot error:&error]&&![mutableStore updateSceneID:immutable[@"id"] snapshot:invalidSnapshot error:&error]&&![mutableStore renameSceneID:immutable[@"id"] name:@"" error:&error]&&mutableStore.scenes==beforeInvalid&&mutableMemory.writes==writes,@"invalid mutations have no side effects");
    NSMutableDictionary *invalidRestore=[deleted mutableCopy];invalidRestore[@"id"]=@"bad";
    check(![mutableStore restoreEntry:invalidRestore atIndex:0 error:&error]&&mutableMemory.writes==writes,@"invalid restore ID");
    extra=[snapshot mutableCopy];extra[@"version"]=@2;check(![TXSceneStore canonicalSnapshot:extra error:&error]&&error.code==TXSceneErrorUnsupportedVersion,@"future snapshot version");
    NSDictionary *invalidEntry=@{@"id":@"bad",@"name":@"Bad",@"snapshot":snapshot};
    NSArray *badContainers=@[@"corrupt",@{},@{@"version":@YES,@"entries":@[]},@{@"version":@2,@"entries":@[]},@{@"version":@1,@"entries":@"bad"},@{@"version":@1,@"entries":@[invalidEntry]},@{@"version":@1,@"entries":@[immutable,immutable]},@{@"version":@1,@"entries":@[@{@"id":NSUUID.UUID.UUIDString,@"name":@"Future",@"snapshot":extra}]}];
    for(id bad in badContainers){TXSceneMemoryDefaults *broken=[TXSceneMemoryDefaults new];broken.stored=bad;TXSceneStore *blocked=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)broken];check(blocked.readOnly&&![blocked reload:&error]&&error!=nil,@"corrupt storage read only with error");check(![blocked addSceneNamed:@"Safe" snapshot:snapshot error:&error]&&error.code==TXSceneErrorReadOnly&&![blocked updateSceneID:firstID snapshot:snapshot error:&error]&&![blocked renameSceneID:firstID name:@"Safe" error:&error]&&![blocked removeSceneID:firstID error:&error]&&![blocked restoreEntry:immutable atIndex:0 error:&error]&&broken.writes==0&&broken.stored==bad,@"read only mutations preserve original defaults");broken.stored=nil;check([blocked reload:&error]&&!blocked.readOnly&&blocked.scenes.count==0&&broken.writes==0,@"reload recovers after explicit removal");}
    printf("TX6Mac scene store self-check: %s\n",ok?"PASS":"FAIL");return ok;
}
