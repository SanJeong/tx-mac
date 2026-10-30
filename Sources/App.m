#import "TX6.h"
#import "BrowserBridge.h"
#import <CoreAudioKit/CoreAudioKit.h>
#import <math.h>

static NSColor *Color(unsigned hex) { return [NSColor colorWithSRGBRed:((hex>>16)&255)/255.0 green:((hex>>8)&255)/255.0 blue:(hex&255)/255.0 alpha:1]; }
static NSFont *Mono(CGFloat size,NSFontWeight weight) { return [NSFont monospacedSystemFontOfSize:size weight:weight]; }
static void Text(NSString *s,NSRect frame,NSFont *font,NSColor *color,NSTextAlignment alignment) {
    NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.alignment=alignment;p.lineBreakMode=NSLineBreakByTruncatingTail;
    [s drawInRect:frame withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:p}];
}
static NSTextField *Label(NSString *s,NSRect frame,CGFloat size,BOOL mono) {
    NSTextField *v=[NSTextField labelWithString:s];v.frame=frame;v.font=mono?Mono(size,NSFontWeightRegular):[NSFont systemFontOfSize:size];v.textColor=Color(0x252625);v.lineBreakMode=NSLineBreakByTruncatingTail;return v;
}
@interface TXKey:NSButton
@property(nonatomic) BOOL lightKey;
@end
@implementation TXKey
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty {
    BOOL on=self.state==NSControlStateValueOn,pressed=self.highlighted;NSRect r=NSInsetRect(self.bounds,1,1);
    NSColor *face=self.bezelColor?:Color(on?0xF36B2F:(self.lightKey?0xECECE7:0x30342D));if(pressed)face=Color(0xF36B2F);
    [Color(0x61675C) setFill];[[NSBezierPath bezierPathWithRoundedRect:r xRadius:2 yRadius:2] fill];r.size.height-=3;
    [face setFill];[[NSBezierPath bezierPathWithRoundedRect:r xRadius:2 yRadius:2] fill];
    [Color(self.lightKey||on||self.bezelColor||pressed?0x252625:0xF1F2E9) setFill];
    NSColor *ink=Color(self.lightKey||on||self.bezelColor||pressed?0x252625:0xF1F2E9);CGFloat h=[self.title containsString:@"\n"]?28:17;
    Text(self.title,NSMakeRect(5,NSMidY(r)-h/2,r.size.width-10,h),[self.title containsString:@"\n"]?Mono(9,NSFontWeightSemibold):self.font,ink,NSTextAlignmentCenter);
    if(self.focusRingType!=NSFocusRingTypeNone&&self.window.firstResponder==self){[Color(0x608CA6) setStroke];NSFrameRect(NSInsetRect(self.bounds,0.5,0.5));}
}
@end
@interface TXPopup:NSPopUpButton
@end
@implementation TXPopup
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty {
    NSRect face=NSInsetRect(self.bounds,1,2);[Color(self.enabled?0xECECE7:0xCCD0C5) setFill];[[NSBezierPath bezierPathWithRoundedRect:face xRadius:2 yRadius:2] fill];[Color(0x92998B) setStroke];NSFrameRect(face);
    Text(self.selectedItem.title?:@"",NSMakeRect(8,NSMidY(face)-8,self.bounds.size.width-28,18),self.font?:[NSFont systemFontOfSize:11],Color(0x252625),NSTextAlignmentLeft);
    if(self.enabled){NSBezierPath *triangle=[NSBezierPath bezierPath];[triangle moveToPoint:NSMakePoint(self.bounds.size.width-17,NSMidY(face)-2)];[triangle lineToPoint:NSMakePoint(self.bounds.size.width-10,NSMidY(face)-2)];[triangle lineToPoint:NSMakePoint(self.bounds.size.width-13.5,NSMidY(face)+2)];[triangle closePath];[Color(0x555B51) setFill];[triangle fill];}
}
@end
static NSButton *Button(NSString *title,NSRect frame,id target,SEL action) {
    TXKey *b=[[TXKey alloc] initWithFrame:frame];b.title=title;b.target=target;b.action=action;b.buttonType=NSButtonTypeMomentaryPushIn;b.bordered=NO;b.lightKey=![title containsString:@"MUTE"]&&![title containsString:@"FX "];b.font=[NSFont systemFontOfSize:11 weight:NSFontWeightMedium];return b;
}

@interface TXCanvas:NSView
@property(nonatomic,copy) NSString *connection,*output,*message;
@property(nonatomic) float master;
@property(nonatomic) BOOL running,muted,audioWaiting,limited;
@end
@implementation TXCanvas
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty {
    [Color(0xD8D9D4) setFill];NSRectFill(self.bounds);
    Text(@"TX · MAC",NSMakeRect(24,18,330,37),Mono(29,NSFontWeightBold),Color(0x252625),NSTextAlignmentLeft);
    Text(@"DESKTOP MIXER / 01 OS · 02—06 APPS",NSMakeRect(26,57,590,16),Mono(9,NSFontWeightMedium),Color(0x555953),NSTextAlignmentLeft);
    Text(@"FIELD CONTROL\nUSB + BLE MIDI",NSMakeRect(865,26,168,32),Mono(9,NSFontWeightMedium),Color(0x555953),NSTextAlignmentRight);
    [Color(0xBCC1B5) setFill];NSRectFill(NSMakeRect(850,128,1,648));
    NSRect lcd=NSMakeRect(865,132,167,109);[Color(0x202321) setFill];[[NSBezierPath bezierPathWithRoundedRect:lcd xRadius:3 yRadius:3] fill];NSColor *light=Color(0xE3E7D2);
    Text(self.connection?:@"MIDI WAIT",NSMakeRect(875,141,147,18),Mono(9,NSFontWeightMedium),light,NSTextAlignmentLeft);
    Text(self.output?:@"OUTPUT WAIT",NSMakeRect(875,161,147,18),Mono(9,NSFontWeightRegular),light,NSTextAlignmentLeft);
    Text(self.muted?@"MUTE":[NSString stringWithFormat:@"%03.0f",self.master*100],NSMakeRect(873,185,104,45),Mono(33,NSFontWeightMedium),self.muted?Color(0xF36B2F):light,NSTextAlignmentLeft);
    [Color(self.running?0xF36B2F:0x797D71) setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1009,195,6,6)] fill];
    Text(self.limited?@"LIMIT":(self.running?@"AUDIO":(self.audioWaiting?@"WAIT":@"IDLE")),NSMakeRect(977,211,46,16),Mono(8,NSFontWeightMedium),light,NSTextAlignmentRight);
    [Color(0xA8ABA3) setFill];NSRectFill(NSMakeRect(24,118,1012,1));NSRectFill(NSMakeRect(24,782,1012,1));
    Text(@"FADERS / APP LEVEL     POTS / HIGH · MID · LOW     SELECT / MASTER",NSMakeRect(24,794,1012,16),Mono(9,NSFontWeightMedium),Color(0x555953),NSTextAlignmentLeft);
    Text(self.message?:@"",NSMakeRect(24,817,1012,20),[NSFont systemFontOfSize:11],Color(0x555953),NSTextAlignmentLeft);
}
@end

@interface TXKnob:NSControl
@property(nonatomic) double value;
@property(nonatomic,strong) NSColor *accent;
@property(nonatomic,copy) NSString *caption,*frequency;
@property(nonatomic) BOOL awaitingPickup;
@end
@implementation TXKnob
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)isAccessibilityElement{return YES;}
- (NSString*)accessibilityRole{return NSAccessibilitySliderRole;}
- (id)accessibilityValue{return @(self.value);}
- (NSString*)accessibilityValueDescription{return [NSString stringWithFormat:@"%+.1f dB",self.value];}
- (void)setAccessibilityValue:(id)value{self.value=[value doubleValue];[self sendAction:self.action to:self.target];}
- (id)accessibilityMinValue{return @(-18);}
- (id)accessibilityMaxValue{return @18;}
- (BOOL)accessibilityPerformIncrement{self.value+=0.5;[self sendAction:self.action to:self.target];return YES;}
- (BOOL)accessibilityPerformDecrement{self.value-=0.5;[self sendAction:self.action to:self.target];return YES;}

- (void)setValue:(double)value{_value=fmax(-18,fmin(18,value));self.needsDisplay=YES;NSAccessibilityPostNotification(self,NSAccessibilityValueChangedNotification);}
- (void)drawRect:(NSRect)dirty {
    NSPoint center=NSMakePoint(NSMidX(self.bounds),43);CGFloat r=23;
    Text(self.caption?:@"",NSMakeRect(0,0,self.bounds.size.width,16),Mono(9,NSFontWeightSemibold),Color(0x555953),NSTextAlignmentCenter);
    [Color(0xB4B7AE) setStroke];NSBezierPath *arc=[NSBezierPath bezierPath];arc.lineWidth=3;[arc appendBezierPathWithArcWithCenter:center radius:r+4 startAngle:135 endAngle:405 clockwise:NO];[arc stroke];
    [Color(self.enabled?0xECECE7:0xC5CABC) setFill];NSBezierPath *circle=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x-r,center.y-r,r*2,r*2)];[circle fill];[Color(0x686D63) setStroke];circle.lineWidth=1;[circle stroke];
    double theta=(135+(self.value+18)/36*270)*M_PI/180;
    NSPoint tip=NSMakePoint(center.x+cos(theta)*(r-5),center.y+sin(theta)*(r-5));
    NSBezierPath *indicator=[NSBezierPath bezierPath];indicator.lineWidth=3;indicator.lineCapStyle=NSLineCapStyleRound;[indicator moveToPoint:center];[indicator lineToPoint:tip];if([self.caption isEqual:@"LOW"]){indicator.lineWidth=5;[Color(0x555B51) setStroke];[indicator stroke];indicator.lineWidth=2;}[self.accent?:Color(0x252625) setStroke];[indicator stroke];
    Text([NSString stringWithFormat:@"%+.1f dB",self.value],NSMakeRect(0,72,self.bounds.size.width,16),Mono(10,NSFontWeightMedium),Color(0x252625),NSTextAlignmentCenter);

    if(self.awaitingPickup){[Color(0xF36B2F) setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(self.bounds.size.width-12,3,5,5)] fill];}
}
- (void)mouseDown:(NSEvent*)event {
    if(event.clickCount==2){self.value=0;[self sendAction:self.action to:self.target];return;}
    NSPoint start=[self convertPoint:event.locationInWindow fromView:nil];double initial=self.value;
    while(YES){NSEvent *e=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];if(e.type==NSEventTypeLeftMouseUp)break;NSPoint p=[self convertPoint:e.locationInWindow fromView:nil];self.value=initial+(start.y-p.y)*((e.modifierFlags&NSEventModifierFlagShift)?0.025:0.12);[self sendAction:self.action to:self.target];}
}
- (void)scrollWheel:(NSEvent*)event{self.value+=event.scrollingDeltaY*(event.hasPreciseScrollingDeltas?0.05:0.5);[self sendAction:self.action to:self.target];}
- (void)keyDown:(NSEvent*)event{if(event.keyCode==126||event.keyCode==124)self.value+=0.5;else if(event.keyCode==125||event.keyCode==123)self.value-=0.5;else{[super keyDown:event];return;}[self sendAction:self.action to:self.target];}
@end

@interface TXFader:NSControl
@property(nonatomic) double value,peak;
@property(nonatomic) BOOL muted,rotary;
@property(nonatomic) BOOL awaitingPickup;
@end
@implementation TXFader
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)isAccessibilityElement{return YES;}
- (NSString*)accessibilityRole{return NSAccessibilitySliderRole;}
- (id)accessibilityValue{return @(self.value);}
- (NSString*)accessibilityValueDescription{return [NSString stringWithFormat:@"%.0f%%",self.value*100];}
- (void)setAccessibilityValue:(id)value{self.value=[value doubleValue];[self sendAction:self.action to:self.target];}
- (id)accessibilityMinValue{return @0;}
- (id)accessibilityMaxValue{return @1;}
- (BOOL)accessibilityPerformIncrement{self.value+=0.01;[self sendAction:self.action to:self.target];return YES;}
- (BOOL)accessibilityPerformDecrement{self.value-=0.01;[self sendAction:self.action to:self.target];return YES;}

