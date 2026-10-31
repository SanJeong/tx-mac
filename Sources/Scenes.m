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

static BOOL TXSceneNativeBundleID(id value) {
    if(![value isKindOfClass:NSString.class]||![value length]||[value isEqual:TXSceneSystemKey])return NO;
    NSMutableCharacterSet *invalid=[NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [invalid formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];[invalid addCharactersInString:@":/"];
    return [value rangeOfCharacterFromSet:invalid].location==NSNotFound;
}
static NSArray *TXSceneResolveAssignment(NSString *assignment,NSDictionary *groups,NSError **error) {
    if(![assignment isKindOfClass:NSString.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid channel assignment.");return nil;}
    if([assignment hasPrefix:@"app-group:"]){
        NSString *groupID=TXSceneID([assignment substringFromIndex:10]);NSDictionary *group=groupID?groups[groupID]:nil;
        if(!group){TXSceneFail(error,TXSceneErrorInvalidData,@"Channel references an unknown app group.");return nil;}return group[@"bundleIDs"];
    }
    if(!assignment.length||[assignment isEqual:TXSceneSystemKey]||[assignment hasPrefix:@"pid:"]||[assignment hasPrefix:@"chrome-tab:"])return @[];
    return @[[assignment copy]];
}
static BOOL TXSceneValidateOwnership(NSArray *assignments,NSDictionary *groups,BOOL chromeTabs,NSError **error) {
    if(![assignments isKindOfClass:NSArray.class]||assignments.count!=6||![assignments[0] isEqual:TXSceneSystemKey])return TXSceneFail(error,TXSceneErrorInvalidData,@"Six assignments with system sounds on channel one are required.");
    NSMutableSet *owned=[NSMutableSet set];
    for(NSUInteger i=1;i<6;i++){
        id assignment=assignments[i];
        if(![assignment isKindOfClass:NSString.class]||[assignment isEqual:TXSceneSystemKey])return TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid channel assignment.");
        if([assignment hasPrefix:@"chrome-tab:"]&&!chromeTabs)return TXSceneFail(error,TXSceneErrorInvalidData,@"Chrome tabs require tab mode.");
        NSArray *members=TXSceneResolveAssignment(assignment,groups,error);if(!members)return NO;
        if(chromeTabs&&[assignment hasPrefix:@"app-group:"]&&[members containsObject:@"com.google.Chrome"])return TXSceneFail(error,TXSceneErrorInvalidData,@"Chrome cannot belong to an active group while tab mode is enabled.");
        for(NSString *member in members){if([owned containsObject:member])return TXSceneFail(error,TXSceneErrorInvalidData,@"An app cannot be owned by multiple active channels.");[owned addObject:member];}
    }return YES;
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
+ (NSDictionary*)canonicalAppGroups:(id)value error:(NSError**)error {
    if(error)*error=nil;
    if(![value isKindOfClass:NSDictionary.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"App groups must be a dictionary.");return nil;}
    if([value count]>16){TXSceneFail(error,TXSceneErrorLimitReached,@"At most 16 app groups can be saved.");return nil;}
    NSMutableDictionary *clean=[NSMutableDictionary dictionary];NSMutableArray *names=[NSMutableArray array];
    for(id rawID in value){NSString *groupID=TXSceneID(rawID);id group=value[rawID];
        if(!groupID||clean[groupID]||![group isKindOfClass:NSDictionary.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid or duplicate app group ID.");return nil;}
        NSString *name=TXSceneName(group[@"name"],error);if(!name)return nil;
        for(NSString *existing in names)if([existing caseInsensitiveCompare:name]==NSOrderedSame){TXSceneFail(error,TXSceneErrorDuplicateName,@"App group names must be unique.");return nil;}
        id members=group[@"bundleIDs"];
        if(![members isKindOfClass:NSArray.class]||[members count]<1||[members count]>32){TXSceneFail(error,TXSceneErrorInvalidData,@"App groups require 1 to 32 native apps.");return nil;}
        NSMutableSet *unique=[NSMutableSet set];
        for(id member in members){if(!TXSceneNativeBundleID(member)||[unique containsObject:member]){TXSceneFail(error,TXSceneErrorInvalidData,@"App group members must be unique native bundle IDs.");return nil;}[unique addObject:[member copy]];}
        NSArray *sorted=[[unique allObjects] sortedArrayUsingSelector:@selector(compare:)];
        clean[groupID]=@{@"name":name,@"bundleIDs":sorted};[names addObject:name];
    }return [clean copy];
}
+ (NSArray<NSString*>*)bundleIDsForAssignment:(NSString*)assignment appGroups:(NSDictionary*)appGroups error:(NSError**)error {
    NSDictionary *groups=[self canonicalAppGroups:appGroups error:error];if(!groups)return nil;
    return TXSceneResolveAssignment(assignment,groups,error);
}
+ (BOOL)validateAssignments:(NSArray*)assignments appGroups:(NSDictionary*)appGroups chromeTabs:(BOOL)chromeTabs error:(NSError**)error {
    NSDictionary *groups=[self canonicalAppGroups:appGroups error:error];if(!groups)return NO;
    return TXSceneValidateOwnership(assignments,groups,chromeTabs,error);
}
+ (NSDictionary*)canonicalSnapshot:(id)value error:(NSError**)error {
    if(error)*error=nil;
    if(![value isKindOfClass:NSDictionary.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"Scene snapshot must be a dictionary.");return nil;}
    NSDictionary *source=value;
    if(!TXSceneInteger(source[@"version"],1,NSIntegerMax)){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid snapshot version.");return nil;}
    NSInteger version=[source[@"version"] integerValue];
    if(version!=1&&version!=2){TXSceneFail(error,TXSceneErrorUnsupportedVersion,@"Unsupported snapshot version.");return nil;}
    NSDictionary *groups=@{};
    if(version==2){groups=[self canonicalAppGroups:source[@"appGroups"] error:error];if(!groups)return nil;}
    else if(source[@"appGroups"]){
        NSDictionary *legacyGroups=[self canonicalAppGroups:source[@"appGroups"] error:error];
        if(!legacyGroups)return nil;
        if(legacyGroups.count){TXSceneFail(error,TXSceneErrorInvalidData,@"Version one snapshots cannot contain app groups.");return nil;}
    }
    id assignments=source[@"assignments"],channels=source[@"channels"],pending=source[@"pendingSources"];
    if(![assignments isKindOfClass:NSArray.class]||[assignments count]!=6||![channels isKindOfClass:NSArray.class]||[channels count]!=6||(pending&&(![pending isKindOfClass:NSArray.class]||[pending count]!=6))){TXSceneFail(error,TXSceneErrorInvalidData,@"Scenes require six assignments and channels.");return nil;}
    if(!TXSceneBoolean(source[@"followDefaultOutput"])||!TXSceneBoolean(source[@"chromeTabs"])||![source[@"outputUID"] isKindOfClass:NSString.class]||![source[@"monitorUID"] isKindOfClass:NSString.class]||(source[@"monitorName"]&&![source[@"monitorName"] isKindOfClass:NSString.class])||!TXSceneNumber(source[@"monitorGain"],0,1)){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene output settings.");return nil;}
    NSMutableArray *cleanAssignments=[NSMutableArray arrayWithCapacity:6],*cleanChannels=[NSMutableArray arrayWithCapacity:6],*cleanPending=[NSMutableArray arrayWithCapacity:6];
    NSMutableDictionary *referencedGroups=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<6;i++) {
        id assignment=assignments[i],channel=channels[i],intent=pending?pending[i]:@"";
        if(![assignment isKindOfClass:NSString.class]||![intent isKindOfClass:NSString.class]||![@[@"",@"tab",@"process"] containsObject:intent]||![channel isKindOfClass:NSDictionary.class]){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid scene channel data.");return nil;}
        if([assignment hasPrefix:@"app-group:"]){
            if(version==1){TXSceneFail(error,TXSceneErrorInvalidData,@"Version one snapshots cannot reference app groups.");return nil;}
            NSString *groupID=TXSceneID([assignment substringFromIndex:10]);
            if(!groupID||!groups[groupID]){TXSceneFail(error,TXSceneErrorInvalidData,@"Channel references an unknown app group.");return nil;}
            assignment=[@"app-group:" stringByAppendingString:groupID];
            if(i>0)referencedGroups[groupID]=groups[groupID];
        }
        if(i==0){assignment=TXSceneSystemKey;intent=@"";}
        else if([assignment isEqualToString:TXSceneSystemKey]){TXSceneFail(error,TXSceneErrorInvalidData,@"System sounds must use channel one.");return nil;}
        else if([assignment hasPrefix:@"chrome-tab:"]){assignment=@"";intent=@"tab";}
        else if([assignment hasPrefix:@"pid:"]){assignment=@"";intent=@"process";}
        if(([intent isEqualToString:@"tab"]&&![source[@"chromeTabs"] boolValue])||([assignment length]&&[intent length])){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid pending source intent.");return nil;}
        id eq=channel[@"eq"];
        if(!TXSceneNumber(channel[@"gain"],0,1)||!TXSceneBoolean(channel[@"muted"])||!TXSceneInteger(channel[@"route"],0,3)||![eq isKindOfClass:NSArray.class]||[eq count]!=3){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid channel controls.");return nil;}
        NSMutableArray *cleanEQ=[NSMutableArray arrayWithCapacity:3];
        for(id band in eq){if(!TXSceneNumber(band,-18,18)){TXSceneFail(error,TXSceneErrorInvalidData,@"Invalid equalizer value.");return nil;}[cleanEQ addObject:@([band doubleValue])];}
        [cleanAssignments addObject:[assignment copy]];[cleanPending addObject:[intent copy]];
        [cleanChannels addObject:@{@"gain":@([channel[@"gain"] doubleValue]),@"eq":[cleanEQ copy],@"muted":@([channel[@"muted"] boolValue]),@"route":@([channel[@"route"] integerValue])}];
    }
    if(!TXSceneValidateOwnership(cleanAssignments,groups,[source[@"chromeTabs"] boolValue],error))return nil;
    NSMutableDictionary *result=[@{@"version":@2,@"appGroups":[referencedGroups copy],@"assignments":[cleanAssignments copy],@"channels":[cleanChannels copy],@"pendingSources":[cleanPending copy],@"followDefaultOutput":@([source[@"followDefaultOutput"] boolValue]),@"outputUID":[source[@"followDefaultOutput"] boolValue]?@"":[source[@"outputUID"] copy],@"monitorUID":[source[@"monitorUID"] copy],@"monitorGain":@([source[@"monitorGain"] doubleValue]),@"chromeTabs":@([source[@"chromeTabs"] boolValue])} mutableCopy];
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
static void TXRunSceneGroupSelfCheck(void (^check)(BOOL,NSString*)) {
    NSDictionary *v1=TXSceneCheckSnapshot();NSError *error=nil;
    NSMutableDictionary *v2=[v1 mutableCopy];v2[@"version"]=@2;v2[@"appGroups"]=@{};
    check([TXSceneStore snapshot:v1 equals:v2],@"v1 and empty v2 are semantically equal");
    NSMutableDictionary *hugeVersion=[v1 mutableCopy];hugeVersion[@"version"]=@((double)NSIntegerMax);
    check(![TXSceneStore canonicalSnapshot:hugeVersion error:&error]&&error.code==TXSceneErrorUnsupportedVersion,@"large future snapshot version is rejected");
    NSDictionary *legacyEntry=@{@"id":NSUUID.UUID.UUIDString,@"name":@"Legacy",@"snapshot":v1};
    NSDictionary *legacyContainer=@{@"version":@1,@"entries":@[legacyEntry]};
    TXSceneMemoryDefaults *legacyMemory=[TXSceneMemoryDefaults new];legacyMemory.stored=legacyContainer;
    TXSceneStore *legacyStore=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)legacyMemory];
    check(!legacyStore.readOnly&&legacyMemory.writes==0&&legacyMemory.stored==legacyContainer&&[legacyStore.scenes[0][@"snapshot"][@"version"] isEqual:@2],@"legacy reload upgrades only memory");
    check([legacyStore renameSceneID:legacyEntry[@"id"] name:@"Upgraded" error:&error]&&legacyMemory.writes==1&&[legacyMemory.stored[@"version"] isEqual:@1]&&[legacyMemory.stored[@"entries"][0][@"snapshot"][@"version"] isEqual:@2],@"explicit mutation saves v2 inside v1 container");
    NSString *groupA=@"A67AEE01-438A-4CD5-9D89-57E47D2F3E01",*groupB=@"B67AEE01-438A-4CD5-9D89-57E47D2F3E02";
    NSString *tokenA=[@"app-group:" stringByAppendingString:groupA],*tokenB=[@"app-group:" stringByAppendingString:groupB];
    NSMutableString *groupName=[@" Cafe\u0301 " mutableCopy],*nativeID=[@"org.closed.Z" mutableCopy];
    NSMutableArray *members=[NSMutableArray arrayWithObjects:nativeID,@"org.closed.A",nil];
    NSMutableDictionary *group=[@{@"name":groupName,@"bundleIDs":members,@"privateTitle":@"discard"} mutableCopy];
    NSMutableDictionary *library=[@{groupA.lowercaseString:group,groupB:@{@"name":@"Other",@"bundleIDs":@[@"org.closed.Z"]}} mutableCopy];
    NSDictionary *clean=[TXSceneStore canonicalAppGroups:library error:&error];
    check(clean&&[clean[groupA][@"name"] isEqual:@"Café"]&&[clean[groupA][@"bundleIDs"] isEqual:@[@"org.closed.A",@"org.closed.Z"]]&&!clean[groupA][@"privateTitle"],@"group IDs names and stable members canonicalized");
    [groupName appendString:@" changed"];[nativeID appendString:@" changed"];[members removeAllObjects];[group removeAllObjects];[library removeAllObjects];
    check([clean[groupA][@"name"] isEqual:@"Café"]&&[clean[groupA][@"bundleIDs"] isEqual:@[@"org.closed.A",@"org.closed.Z"]],@"app groups are deeply immutable");
    NSDictionary *definition=@{@"name":@"Desk",@"bundleIDs":@[@"org.closed.Z",@"org.closed.A"]};
    NSDictionary *groups=@{groupA:definition,groupB:@{@"name":@"Overlap",@"bundleIDs":@[@"org.closed.Z"]}};
    v2[@"appGroups"]=groups;v2[@"assignments"]=@[TXSceneSystemKey,tokenA.lowercaseString,@"",@"",@"",@""];
    NSDictionary *snapshot=[TXSceneStore canonicalSnapshot:v2 error:&error];
    check(snapshot&&[snapshot[@"appGroups"] count]==1&&snapshot[@"appGroups"][groupA]&&[snapshot[@"assignments"][1] isEqual:tokenA],@"only referenced groups embedded and tokens normalized");
    check([[TXSceneStore bundleIDsForAssignment:tokenA appGroups:groups error:&error] isEqual:@[@"org.closed.A",@"org.closed.Z"]],@"group resolver returns sorted native members");
    check([[TXSceneStore bundleIDsForAssignment:@"closed.native.app" appGroups:groups error:&error] isEqual:@[@"closed.native.app"]],@"native resolver retains closed apps");
    for(NSString *special in @[@"",TXSceneSystemKey,@"pid:123",@"chrome-tab:private"])
        check([TXSceneStore bundleIDsForAssignment:special appGroups:groups error:&error].count==0,@"non-native resolver returns no bundle IDs");
    check(![TXSceneStore bundleIDsForAssignment:@"app-group:unknown" appGroups:groups error:&error]&&error.code==TXSceneErrorInvalidData,@"dangling resolver fails");
    check([TXSceneStore validateAssignments:v2[@"assignments"] appGroups:groups chromeTabs:NO error:&error],@"unreferenced overlapping groups allowed");
    for(NSArray *assignments in @[@[TXSceneSystemKey,tokenA,tokenB,@"",@"",@""],@[TXSceneSystemKey,tokenA,@"org.closed.A",@"",@"",@""],@[TXSceneSystemKey,@"org.closed.A",tokenA,@"",@"",@""],@[TXSceneSystemKey,tokenA,tokenA,@"",@"",@""]]){
        v2[@"assignments"]=assignments;check(![TXSceneStore canonicalSnapshot:v2 error:&error]&&![TXSceneStore validateAssignments:assignments appGroups:groups chromeTabs:NO error:&error],@"active native and group ownership cannot overlap");
    }
    check(![TXSceneStore validateAssignments:@[] appGroups:groups chromeTabs:NO error:&error]&&![TXSceneStore validateAssignments:@[@"",@"",@"",@"",@"",@""] appGroups:groups chromeTabs:NO error:&error],@"assignment helper requires fixed six slots");
    v2[@"assignments"]=@[TXSceneSystemKey,tokenB,@"",@"",@"",@""];v2[@"appGroups"]=@{groupA:definition};
    check(![TXSceneStore canonicalSnapshot:v2 error:&error],@"snapshot dangling group rejected");
    NSMutableDictionary *legacyGroupSnapshot=[v1 mutableCopy];legacyGroupSnapshot[@"assignments"]=@[TXSceneSystemKey,tokenA,@"",@"",@"",@""];legacyGroupSnapshot[@"appGroups"]=@{groupA:definition};
    check(![TXSceneStore canonicalSnapshot:legacyGroupSnapshot error:&error],@"v1 cannot silently drop group definitions");
    [legacyGroupSnapshot removeObjectForKey:@"appGroups"];check(![TXSceneStore canonicalSnapshot:legacyGroupSnapshot error:&error],@"v1 cannot silently drop group token");
    NSDictionary *chromeGroups=@{groupA:@{@"name":@"Browser",@"bundleIDs":@[@"com.google.Chrome"]}};
    v2[@"appGroups"]=chromeGroups;v2[@"assignments"]=@[TXSceneSystemKey,tokenA,@"",@"",@"",@""];v2[@"chromeTabs"]=@NO;
    check([TXSceneStore canonicalSnapshot:v2 error:&error]!=nil,@"Chrome group allowed in aggregate mode");
    v2[@"chromeTabs"]=@YES;check(![TXSceneStore canonicalSnapshot:v2 error:&error]&&![TXSceneStore validateAssignments:v2[@"assignments"] appGroups:chromeGroups chromeTabs:YES error:&error],@"active Chrome group conflicts with tabs");
    v2[@"assignments"]=v1[@"assignments"];check([TXSceneStore canonicalSnapshot:v2 error:&error]!=nil,@"unreferenced Chrome group does not conflict with tabs");
    NSArray *badMembers=@[@[],@[@"duplicate.app",@"duplicate.app"],@[@1],@[@""],@[@"contains space"],@[@"https://private"],@[TXSceneSystemKey],@[@"pid:99"],@[@"chrome-tab:private"],@[tokenA]];
    for(NSArray *bad in badMembers)check(![TXSceneStore canonicalAppGroups:@{groupA:@{@"name":@"Bad",@"bundleIDs":bad}} error:&error],@"invalid and reserved group members rejected");
    NSMutableArray *manyMembers=[NSMutableArray array];for(NSUInteger i=0;i<32;i++)[manyMembers addObject:[NSString stringWithFormat:@"org.closed.%lu",(unsigned long)i]];
    check([TXSceneStore canonicalAppGroups:@{groupA:@{@"name":@"Boundary",@"bundleIDs":manyMembers}} error:&error]!=nil,@"32 group members allowed");[manyMembers addObject:@"org.closed.overflow"];
    check(![TXSceneStore canonicalAppGroups:@{groupA:@{@"name":@"Boundary",@"bundleIDs":manyMembers}} error:&error],@"33 group members rejected");
    for(NSString *badName in @[@"",@"  ",@"bad\nname",[@"x" stringByPaddingToLength:33 withString:@"x" startingAtIndex:0]])check(![TXSceneStore canonicalAppGroups:@{groupA:@{@"name":badName,@"bundleIDs":@[@"native.app"]}} error:&error]&&error.code==TXSceneErrorInvalidName,@"group name constraints");
    check(![TXSceneStore canonicalAppGroups:@{groupA:@{@"name":@"Café",@"bundleIDs":@[@"app.A"]},groupB:@{@"name":@"CAFE\u0301",@"bundleIDs":@[@"app.B"]}} error:&error]&&error.code==TXSceneErrorDuplicateName,@"group names unique after case and NFC normalization");
    check(![TXSceneStore canonicalAppGroups:@{groupA:definition,groupA.lowercaseString:definition} error:&error],@"duplicate normalized group UUID rejected");
    check(![TXSceneStore canonicalAppGroups:@{@"bad-id":definition} error:&error]&&![TXSceneStore canonicalAppGroups:@[] error:&error]&&![TXSceneStore canonicalAppGroups:@{groupA:@"bad"} error:&error],@"invalid group root and IDs rejected");
    NSMutableDictionary *manyGroups=[NSMutableDictionary dictionary];for(NSUInteger i=0;i<16;i++)manyGroups[NSUUID.UUID.UUIDString]=@{@"name":[NSString stringWithFormat:@"Group %lu",(unsigned long)i],@"bundleIDs":@[@"overlap.allowed"]};
    check([TXSceneStore canonicalAppGroups:manyGroups error:&error]!=nil,@"16 overlapping library groups allowed");manyGroups[NSUUID.UUID.UUIDString]=@{@"name":@"Overflow",@"bundleIDs":@[@"app.extra"]};
    check(![TXSceneStore canonicalAppGroups:manyGroups error:&error]&&error.code==TXSceneErrorLimitReached,@"17 group limit");
    TXSceneMemoryDefaults *memory=[TXSceneMemoryDefaults new];TXSceneStore *store=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)memory];
    NSDictionary *sceneA=[store addSceneNamed:@"First" snapshot:snapshot error:&error];
    NSMutableDictionary *second=[snapshot mutableCopy];second[@"appGroups"]=@{groupA:@{@"name":@"Desk changed",@"bundleIDs":@[@"independent.app"]}};
    NSDictionary *sceneB=[store addSceneNamed:@"Second" snapshot:second error:&error];
    TXSceneStore *reloaded=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)memory];
    check(sceneA&&sceneB&&[reloaded.scenes isEqual:store.scenes]&&[sceneA[@"snapshot"][@"appGroups"][groupA][@"bundleIDs"] isEqual:@[@"org.closed.A",@"org.closed.Z"]]&&[sceneB[@"snapshot"][@"appGroups"][groupA][@"bundleIDs"] isEqual:@[@"independent.app"]],@"v2 scene definitions roundtrip independently");
    check(![TXSceneStore snapshot:sceneA[@"snapshot"] equals:sceneB[@"snapshot"]],@"changed embedded group changes semantic snapshot");
    NSMutableDictionary *dangling=[snapshot mutableCopy];dangling[@"appGroups"]=@{};NSDictionary *broken=@{@"version":@1,@"entries":@[@{@"id":NSUUID.UUID.UUIDString,@"name":@"Broken",@"snapshot":dangling}]};
    TXSceneMemoryDefaults *brokenMemory=[TXSceneMemoryDefaults new];brokenMemory.stored=broken;TXSceneStore *blocked=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)brokenMemory];
    check(blocked.readOnly&&![blocked addSceneNamed:@"Never" snapshot:snapshot error:&error]&&brokenMemory.stored==broken&&brokenMemory.writes==0,@"orphan group storage preserved read only");
}

BOOL TXRunSceneStoreSelfCheck(void) {
    __block BOOL ok=YES;
    void (^check)(BOOL,NSString*)=^(BOOL success,NSString *label){if(!success){fprintf(stderr,"Scene self-check failed: %s\n",label.UTF8String);ok=NO;}};
    TXRunSceneGroupSelfCheck(check);
    NSDictionary *snapshot=TXSceneCheckSnapshot();NSError *error=nil;
    NSDictionary *canonical=[TXSceneStore canonicalSnapshot:snapshot error:&error];check(canonical!=nil&&!error,@"canonical valid snapshot");
    check([canonical[@"version"] isEqual:@2]&&[canonical[@"appGroups"] isEqual:@{}],@"v1 snapshots upgrade in memory to v2");
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
    NSMutableDictionary *extra=[snapshot mutableCopy];extra[@"master"]=@0;extra[@"masterMuted"]=@YES;extra[@"midi"]=@"secret";extra[@"language"]=@"ko";extra[@"autoStart"]=@YES;extra[@"permissions"]=@{};extra[@"fx2"]=@YES;extra[@"fx2Type"]=@3;
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
    extra=[snapshot mutableCopy];extra[@"version"]=@3;check(![TXSceneStore canonicalSnapshot:extra error:&error]&&error.code==TXSceneErrorUnsupportedVersion,@"future snapshot version");
    NSDictionary *invalidEntry=@{@"id":@"bad",@"name":@"Bad",@"snapshot":snapshot};
    NSArray *badContainers=@[@"corrupt",@{},@{@"version":@YES,@"entries":@[]},@{@"version":@2,@"entries":@[]},@{@"version":@1,@"entries":@"bad"},@{@"version":@1,@"entries":@[invalidEntry]},@{@"version":@1,@"entries":@[immutable,immutable]},@{@"version":@1,@"entries":@[@{@"id":NSUUID.UUID.UUIDString,@"name":@"Future",@"snapshot":extra}]}];
    for(id bad in badContainers){TXSceneMemoryDefaults *broken=[TXSceneMemoryDefaults new];broken.stored=bad;TXSceneStore *blocked=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)broken];check(blocked.readOnly&&![blocked reload:&error]&&error!=nil,@"corrupt storage read only with error");check(![blocked addSceneNamed:@"Safe" snapshot:snapshot error:&error]&&error.code==TXSceneErrorReadOnly&&![blocked updateSceneID:firstID snapshot:snapshot error:&error]&&![blocked renameSceneID:firstID name:@"Safe" error:&error]&&![blocked removeSceneID:firstID error:&error]&&![blocked restoreEntry:immutable atIndex:0 error:&error]&&broken.writes==0&&broken.stored==bad,@"read only mutations preserve original defaults");broken.stored=nil;check([blocked reload:&error]&&!blocked.readOnly&&blocked.scenes.count==0&&broken.writes==0,@"reload recovers after explicit removal");}
    printf("TX6Mac scene store self-check: %s\n",ok?"PASS":"FAIL");return ok;
}
