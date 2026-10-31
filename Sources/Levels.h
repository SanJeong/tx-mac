#import "TX6.h"

typedef struct {
    float peak[8],hold[8],gainReductionDB[2];
    BOOL over[8],available[8],unsupported[6],audioReady,requestedRunning,monitorSelected,canReset;
    uint64_t resetRequested,resetApplied;
} TXLevelSnapshot;

TXLevelSnapshot TXReadLevels(TXRenderState *state,BOOL audioReady,BOOL requestedRunning,BOOL monitorSelected,BOOL monitoring);
NSString *TXLevelDBFS(float peak);
BOOL TXLevelIsLimiting(float reductionDB);
NSDictionary<NSString*,id> *TXLevelRowDisplay(TXLevelSnapshot snapshot,NSUInteger row);
BOOL TXRunLevelsSelfCheck(void);

@interface TXLevelsController:NSWindowController
@property(nonatomic,strong) NSButton *resetButton;
- (instancetype)initWithRenderState:(TXRenderState*)state;
- (void)updateSnapshot:(TXLevelSnapshot)snapshot channelNames:(NSArray<NSString*>*)names;
@end