- (void)setValue:(double)value{_value=fmax(0,fmin(1,value));self.needsDisplay=YES;NSAccessibilityPostNotification(self,NSAccessibilityValueChangedNotification);}
- (void)drawRect:(NSRect)dirty {
    if(self.rotary){NSPoint center=NSMakePoint(NSMidX(self.bounds),63);CGFloat r=46;[Color(0xECECE7) setFill];NSBezierPath *cap=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x-r,center.y-r,r*2,r*2)];[cap fill];[Color(0x747C6B) setStroke];cap.lineWidth=1.2;[cap stroke];
        NSBezierPath *ring=[NSBezierPath bezierPath];ring.lineWidth=3;[ring appendBezierPathWithArcWithCenter:center radius:r+6 startAngle:135 endAngle:405 clockwise:NO];[Color(0xA5AE9B) setStroke];[ring stroke];
        double angle=(135+self.value*270)*M_PI/180;NSBezierPath *pointer=[NSBezierPath bezierPath];pointer.lineWidth=4;pointer.lineCapStyle=NSLineCapStyleRound;[pointer moveToPoint:center];[pointer lineToPoint:NSMakePoint(center.x+cos(angle)*(r-9),center.y+sin(angle)*(r-9))];[Color(0x252625) setStroke];[pointer stroke];Text([NSString stringWithFormat:@"%.0f%%",self.value*100],NSMakeRect(0,127,self.bounds.size.width,22),Mono(15,NSFontWeightMedium),Color(0x252625),NSTextAlignmentCenter);return;}
    CGFloat x=NSMidX(self.bounds)-7,top=17,bottom=self.bounds.size.height-33,height=bottom-top;
    [Color(0x555B51) setFill];[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x-2,top,4,height) xRadius:2 yRadius:2] fill];
    for(int i=0;i<=10;i++){CGFloat y=top+height*i/10;[Color(0xA3A89C) setFill];NSRectFill(NSMakeRect(x-13,y,5,1));if(i%5==0)Text(i==0?@"0":(i==5?@"−6":@"−∞"),NSMakeRect(x-40,y-6,24,14),Mono(7,NSFontWeightRegular),Color(0x666B61),NSTextAlignmentRight);}
    for(int i=0;i<12;i++){BOOL lit=!self.muted&&self.peak>pow(10,(-42+i*3.5)/20);NSColor *c=lit?Color(i>9?0xF36B2F:0x73845C):Color(0xB6BBB0);[c setFill];NSRectFill(NSMakeRect(x+24,bottom-7-i*(height-7)/12,5,6));}
    CGFloat y=top+(1-self.value)*height;[Color(self.muted||!self.enabled?0xB7BBB0:0xECECE7) setFill];NSBezierPath *cap=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x-12,y-10,25,20) xRadius:2 yRadius:2];[cap fill];[Color(0x555B51) setStroke];[cap stroke];[Color(self.awaitingPickup?0xF36B2F:0x252625) setFill];NSRectFill(NSMakeRect(x-8,y,17,2));
    Text([NSString stringWithFormat:@"%.0f%%",self.value*100],NSMakeRect(0,self.bounds.size.height-18,self.bounds.size.width,16),Mono(11,NSFontWeightSemibold),Color(0x252625),NSTextAlignmentCenter);
}
- (void)updateFromEvent:(NSEvent*)event{NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];self.value=1-(p.y-17)/(self.bounds.size.height-50);[self sendAction:self.action to:self.target];}
- (void)mouseDown:(NSEvent*)event{if(self.rotary){NSPoint start=[self convertPoint:event.locationInWindow fromView:nil];double initial=self.value;while(YES){NSEvent *e=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];if(e.type==NSEventTypeLeftMouseUp)break;NSPoint p=[self convertPoint:e.locationInWindow fromView:nil];self.value=initial+(start.y-p.y)*0.004;[self sendAction:self.action to:self.target];}return;}[self updateFromEvent:event];while(YES){NSEvent *e=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];if(e.type==NSEventTypeLeftMouseUp)break;[self updateFromEvent:e];}}
- (void)scrollWheel:(NSEvent*)event{self.value+=event.scrollingDeltaY*(event.hasPreciseScrollingDeltas?0.001:0.02);[self sendAction:self.action to:self.target];}
- (void)keyDown:(NSEvent*)event{if(event.keyCode==126||event.keyCode==124)self.value+=0.01;else if(event.keyCode==125||event.keyCode==123)self.value-=0.01;else{[super keyDown:event];return;}[self sendAction:self.action to:self.target];}
@end

@interface TXChannel:NSView
@property(nonatomic) NSInteger slot;
@property(nonatomic,strong) NSPopUpButton *assignment;
@property(nonatomic,strong) NSArray<TXKnob*> *knobs;
@property(nonatomic,strong) TXFader *fader;
@property(nonatomic,strong) NSButton *mute;
@property(nonatomic,strong) NSTextField *activity;
@end
@implementation TXChannel
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty {
    [Color(0xBDC1B7) setFill];NSRectFill(NSMakeRect(self.bounds.size.width-1,0,1,self.bounds.size.height));
    Text([NSString stringWithFormat:@"%02ld",(long)self.slot+1],NSMakeRect(10,8,self.bounds.size.width-20,35),Mono(27,NSFontWeightMedium),Color(0x252625),NSTextAlignmentLeft);
    Text(self.slot==0?@"OS / SOUND":@"APP / INPUT",NSMakeRect(10,43,self.bounds.size.width-20,14),Mono(8,NSFontWeightMedium),Color(0x666B61),NSTextAlignmentLeft);
    Text(@"3-BAND EQ  ±18 dB",NSMakeRect(0,93,self.bounds.size.width,14),Mono(8,NSFontWeightRegular),Color(0x666B61),NSTextAlignmentCenter);
    Text(@"LEVEL",NSMakeRect(0,385,self.bounds.size.width,15),Mono(8,NSFontWeightMedium),Color(0x666B61),NSTextAlignmentCenter);
}
@end

// 앱이 다른 물리 트랙으로 이동해도 음량·EQ·음소거는 해당 앱을 따라갑니다.
static NSDictionary<NSString*,NSDictionary*> *TXSnapshotAssignments(NSArray<NSString*> *assignments,TXRenderState *state) {
    NSMutableDictionary *snapshots=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<MIN(assignments.count,6);i++){NSString *key=assignments[i];if(!key.length)continue;snapshots[key]=@{@"gain":@(atomic_load(&state->gain[i])),@"muted":@(atomic_load(&state->muted[i])),@"eq":@[@(atomic_load(&state->eq[i][0])),@(atomic_load(&state->eq[i][1])),@(atomic_load(&state->eq[i][2]))]};}
    return snapshots;
}
static void TXApplyAssignmentSnapshots(NSArray<NSString*> *assignments,NSDictionary<NSString*,NSDictionary*> *snapshots,TXRenderState *state) {
    for(NSUInteger i=0;i<MIN(assignments.count,6);i++){
        NSDictionary *saved=snapshots[assignments[i]];atomic_store(&state->gain[i],saved?[saved[@"gain"] floatValue]:1);atomic_store(&state->muted[i],saved?[saved[@"muted"] boolValue]:false);
        for(int b=0;b<3;b++)atomic_store(&state->eq[i][b],saved?[saved[@"eq"][b] floatValue]:0);atomic_store(&state->peak[i],0);
    }
}
static NSArray<NSString*> *TXOrderedAssignments(NSArray<NSString*> *assignments,NSSet<NSString*> *active,NSDictionary<NSString*,NSDate*> *lastActive,NSSet<NSString*> *observedActive,NSDate *now) {
    NSArray *tail=[assignments subarrayWithRange:NSMakeRange(1,5)];
    NSInteger (^priority)(NSString*)=^NSInteger(NSString *key){if(!key.length)return 2;BOOL recent=[observedActive containsObject:key]&&lastActive[key]&&[now timeIntervalSinceDate:lastActive[key]]<3;return [active containsObject:key]||recent?0:1;};
    NSArray *ordered=[tail sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *a,NSString *b){NSInteger pa=priority(a),pb=priority(b);return pa<pb?NSOrderedAscending:(pa>pb?NSOrderedDescending:NSOrderedSame);}];
    NSMutableArray *result=[NSMutableArray arrayWithObject:@"local.tx6mac.system-sounds"];[result addObjectsFromArray:ordered];return result;
}
static BOOL TXRunUIModelSelfCheck(void) {
    NSArray *before=@[@"local.tx6mac.system-sounds",@"Claude",@"Xcode",@"Youna",@"",@""];TXRenderState state={0};
    for(int i=0;i<6;i++)atomic_store(&state.gain[i],1);atomic_store(&state.gain[0],0.25);atomic_store(&state.gain[3],0.42);atomic_store(&state.muted[3],true);atomic_store(&state.eq[3][0],-3);atomic_store(&state.eq[3][1],5);atomic_store(&state.eq[3][2],2);
    NSDictionary *snapshots=TXSnapshotAssignments(before,&state);NSDate *now=[NSDate dateWithTimeIntervalSince1970:100];NSSet *active=[NSSet setWithObject:@"Youna"];
    NSArray *ordered=TXOrderedAssignments(before,active,@{},[NSSet set],now);
    if(![ordered isEqual:@[@"local.tx6mac.system-sounds",@"Youna",@"Claude",@"Xcode",@"",@""]])return NO;
    TXApplyAssignmentSnapshots(ordered,snapshots,&state);
    if(fabs(atomic_load(&state.gain[1])-0.42)>0.000001||!atomic_load(&state.muted[1])||atomic_load(&state.eq[1][0])!=-3||atomic_load(&state.eq[1][1])!=5||atomic_load(&state.eq[1][2])!=2||atomic_load(&state.gain[0])!=0.25)return NO;
    atomic_store(&state.gain[4],0.1);atomic_store(&state.muted[4],true);atomic_store(&state.eq[4][2],18);NSMutableArray *withNew=[ordered mutableCopy];withNew[4]=@"New App";TXApplyAssignmentSnapshots(withNew,snapshots,&state);
    if(atomic_load(&state.gain[4])!=1||atomic_load(&state.muted[4])||atomic_load(&state.eq[4][2])!=0)return NO;
    NSArray *held=TXOrderedAssignments(before,active,@{@"Claude":[now dateByAddingTimeInterval:-2]},[NSSet setWithObject:@"Claude"],now);
    if(![held[1] isEqual:@"Claude"]||![held[2] isEqual:@"Youna"])return NO;
    NSArray *expired=TXOrderedAssignments(before,active,@{@"Claude":[now dateByAddingTimeInterval:-4]},[NSSet setWithObject:@"Claude"],now);
    return [expired isEqual:ordered];
}

