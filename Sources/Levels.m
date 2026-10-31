#import "Levels.h"
#import "Localization.h"
#import <math.h>

TXLevelSnapshot TXReadLevels(TXRenderState *s,BOOL audioReady,BOOL requestedRunning,BOOL monitorSelected,BOOL monitoring) {
    TXLevelSnapshot v={0};v.audioReady=audioReady;v.requestedRunning=requestedRunning;v.monitorSelected=monitorSelected;if(!s)return v;
    v.canReset=audioReady&&requestedRunning&&atomic_load_explicit(&s->callbacks,memory_order_relaxed)>0;
    v.resetApplied=atomic_load_explicit(&s->levelResetApplied,memory_order_acquire);
    v.resetRequested=atomic_load_explicit(&s->levelResetRequested,memory_order_relaxed);
    for(int i=0;i<6;i++){v.peak[i]=atomic_load_explicit(&s->peak[i],memory_order_relaxed);v.hold[i]=atomic_load_explicit(&s->channelPeakHold[i],memory_order_relaxed);v.over[i]=atomic_load_explicit(&s->channelOver[i],memory_order_relaxed);v.available[i]=v.canReset;}
    v.peak[6]=atomic_load_explicit(&s->mainPreLimiterPeak,memory_order_relaxed);v.hold[6]=atomic_load_explicit(&s->mainPreLimiterHold,memory_order_relaxed);v.gainReductionDB[0]=atomic_load_explicit(&s->mainGainReductionDB,memory_order_relaxed);v.available[6]=v.canReset;
    v.peak[7]=atomic_load_explicit(&s->monitorPreLimiterPeak,memory_order_relaxed);v.hold[7]=atomic_load_explicit(&s->monitorPreLimiterHold,memory_order_relaxed);v.gainReductionDB[1]=atomic_load_explicit(&s->monitorGainReductionDB,memory_order_relaxed);v.available[7]=v.canReset&&monitorSelected&&monitoring;
    v.over[6]=v.hold[6]>1;v.over[7]=v.hold[7]>1;return v;
}
NSString *TXLevelDBFS(float peak) {return !isfinite(peak)||peak<=0?@"−∞":peak<1e-6f?@"< −120":[NSString stringWithFormat:@"%.1f",20*log10f(peak)];}
BOOL TXLevelIsLimiting(float reductionDB) {return isfinite(reductionDB)&&reductionDB>-20*log10f(.999f);}
NSDictionary<NSString*,id> *TXLevelRowDisplay(TXLevelSnapshot v,NSUInteger row) {
    if(row>=8)return @{};
    if(row<6&&v.unsupported[row])return @{@"peak":@"—",@"hold":@"—",@"status":TXL(@"탭 레벨 측정 미지원"),@"warning":@NO};
    if(!v.available[row])return @{@"peak":@"—",@"hold":@"—",@"status":row==7&&!v.monitorSelected?TXL(@"끔"):!v.requestedRunning?TXL(@"중지"):TXL(@"연결 대기"),@"warning":@NO};
    BOOL pending=v.resetRequested!=v.resetApplied,over=v.over[row]&&!pending;NSString *status=over?@"OVER":@"—";BOOL limiting=NO;
    if(row>=6){float gr=v.gainReductionDB[row-6];gr=isfinite(gr)&&gr>0?gr:0;limiting=TXLevelIsLimiting(gr);status=[NSString stringWithFormat:@"%@%@GR %.3f dB",over?@"OVER · ":@"",limiting?@"LIMIT · ":@"",gr];}
    return @{@"peak":TXLevelDBFS(v.peak[row]),@"hold":pending?@"—":TXLevelDBFS(v.hold[row]),@"status":status,@"warning":@(over||limiting)};
}
static NSString *LevelResetStatus(TXLevelSnapshot v) {return !v.canReset?TXL(@"오디오 실행 후 최고값을 초기화할 수 있습니다."):v.resetRequested!=v.resetApplied?TXL(@"최고값 초기화 대기"):TXL(@"OVER: 최고 피크 초과 기록 · LIMIT: 현재 리미터 감쇄");}
static NSColor *LevelColor(unsigned hex) {return [NSColor colorWithSRGBRed:((hex>>16)&255)/255.0 green:((hex>>8)&255)/255.0 blue:(hex&255)/255.0 alpha:1];}
static NSTextField *LevelLabel(NSString *text,NSRect frame,CGFloat size,BOOL mono) {
    NSTextField *label=[NSTextField labelWithString:text];label.frame=frame;label.font=mono?[NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular]:[NSFont systemFontOfSize:size];label.textColor=LevelColor(0x252625);label.lineBreakMode=NSLineBreakByTruncatingTail;return label;
}
@implementation TXLevelsController {
    NSPanel *_panel;TXRenderState *_state;TXLevelSnapshot _snapshot;NSArray<NSString*> *_names;NSArray<NSArray<NSTextField*>*> *_rows;NSButton *_reset;NSTextField *_resetStatus;
}
- (instancetype)initWithRenderState:(TXRenderState*)state {if((self=[super initWithWindow:nil])){_state=state;[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:) name:TXLanguageDidChangeNotification object:nil];}return self;}
- (void)languageChanged:(NSNotification*)note {if(!_panel)return;BOOL visible=self.window.visible;NSRect frame=self.window.frame;[self close];[self buildPanel];[self.window setFrame:frame display:NO];[self refreshLabels];if(visible)[super showWindow:nil];}
- (NSButton*)prepareResetButton {
    _reset=self.resetButton?:[NSButton buttonWithTitle:@"" target:nil action:NULL];_reset.frame=NSMakeRect(20,24,170,30);_reset.title=TXL(@"최고값 초기화");_reset.target=self;_reset.action=@selector(resetPeaks:);return _reset;
}
- (void)buildPanel {
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,760,470) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];panel.title=TXL(@"레벨");panel.releasedWhenClosed=NO;panel.backgroundColor=LevelColor(0xD8D9D4);panel.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];_panel=panel;self.window=panel;NSView *view=panel.contentView;
    NSArray *headers=@[TXL(@"트랙 / 출력"),TXL(@"현재 피크 (dBFS)"),TXL(@"최고 피크 (dBFS)"),TXL(@"상태")];CGFloat x[]={20,254,378,502},width[]={224,114,114,238};for(int c=0;c<4;c++)[view addSubview:LevelLabel(headers[c],NSMakeRect(x[c],422,width[c],22),11,NO)];
    NSMutableArray *rows=[NSMutableArray array];for(int r=0;r<8;r++){NSMutableArray *fields=[NSMutableArray array];for(int c=0;c<4;c++){NSTextField *field=LevelLabel(@"",NSMakeRect(x[c],388-r*33,width[c],24),11,c!=0);if(c==1||c==2)field.alignment=NSTextAlignmentRight;[view addSubview:field];[fields addObject:field];}[rows addObject:fields];}_rows=rows;
    NSTextField *note=LevelLabel(TXL(@"CH: EQ·음량·음소거 후, MASTER·출력 경로 전. MAIN/MONITOR: 리미터 전 샘플 피크. 미지정 앱은 MAIN에 포함됩니다."),NSMakeRect(20,82,720,52),11,NO);note.maximumNumberOfLines=3;note.lineBreakMode=NSLineBreakByWordWrapping;[view addSubview:note];
    [view addSubview:[self prepareResetButton]];_resetStatus=LevelLabel(@"",NSMakeRect(206,27,534,23),11,NO);[view addSubview:_resetStatus];[panel center];
}
- (void)showWindow:(id)sender {if(!_panel)[self buildPanel];[self refreshLabels];[super showWindow:sender];}
- (void)updateSnapshot:(TXLevelSnapshot)snapshot channelNames:(NSArray<NSString*>*)names {_snapshot=snapshot;_names=[names copy];if(_panel)[self refreshLabels];}
- (BOOL)hasPanel {return _panel!=nil;}
- (void)refreshLabels {
    if(!_panel)return;
    for(NSUInteger r=0;r<8;r++){NSArray *fields=_rows[r];NSString *name=r<6?[NSString stringWithFormat:@"CH %02lu · %@",(unsigned long)r+1,_names.count>r?_names[r]:TXL(@"앱 미지정")]:r==6?@"MAIN":@"MONITOR";NSTextField *title=fields[0];title.stringValue=name;title.toolTip=name;NSDictionary *display=TXLevelRowDisplay(_snapshot,r);for(NSUInteger c=1;c<4;c++){NSTextField *field=fields[c];field.stringValue=display[@[@"",@"peak",@"hold",@"status"][c]];field.accessibilityLabel=[name stringByAppendingFormat:@" · %@",@[TXL(@"트랙 / 출력"),TXL(@"현재 피크 (dBFS)"),TXL(@"최고 피크 (dBFS)"),TXL(@"상태")][c]];field.toolTip=field.stringValue;field.textColor=c==3&&[display[@"warning"] boolValue]?LevelColor(0xF36B2F):LevelColor(0x252625);}}
    BOOL pending=_snapshot.resetRequested!=_snapshot.resetApplied;_reset.enabled=_snapshot.canReset&&!pending;_resetStatus.stringValue=LevelResetStatus(_snapshot);_resetStatus.toolTip=_resetStatus.stringValue;
}
- (void)resetPeaks:(id)sender {if(!_state||!_snapshot.canReset)return;TXRequestLevelPeakReset(_state);_snapshot.resetRequested=atomic_load_explicit(&_state->levelResetRequested,memory_order_relaxed);[self refreshLabels];}
@end

