#import <Foundation/Foundation.h>
#import "BrowserOrigin.h"
#import <signal.h>
#import <unistd.h>

@interface TXNativeHost:NSObject
@property(nonatomic,copy) NSString *session;
@property(nonatomic,strong) NSLock *outputLock;
@property(nonatomic) BOOL profileBound;
- (void)send:(NSDictionary*)message;
- (void)controls:(NSNotification*)note;
- (void)receive:(NSDictionary*)message;
@end
@implementation TXNativeHost
- (void)send:(NSDictionary*)message {
    NSData *data=[NSJSONSerialization dataWithJSONObject:message options:0 error:nil];if(!data||data.length>1048576)return;
    uint32_t size=(uint32_t)data.length;[self.outputLock lock];BOOL ok=fwrite(&size,1,4,stdout)==4&&fwrite(data.bytes,1,size,stdout)==size&&fflush(stdout)==0;[self.outputLock unlock];if(!ok)exit(0);
}
- (void)controls:(NSNotification*)note {
    if(![note.object isEqual:self.session])return;NSString *json=note.userInfo[@"json"];if(![json isKindOfClass:NSString.class]||json.length>262144)return;
    NSDictionary *message=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if(![message isKindOfClass:NSDictionary.class]||![message[@"type"] isEqual:@"controls"]||![message[@"session"] isEqual:self.session])return;
    [self send:message];
}
- (void)receive:(NSDictionary*)message {
    if(![message isKindOfClass:NSDictionary.class]||![message[@"type"] isEqual:@"tabs"]||![message[@"tabs"] isKindOfClass:NSArray.class])return;
    if(!self.profileBound){
        NSString *profile=message[@"profileSession"];
        if([profile isKindOfClass:NSString.class]&&[[NSUUID alloc] initWithUUIDString:profile]){self.session=profile;self.profileBound=YES;}
    }
    NSMutableDictionary *payload=[message mutableCopy];payload[@"session"]=self.session;[payload removeObjectForKey:@"profileSession"];
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];if(!data||data.length>262144)return;
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"local.tx6mac.browser.tabs" object:self.session userInfo:@{@"json":[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]} deliverImmediately:YES];
}
@end

int main(int argc,const char *argv[]) {@autoreleasepool {
    // Chrome의 허용된 확장 원본만 로컬 브리지에 연결합니다.
    if(argc<2||![[NSString stringWithUTF8String:argv[1]] isEqual:TX_EXTENSION_ORIGIN])return 1;
    signal(SIGPIPE,SIG_IGN);TXNativeHost *host=[TXNativeHost new];host.session=NSUUID.UUID.UUIDString;host.outputLock=[NSLock new];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:host selector:@selector(controls:) name:@"local.tx6mac.browser.controls" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        while(YES){@autoreleasepool{
            uint32_t length=0;if(fread(&length,1,4,stdin)!=4)break;if(!length||length>262144)break;
            NSMutableData *data=[NSMutableData dataWithLength:length];size_t have=0;
            while(have<length){size_t n=fread((char*)data.mutableBytes+have,1,length-have,stdin);if(!n)break;have+=n;}if(have!=length)break;
            id message=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];dispatch_async(dispatch_get_main_queue(),^{[host receive:message];});
        }}
        dispatch_async(dispatch_get_main_queue(),^{[host receive:@{@"type":@"tabs",@"tabs":@[],@"disconnected":@YES}];exit(0);});
    });
    [[NSRunLoop mainRunLoop] run];
}return 0;}