// TX-6는 홈과 메뉴에서 같은 CC31을 보내므로, 확인된 홈 화면에서만 조절을 허용합니다.
typedef struct { BOOL suspended,shiftDown,shiftSoloCandidate,shiftUsed;UInt8 reason; } TXDeviceContext;
static BOOL TXConsumeDeviceContext(TXDeviceContext *context,UInt8 cc,UInt8 value) {
    BOOL pressed=value>=64;
    if(cc==35){
        if(pressed){if(!context->shiftDown){context->shiftDown=YES;context->shiftSoloCandidate=context->suspended;context->shiftUsed=NO;}}
        else if(context->shiftDown){BOOL home=context->shiftSoloCandidate&&!context->shiftUsed;context->shiftDown=NO;context->shiftSoloCandidate=NO;context->shiftUsed=NO;if(home){context->suspended=NO;context->reason=0;}}
        return YES;
    }
    if(context->shiftDown){context->shiftUsed=YES;if(pressed&&((cc>=25&&cc<=34)||cc==36||cc==37)){context->suspended=YES;context->reason=cc;}return YES;}
    if(pressed&&(cc==32||cc==36||cc==37)){context->suspended=YES;context->reason=cc;return YES;}
    return context->suspended;
}
static BOOL TXRunDeviceContextSelfCheck(void) {
    TXDeviceContext context={0};
    if(!TXConsumeDeviceContext(&context,35,127)||!TXConsumeDeviceContext(&context,32,127)||!context.suspended)return NO;
    if(!TXConsumeDeviceContext(&context,31,1)||!TXConsumeDeviceContext(&context,33,127)||!TXConsumeDeviceContext(&context,34,127))return NO;
    TXConsumeDeviceContext(&context,35,0);if(!context.suspended)return NO;
    TXConsumeDeviceContext(&context,35,127);TXConsumeDeviceContext(&context,35,0);if(context.suspended||TXConsumeDeviceContext(&context,31,1))return NO;
    TXConsumeDeviceContext(&context,32,127);if(!TXConsumeDeviceContext(&context,31,127))return NO;
    TXConsumeDeviceContext(&context,35,127);TXConsumeDeviceContext(&context,35,0);if(context.suspended)return NO;
    TXConsumeDeviceContext(&context,36,127);if(!context.suspended||!TXConsumeDeviceContext(&context,25,127))return NO;
    TXConsumeDeviceContext(&context,35,127);TXConsumeDeviceContext(&context,35,0);
    TXConsumeDeviceContext(&context,35,127);TXConsumeDeviceContext(&context,25,127);TXConsumeDeviceContext(&context,35,0);if(!context.suspended)return NO;
    TXConsumeDeviceContext(&context,35,127);TXConsumeDeviceContext(&context,31,1);TXConsumeDeviceContext(&context,35,0);if(!context.suspended)return NO;
    TXConsumeDeviceContext(&context,35,127);TXConsumeDeviceContext(&context,35,0);
    if(context.suspended||TXConsumeDeviceContext(&context,25,127))return NO;
    TXConsumeDeviceContext(&context,37,127);if(!context.suspended)return NO;
    context=(TXDeviceContext){.suspended=YES};return TXConsumeDeviceContext(&context,31,1);
}

@interface TXHUDPanel:NSPanel
@end
@implementation TXHUDPanel
- (BOOL)canBecomeKeyWindow{return NO;}
- (BOOL)canBecomeMainWindow{return NO;}
@end
@interface TXHUDView:NSView
@property(nonatomic,copy) NSString *heading,*application,*message;
@property(nonatomic) CGFloat arrowX;
@end
@implementation TXHUDView
- (BOOL)isFlipped{return YES;}
- (BOOL)isOpaque{return NO;}
- (void)drawRect:(NSRect)dirty {
    NSColor *background=Color(0x202321);[background setFill];NSBezierPath *body=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0,8,self.bounds.size.width,self.bounds.size.height-8) xRadius:5 yRadius:5];[body fill];
    NSBezierPath *arrow=[NSBezierPath bezierPath];[arrow moveToPoint:NSMakePoint(self.arrowX,0)];[arrow lineToPoint:NSMakePoint(self.arrowX-7,9)];[arrow lineToPoint:NSMakePoint(self.arrowX+7,9)];[arrow closePath];[arrow fill];
    Text(self.heading?:@"TX · MAC",NSMakeRect(16,18,self.bounds.size.width-32,14),Mono(8,NSFontWeightSemibold),Color(0xF36B2F),NSTextAlignmentLeft);
    Text(self.application?:@"",NSMakeRect(16,36,self.bounds.size.width-32,20),[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],Color(0xE3E7D2),NSTextAlignmentLeft);
    Text(self.message?:@"",NSMakeRect(16,61,self.bounds.size.width-32,31),Mono(self.message.length>17?15:21,NSFontWeightMedium),Color(0xE3E7D2),NSTextAlignmentLeft);
}
@end

