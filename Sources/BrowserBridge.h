#import <Foundation/Foundation.h>

// 오디오는 브라우저 메모리에서 처리합니다. 탭 제목·도메인과 제어 값만 로컬 브리지로 전달합니다.
@interface TXBrowserBridge : NSObject
@property(nonatomic,readonly) NSArray<NSDictionary*> *tabs;
@property(nonatomic,readonly) BOOL connected;
@property(nonatomic,copy) void (^changed)(void);
- (void)start;
- (void)stop;
// tab: id, session, title, host, active, captured, peak
// control: tabId, session, gain, muted, eq:[low,mid,high]
- (void)sendControls:(NSArray<NSDictionary*>*)channels enabled:(BOOL)enabled;
@end

BOOL TXRunBrowserSelfCheck(void);