BOOL TXRunLevelsSelfCheck(void) {
    if(![TXLevelDBFS(nextafterf(1e-6f,0)) isEqual:@"< −120"]||![TXLevelDBFS(1e-6f) isEqual:@"-120.0"]||![TXLevelDBFS(nextafterf(1e-6f,1)) isEqual:@"-120.0"]||![TXLevelDBFS(1e-20f) isEqual:@"< −120"])return NO;
    if(![TXLevelDBFS(0) isEqual:@"−∞"]||![TXLevelDBFS(1) isEqual:@"0.0"]||![TXLevelDBFS(2) isEqual:@"6.0"]||TXLevelIsLimiting(0)||TXLevelIsLimiting(-20*log10f(.999f))||!TXLevelIsLimiting(-20*log10f(.998f)))return NO;
    TXRenderState state={0};atomic_store(&state.callbacks,1);atomic_store(&state.peak[0],.5f);atomic_store(&state.channelPeakHold[0],2);atomic_store(&state.channelOver[0],true);atomic_store(&state.mainPreLimiterPeak,1.5f);atomic_store(&state.mainPreLimiterHold,2);atomic_store(&state.mainGainReductionDB,2.5f);atomic_store(&state.monitorPreLimiterPeak,4);atomic_store(&state.monitorPreLimiterHold,4);atomic_store(&state.monitorGainReductionDB,6);
    TXLevelSnapshot v=TXReadLevels(&state,YES,YES,NO,NO);if(![TXLevelRowDisplay(v,0)[@"status"] isEqual:@"OVER"]||![TXLevelRowDisplay(v,6)[@"status"] isEqual:@"OVER · LIMIT · GR 2.500 dB"]||![TXLevelRowDisplay(v,7)[@"status"] isEqual:TXL(@"끔")]||![TXLevelRowDisplay(v,7)[@"peak"] isEqual:@"—"])return NO;
    v=TXReadLevels(&state,YES,YES,YES,NO);if(![TXLevelRowDisplay(v,7)[@"status"] isEqual:TXL(@"연결 대기")])return NO;
    TXLevelsController *controller=[[TXLevelsController alloc] initWithRenderState:&state];NSButton *injected=[NSButton new];controller.resetButton=injected;if([controller prepareResetButton]!=injected||[controller prepareResetButton]!=injected||injected.target!=controller||injected.action!=@selector(resetPeaks:)||![injected.title isEqual:TXL(@"최고값 초기화")])return NO;[controller updateSnapshot:v channelNames:@[@"System",@"Group · 2"]];[controller resetPeaks:nil];uint64_t ticket=atomic_load(&state.levelResetRequested);if(!ticket||[controller hasPanel])return NO;v=TXReadLevels(&state,YES,YES,YES,YES);if(v.resetApplied==ticket||![TXLevelRowDisplay(v,0)[@"hold"] isEqual:@"—"]||![TXLevelRowDisplay(v,6)[@"status"] isEqual:@"LIMIT · GR 2.500 dB"]||atomic_load(&state.mainGainReductionDB)!=2.5f||atomic_load(&state.peak[0])!=.5f)return NO;
    atomic_store(&state.channelPeakHold[0],0);atomic_store(&state.channelOver[0],false);atomic_store_explicit(&state.levelResetApplied,ticket,memory_order_release);v=TXReadLevels(&state,YES,YES,YES,YES);if(v.resetApplied!=ticket||![TXLevelRowDisplay(v,0)[@"hold"] isEqual:@"−∞"]||![TXLevelRowDisplay(v,0)[@"status"] isEqual:@"—"])return NO;
    if(![TXLevelRowDisplay(TXReadLevels(&state,NO,YES,YES,YES),0)[@"status"] isEqual:TXL(@"연결 대기")])return NO;
    TXLevelSnapshot stopped=TXReadLevels(&state,NO,NO,YES,NO);[controller updateSnapshot:stopped channelNames:@[]];uint64_t before=atomic_load(&state.levelResetRequested);[controller resetPeaks:nil];if(atomic_load(&state.levelResetRequested)!=before||![LevelResetStatus(stopped) isEqual:TXL(@"오디오 실행 후 최고값을 초기화할 수 있습니다.")])return NO;if(stopped.canReset||![TXLevelRowDisplay(stopped,6)[@"status"] isEqual:TXL(@"중지")]||![TXLevelRowDisplay(stopped,7)[@"hold"] isEqual:@"—"])return NO;
    atomic_store(&state.callbacks,0);v=TXReadLevels(&state,YES,YES,YES,YES);if(v.canReset||![TXLevelRowDisplay(v,6)[@"status"] isEqual:TXL(@"연결 대기")])return NO;
    v.unsupported[1]=YES;if(![TXLevelRowDisplay(v,1)[@"status"] isEqual:TXL(@"탭 레벨 측정 미지원")]||![TXLevelRowDisplay(v,1)[@"peak"] isEqual:@"—"])return NO;
    printf("TX6Mac level display, limiter threshold and reset acknowledgement: PASS\n");return YES;
}
