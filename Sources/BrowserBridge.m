#import "BrowserBridge.h"
#import <math.h>

static NSString *const TXTabsNotification=@"local.tx6mac.browser.tabs";
static BOOL TXBool(id value) { return [value respondsToSelector:@selector(boolValue)] && [value boolValue]; }
static NSString *const TXControlsNotification=@"local.tx6mac.browser.controls";
@implementation TXBrowserBridge {
    NSMutableDictionary<NSString*,NSDictionary*> *_sessions;
    BOOL _started;
}
- (instancetype)init {if((self=[super init]))_sessions=[NSMutableDictionary dictionary];return self;}
- (void)start {if(_started)return;_started=YES;[[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(received:) name:TXTabsNotification object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];}
- (void)stop {if(!_started)return;[self sendControls:@[] enabled:NO];[[NSDistributedNotificationCenter defaultCenter] removeObserver:self];[_sessions removeAllObjects];_started=NO;}
- (void)received:(NSNotification*)note {
    NSString *json=note.userInfo[@"json"];if(![json isKindOfClass:NSString.class]||json.length>262144)return;
    NSDictionary *payload=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if(![payload isKindOfClass:NSDictionary.class]||![payload[@"type"] isEqual:@"tabs"])return;
    NSString *session=payload[@"session"];NSArray *tabs=payload[@"tabs"];
    if(![session isKindOfClass:NSString.class]||!session.length||session.length>80||![tabs isKindOfClass:NSArray.class]||tabs.count>200)return;
    if(TXBool(payload[@"disconnected"])){[_sessions removeObjectForKey:session];if(self.changed)self.changed();return;}
    NSMutableArray *clean=[NSMutableArray array];
    for(id tab in tabs){
        if(![tab isKindOfClass:NSDictionary.class]||![tab[@"id"] isKindOfClass:NSNumber.class]||![tab[@"title"] isKindOfClass:NSString.class])continue;
        NSString *title=tab[@"title"];if(title.length>100)title=[title substringToIndex:100];NSString *host=[tab[@"host"] isKindOfClass:NSString.class]?tab[@"host"]:@"";if(host.length>200)host=[host substringToIndex:200];
        float peak=[tab[@"peak"] respondsToSelector:@selector(floatValue)]?[tab[@"peak"] floatValue]:0;if(!isfinite(peak))peak=0;
        [clean addObject:@{@"id":tab[@"id"],@"session":session,@"title":title,@"host":host,@"active":@(TXBool(tab[@"active"])),@"captured":@(TXBool(tab[@"captured"])),@"muted":@(TXBool(tab[@"muted"])),@"detected":@(TXBool(tab[@"detected"])),@"peak":@(fmaxf(0,fminf(1,peak)))}];
    }
    NSDictionary *old=_sessions[session];_sessions[session]=@{@"tabs":clean,@"time":@(NSDate.date.timeIntervalSince1970)};
    NSMutableArray *oldShape=[NSMutableArray array],*newShape=[NSMutableArray array];
    for(NSDictionary *t in old[@"tabs"]?:@[]){NSMutableDictionary *v=[t mutableCopy];[v removeObjectForKey:@"peak"];[oldShape addObject:v];}
    for(NSDictionary *t in clean){NSMutableDictionary *v=[t mutableCopy];[v removeObjectForKey:@"peak"];[newShape addObject:v];}
    if(![oldShape isEqual:newShape]&&self.changed)self.changed();
}
- (void)prune {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    for(NSString *key in _sessions.allKeys)if(now-[_sessions[key][@"time"] doubleValue]>5)[_sessions removeObjectForKey:key];
}
- (NSArray<NSDictionary*>*)tabs {[self prune];NSMutableArray *tabs=[NSMutableArray array];for(NSString *key in [_sessions.allKeys sortedArrayUsingSelector:@selector(compare:)])[tabs addObjectsFromArray:_sessions[key][@"tabs"]];return tabs;}
- (BOOL)connected {[self prune];return _sessions.count>0;}
- (void)sendControls:(NSArray<NSDictionary*>*)channels enabled:(BOOL)enabled {
    [self prune];for(NSString *session in _sessions){
        NSMutableArray *filtered=[NSMutableArray array];
        for(NSDictionary *channel in channels)if([channel[@"session"] isEqual:session]&&[channel[@"tabId"] isKindOfClass:NSNumber.class]){
            NSArray *eq=[channel[@"eq"] isKindOfClass:NSArray.class]?channel[@"eq"]:@[];if(eq.count!=3)continue;
            float gain=[channel[@"gain"] floatValue];if(!isfinite(gain))gain=1;NSMutableArray *cleanEQ=[NSMutableArray array];for(id number in eq){float db=[number respondsToSelector:@selector(floatValue)]?[number floatValue]:0;if(!isfinite(db))db=0;[cleanEQ addObject:@(fmaxf(-18,fminf(18,db)))];}
            [filtered addObject:@{@"tabId":channel[@"tabId"],@"gain":@(fmaxf(0,fminf(1,gain))),@"muted":@([channel[@"muted"] boolValue]),@"eq":cleanEQ}];
        }
        NSDictionary *payload=@{@"type":@"controls",@"session":session,@"channels":filtered,@"enabled":@(enabled)};
        NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];if(!data)continue;
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:TXControlsNotification object:session userInfo:@{@"json":[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]} deliverImmediately:YES];
    }
}
+ (BOOL)selfCheck {
    TXBrowserBridge *bridge=[TXBrowserBridge new];__block int changes=0;bridge.changed=^{changes++;};
    NSDictionary *(^packet)(float)=^NSDictionary*(float peak){return @{@"type":@"tabs",@"session":@"fixture",@"tabs":@[@{@"id":@7,@"title":@"채널 검사",@"host":@"example.invalid",@"active":@YES,@"captured":@YES,@"peak":@(peak)}]};};
    void (^feed)(NSDictionary*)=^(NSDictionary *p){NSData *d=[NSJSONSerialization dataWithJSONObject:p options:0 error:nil];[bridge received:[NSNotification notificationWithName:TXTabsNotification object:nil userInfo:@{@"json":[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]}]];};
    feed(packet(0.1));if(!bridge.connected||bridge.tabs.count!=1||changes!=1)return NO;
    feed(packet(0.4));if(changes!=1||fabsf([bridge.tabs[0][@"peak"] floatValue]-0.4f)>0.001f)return NO;
    feed(@{@"type":@"tabs",@"session":@"fixture",@"tabs":@[@{@"id":@7,@"title":@"검사",@"active":NSNull.null,@"captured":NSNull.null}]});
    if([bridge.tabs[0][@"captured"] boolValue])return NO;
    feed(@{@"type":@"tabs",@"session":@"fixture",@"tabs":@[],@"disconnected":@YES});
    return !bridge.connected&&bridge.tabs.count==0;
}
- (void)dealloc{[self stop];}
@end

BOOL TXRunBrowserSelfCheck(void) { return [TXBrowserBridge selfCheck]; }
