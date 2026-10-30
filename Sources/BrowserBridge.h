#import <Foundation/Foundation.h>

@interface TXBrowserBridge : NSObject
@property(nonatomic,readonly) NSArray<NSDictionary*> *tabs;
@property(nonatomic,readonly) BOOL connected;
@property(nonatomic,copy) void (^changed)(void);
- (void)start;
- (void)stop;
- (void)sendControls:(NSArray<NSDictionary*>*)channels enabled:(BOOL)enabled;
@end

BOOL TXRunBrowserSelfCheck(void);