@interface TXApp:NSObject<NSApplicationDelegate,NSWindowDelegate,NSMenuDelegate>
@end
@implementation TXApp {
    TXAudio *_audio;TXMIDI *_midi;TXBrowserBridge *_browser;NSDate *_lastBrowserSend;NSTextField *_browserLabel;NSWindow *_window;TXCanvas *_canvas;NSStatusItem *_statusItem;
    NSMenu *_statusMenu;CABTLEMIDIWindowController *_bluetooth;
    NSPopUpButton *_outputMenu,*_transportMenu;NSButton *_startButton,*_pickupButton,*_invertButton,*_masterMute,*_soundKey,*_autoButton,*_hudButton;TXHUDPanel *_hud;TXHUDView *_hudView;NSTimer *_hudDismiss;NSDictionary *_pendingHUD;BOOL _hudEnabled,_statusMenuTracking;NSPopover *_settingsPopover;TXDeviceContext _deviceContext;NSTextField *_deviceContextLabel,*_calibrationInput;NSButton *_resumeDeviceButton;
    TXFader *_masterFader;NSArray<TXChannel*> *_channels;NSTextField *_remainderLabel;
    NSArray<NSDictionary*> *_outputs,*_processes;NSMutableArray<NSString*> *_assignments;NSString *_outputUID,*_signature,*_statusFile,*_lastMIDI;
    NSTimer *_poll,*_meter;BOOL _desiredRunning,_isBuilding,_pickup,_invert,_autoAssign;NSInteger _overflowCount;NSMutableDictionary<NSString*,NSDate*> *_lastActive;NSMutableSet<NSString*> *_observedActive;NSString *_outputMenuSignature,*_processMenuSignature;NSDate *_startedAt,*_progressAt;uint64_t _progressFrames;BOOL _latched[6][4];double _previous[6][4];BOOL _havePrevious[6][4];
    NSMenuItem *_masterMenuLabel;NSSlider *_menuMaster;NSMutableArray<NSMenuItem*> *_muteItems;NSDate *_lastSave,*_lastLimitDate;uint64_t _lastLimitedFrames;
}
- (void)applicationDidFinishLaunching:(NSNotification*)note {
    _audio=[TXAudio new];_midi=[TXMIDI new];_browser=[TXBrowserBridge new];_lastActive=[NSMutableDictionary dictionary];_observedActive=[NSMutableSet set];_assignments=[NSMutableArray array];_outputs=@[];_processes=@[];_lastMIDI=@"아직 조작 신호가 없습니다";_deviceContext.suspended=YES;
    NSArray *args=NSProcessInfo.processInfo.arguments;NSUInteger index=[args indexOfObject:@"--status-file"];if(index!=NSNotFound&&index+1<args.count)_statusFile=args[index+1];
    [self loadSettings];[self buildWindow];[self buildStatusItem];[self refreshDevices];
    __weak TXApp *weakSelf=self;_midi.received=^(NSString *source,UInt8 channel,UInt8 cc,UInt8 value){dispatch_async(dispatch_get_main_queue(),^{[weakSelf handleMIDI:source channel:channel cc:cc value:value];});};
    _browser.changed=^{dispatch_async(dispatch_get_main_queue(),^{[weakSelf browserChanged];});};[_browser start];
    _midi.changed=^{dispatch_async(dispatch_get_main_queue(),^{[weakSelf deviceConnectionChanged];});};[_midi start];
    _poll=[NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    _meter=[NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_poll forMode:NSRunLoopCommonModes];[[NSRunLoop mainRunLoop] addTimer:_meter forMode:NSRunLoopCommonModes];
    [_window center];[_window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[self updateStatus];
}
- (void)loadSettings {
    NSDictionary *d=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"TX6Mac.profile"]?:@{};
    NSArray *saved=d[@"assignments"];for(int i=0;i<6;i++)[_assignments addObject:(saved.count>(NSUInteger)i&&[saved[i] isKindOfClass:NSString.class])?saved[i]:@""];
    NSMutableDictionary *savedByKey=[NSMutableDictionary dictionary];for(NSUInteger i=0;i<6;i++)if(_assignments[i].length&&[d[@"channels"] count]>i)savedByKey[_assignments[i]]=d[@"channels"][i];
    if([_assignments[0] isEqual:@"local.tx6mac.system-sounds"]){NSMutableSet *seen=[NSMutableSet setWithObject:@"local.tx6mac.system-sounds"];for(int i=1;i<6;i++){NSString *key=_assignments[i];if(key.length&&[seen containsObject:key])_assignments[i]=@"";else if(key.length)[seen addObject:key];}}
    else {NSMutableArray *migrated=[NSMutableArray array];for(NSString *key in _assignments)if(key.length&&![key isEqual:@"local.tx6mac.system-sounds"]&&![migrated containsObject:key])[migrated addObject:key];[_assignments removeAllObjects];[_assignments addObject:@"local.tx6mac.system-sounds"];for(int i=0;i<5;i++)[_assignments addObject:migrated.count>(NSUInteger)i?migrated[i]:@""]; }
    _outputUID=d[@"outputUID"]?:[TXAudio uid:TXAudio.defaultOutput];_midi.transport=d[@"transport"]?:@"auto";
    _hudEnabled=d[@"showHUD"]?[d[@"showHUD"] boolValue]:YES;_autoAssign=d[@"autoAssign"]?[d[@"autoAssign"] boolValue]:YES;_pickup=d[@"pickup"]?[d[@"pickup"] boolValue]:YES;_invert=[d[@"invert"] boolValue];
    TXRenderState *s=_audio.state;atomic_store(&s->master,d[@"master"]?fmax(0,fmin(1,[d[@"master"] floatValue])):1);
    for(int i=0;i<6;i++){
        NSDictionary *ch=savedByKey[_assignments[i]]?:@{};
        atomic_store(&s->gain[i],ch[@"gain"]?fmax(0,fmin(1,[ch[@"gain"] floatValue])):1);
        atomic_store(&s->muted[i],[ch[@"muted"] boolValue]);
        for(int b=0;b<3;b++)atomic_store(&s->eq[i][b],[ch[@"eq"] count]>(NSUInteger)b?fmax(-18,fmin(18,[ch[@"eq"][b] floatValue])):0);
    }
}
- (void)saveSettings {
    NSMutableArray *channels=[NSMutableArray array];TXRenderState *s=_audio.state;
    for(int i=0;i<6;i++)[channels addObject:@{@"gain":@(atomic_load(&s->gain[i])),@"muted":@(atomic_load(&s->muted[i])),@"eq":@[@(atomic_load(&s->eq[i][0])),@(atomic_load(&s->eq[i][1])),@(atomic_load(&s->eq[i][2]))]}];
    [[NSUserDefaults standardUserDefaults] setObject:@{@"assignments":_assignments,@"outputUID":_outputUID?:@"",@"transport":_midi.transport?:@"auto",@"autoAssign":@(_autoAssign),@"showHUD":@(_hudEnabled),@"pickup":@(_pickup),@"invert":@(_invert),@"master":@(atomic_load(&s->master)),@"channels":channels} forKey:@"TX6Mac.profile"];
    _lastSave=NSDate.date;[self sendBrowserControls];
}
- (void)buildWindow {
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1060,850) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"TX · MAC — 프로그램별 믹서";_window.contentMinSize=NSMakeSize(900,570);_window.delegate=self;_window.releasedWhenClosed=NO;_window.backgroundColor=Color(0xD8D9D4);
    _window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];_canvas=[[TXCanvas alloc] initWithFrame:NSMakeRect(0,0,1060,850)];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,1060,850)];scroll.hasVerticalScroller=YES;scroll.hasHorizontalScroller=YES;scroll.autohidesScrollers=YES;scroll.drawsBackground=NO;scroll.documentView=_canvas;scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_window.contentView=scroll;
    CGFloat available=(NSScreen.mainScreen.visibleFrame.size.height?:930)-80;if(available<850)[_window setContentSize:NSMakeSize(1060,MAX(570,available))];
    [_canvas addSubview:Label(@"OUTPUT",NSMakeRect(24,91,62,18),10,YES)];_outputMenu=[[TXPopup alloc] initWithFrame:NSMakeRect(83,83,310,28) pullsDown:NO];_outputMenu.target=self;_outputMenu.action=@selector(outputChanged:);_outputMenu.font=[NSFont systemFontOfSize:12];_outputMenu.accessibilityLabel=@"오디오 출력 장치";[_canvas addSubview:_outputMenu];
    _transportMenu=[[TXPopup alloc] initWithFrame:NSMakeRect(410,83,145,28) pullsDown:NO];for(NSArray *v in @[@[@"MIDI 자동",@"auto"],@[@"USB MIDI",@"usb"],@[@"Bluetooth MIDI",@"ble"]]){[_transportMenu addItemWithTitle:v[0]];_transportMenu.lastItem.representedObject=v[1];}for(NSMenuItem *item in _transportMenu.itemArray)if([item.representedObject isEqual:_midi.transport])[_transportMenu selectItem:item];_transportMenu.target=self;_transportMenu.action=@selector(transportChanged:);[_canvas addSubview:_transportMenu];
    [_canvas addSubview:Button(@"Bluetooth 연결…",NSMakeRect(565,83,138,28),self,@selector(showBluetooth:))];
    [_canvas addSubview:Button(@"오디오 권한…",NSMakeRect(865,699,167,29),self,@selector(showPrivacy:))];
    _startButton=Button(@"믹서 시작",NSMakeRect(865,259,167,36),self,@selector(primaryControl:));_startButton.bezelColor=Color(0xF36B2F);[_canvas addSubview:_startButton];
    NSMutableArray *channelViews=[NSMutableArray array];TXRenderState *s=_audio.state;
    NSArray *names=@[@"HIGH",@"MID",@"LOW"],*frequencies=@[@"8 kHz",@"1 kHz",@"120 Hz"];unsigned colors[3]={0x608CA6,0xF36B2F,0xF1F1E9};
    for(int i=0;i<6;i++){
        TXChannel *c=[[TXChannel alloc] initWithFrame:NSMakeRect(24+i*136,130,136,634)];c.slot=i;
        c.assignment=[[TXPopup alloc] initWithFrame:NSMakeRect(7,62,122,25) pullsDown:NO];c.assignment.font=[NSFont systemFontOfSize:11];c.assignment.target=self;c.assignment.action=@selector(assignmentChanged:);c.assignment.tag=i;c.assignment.accessibilityLabel=i==0?@"트랙 1 시스템 사운드 고정":[NSString stringWithFormat:@"트랙 %d 프로그램",i+1];c.assignment.enabled=i!=0;[c addSubview:c.assignment];
        NSMutableArray *knobs=[NSMutableArray array];for(int j=0;j<3;j++){
            TXKnob *k=[[TXKnob alloc] initWithFrame:NSMakeRect(30,110+j*90,76,92)];k.caption=names[j];k.frequency=frequencies[j];k.accent=Color(colors[j]);k.value=atomic_load(&s->eq[i][2-j]);k.tag=i*3+(2-j);k.target=self;k.action=@selector(eqChanged:);k.accessibilityRole=NSAccessibilitySliderRole;k.accessibilityLabel=[NSString stringWithFormat:@"트랙 %d %@ EQ",i+1,names[j]];k.awaitingPickup=_pickup;k.toolTip=@"위아래 드래그 또는 스크롤. 두 번 클릭하면 0 dB. Shift로 미세 조절.";[knobs addObject:k];[c addSubview:k];}
        c.knobs=knobs;c.fader=[[TXFader alloc] initWithFrame:NSMakeRect(21,455,94,0)];
        // 실제 TX-6처럼 EQ 세 줄 아래에 페이더와 채널 버튼을 배치합니다.
        for(int j=0;j<3;j++)c.knobs[j].frame=NSMakeRect(30,110+j*90,76,92);
        c.fader.frame=NSMakeRect(22,402,92,151);c.fader.value=atomic_load(&s->gain[i]);c.fader.awaitingPickup=_pickup;c.fader.tag=i;c.fader.target=self;c.fader.action=@selector(gainChanged:);c.fader.accessibilityRole=NSAccessibilitySliderRole;c.fader.accessibilityLabel=[NSString stringWithFormat:@"트랙 %d 음량",i+1];[c addSubview:c.fader];
        c.activity=Label(@"미지정",NSMakeRect(9,560,118,18),10,NO);c.activity.alignment=NSTextAlignmentCenter;[c addSubview:c.activity];
        c.mute=Button(@"MUTE",NSMakeRect(18,588,100,31),self,@selector(muteChanged:));c.mute.tag=i;c.mute.buttonType=NSButtonTypePushOnPushOff;c.mute.state=atomic_load(&s->muted[i])?NSControlStateValueOn:NSControlStateValueOff;c.mute.font=Mono(10,NSFontWeightSemibold);c.mute.accessibilityLabel=[NSString stringWithFormat:@"트랙 %d 음소거",i+1];[c addSubview:c.mute];
        [_canvas addSubview:c];[channelViews addObject:c];
    }_channels=channelViews;
    [_canvas addSubview:Label(@"SELECT",NSMakeRect(865,315,167,28),25,YES)];
    [_canvas addSubview:Label(@"ALL APPLICATIONS",NSMakeRect(865,342,167,16),9,YES)];
    _masterFader=[[TXFader alloc] initWithFrame:NSMakeRect(874,366,150,153)];_browserLabel.stringValue=_browser.connected?@"Chrome 오디오 탭 자동 감지 · 음소거 바로 가능\n개별 음량·EQ는 해당 탭에서 ⌘⇧6으로 연결":@"Chrome 확장을 연결하면 재생 탭 자동 감지\n개별 음량·EQ 연결 단축키: ⌘⇧6";_remainderLabel.stringValue=_overflowCount>0?[NSString stringWithFormat:@"추가 %ld개 앱은 MASTER 적용",(long)_overflowCount]:@"미지정 앱도 MASTER 적용";_masterFader.rotary=YES;_masterFader.value=atomic_load(&s->master);_masterFader.target=self;_masterFader.action=@selector(masterChanged:);_masterFader.accessibilityRole=NSAccessibilitySliderRole;_masterFader.accessibilityLabel=@"전체 음량";[_canvas addSubview:_masterFader];
    _soundKey=Button(@"FX I\nSOUND",NSMakeRect(865,540,78,44),self,@selector(soundKey:));[_canvas addSubview:_soundKey];_masterMute=Button(@"FX II\nMUTE",NSMakeRect(954,540,78,44),self,@selector(muteKey:));[_canvas addSubview:_masterMute];
    [_canvas addSubview:Button(@"EQ 초기화",NSMakeRect(865,607,167,29),self,@selector(resetEQ:))];
    _autoButton=[NSButton checkboxWithTitle:@"자동 앱 매칭" target:self action:@selector(autoChanged:)];_autoButton.frame=NSMakeRect(863,673,167,21);_autoButton.state=_autoAssign?NSControlStateValueOn:NSControlStateValueOff;_autoButton.font=[NSFont systemFontOfSize:11];_autoButton.toolTip=@"재생 중인 앱을 트랙에 자동 배정합니다. 수동 지정하면 자동 매칭이 꺼집니다.";
    _pickupButton=[NSButton checkboxWithTitle:@"하드웨어 픽업" target:self action:@selector(settingsChanged:)];_pickupButton.frame=NSMakeRect(863,701,167,21);_pickupButton.state=_pickup?NSControlStateValueOn:NSControlStateValueOff;_pickupButton.font=[NSFont systemFontOfSize:11];_pickupButton.toolTip=@"페이더를 현재 표시값까지 움직여야 연결됩니다. 처음에는 맨 위(100%)까지 올리세요. 노브도 현재 EQ값에 맞추면 연결됩니다. 끄면 즉시 반응합니다.";
    _invertButton=[NSButton checkboxWithTitle:@"페이더 방향 반전" target:self action:@selector(settingsChanged:)];_invertButton.frame=NSMakeRect(863,729,167,21);_invertButton.state=_invert?NSControlStateValueOn:NSControlStateValueOff;_invertButton.font=[NSFont systemFontOfSize:11];NSViewController *settings=[NSViewController new];settings.view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,360,520)];
    _autoButton.frame=NSMakeRect(18,473,324,24);_pickupButton.frame=NSMakeRect(18,437,324,24);_invertButton.frame=NSMakeRect(18,401,324,24);[settings.view addSubview:_autoButton];[settings.view addSubview:_pickupButton];[settings.view addSubview:_invertButton];_hudButton=[NSButton checkboxWithTitle:@"조절 시 상태 표시" target:self action:@selector(settingsChanged:)];_hudButton.frame=NSMakeRect(18,365,324,24);_hudButton.state=_hudEnabled?NSControlStateValueOn:NSControlStateValueOff;[settings.view addSubview:_hudButton];
    _deviceContextLabel=Label(@"TX-6 홈 화면 확인 필요",NSMakeRect(18,311,324,40),11,NO);_deviceContextLabel.maximumNumberOfLines=2;_deviceContextLabel.lineBreakMode=NSLineBreakByWordWrapping;[settings.view addSubview:_deviceContextLabel];
    _resumeDeviceButton=Button(@"기기 홈 화면 확인 · TX-6 제어 재개",NSMakeRect(18,276,324,29),self,@selector(resumeDeviceControls:));[settings.view addSubview:_resumeDeviceButton];
    [settings.view addSubview:Label(@"기기 현재 메인 숫자와 맞추기 (0~100)",NSMakeRect(18,243,324,22),11,NO)];
    _calibrationInput=[[NSTextField alloc] initWithFrame:NSMakeRect(18,207,99,27)];_calibrationInput.placeholderString=@"0–100";_calibrationInput.font=Mono(12,NSFontWeightMedium);_calibrationInput.alignment=NSTextAlignmentCenter;NSNumberFormatter *formatter=[NSNumberFormatter new];formatter.minimum=@0;formatter.maximum=@100;formatter.allowsFloats=NO;_calibrationInput.formatter=formatter;_calibrationInput.target=self;_calibrationInput.action=@selector(calibrateMaster:);_calibrationInput.accessibilityLabel=@"TX-6 현재 메인 숫자 0부터 100";[settings.view addSubview:_calibrationInput];
    [settings.view addSubview:Button(@"맥 전체 음량에 맞춤",NSMakeRect(130,207,212,28),self,@selector(calibrateMaster:))];NSTextField *calibrationNote=Label(@"입력한 숫자를 맥 전체 음량 %로 설정합니다.\n기기 자동 조회·상시 동기화 기능은 아닙니다.",NSMakeRect(18,151,324,46),10,NO);calibrationNote.maximumNumberOfLines=2;calibrationNote.lineBreakMode=NSLineBreakByWordWrapping;[settings.view addSubview:calibrationNote];[settings.view addSubview:Label(@"CH 01 시스템 사운드 고정 · CH 02–06 앱 / 탭",NSMakeRect(18,109,324,24),10,NO)];_browserLabel=Label(@"Chrome 탭: 확장 아이콘에서 연결",NSMakeRect(18,20,324,64),11,NO);_browserLabel.maximumNumberOfLines=2;_browserLabel.lineBreakMode=NSLineBreakByWordWrapping;[settings.view addSubview:_browserLabel];_settingsPopover=[NSPopover new];_settingsPopover.behavior=NSPopoverBehaviorTransient;_settingsPopover.contentViewController=settings;
    [_canvas addSubview:Button(@"SETUP / 설정",NSMakeRect(865,653,167,29),self,@selector(showSettings:))];
    _remainderLabel=Label(@"미지정 앱도 MASTER 적용",NSMakeRect(865,748,167,22),10,NO);[_canvas addSubview:_remainderLabel];
    NSMenu *main=[NSMenu new],*appMenu=[NSMenu new];NSMenuItem *appItem=[NSMenuItem new];appItem.submenu=appMenu;[main addItem:appItem];[appMenu addItemWithTitle:@"TX · MAC 정보" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];[appMenu addItem:NSMenuItem.separatorItem];[appMenu addItemWithTitle:@"TX · MAC 숨기기" action:@selector(hide:) keyEquivalent:@"h"];[appMenu addItemWithTitle:@"TX · MAC 종료" action:@selector(terminate:) keyEquivalent:@"q"];NSApp.mainMenu=main;
}
- (NSView*)sliderViewForSlot:(NSInteger)slot band:(NSInteger)band {
    NSView *v=[[NSView alloc] initWithFrame:NSMakeRect(0,0,280,38)];NSSlider *slider=[NSSlider sliderWithValue:0 minValue:band<0?0:-18 maxValue:band<0?1:18 target:self action:@selector(menuSliderChanged:)];slider.frame=NSMakeRect(15,8,205,22);slider.tag=slot*10+band+1;
    slider.enabled=slot==6||[self canAdjustVolumeForSlot:slot];if(!slider.enabled)slider.toolTip=@"음소거 가능 · 음량/EQ는 Chrome 탭에서 ⌘⇧6으로 연결";slider.doubleValue=slot==6?atomic_load(&_audio.state->master):(band<0?atomic_load(&_audio.state->gain[slot]):atomic_load(&_audio.state->eq[slot][band]));[v addSubview:slider];
    NSTextField *value=Label(band<0?[NSString stringWithFormat:@"%.0f%%",slider.doubleValue*100]:[NSString stringWithFormat:@"%+.0f",slider.doubleValue],NSMakeRect(225,11,48,18),11,YES);value.tag=999;[v addSubview:value];return v;
}
- (void)buildStatusItem {
    _statusItem=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];_statusItem.button.image=[self menuIcon];_statusItem.button.imagePosition=NSImageOnly;_statusItem.button.toolTip=@"TX · MAC — 프로그램별 음량과 EQ";
    _statusMenu=[NSMenu new];_statusMenu.delegate=self;_statusItem.menu=_statusMenu;
}
- (NSImage*)menuIcon {
    NSImage *image=[[NSImage alloc] initWithSize:NSMakeSize(22,18)];[image lockFocus];[[NSColor blackColor] setStroke];
    for(int i=0;i<6;i++){CGFloat x=2+i*3.5,y=4+(i%3)*4;NSBezierPath *line=[NSBezierPath bezierPath];line.lineWidth=1;[line moveToPoint:NSMakePoint(x,2)];[line lineToPoint:NSMakePoint(x,16)];[line stroke];[[NSColor blackColor] setFill];NSRectFill(NSMakeRect(x-1.3,y,2.6,3));}
    [image unlockFocus];image.template=YES;return image;
}
- (void)menuWillOpen:(NSMenu*)menu {
    _statusMenuTracking=YES;[self hideHUD:nil];_pendingHUD=nil;[menu removeAllItems];NSMenuItem *title=[[NSMenuItem alloc] initWithTitle:@"TX · MAC / SIX CHANNEL" action:nil keyEquivalent:@""];title.enabled=NO;[menu addItem:title];
    NSMenuItem *status=[[NSMenuItem alloc] initWithTitle:_audio.running?(atomic_load(&_audio.state->callbacks)>0?@"● 믹서 실행 중":@"○ 오디오 대기 · 권한 확인"):@"○ 믹서 대기 중" action:nil keyEquivalent:@""];status.enabled=NO;[menu addItem:status];if(_deviceContext.suspended||_deviceContext.shiftDown){NSMenuItem *resume=[[NSMenuItem alloc] initWithTitle:@"홈 화면 확인 후 TX-6 제어 재개" action:@selector(resumeDeviceControls:) keyEquivalent:@""];resume.target=self;[menu addItem:resume];}
    [menu addItem:NSMenuItem.separatorItem];[menu addItemWithTitle:@"전체 음량" action:nil keyEquivalent:@""];
    NSMenuItem *master=[NSMenuItem new];master.view=[self sliderViewForSlot:6 band:-1];[menu addItem:master];
    NSMenuItem *mute=[[NSMenuItem alloc] initWithTitle:@"전체 음소거" action:@selector(masterMenuMute:) keyEquivalent:@""];mute.target=self;mute.state=atomic_load(&_audio.state->masterMuted)?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:mute];
    [menu addItem:NSMenuItem.separatorItem];
    for(int i=0;i<6;i++){
        NSString *name=[self nameForKey:_assignments[i]];NSMenuItem *channel=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%02d  %@",i+1,name.length?name:@"앱 미지정"] action:nil keyEquivalent:@""];NSMenu *sub=[NSMenu new];channel.submenu=sub;
        NSMenuItem *chMute=[[NSMenuItem alloc] initWithTitle:@"음소거" action:@selector(menuMute:) keyEquivalent:@""];chMute.tag=i;chMute.target=self;chMute.state=atomic_load(&_audio.state->muted[i])?NSControlStateValueOn:NSControlStateValueOff;[sub addItem:chMute];
        for(int b=-1;b<3;b++){[sub addItemWithTitle:b<0?@"음량":@[@"LOW · 120 Hz",@"MID · 1 kHz",@"HIGH · 8 kHz"][b] action:nil keyEquivalent:@""];NSMenuItem *s=[NSMenuItem new];s.view=[self sliderViewForSlot:i band:b];[sub addItem:s];}
        [menu addItem:channel];
    }
    [menu addItem:NSMenuItem.separatorItem];NSMenuItem *output=[[NSMenuItem alloc] initWithTitle:@"출력 장치" action:nil keyEquivalent:@""];NSMenu *outs=[NSMenu new];output.submenu=outs;
    for(NSDictionary *d in _outputs){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:d[@"name"] action:@selector(menuOutput:) keyEquivalent:@""];item.target=self;item.representedObject=d[@"uid"];item.state=[d[@"uid"] isEqual:_outputUID]?NSControlStateValueOn:NSControlStateValueOff;[outs addItem:item];}[menu addItem:output];
    for(NSArray *entry in @[@[@"믹서 창 열기",NSStringFromSelector(@selector(showWindow:))],@[@"Bluetooth 연결…",NSStringFromSelector(@selector(showBluetooth:))],@[_desiredRunning?@"믹서 중지 · 원음 복구":@"믹서 시작",NSStringFromSelector(@selector(toggleMixer:))]]){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];item.target=self;[menu addItem:item];}
    [menu addItem:NSMenuItem.separatorItem];NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:@"종료 · 원음 복구" action:@selector(terminate:) keyEquivalent:@"q"];[menu addItem:quit];
}
- (void)menuDidClose:(NSMenu*)menu {
    _statusMenuTracking=NO;[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(displayPendingHUD) object:nil];[self performSelector:@selector(displayPendingHUD) withObject:nil afterDelay:0.12 inModes:@[NSRunLoopCommonModes]];
}
- (void)showHUDForSlot:(NSInteger)slot message:(NSString*)message {
    if(!_hudEnabled)return;NSString *name=slot>=0&&slot<6?[self nameForKey:_assignments[slot]]:@"전체 오디오";if(!name.length)name=@"앱 미지정";
    _pendingHUD=@{@"heading":slot>=0&&slot<6?[NSString stringWithFormat:@"CHANNEL %02ld / %@",(long)slot+1,slot==0?@"OS":@"APP"]:@"MASTER / ALL AUDIO",@"application":name,@"message":message?:@"",@"time":NSDate.date};
    if(!_statusMenuTracking)[self displayPendingHUD];
}
- (void)displayPendingHUD {
    if(!_hudEnabled||_statusMenuTracking||!_pendingHUD)return;NSDate *time=_pendingHUD[@"time"];if([NSDate.date timeIntervalSinceDate:time]>2){_pendingHUD=nil;return;}
    NSStatusBarButton *button=_statusItem.button;if(!button.window)return;
    if(!_hud){_hud=[[TXHUDPanel alloc] initWithContentRect:NSMakeRect(0,0,308,108) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];_hud.opaque=NO;_hud.backgroundColor=NSColor.clearColor;_hud.hasShadow=YES;_hud.level=NSStatusWindowLevel;_hud.hidesOnDeactivate=NO;_hud.ignoresMouseEvents=YES;_hud.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorStationary;_hudView=[[TXHUDView alloc] initWithFrame:NSMakeRect(0,0,308,108)];_hud.contentView=_hudView;}
    _hudView.heading=_pendingHUD[@"heading"];_hudView.application=_pendingHUD[@"application"];_hudView.message=_pendingHUD[@"message"];
    NSRect anchor=[button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];NSScreen *screen=button.window.screen?:NSScreen.mainScreen;CGFloat x=MAX(NSMinX(screen.visibleFrame)+8,MIN(NSMidX(anchor)-154,NSMaxX(screen.visibleFrame)-316));CGFloat y=NSMinY(anchor)-114;_hudView.arrowX=NSMidX(anchor)-x;_hudView.needsDisplay=YES;[_hud setFrameOrigin:NSMakePoint(x,y)];[_hud orderFrontRegardless];
    [_hudDismiss invalidate];_hudDismiss=[NSTimer timerWithTimeInterval:1.8 target:self selector:@selector(hideHUD:) userInfo:nil repeats:NO];[[NSRunLoop mainRunLoop] addTimer:_hudDismiss forMode:NSRunLoopCommonModes];[self writeStatus];
}
- (void)hideHUD:(id)sender {[_hudDismiss invalidate];_hudDismiss=nil;[_hud orderOut:nil];[self writeStatus];}
- (NSString*)nameForKey:(NSString*)key {if([key isEqual:@"local.tx6mac.system-sounds"])return @"시스템 사운드";for(NSDictionary *p in _processes)if([p[@"key"] isEqual:key])return p[@"name"];if(!key.length)return @"";if([key hasPrefix:@"chrome-tab:"])return @"Chrome 탭 연결 대기";NSURL *url=[[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:key];return url?[[NSFileManager defaultManager] displayNameAtPath:url.path]:key;}
- (void)refreshDevices {
    _outputs=TXAudio.outputs;NSMutableArray *processes=[TXAudio.processes mutableCopy];BOOL captured=NO;
    for(NSDictionary *tab in _browser.tabs)if([tab[@"captured"] boolValue]||[tab[@"active"] boolValue]||[_assignments containsObject:[self keyForTab:tab]]){captured=YES;NSString *key=[self keyForTab:tab];NSString *title=[tab[@"title"] length]?tab[@"title"]:tab[@"host"];NSDictionary *p=@{@"key":key,@"name":[@"↗ " stringByAppendingString:title?:@"Chrome 탭"],@"ids":@[],@"bundles":@[],@"active":tab[@"active"]?:@NO,@"isBrowserTab":@YES,@"canVolume":@([tab[@"captured"] boolValue]),@"tabId":tab[@"id"],@"session":tab[@"session"],@"peak":tab[@"peak"]?:@0,@"fullTitle":title?:@"Chrome 탭"};[processes insertObject:p atIndex:0];}
    if(captured){NSIndexSet *chrome=[processes indexesOfObjectsPassingTest:^BOOL(NSDictionary *p,NSUInteger idx,BOOL *stop){(void)idx;(void)stop;return [p[@"key"] isEqual:@"com.google.Chrome"];}];[processes removeObjectsAtIndexes:chrome];BOOL cleared=NO;for(int i=1;i<6;i++)if([_assignments[i] isEqual:@"com.google.Chrome"]){_assignments[i]=@"";[self clearPickupForSlot:i];cleared=YES;}if(cleared){_canvas.message=@"Chrome 오디오 탭을 감지해 Chrome 전체 배정을 해제했습니다. 음소거는 바로, 음량·EQ는 탭에서 ⌘⇧6으로 연결합니다.";[self saveSettings];}}
    _processes=processes;[self autoMatch];
    NSString *outSig=[NSString stringWithFormat:@"%@|%@",_outputs,_outputUID];BOOL outputChanged=![_outputMenuSignature isEqual:outSig];_outputMenuSignature=outSig;
    NSMutableArray *processMenu=[NSMutableArray array];for(NSDictionary *p in _processes)[processMenu addObject:@[p[@"key"],p[@"name"]]];NSString *processSig=[NSString stringWithFormat:@"%@|%@",processMenu,_assignments];BOOL processesChanged=![_processMenuSignature isEqual:processSig];_processMenuSignature=processSig;
    if(outputChanged){[_outputMenu removeAllItems];for(NSDictionary *d in _outputs){[_outputMenu addItemWithTitle:[NSString stringWithFormat:@"%@  ·  %@ ch",d[@"name"],d[@"channels"]]];_outputMenu.lastItem.representedObject=d[@"uid"];if([d[@"uid"] isEqual:_outputUID])[_outputMenu selectItem:_outputMenu.lastItem];}
    BOOL found=NO;for(NSDictionary *d in _outputs)if([d[@"uid"] isEqual:_outputUID])found=YES;
    if(!found){[_outputMenu addItemWithTitle:@"선택한 출력 장치가 연결되지 않음"];_outputMenu.lastItem.representedObject=_outputUID;[_outputMenu selectItem:_outputMenu.lastItem];}}
    if(processesChanged)for(int i=0;i<6;i++){
        TXChannel *c=_channels[i];[c.assignment removeAllItems];[c.assignment addItemWithTitle:_autoAssign?@"재생 앱 대기…":@"앱 지정…"];c.assignment.lastItem.representedObject=@"";BOOL present=!_assignments[i].length;
        for(NSDictionary *p in _processes){NSString *key=p[@"key"];if(![p[@"isSystemSound"] boolValue]&&![self isAutomaticCandidate:p]&&![key isEqual:_assignments[i]])continue;BOOL used=NO;for(int j=0;j<6;j++)if(j!=i&&[_assignments[j] isEqual:key])used=YES;if(used)continue;
            [c.assignment addItemWithTitle:p[@"name"]];c.assignment.lastItem.representedObject=key;if([key isEqual:_assignments[i]]){[c.assignment selectItem:c.assignment.lastItem];present=YES;}}
        c.assignment.toolTip=@"실행 중인 앱 또는 연결된 Chrome 탭을 지정합니다.";for(NSDictionary *p in _processes)if([p[@"key"] isEqual:_assignments[i]])c.assignment.toolTip=p[@"fullTitle"]?:p[@"name"];
        if(!present){[c.assignment addItemWithTitle:i==0?@"시스템 사운드":[NSString stringWithFormat:@"%@ (대기)",[self nameForKey:_assignments[i]]]];c.assignment.lastItem.representedObject=_assignments[i];[c.assignment selectItem:c.assignment.lastItem];}
    }
    for(int i=0;i<6;i++){TXChannel *c=_channels[i];BOOL available=[self canAdjustVolumeForSlot:i];c.fader.enabled=available;c.fader.needsDisplay=YES;for(TXKnob *knob in c.knobs){knob.enabled=available;knob.needsDisplay=YES;}if(!available){c.fader.toolTip=@"음소거는 바로 조절됩니다. 개별 음량·EQ는 해당 Chrome 탭에서 ⌘⇧6으로 연결하세요.";for(TXKnob *knob in c.knobs)knob.toolTip=c.fader.toolTip;}else{c.fader.toolTip=@"음량을 드래그하거나 스크롤하여 조절합니다.";for(TXKnob *knob in c.knobs)knob.toolTip=@"위아래 드래그 또는 스크롤. 두 번 클릭하면 0 dB. Shift로 미세 조절.";}}
}
- (NSString*)keyForTab:(NSDictionary*)tab {return [NSString stringWithFormat:@"chrome-tab:%@:%@",tab[@"session"],tab[@"id"]];}
- (void)browserChanged {
    [self refreshDevices];if(_desiredRunning&&![_signature isEqual:[self currentSignature]])[self rebuildAudio];[self updateStatus];[self writeStatus];
}
- (void)sendBrowserControls {
    if(!_browser)return;NSMutableArray *controls=[NSMutableArray array];TXRenderState *s=_audio.state;
    for(NSDictionary *tab in _browser.tabs){NSString *key=[self keyForTab:tab];NSUInteger slot=[_assignments indexOfObject:key];BOOL mapped=slot!=NSNotFound&&slot<6;
        [controls addObject:@{@"tabId":tab[@"id"],@"session":tab[@"session"],@"gain":mapped?@(atomic_load(&s->gain[slot])):@1,@"muted":mapped?@(atomic_load(&s->muted[slot])):@NO,@"eq":mapped?@[@(atomic_load(&s->eq[slot][0])),@(atomic_load(&s->eq[slot][1])),@(atomic_load(&s->eq[slot][2]))]:@[@0,@0,@0]}];
    }
    [_browser sendControls:controls enabled:_audio.running];_lastBrowserSend=NSDate.date;
}
- (NSDictionary*)processForSlot:(NSInteger)slot {
    if(slot<0||slot>=6)return nil;for(NSDictionary *process in _processes)if([process[@"key"] isEqual:_assignments[slot]])return process;return nil;
}
- (BOOL)canAdjustVolumeForSlot:(NSInteger)slot {
    NSDictionary *process=[self processForSlot:slot];if(slot>=0&&slot<6&&[_assignments[slot] hasPrefix:@"chrome-tab:"])return [process[@"canVolume"] boolValue];return ![process[@"isBrowserTab"] boolValue]||[process[@"canVolume"] boolValue];
}
- (void)showBrowserCaptureHint:(NSInteger)slot {
    _canvas.message=@"Chrome 탭 음소거는 바로 조절됩니다. 개별 음량·EQ는 해당 탭에서 ⌘⇧6을 한 번 눌러 연결하세요.";[self showHUDForSlot:slot message:@"음량·EQ 연결: ⌘⇧6"];_canvas.needsDisplay=YES;
}
- (BOOL)isAutomaticCandidate:(NSDictionary*)process {
    NSString *key=process[@"key"];if([process[@"isBrowserTab"] boolValue])return YES;if([process[@"isSystemSound"] boolValue]||[key isEqual:@"local.tx6mac.system-sounds"])return NO;if(!key.length||[key hasPrefix:@"pid:"]||[key isEqual:NSBundle.mainBundle.bundleIdentifier])return NO;
    // 설치된 응용 프로그램만 자동 배정하고 오디오 시스템 서비스는 제외합니다.
    return [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:key]!=nil;
}
- (void)clearPickupForSlot:(NSInteger)slot {
    memset(_latched[slot],0,sizeof(_latched[slot]));memset(_havePrevious[slot],0,sizeof(_havePrevious[slot]));
    _channels[slot].fader.awaitingPickup=_pickup;for(TXKnob *knob in _channels[slot].knobs)knob.awaitingPickup=_pickup;
}
- (void)autoMatch {
    NSDate *now=NSDate.date;NSMutableArray<NSString*> *active=[NSMutableArray array];
    for(NSDictionary *p in _processes)if([p[@"active"] boolValue]&&[self isAutomaticCandidate:p]){NSString *key=p[@"key"];[active addObject:key];_lastActive[key]=now;[_observedActive addObject:key];}
    _overflowCount=MAX(0,(NSInteger)active.count-5);if(!_autoAssign)return;
    NSArray *previous=[_assignments copy];NSDictionary *snapshots=TXSnapshotAssignments(previous,_audio.state);NSMutableArray<NSString*> *next=[previous mutableCopy];
    for(NSString *key in next)if(key.length&&!_lastActive[key])_lastActive[key]=now;
    for(NSString *key in active){if([next containsObject:key])continue;NSInteger candidate=NSNotFound;
        for(int i=1;i<6;i++)if(!next[i].length){candidate=i;break;}
        if(candidate==NSNotFound){NSTimeInterval longest=12;for(int i=1;i<6;i++){NSString *old=next[i];if([active containsObject:old])continue;NSTimeInterval age=[now timeIntervalSinceDate:_lastActive[old]?:now];if(age>=longest){candidate=i;longest=age;}}}
        if(candidate!=NSNotFound)next[candidate]=key;
    }
    next=[TXOrderedAssignments(next,[NSSet setWithArray:active],_lastActive,_observedActive,now) mutableCopy];
    if([next isEqual:previous])return;
    // 이전 오디오 경로에 새 트랙의 설정이 잠시 적용되는 것을 막습니다.
    if(_audio.running){[_audio stop];_signature=nil;}
    _assignments=next;TXApplyAssignmentSnapshots(_assignments,snapshots,_audio.state);
    for(int i=0;i<6;i++){[self clearPickupForSlot:i];TXChannel *c=_channels[i];c.fader.value=atomic_load(&_audio.state->gain[i]);c.mute.state=atomic_load(&_audio.state->muted[i])?NSControlStateValueOn:NSControlStateValueOff;for(int b=0;b<3;b++)c.knobs[2-b].value=atomic_load(&_audio.state->eq[i][b]);}
    [self saveSettings];
}
- (void)autoChanged:(NSButton*)sender {
    _autoAssign=sender.state==NSControlStateValueOn;[self refreshDevices];[self saveSettings];if(_desiredRunning&&![_signature isEqual:[self currentSignature]])[self rebuildAudio];[self updateStatus];
}
- (NSArray*)currentGroups {
    NSMutableArray *groups=[NSMutableArray array];for(int i=0;i<6;i++){NSArray *ids=@[];for(NSDictionary *p in _processes)if([p[@"key"] isEqual:_assignments[i]])ids=p[@"ids"];[groups addObject:ids];}return groups;
}
- (NSDictionary*)selectedOutput {for(NSDictionary *d in _outputs)if([d[@"uid"] isEqual:_outputUID])return d;return nil;}
- (NSString*)currentSignature {
    NSDictionary *d=[self selectedOutput];double rate=0;if(d){AudioObjectPropertyAddress a={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 size=sizeof(rate);AudioObjectGetPropertyData([d[@"id"] unsignedIntValue],&a,0,NULL,&size,&rate);}
    return [NSString stringWithFormat:@"%@|%.0f|%@",_outputUID,rate,[self currentGroups]];
}
- (void)rebuildAudio {
    if(!_desiredRunning||_isBuilding)return;NSDictionary *device=[self selectedOutput];if(!device){[_audio stop];_desiredRunning=NO;_audio.lastError=@"출력 장치 연결이 해제되어 믹서를 중지하고 원음을 복구했습니다.";_canvas.message=_audio.lastError;[self updateStatus];return;}
    _isBuilding=YES;NSString *signature=[self currentSignature];BOOL ok=[_audio startOnDevice:[device[@"id"] unsignedIntValue] groups:[self currentGroups]];_isBuilding=NO;
    if(ok){_startedAt=NSDate.date;_progressAt=NSDate.date;_progressFrames=0;_signature=signature;_canvas.message=@"믹서 실행 중 · 앱별 음량과 EQ가 선택한 출력에 적용됩니다.";}else{_desiredRunning=NO;_canvas.message=_audio.lastError;}_startButton.title=_deviceContext.suspended||_deviceContext.shiftDown?@"TX-6 제어 재개":(_desiredRunning?@"믹서 중지":@"믹서 시작");[self sendBrowserControls];[self updateStatus];
}
- (void)toggleMixer:(id)sender {
    _desiredRunning=!_desiredRunning;if(_desiredRunning){[self refreshDevices];[self rebuildAudio];}else{[_audio stop];_audio.lastError=@"";_canvas.message=@"믹서 중지 · 프로그램의 원래 출력이 복구되었습니다.";}[self sendBrowserControls];[self updateStatus];
}
- (void)poll:(id)sender {
    [self refreshDevices];[_midi refresh];if(_desiredRunning&&![_signature isEqual:[self currentSignature]])[self rebuildAudio];[self updateStatus];[self writeStatus];
}
- (void)tick:(id)sender {
    TXRenderState *s=_audio.state;if(!_lastBrowserSend||[NSDate.date timeIntervalSinceDate:_lastBrowserSend]>=1)[self sendBrowserControls];
    if(_audio.running){uint64_t frames=atomic_load(&s->frames);if(frames!=_progressFrames){_progressFrames=frames;_progressAt=NSDate.date;}BOOL active=NO;for(NSDictionary *p in _processes)if([p[@"active"] boolValue])active=YES;NSTimeInterval timeout=frames?6:10;if(active&&_progressAt&&[NSDate.date timeIntervalSinceDate:_progressAt]>timeout){[_audio stop];_desiredRunning=NO;_audio.lastError=@"오디오 처리 응답이 없어 원음을 복구했습니다. 시스템 오디오 권한과 출력 장치를 확인해 주세요.";_canvas.message=_audio.lastError;[self updateStatus];}}
    int fault=atomic_load(&s->layoutFault);if(_audio.running&&fault){[_audio stop];_desiredRunning=NO;_audio.lastError=[NSString stringWithFormat:@"오디오 채널 구조가 변경되어 원음을 복구했습니다. 다시 시작해 주세요. (%d)",fault];_canvas.message=_audio.lastError;[self updateStatus];}
    for(int i=0;i<6;i++){TXChannel *c=_channels[i];float peak=_audio.running?atomic_load(&s->peak[i]):0;for(NSDictionary *tab in _browser.tabs)if([[self keyForTab:tab] isEqual:_assignments[i]])peak=_audio.running&&!atomic_load(&s->muted[i])?[tab[@"peak"] floatValue]*atomic_load(&s->gain[i]):0;c.fader.muted=atomic_load(&s->muted[i]);c.fader.peak=MAX(peak,c.fader.peak*0.82);c.fader.needsDisplay=YES;BOOL active=NO;for(NSDictionary *p in _processes)if([p[@"key"] isEqual:_assignments[i]])active=[p[@"active"] boolValue];c.activity.stringValue=![self canAdjustVolumeForSlot:i]?@"음소거 가능 · 연결 필요":(i==0?@"시스템 효과음 · 고정":(_assignments[i].length?(active?@"오디오 활성":@"소리 재생 대기"):(_autoAssign?@"재생 앱 대기":@"미지정")));}
    uint64_t limited=atomic_load(&s->limitedFrames);if(limited>_lastLimitedFrames)_lastLimitDate=NSDate.date;_lastLimitedFrames=limited;_canvas.limited=_lastLimitDate&&[NSDate.date timeIntervalSinceDate:_lastLimitDate]<1;_canvas.needsDisplay=YES;
    _masterFader.peak=MAX(_audio.running?atomic_load(&s->outputPeak):0,_masterFader.peak*0.82);_masterFader.needsDisplay=YES;
}
- (void)updateStatus {
    TXRenderState *s=_audio.state;_canvas.running=_audio.running&&atomic_load(&s->callbacks)>0;_canvas.audioWaiting=_audio.running&&atomic_load(&s->callbacks)==0;_canvas.master=atomic_load(&s->master);_canvas.muted=atomic_load(&s->masterMuted);
    _canvas.connection=_deviceContext.suspended||_deviceContext.shiftDown?(_deviceContext.reason?@"TX-6 MENU / PAUSED":@"TX-6 HOME CHECK"):(_midi.sources.count?[_midi.sources componentsJoinedByString:@" / "]:@"MIDI 연결 대기");_canvas.output=[self selectedOutput][@"name"]?:@"출력 장치 연결 대기";_canvas.needsDisplay=YES;
    _browserLabel.stringValue=_browser.connected?@"Chrome 오디오 탭 자동 감지 · 음소거 바로 가능\n개별 음량·EQ는 해당 탭에서 ⌘⇧6으로 연결":@"Chrome 확장을 연결하면 재생 탭 자동 감지\n개별 음량·EQ 연결 단축키: ⌘⇧6";_remainderLabel.stringValue=_overflowCount>0?[NSString stringWithFormat:@"추가 %ld개 앱은 MASTER 적용",(long)_overflowCount]:@"미지정 앱도 MASTER 적용";_masterFader.value=atomic_load(&s->master);_masterMute.state=atomic_load(&s->masterMuted)?NSControlStateValueOn:NSControlStateValueOff;_startButton.title=_deviceContext.suspended||_deviceContext.shiftDown?@"TX-6 제어 재개":(_desiredRunning?@"믹서 중지":@"믹서 시작");
    _resumeDeviceButton.enabled=_deviceContext.suspended||_deviceContext.shiftDown;_deviceContextLabel.stringValue=_deviceContext.suspended||_deviceContext.shiftDown?(_deviceContext.reason?@"기기 메뉴 조작 중 · 맥 제어 일시정지\nSHIFT를 단독으로 눌렀다 떼면 홈 제어 재개":@"기기 홈 화면 확인 필요 · 맥 제어 일시정지\nSHIFT를 단독으로 눌렀다 떼면 홈 제어 재개"):@"TX-6 홈 화면 제어 중\n메뉴 진입 신호가 오면 맥 조절을 보호합니다.";
    _statusItem.button.toolTip=[NSString stringWithFormat:@"TX · MAC · %@ · %.0f%%",_audio.running?@"실행":@"대기",atomic_load(&s->master)*100];
}
- (void)writeStatus {
    if(!_statusFile.length)return;NSMutableArray *channels=[NSMutableArray array];TXRenderState *s=_audio.state;for(int i=0;i<6;i++)[channels addObject:@{@"slot":@(i+1),@"application":_assignments[i],@"gain":@(atomic_load(&s->gain[i])),@"muted":@(atomic_load(&s->muted[i])),@"eqLowMidHigh":@[@(atomic_load(&s->eq[i][0])),@(atomic_load(&s->eq[i][1])),@(atomic_load(&s->eq[i][2]))],@"peak":@(atomic_load(&s->peak[i]))}];
    NSDictionary *d=@{@"running":@(_audio.running),@"autoAssign":@(_autoAssign),@"controllerSuspended":@(_deviceContext.suspended||_deviceContext.shiftDown),@"controllerShiftHeld":@(_deviceContext.shiftDown),@"controllerContextReasonCC":@(_deviceContext.reason),@"hudEnabled":@(_hudEnabled),@"hudVisible":@(_hud.isVisible),@"hudTitle":_hudView.application?:@"",@"hudMessage":_hudView.message?:@"",@"overflowApps":@(_overflowCount),@"browserConnected":@(_browser.connected),@"browserTabs":_browser.tabs?:@[],@"outputUID":_outputUID?:@"",@"outputName":[self selectedOutput][@"name"]?:@"",@"midiSources":_midi.sources?:@[],@"lastMIDI":_lastMIDI?:@"",@"master":@(atomic_load(&s->master)),@"masterMuted":@(atomic_load(&s->masterMuted)),@"callbacks":@(atomic_load(&s->callbacks)),@"frames":@(atomic_load(&s->frames)),@"limitedFrames":@(atomic_load(&s->limitedFrames)),@"remainderPeak":@(atomic_load(&s->peak[6])),@"outputPeak":@(atomic_load(&s->outputPeak)),@"sampleRate":@(s->sampleRate),@"physicalInputChannels":@(s->physicalInputChannels),@"tapCount":@(s->tapCount),@"layoutFault":@(atomic_load(&s->layoutFault)),@"error":_audio.lastError?:@"",@"channels":channels};
    NSData *json=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:_statusFile options:NSDataWritingAtomic error:nil];
}
- (void)assignmentChanged:(NSPopUpButton*)sender {if(sender.tag==0)return;_autoAssign=NO;_autoButton.state=NSControlStateValueOff;_assignments[sender.tag]=sender.selectedItem.representedObject?:@"";memset(_latched[sender.tag],0,sizeof(_latched[sender.tag]));memset(_havePrevious[sender.tag],0,sizeof(_havePrevious[sender.tag]));[self saveSettings];[self refreshDevices];if(_desiredRunning)[self rebuildAudio];}
- (void)outputChanged:(NSPopUpButton*)sender {_outputUID=sender.selectedItem.representedObject;[self saveSettings];if(_desiredRunning)[self rebuildAudio];[self updateStatus];}
- (void)transportChanged:(NSPopUpButton*)sender {_midi.transport=sender.selectedItem.representedObject;[_midi refresh];[self saveSettings];[self updateStatus];}
- (void)settingsChanged:(id)sender {BOOL pickup=_pickupButton.state==NSControlStateValueOn,invert=_invertButton.state==NSControlStateValueOn;if(_pickup!=pickup||_invert!=invert){_pickup=pickup;_invert=invert;for(int i=0;i<6;i++)[self clearPickupForSlot:i];}_hudEnabled=_hudButton.state==NSControlStateValueOn;if(!_hudEnabled){_pendingHUD=nil;[self hideHUD:nil];}[self saveSettings];}
- (void)gainChanged:(TXFader*)sender {int i=(int)sender.tag;if(![self canAdjustVolumeForSlot:i]){sender.value=atomic_load(&_audio.state->gain[i]);[self showBrowserCaptureHint:i];return;}atomic_store(&_audio.state->gain[i],sender.value);_latched[i][0]=NO;sender.awaitingPickup=_pickup;[self showHUDForSlot:i message:[NSString stringWithFormat:@"VOLUME %.0f%%",sender.value*100]];[self saveSettings];}
- (void)eqChanged:(TXKnob*)sender {int i=(int)sender.tag/3,b=(int)sender.tag%3;if(![self canAdjustVolumeForSlot:i]){sender.value=atomic_load(&_audio.state->eq[i][b]);[self showBrowserCaptureHint:i];return;}atomic_store(&_audio.state->eq[i][b],sender.value);_latched[i][b+1]=NO;sender.awaitingPickup=_pickup;[self showHUDForSlot:i message:[NSString stringWithFormat:@"%@ %+.1f dB",@[@"LOW",@"MID",@"HIGH"][b],sender.value]];[self saveSettings];}
- (void)masterChanged:(TXFader*)sender {atomic_store(&_audio.state->master,sender.value);[self showHUDForSlot:-1 message:[NSString stringWithFormat:@"VOLUME %.0f%%",sender.value*100]];[self saveSettings];[self updateStatus];}
- (void)muteChanged:(NSButton*)sender {atomic_store(&_audio.state->muted[sender.tag],sender.state==NSControlStateValueOn);[self showHUDForSlot:sender.tag message:sender.state==NSControlStateValueOn?@"음소거":@"음소거 해제"];[self saveSettings];}
- (void)masterMuteChanged:(NSButton*)sender {atomic_store(&_audio.state->masterMuted,sender.state==NSControlStateValueOn);[self showHUDForSlot:-1 message:sender.state==NSControlStateValueOn?@"전체 음소거":@"전체 음소거 해제"];[self updateStatus];}
- (void)resetEQ:(id)sender {for(int i=0;i<6;i++)for(int b=0;b<3;b++){atomic_store(&_audio.state->eq[i][b],0);_latched[i][b+1]=NO;_channels[i].knobs[2-b].value=0;_channels[i].knobs[2-b].awaitingPickup=_pickup;}[self showHUDForSlot:-1 message:@"EQ ALL · 0 dB"];[self saveSettings];}
- (void)menuSliderChanged:(NSSlider*)sender {
    int slot=(int)sender.tag/10,b=(int)sender.tag%10-1;if(slot<6&&![self canAdjustVolumeForSlot:slot]){[self showBrowserCaptureHint:slot];return;}
    if(slot==6){atomic_store(&_audio.state->master,sender.doubleValue);[self updateStatus];}
    else if(b<0){atomic_store(&_audio.state->gain[slot],sender.doubleValue);_channels[slot].fader.value=sender.doubleValue;_latched[slot][0]=NO;_channels[slot].fader.awaitingPickup=_pickup;}
    else {atomic_store(&_audio.state->eq[slot][b],sender.doubleValue);_channels[slot].knobs[2-b].value=sender.doubleValue;_latched[slot][b+1]=NO;_channels[slot].knobs[2-b].awaitingPickup=_pickup;}
    NSTextField *label=[sender.superview viewWithTag:999];label.stringValue=b<0?[NSString stringWithFormat:@"%.0f%%",sender.doubleValue*100]:[NSString stringWithFormat:@"%+.0f",sender.doubleValue];[self showHUDForSlot:slot==6?-1:slot message:b<0?[NSString stringWithFormat:@"VOLUME %.0f%%",sender.doubleValue*100]:[NSString stringWithFormat:@"%@ %+.1f dB",@[@"LOW",@"MID",@"HIGH"][b],sender.doubleValue]];[self saveSettings];
}
- (void)menuMute:(NSMenuItem*)sender {int slot=(int)sender.tag;BOOL mute=!atomic_load(&_audio.state->muted[slot]);atomic_store(&_audio.state->muted[slot],mute);_channels[slot].mute.state=mute?NSControlStateValueOn:NSControlStateValueOff;sender.state=_channels[slot].mute.state;[self showHUDForSlot:slot message:mute?@"음소거":@"음소거 해제"];[self saveSettings];}
- (void)masterMenuMute:(NSMenuItem*)sender {atomic_store(&_audio.state->masterMuted,!atomic_load(&_audio.state->masterMuted));sender.state=atomic_load(&_audio.state->masterMuted)?NSControlStateValueOn:NSControlStateValueOff;[self showHUDForSlot:-1 message:atomic_load(&_audio.state->masterMuted)?@"전체 음소거":@"전체 음소거 해제"];[self updateStatus];}
- (void)menuOutput:(NSMenuItem*)sender {_outputUID=sender.representedObject;[self refreshDevices];[self saveSettings];if(_desiredRunning)[self rebuildAudio];[self updateStatus];}
- (void)deviceConnectionChanged {
    _deviceContext=(TXDeviceContext){.suspended=YES};_canvas.message=@"TX-6 화면을 확인해 주세요. SHIFT를 단독으로 누르고 떼면 홈 제어를 재개합니다.";[self updateStatus];[self writeStatus];
}
- (void)primaryControl:(id)sender {if(_deviceContext.suspended||_deviceContext.shiftDown)[self resumeDeviceControls:sender];else [self toggleMixer:sender];}
- (void)resumeDeviceControls:(id)sender {
    _deviceContext=(TXDeviceContext){0};for(int i=0;i<6;i++)[self clearPickupForSlot:i];_canvas.message=@"TX-6 홈 화면 제어를 재개했습니다. 페이더와 노브는 현재 맥 값에서 픽업합니다.";[self showHUDForSlot:-1 message:@"TX-6 제어 재개"];[self updateStatus];[self writeStatus];
}
- (void)calibrateMaster:(id)sender {
    NSString *text=[_calibrationInput.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSScanner *scanner=[NSScanner scannerWithString:text];double number=0;
    if(![scanner scanDouble:&number]||!scanner.isAtEnd||!isfinite(number)||number<0||number>100){_canvas.message=@"TX-6에 표시된 현재 메인 숫자 0~100을 입력해 주세요.";[self showHUDForSlot:-1 message:@"0~100 숫자 입력"];_canvas.needsDisplay=YES;return;}
    atomic_store(&_audio.state->master,number/100);_canvas.message=@"입력한 기기 숫자에 맥 전체 음량을 맞췄습니다. 자동 조회나 상시 동기화는 아닙니다.";[self showHUDForSlot:-1 message:[NSString stringWithFormat:@"VOLUME %.0f%%",number]];[self saveSettings];[self updateStatus];[self writeStatus];
}
- (BOOL)consumeDeviceContextCC:(UInt8)cc value:(UInt8)value {
    BOOL wasBlocked=_deviceContext.suspended||_deviceContext.shiftDown;BOOL suppress=TXConsumeDeviceContext(&_deviceContext,cc,value);BOOL blocked=_deviceContext.suspended||_deviceContext.shiftDown;
    if(!suppress)return NO;
    if(wasBlocked&&!blocked){for(int i=0;i<6;i++)[self clearPickupForSlot:i];_canvas.message=@"SHIFT 단독 홈 복귀를 확인해 TX-6의 맥 제어를 재개했습니다.";[self showHUDForSlot:-1 message:@"TX-6 제어 재개"];}
    else if(blocked){_canvas.message=_deviceContext.reason?@"기기 메뉴 조작 중 · 맥 제어 일시정지. SHIFT를 단독으로 누르고 떼면 홈 제어를 재개합니다.":@"기기 홈 화면 확인 필요 · 맥 제어 일시정지. SHIFT를 단독으로 누르고 떼면 홈 제어를 재개합니다.";[self showHUDForSlot:-1 message:_deviceContext.reason?@"기기 메뉴 · 제어 정지":@"홈 확인 · 제어 정지"];}
    [self updateStatus];[self writeStatus];return YES;
}
- (BOOL)pickupValue:(double)value slot:(int)slot parameter:(int)parameter current:(double)current {
    if(!_pickup||_latched[slot][parameter])return YES;double tolerance=parameter?0.7:0.035;
    BOOL hit=fabs(value-current)<=tolerance||(_havePrevious[slot][parameter]&&(_previous[slot][parameter]-current)*(value-current)<=0);
    _previous[slot][parameter]=value;_havePrevious[slot][parameter]=YES;if(hit)_latched[slot][parameter]=YES;return hit;
}
- (void)handleMIDI:(NSString*)source channel:(UInt8)channel cc:(UInt8)cc value:(UInt8)value {
    _lastMIDI=[NSString stringWithFormat:@"%@ · CH %d / CC %d / %d",source,channel+1,cc,value];_canvas.message=_audio.lastError.length?_audio.lastError:_lastMIDI;
    if(channel!=0){[self updateStatus];return;}if([self consumeDeviceContextCC:cc value:value])return;TXRenderState *s=_audio.state;
    if(cc>=1&&cc<=6){int i=cc-1;if(![self canAdjustVolumeForSlot:i]){[self showBrowserCaptureHint:i];[self writeStatus];return;}double v=(_invert?127-value:value)/127.0;BOOL hit=[self pickupValue:v slot:i parameter:0 current:atomic_load(&s->gain[i])];_channels[i].fader.awaitingPickup=!hit;if(!hit)_canvas.message=[NSString stringWithFormat:@"픽업 대기 · 트랙 %d 페이더를 %.0f%% 위치까지 움직이면 연결됩니다.",i+1,atomic_load(&s->gain[i])*100];if(hit){atomic_store(&s->gain[i],v);_channels[i].fader.value=v;}[self showHUDForSlot:i message:hit?[NSString stringWithFormat:@"VOLUME %.0f%%",v*100]:[NSString stringWithFormat:@"픽업 대기 · %.0f%%",atomic_load(&s->gain[i])*100]];}
    else if(cc>=7&&cc<=24){int bank=(cc-7)/6,i=(cc-7)%6,b=2-bank;if(![self canAdjustVolumeForSlot:i]){[self showBrowserCaptureHint:i];[self writeStatus];return;}double db=abs((int)value-64)<=1?0:(value/127.0*36-18);TXKnob *k=_channels[i].knobs[bank];BOOL hit=[self pickupValue:db slot:i parameter:b+1 current:atomic_load(&s->eq[i][b])];k.awaitingPickup=!hit;if(!hit)_canvas.message=[NSString stringWithFormat:@"픽업 대기 · 트랙 %d %@ 노브를 %+.1f dB에 맞추면 연결됩니다.",i+1,k.caption,atomic_load(&s->eq[i][b])];if(hit){atomic_store(&s->eq[i][b],db);k.value=db;}[self showHUDForSlot:i message:hit?[NSString stringWithFormat:@"%@ %+.1f dB",k.caption,db]:[NSString stringWithFormat:@"%@ 픽업 · %+.1f dB",k.caption,atomic_load(&s->eq[i][b])]];}
    else if(cc>=25&&cc<=30&&value>=64){int i=cc-25;BOOL mute=!atomic_load(&s->muted[i]);atomic_store(&s->muted[i],mute);_channels[i].mute.state=mute?NSControlStateValueOn:NSControlStateValueOff;[self showHUDForSlot:i message:mute?@"음소거":@"음소거 해제"];}
    else if(cc==31){int delta=value<64?value:(int)value-128;float master=fmaxf(0,fminf(1,atomic_load(&s->master)+delta*0.01));atomic_store(&s->master,master);[self showHUDForSlot:-1 message:[NSString stringWithFormat:@"VOLUME %.0f%%",master*100]];}
    else if(cc==33&&value>=64){atomic_store(&s->masterMuted,false);[self showHUDForSlot:-1 message:@"전체 음소거 해제"];}
    else if(cc==34&&value>=64){atomic_store(&s->masterMuted,true);[self showHUDForSlot:-1 message:@"전체 음소거"];}
    [self sendBrowserControls];[self updateStatus];[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveSettings) object:nil];[self performSelector:@selector(saveSettings) withObject:nil afterDelay:0.4 inModes:@[NSRunLoopCommonModes]];[self writeStatus];
}
- (void)showSettings:(NSButton*)sender {[_settingsPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMinX];}
- (void)soundKey:(id)sender {atomic_store(&_audio.state->masterMuted,false);[self showHUDForSlot:-1 message:@"전체 음소거 해제"];[self updateStatus];}
- (void)muteKey:(id)sender {atomic_store(&_audio.state->masterMuted,true);[self showHUDForSlot:-1 message:@"전체 음소거"];[self updateStatus];}
- (void)showBluetooth:(id)sender {if(!_bluetooth)_bluetooth=[CABTLEMIDIWindowController new];[_bluetooth showWindow:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)showPrivacy:(id)sender {[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];}
- (void)showWindow:(id)sender {[_window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (BOOL)windowShouldClose:(NSWindow*)window {[window orderOut:nil];return NO;}
- (BOOL)applicationShouldHandleReopen:(NSApplication*)app hasVisibleWindows:(BOOL)visible {[self showWindow:nil];return YES;}
- (void)applicationWillTerminate:(NSNotification*)notification {[_poll invalidate];[_meter invalidate];[_hudDismiss invalidate];[_hud orderOut:nil];[self saveSettings];[_audio stop];[_browser stop];[_midi stop];[self writeStatus];}
@end

int main(void) {
    @autoreleasepool {
        NSArray *args=NSProcessInfo.processInfo.arguments;
        if([args containsObject:@"--self-check"]){BOOL ok=TXRunSelfCheck() && TXRunMIDISelfCheck() && TXRunBrowserSelfCheck() && TXRunUIModelSelfCheck() && TXRunDeviceContextSelfCheck();printf("TX6Mac DSP/render self-check: %s\n",ok?"PASS":"FAIL");return ok?0:1;}
        if([args containsObject:@"--diagnose"]){NSData *json=[NSJSONSerialization dataWithJSONObject:TXAudio.diagnostics options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");return 0;}
        NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];__attribute__((objc_precise_lifetime)) TXApp *delegate=[TXApp new];app.delegate=delegate;[app run];
    }return 0;
}
