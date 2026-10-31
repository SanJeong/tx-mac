#import "TX6.h"
#import "BrowserBridge.h"
#import "Localization.h"
#import "Scenes.h"
#import "Levels.h"
#import <CoreAudioKit/CoreAudioKit.h>
#import <math.h>
#import <CommonCrypto/CommonDigest.h>

static const double TXVolumeStep=1.0/99.0;
static const NSUInteger TXSceneMIDILimit=4096;
static NSInteger TXVolumeValue(double gain) {return (NSInteger)llround((isfinite(gain)?fmax(0,fmin(1,gain)):0)*99);}
static NSString *TXVolumeText(double gain) {return [NSString stringWithFormat:@"%ld",(long)TXVolumeValue(gain)];}
static double TXVolumeGain(NSInteger value) {return fmax(0,fmin(99,value))/99.0;}
static NSString *TXVolumeHUD(double gain) {return [@"VOLUME " stringByAppendingString:TXVolumeText(gain)];}
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
    BOOL on=((NSButtonCell*)self.cell).showsStateBy!=0&&self.state==NSControlStateValueOn,pressed=self.highlighted;NSRect r=NSInsetRect(self.bounds,1,1);
    NSColor *face=self.bezelColor?:Color(on?0xF36B2F:(self.lightKey?0xECECE7:0x30342D));if(pressed)face=Color(0xF36B2F);
    [Color(0x61675C) setFill];[[NSBezierPath bezierPathWithRoundedRect:r xRadius:2 yRadius:2] fill];r.size.height-=3;
    [face setFill];[[NSBezierPath bezierPathWithRoundedRect:r xRadius:2 yRadius:2] fill];
    [Color(self.lightKey||on||self.bezelColor||pressed?0x252625:0xF1F2E9) setFill];
    NSColor *ink=Color(self.lightKey||on||self.bezelColor||pressed?0x252625:0xF1F2E9);CGFloat h=[self.title containsString:@"\n"]?28:17;
    NSFont *titleFont=[self.title containsString:@"\n"]?Mono(9,NSFontWeightSemibold):self.font;while(titleFont.pointSize>8&&[self.title sizeWithAttributes:@{NSFontAttributeName:titleFont}].width>r.size.width-10)titleFont=[NSFont systemFontOfSize:titleFont.pointSize-0.5 weight:NSFontWeightMedium];
    Text(self.title,NSMakeRect(5,NSMidY(r)-h/2,r.size.width-10,h),titleFont,ink,NSTextAlignmentCenter);
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
@property(nonatomic,copy) NSString *connection,*output,*monitor,*message;
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
    Text(self.output?:@"MAIN WAIT",NSMakeRect(875,158,147,14),Mono(9,NSFontWeightRegular),light,NSTextAlignmentLeft);
    Text(self.monitor?:@"MON OFF",NSMakeRect(875,173,147,14),Mono(9,NSFontWeightRegular),light,NSTextAlignmentLeft);
    Text(self.muted?@"MUTE":[NSString stringWithFormat:@"%02ld",(long)TXVolumeValue(self.master)],NSMakeRect(873,190,104,40),Mono(33,NSFontWeightMedium),self.muted?Color(0xF36B2F):light,NSTextAlignmentLeft);
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
- (BOOL)acceptsFirstResponder{return self.enabled;}
- (BOOL)isAccessibilityElement{return YES;}
- (NSString*)accessibilityRole{return NSAccessibilitySliderRole;}
- (id)accessibilityValue{return @(self.value);}
- (NSString*)accessibilityValueDescription{return [NSString stringWithFormat:@"%+.1f dB",self.value];}
- (void)setAccessibilityValue:(id)value{if(!self.enabled)return;self.value=[value doubleValue];[self sendAction:self.action to:self.target];}
- (id)accessibilityMinValue{return @(-18);}
- (id)accessibilityMaxValue{return @18;}
- (BOOL)accessibilityPerformIncrement{if(!self.enabled)return NO;self.value+=0.5;[self sendAction:self.action to:self.target];return YES;}
- (BOOL)accessibilityPerformDecrement{if(!self.enabled)return NO;self.value-=0.5;[self sendAction:self.action to:self.target];return YES;}

- (void)setValue:(double)value{double next=isfinite(value)?fmax(-18,fmin(18,value)):0;if(_value==next)return;_value=next;self.needsDisplay=YES;NSAccessibilityPostNotification(self,NSAccessibilityValueChangedNotification);}
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
    if(!self.enabled)return;
    if(event.clickCount==2){self.value=0;[self sendAction:self.action to:self.target];return;}
    NSPoint start=[self convertPoint:event.locationInWindow fromView:nil];double initial=self.value;
    while(YES){NSEvent *e=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];if(e.type==NSEventTypeLeftMouseUp)break;NSPoint p=[self convertPoint:e.locationInWindow fromView:nil];self.value=initial+(start.y-p.y)*((e.modifierFlags&NSEventModifierFlagShift)?0.025:0.12);[self sendAction:self.action to:self.target];}
}
- (void)scrollWheel:(NSEvent*)event{if(!self.enabled)return;self.value+=event.scrollingDeltaY*(event.hasPreciseScrollingDeltas?0.05:0.5);[self sendAction:self.action to:self.target];}
- (void)keyDown:(NSEvent*)event{if(!self.enabled)return;if(event.keyCode==126||event.keyCode==124)self.value+=0.5;else if(event.keyCode==125||event.keyCode==123)self.value-=0.5;else{[super keyDown:event];return;}[self sendAction:self.action to:self.target];}
@end

@interface TXFader:NSControl
@property(nonatomic) double value,peak,peakHold;
@property(nonatomic) BOOL muted,rotary;
@property(nonatomic) BOOL awaitingPickup;
@end
@implementation TXFader
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return self.enabled;}
- (BOOL)isAccessibilityElement{return YES;}
- (NSString*)accessibilityRole{return NSAccessibilitySliderRole;}
- (id)accessibilityValue{return @(self.value);}
- (NSString*)accessibilityValueDescription{return TXVolumeText(self.value);}
- (void)setAccessibilityValue:(id)value{if(!self.enabled)return;self.value=[value doubleValue];[self sendAction:self.action to:self.target];}
- (id)accessibilityMinValue{return @0;}
- (id)accessibilityMaxValue{return @1;}
- (BOOL)accessibilityPerformIncrement{if(!self.enabled)return NO;self.value+=TXVolumeStep;[self sendAction:self.action to:self.target];return YES;}
- (BOOL)accessibilityPerformDecrement{if(!self.enabled)return NO;self.value-=TXVolumeStep;[self sendAction:self.action to:self.target];return YES;}

- (void)setValue:(double)value{double next=isfinite(value)?fmax(0,fmin(1,value)):0;if(_value==next)return;_value=next;self.needsDisplay=YES;NSAccessibilityPostNotification(self,NSAccessibilityValueChangedNotification);}
- (void)drawRect:(NSRect)dirty {
    if(self.rotary){NSPoint center=NSMakePoint(NSMidX(self.bounds),63);CGFloat r=46;[Color(0xECECE7) setFill];NSBezierPath *cap=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x-r,center.y-r,r*2,r*2)];[cap fill];[Color(0x747C6B) setStroke];cap.lineWidth=1.2;[cap stroke];
        NSBezierPath *ring=[NSBezierPath bezierPath];ring.lineWidth=3;[ring appendBezierPathWithArcWithCenter:center radius:r+6 startAngle:135 endAngle:405 clockwise:NO];[Color(0xA5AE9B) setStroke];[ring stroke];
        double angle=(135+self.value*270)*M_PI/180;NSBezierPath *pointer=[NSBezierPath bezierPath];pointer.lineWidth=4;pointer.lineCapStyle=NSLineCapStyleRound;[pointer moveToPoint:center];[pointer lineToPoint:NSMakePoint(center.x+cos(angle)*(r-9),center.y+sin(angle)*(r-9))];[Color(0x252625) setStroke];[pointer stroke];Text(TXVolumeText(self.value),NSMakeRect(0,127,self.bounds.size.width,22),Mono(15,NSFontWeightMedium),Color(0x252625),NSTextAlignmentCenter);return;}
    CGFloat x=NSMidX(self.bounds)-7,top=17,bottom=self.bounds.size.height-33,height=bottom-top;
    [Color(0x555B51) setFill];[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x-2,top,4,height) xRadius:2 yRadius:2] fill];
    for(int i=0;i<=10;i++){CGFloat y=top+height*i/10;[Color(0xA3A89C) setFill];NSRectFill(NSMakeRect(x-13,y,5,1));if(i%5==0)Text(i==0?@"0":(i==5?@"−6":@"−∞"),NSMakeRect(x-40,y-6,24,14),Mono(7,NSFontWeightRegular),Color(0x666B61),NSTextAlignmentRight);}
    for(int i=0;i<12;i++){BOOL lit=!self.muted&&self.peak>pow(10,(-42+i*3.5)/20);NSColor *c=lit?Color(i>9?0xF36B2F:0x73845C):Color(0xB6BBB0);[c setFill];NSRectFill(NSMakeRect(x+24,bottom-7-i*(height-7)/12,5,6));}
    if(self.peakHold>0){double index=fmax(0,fmin(11,(20*log10(self.peakHold)+42)/3.5));[Color(self.peakHold>1?0xF36B2F:0x555B51) setFill];NSRectFill(NSMakeRect(x+21,bottom-7-index*(height-7)/12,11,1));}
    CGFloat y=top+(1-self.value)*height;[Color(self.muted||!self.enabled?0xB7BBB0:0xECECE7) setFill];NSBezierPath *cap=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x-12,y-10,25,20) xRadius:2 yRadius:2];[cap fill];[Color(0x555B51) setStroke];[cap stroke];[Color(self.awaitingPickup?0xF36B2F:0x252625) setFill];NSRectFill(NSMakeRect(x-8,y,17,2));
    Text(TXVolumeText(self.value),NSMakeRect(0,self.bounds.size.height-18,self.bounds.size.width,16),Mono(11,NSFontWeightSemibold),Color(0x252625),NSTextAlignmentCenter);
}
- (void)updateFromEvent:(NSEvent*)event{NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];self.value=1-(p.y-17)/(self.bounds.size.height-50);[self sendAction:self.action to:self.target];}
- (void)mouseDown:(NSEvent*)event{if(!self.enabled)return;if(self.rotary){NSPoint start=[self convertPoint:event.locationInWindow fromView:nil];double initial=self.value;while(YES){NSEvent *e=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];if(e.type==NSEventTypeLeftMouseUp)break;NSPoint p=[self convertPoint:e.locationInWindow fromView:nil];self.value=initial+(start.y-p.y)*0.004;[self sendAction:self.action to:self.target];}return;}[self updateFromEvent:event];while(YES){NSEvent *e=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];if(e.type==NSEventTypeLeftMouseUp)break;[self updateFromEvent:e];}}
- (void)scrollWheel:(NSEvent*)event{if(!self.enabled)return;self.value+=event.scrollingDeltaY*(event.hasPreciseScrollingDeltas?0.001:2*TXVolumeStep);[self sendAction:self.action to:self.target];}
- (void)keyDown:(NSEvent*)event{if(!self.enabled)return;if(event.keyCode==126||event.keyCode==124)self.value+=TXVolumeStep;else if(event.keyCode==125||event.keyCode==123)self.value-=TXVolumeStep;else{[super keyDown:event];return;}[self sendAction:self.action to:self.target];}
@end

@interface TXMonitorSliderCell:NSSliderCell
@end
@implementation TXMonitorSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    [Color(0x555B51) setFill];NSRectFill(NSMakeRect(NSMinX(rect),floor(NSMidY(rect))-2,NSWidth(rect),4));
}
- (void)drawKnob:(NSRect)rect {
    NSRect cap=NSMakeRect(floor(NSMidX(rect))-7,floor(NSMidY(rect))-8,14,16);
    [Color(0xA3A89C) setFill];NSRectFill(NSOffsetRect(cap,1,1));[Color(self.enabled?0xECECE7:0xB7BBB0) setFill];NSRectFill(cap);[Color(0x555B51) setStroke];NSFrameRect(cap);
    [Color(0x252625) setFill];NSRectFill(NSMakeRect(NSMidX(cap)-1,NSMidY(cap)-5,2,10));
}
@end
@interface TXVolumeSlider:NSSlider
@end
@implementation TXVolumeSlider
- (NSString*)accessibilityValueDescription {return TXVolumeText(self.doubleValue);}
- (void)changeVolumeBy:(double)delta {self.doubleValue=fmax(self.minValue,fmin(self.maxValue,self.doubleValue+delta));[self sendAction:self.action to:self.target];}
- (BOOL)accessibilityPerformIncrement {if(!self.enabled)return NO;[self changeVolumeBy:TXVolumeStep];return YES;}
- (BOOL)accessibilityPerformDecrement {if(!self.enabled)return NO;[self changeVolumeBy:-TXVolumeStep];return YES;}
- (void)keyDown:(NSEvent*)event {if(!self.enabled)return;if(event.keyCode==126||event.keyCode==124)[self changeVolumeBy:TXVolumeStep];else if(event.keyCode==125||event.keyCode==123)[self changeVolumeBy:-TXVolumeStep];else [super keyDown:event];}
@end
@interface TXMonitorSlider:TXVolumeSlider
@end
@implementation TXMonitorSlider
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])){self.cell=[TXMonitorSliderCell new];self.minValue=0;self.maxValue=1;self.continuous=YES;self.sliderType=NSSliderTypeLinear;self.vertical=NO;}return self;
}
@end

@interface TXChannel:NSView
@property(nonatomic) NSInteger slot;
@property(nonatomic,strong) NSPopUpButton *assignment;
@property(nonatomic,strong) NSArray<TXKnob*> *knobs;
@property(nonatomic,strong) TXFader *fader;
@property(nonatomic,strong) NSButton *mute;
@property(nonatomic,strong) NSPopUpButton *route;
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

// Keep gain, EQ and mute tied to physical slots.
static NSArray<NSString*> *TXStableAssignments(NSArray<NSString*> *assignments,NSSet<NSString*> *present,NSArray<NSString*> *candidates,BOOL fillEmpty,NSIndexSet *reserved) {
    NSMutableArray *next=[assignments mutableCopy];
    for(int i=1;i<6;i++)if(![reserved containsIndex:i]&&[next[i] length]&&![present containsObject:next[i]])next[i]=@"";
    if(!fillEmpty)return next;
    for(NSString *key in candidates){if([next containsObject:key])continue;for(int i=1;i<6;i++)if(![reserved containsIndex:i]&&![next[i] length]){next[i]=key;break;}}
    return next;
}
static NSInteger TXAutomaticPriority(NSDictionary *process) {
    if([process[@"key"] isEqual:@"com.google.Chrome"])return 0;
    if(![process[@"isBrowserTab"] boolValue])return 1;
    return [process[@"canVolume"] boolValue]?2:3;
}
static NSArray<NSString*> *TXResolveChromeFamily(NSArray<NSString*> *assignments,NSArray<NSString*> *candidates,BOOL tabMode) {
    NSMutableArray *next=[assignments mutableCopy];NSInteger firstParent=NSNotFound,firstChild=NSNotFound;
    for(int i=1;i<6;i++){
        if([next[i] isEqual:@"com.google.Chrome"]&&firstParent==NSNotFound)firstParent=i;
        if([next[i] hasPrefix:@"chrome-tab:"]&&firstChild==NSNotFound)firstChild=i;
    }
    if(!tabMode){
        NSInteger destination=firstParent!=NSNotFound?firstParent:firstChild;
        for(int i=1;i<6;i++)if([next[i] isEqual:@"com.google.Chrome"]||[next[i] hasPrefix:@"chrome-tab:"])next[i]=i==destination?@"com.google.Chrome":@"";
    }else{
        for(int i=1;i<6;i++)if([next[i] isEqual:@"com.google.Chrome"]){
            next[i]=@"";
            for(NSString *key in candidates)if([key hasPrefix:@"chrome-tab:"]&&![next containsObject:key]){next[i]=key;break;}
        }
    }
    return next;
}
static NSArray<NSDictionary*> *TXBrowserProcesses(NSArray<NSDictionary*> *native,NSArray<NSDictionary*> *tabs,NSArray<NSString*> *assignments,BOOL tabMode) {
    NSMutableArray *processes=[NSMutableArray array];
    // Show either Chrome aggregate audio or individual tabs.
    for(NSDictionary *process in native){
        if([process[@"key"] isEqual:@"com.google.Chrome"]){if(tabMode)continue;NSMutableDictionary *chrome=[process mutableCopy];chrome[@"isBrowserAggregate"]=@YES;[processes addObject:chrome];}
        else [processes addObject:process];
    }
    if(!tabMode)return processes;
    for(NSDictionary *tab in tabs){
        NSString *key=[NSString stringWithFormat:@"chrome-tab:%@:%@",tab[@"session"],tab[@"id"]];
        if(![tab[@"captured"] boolValue]&&![tab[@"active"] boolValue]&&![assignments containsObject:key])continue;
        NSString *title=[tab[@"title"] length]?tab[@"title"]:tab[@"host"];
        [processes addObject:@{@"key":key,@"name":[@"↗ " stringByAppendingString:title?:TXL(@"Chrome 탭")],@"ids":@[],@"bundles":@[],@"active":tab[@"active"]?:@NO,@"isBrowserTab":@YES,@"canVolume":@([tab[@"captured"] boolValue]),@"tabId":tab[@"id"],@"session":tab[@"session"],@"peak":tab[@"peak"]?:@0,@"fullTitle":title?:TXL(@"Chrome 탭")}];
    }
    return processes;
}
static NSArray<NSArray<NSNumber*>*> *TXNativeGroups(NSArray<NSDictionary*> *processes,NSArray<NSString*> *assignments) {
    NSMutableArray *groups=[NSMutableArray array];
    for(NSString *key in assignments){
        NSArray *ids=@[];
        for(NSDictionary *process in processes)if([process[@"key"] isEqual:key]&&![process[@"isBrowserTab"] boolValue]){
            if([process[@"ids"] isKindOfClass:NSArray.class])ids=[process[@"ids"] sortedArrayUsingSelector:@selector(compare:)];
            break;
        }
        [groups addObject:ids];
    }
    return groups;
}
static BOOL TXMayAutoStart(BOOL enabled,BOOL setupSeen,BOOL explicitlyStopped,BOOL sleeping) {return enabled&&setupSeen&&!explicitlyStopped&&!sleeping;}
static NSTimeInterval TXRetryDelay(NSUInteger attempt) {return attempt<3?((NSTimeInterval[]){3,10,30})[attempt]:0;}
static NSString *TXHexBytes(const unsigned char *bytes,NSUInteger length) {
    NSMutableString *hex=[NSMutableString stringWithCapacity:length*2];for(NSUInteger i=0;i<length;i++)[hex appendFormat:@"%02X",bytes[i]];return hex;
}
static NSString *TXDeviceUIDDigest(NSString *uid) {
    NSData *data=[uid dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);return TXHexBytes(digest,sizeof(digest));
}
static BOOL TXIsTX6Output(NSDictionary *device) {
    NSString *name=[device[@"name"] uppercaseString],*uid=[device[@"uid"] uppercaseString];return [name containsString:@"TX-6"]||[name containsString:@"TX6"]||[uid containsString:@"TX-6"]||[uid containsString:@"TX6"];
}
static NSString *TXOutputDeviceTitle(NSDictionary *device,NSArray<NSDictionary*> *devices) {
    NSString *name=device[@"name"]?:@"",*uid=device[@"uid"]?:@"",*title=TXIsTX6Output(device)?[name stringByAppendingFormat:@" · %@",TXL(@"스테레오 출력")]:name;NSMutableArray<NSString*> *others=[NSMutableArray array];
    for(NSDictionary *other in devices)if([other[@"name"] isEqual:name]&&![other[@"uid"] isEqual:uid])[others addObject:TXDeviceUIDDigest(other[@"uid"]?:@"")];
    if(!others.count)return title;
    NSString *digest=TXDeviceUIDDigest(uid);NSUInteger length=6;BOOL collision=YES;
    while(collision&&length<=digest.length){collision=NO;for(NSString *other in others)if([[other substringToIndex:length] isEqual:[digest substringToIndex:length]]){collision=YES;break;}if(collision&&length<digest.length)length+=2;else break;}
    NSString *identifier=[digest substringToIndex:length];
    if(collision){NSData *data=[uid dataUsingEncoding:NSUTF8StringEncoding];identifier=[identifier stringByAppendingFormat:@"-%@",TXHexBytes(data.bytes,data.length)];}
    return [title stringByAppendingFormat:@" · %@",identifier];
}
static NSString *TXOutputDeviceHelp(NSDictionary *device,NSString *title,NSString *error) {
    NSString *help=title?:@"";if(TXIsTX6Output(device))help=[help stringByAppendingFormat:@"\n%@",TXL(@"스테레오 출력입니다. 기기 페이더와 EQ도 적용됩니다. 앱의 6트랙 독립 출력 및 TX-6 AUX/CUE 라우팅은 지원하지 않습니다.")];return error.length?[help stringByAppendingFormat:@" · %@",error]:help;
}
static UInt32 TXSavedRoute(id value) {
    if(!value)return TXOutputMain;
    if(![value isKindOfClass:NSNumber.class])return TXOutputOff;
    double route=[value doubleValue];return isfinite(route)&&floor(route)==route&&route>=0&&route<=3?(UInt32)route:TXOutputOff;
}
static float TXSavedMonitorGain(id value) {
    if(!value)return 1;
    if(![value isKindOfClass:NSNumber.class]||!isfinite([value doubleValue]))return 0;
    return fmax(0,fmin(1,[value doubleValue]));
}
static NSArray<NSString*> *TXRouteTitles(void) {return @[TXL(@"메인"),TXL(@"미리 듣기"),TXL(@"둘 다"),TXL(@"끔")];}
static BOOL TXRunUIModelSelfCheck(void) {
    if(![TXVolumeText(0) isEqual:@"0"]||![TXVolumeText(.5) isEqual:@"50"]||![TXVolumeText(1) isEqual:@"99"]||TXVolumeGain(99)!=1||fabs(TXVolumeGain(25)-25.0/99)>1e-12||![TXVolumeHUD(1) isEqual:@"VOLUME 99"])return NO;
    TXFader *volume=[TXFader new];volume.value=98.0/99;[volume accessibilityPerformIncrement];if(fabs(volume.value-1)>1e-12||![volume.accessibilityValueDescription isEqual:@"99"])return NO;
    NSEvent *left=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:123];[volume keyDown:left];if(fabs(volume.value-98.0/99)>1e-12)return NO;
    TXVolumeSlider *menuVolume=[TXVolumeSlider new];menuVolume.minValue=0;menuVolume.maxValue=1;menuVolume.doubleValue=0;[menuVolume accessibilityPerformIncrement];if(fabs(menuVolume.doubleValue-TXVolumeStep)>1e-12)return NO;[menuVolume accessibilityPerformDecrement];if(menuVolume.doubleValue!=0)return NO;menuVolume.doubleValue=1;[menuVolume keyDown:left];if(fabs(menuVolume.doubleValue-98.0/99)>1e-12)return NO;menuVolume.doubleValue=1;if(![menuVolume.accessibilityValueDescription isEqual:@"99"])return NO;
    NSDictionary *studioA=@{@"name":@"Studio Display",@"uid":@"studioA"},*studioB=@{@"name":@"Studio Display",@"uid":@"studioB"},*unique=@{@"name":@"USB Headphones",@"uid":@"headphones"};NSArray *ordered=@[studioA,studioB,unique],*reversed=@[unique,studioB,studioA];
    if(![TXOutputDeviceTitle(studioA,ordered) isEqual:@"Studio Display · EC30F4"]||![TXOutputDeviceTitle(studioB,ordered) isEqual:@"Studio Display · ACF72A"]||![TXOutputDeviceTitle(unique,ordered) isEqual:@"USB Headphones"]||![TXOutputDeviceTitle(studioA,@[studioA]) isEqual:@"Studio Display"])return NO;
    for(NSDictionary *device in ordered)if(![TXOutputDeviceTitle(device,ordered) isEqual:TXOutputDeviceTitle(device,reversed)])return NO;
    NSDictionary *collisionA=@{@"name":@"USB Audio",@"uid":@"collision-fixture-2445"},*collisionB=@{@"name":@"USB Audio",@"uid":@"collision-fixture-3381"};NSArray *collisions=@[collisionA,collisionB];if(![TXOutputDeviceTitle(collisionA,collisions) isEqual:@"USB Audio · B9043340"]||![TXOutputDeviceTitle(collisionB,collisions) isEqual:@"USB Audio · B90433A4"]||![TXOutputDeviceTitle(collisionA,collisions) isEqual:TXOutputDeviceTitle(collisionA,@[collisionB,collisionA])])return NO;
    NSDictionary *txA=@{@"name":@"TX-6",@"uid":@"studioA"},*txB=@{@"name":@"TX-6",@"uid":@"studioB"},*txUID=@{@"name":@"USB Audio",@"uid":@"usb-tx6"};NSString *txTitle=[@"TX-6 · " stringByAppendingString:TXL(@"스테레오 출력")];
    if(![TXOutputDeviceTitle(txA,@[txA]) isEqual:txTitle]||![TXOutputDeviceTitle(txA,@[txA,txB]) isEqual:[txTitle stringByAppendingString:@" · EC30F4"]]||![TXOutputDeviceTitle(txB,@[txB,txA]) isEqual:[txTitle stringByAppendingString:@" · ACF72A"]]||![TXOutputDeviceTitle(txUID,@[txUID]) isEqual:[@"USB Audio · " stringByAppendingString:TXL(@"스테레오 출력")]])return NO;
    NSString *scope=TXL(@"스테레오 출력입니다. 기기 페이더와 EQ도 적용됩니다. 앱의 6트랙 독립 출력 및 TX-6 AUX/CUE 라우팅은 지원하지 않습니다.");
    if(![TXOutputDeviceHelp(txA,txTitle,nil) isEqual:[txTitle stringByAppendingFormat:@"\n%@",scope]]||![TXOutputDeviceHelp(unique,@"USB Headphones",nil) isEqual:@"USB Headphones"]||![TXOutputDeviceHelp(unique,@"USB Headphones",@"offline") isEqual:@"USB Headphones · offline"])return NO;
    if(TXSavedRoute(nil)!=TXOutputMain||TXSavedRoute(@0)!=TXOutputMain||TXSavedRoute(@1)!=TXOutputMonitor||TXSavedRoute(@2)!=TXOutputBoth||TXSavedRoute(@3)!=TXOutputOff)return NO;
    for(id invalid in @[@-1,@4,@1.5,@"1",NSNull.null,@(NAN)])if(TXSavedRoute(invalid)!=TXOutputOff)return NO;
    if(TXSavedMonitorGain(nil)!=1||TXSavedMonitorGain(@0)!=0||TXSavedMonitorGain(@2)!=1||TXSavedMonitorGain(@-1)!=0||TXSavedMonitorGain(@"bad")!=0||TXSavedMonitorGain(@(NAN))!=0)return NO;
    NSDictionary *profile=@{@"channels":@[@{@"route":@2}],@"monitorUID":@"offline-monitor",@"monitorGain":@0.42};NSData *stored=[NSPropertyListSerialization dataWithPropertyList:profile format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];NSDictionary *restored=[NSPropertyListSerialization propertyListWithData:stored options:NSPropertyListImmutable format:NULL error:nil];if(TXSavedRoute(restored[@"channels"][0][@"route"])!=TXOutputBoth||fabs(TXSavedMonitorGain(restored[@"monitorGain"])-.42)>.000001||![restored[@"monitorUID"] isEqual:@"offline-monitor"])return NO;
    NSArray *before=@[@"local.tx6mac.system-sounds",@"Claude",@"Xcode",@"Youna",@"",@""];NSSet *present=[NSSet setWithArray:before];
    if(![TXStableAssignments(before,present,@[@"Youna"],YES,nil) isEqual:before])return NO;
    NSArray *newApp=TXStableAssignments(before,[present setByAddingObject:@"New"],@[@"New",@"Youna"],YES,nil);
    if(![newApp isEqual:@[@"local.tx6mac.system-sounds",@"Claude",@"Xcode",@"Youna",@"New",@""]])return NO;
    NSMutableSet *closed=[present mutableCopy];[closed removeObject:@"Xcode"];
    if(![TXStableAssignments(before,closed,@[],YES,nil) isEqual:@[@"local.tx6mac.system-sounds",@"Claude",@"",@"Youna",@"",@""]])return NO;
    NSArray *full=@[@"local.tx6mac.system-sounds",@"A",@"B",@"C",@"D",@"E"];
    if(![TXStableAssignments(before,closed,@[@"New"],NO,[NSIndexSet indexSetWithIndex:2]) isEqual:before])return NO;
    if(![TXStableAssignments(full,[NSSet setWithArray:full],@[@"New"],YES,nil) isEqual:full])return NO;
    TXRenderState state={0};atomic_store(&state.gain[1],0.42);atomic_store(&state.muted[1],true);atomic_store(&state.eq[1][0],-3);
    NSArray *chrome=@[@"local.tx6mac.system-sounds",@"com.google.Chrome",@"Other",@"",@"",@""];
    NSArray *both=@[@"local.tx6mac.system-sounds",@"chrome-tab:A",@"Other",@"",@"com.google.Chrome",@"chrome-tab:B"];
    NSArray *onlyChrome=TXResolveChromeFamily(both,@[@"com.google.Chrome"],NO);
    if(![onlyChrome isEqual:@[@"local.tx6mac.system-sounds",@"",@"Other",@"",@"com.google.Chrome",@""]])return NO;
    if(![TXResolveChromeFamily(onlyChrome,@[@"com.google.Chrome"],NO) isEqual:onlyChrome])return NO;
    NSArray *legacyTabs=@[@"local.tx6mac.system-sounds",@"chrome-tab:A",@"Other",@"",@"chrome-tab:B",@""];
    if(![TXResolveChromeFamily(legacyTabs,@[],NO) isEqual:chrome])return NO;
    NSArray *onlyTabs=TXResolveChromeFamily(chrome,@[@"chrome-tab:A",@"chrome-tab:B"],YES);
    if(![onlyTabs isEqual:@[@"local.tx6mac.system-sounds",@"chrome-tab:A",@"Other",@"",@"",@""]])return NO;
    if(![TXResolveChromeFamily(onlyTabs,@[@"chrome-tab:A"],YES) isEqual:onlyTabs]||[TXResolveChromeFamily(chrome,@[],YES) containsObject:@"com.google.Chrome"])return NO;
    if(fabs(atomic_load(&state.gain[1])-0.42)>0.000001||!atomic_load(&state.muted[1])||atomic_load(&state.eq[1][0])!=-3)return NO;
    NSDictionary *chromeProcess=@{@"key":@"com.google.Chrome",@"ids":@[@155,@156,@157],@"active":@NO};
    NSDictionary *detectedTab=@{@"session":@"fixture",@"id":@7,@"title":@"검사",@"host":@"example.invalid",@"active":@YES,@"captured":@NO};
    NSArray *unconnected=TXBrowserProcesses(@[chromeProcess],@[detectedTab],@[],NO);
    if(unconnected.count!=1||![unconnected[0][@"ids"] isEqual:@[@155,@156,@157]])return NO;
    NSMutableDictionary *capturedTab=[detectedTab mutableCopy];capturedTab[@"captured"]=@YES;
    NSArray *connected=TXBrowserProcesses(@[chromeProcess],@[capturedTab],@[],NO);
    if(connected.count!=1||![connected[0][@"ids"] isEqual:unconnected[0][@"ids"]])return NO;
    NSArray *tabProcesses=TXBrowserProcesses(@[chromeProcess],@[capturedTab],@[],YES);
    NSArray *detectedProcesses=TXBrowserProcesses(@[chromeProcess],@[detectedTab],@[],YES);
    if(tabProcesses.count!=1||[tabProcesses[0][@"ids"] count]||![tabProcesses[0][@"isBrowserTab"] boolValue]||![tabProcesses[0][@"canVolume"] boolValue])return NO;
    if(detectedProcesses.count!=1||[detectedProcesses[0][@"canVolume"] boolValue]||[detectedProcesses[0][@"ids"] count])return NO;
    NSArray *nativeAssignments=@[@"local.tx6mac.system-sounds",@"com.google.Chrome",@"chrome-tab:fixture:7",@"",@"",@""];
    NSArray *uncapturedGroups=TXNativeGroups(unconnected,nativeAssignments),*capturedGroups=TXNativeGroups(connected,nativeAssignments);
    if(![uncapturedGroups isEqual:capturedGroups]||![capturedGroups[1] isEqual:@[@155,@156,@157]]||[capturedGroups[2] count])return NO;
    NSArray *tabGroups=TXNativeGroups(tabProcesses,nativeAssignments);if([tabGroups[1] count]||[tabGroups[2] count])return NO;
    if(TXAutomaticPriority(chromeProcess)>=TXAutomaticPriority(@{@"key":@"Other"})||TXAutomaticPriority(@{@"key":@"Other"})>=TXAutomaticPriority(tabProcesses[0])||TXAutomaticPriority(tabProcesses[0])>=TXAutomaticPriority(detectedProcesses[0]))return NO;
    return TXMayAutoStart(YES,YES,NO,NO)&&!TXMayAutoStart(YES,NO,NO,NO)&&!TXMayAutoStart(YES,YES,YES,NO)&&!TXMayAutoStart(YES,YES,NO,YES)&&!TXMayAutoStart(NO,YES,NO,NO)&&TXRetryDelay(0)==3&&TXRetryDelay(1)==10&&TXRetryDelay(2)==30&&TXRetryDelay(3)==0;
}

// CC31 also controls device menus; require a confirmed home context.
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
    return context->suspended&&(context->reason||cc==31);
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
    context=(TXDeviceContext){.suspended=YES};for(UInt8 cc=1;cc<=30;cc++)if(TXConsumeDeviceContext(&context,cc,127))return NO;
    if(TXConsumeDeviceContext(&context,33,127)||TXConsumeDeviceContext(&context,34,127))return NO;
    return context.suspended&&!context.reason&&TXConsumeDeviceContext(&context,31,1);
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

@interface TXAudio (TXOutputIdentity)
- (NSString*)outputUIDForDevice:(AudioDeviceID)device expectedUID:(NSString*)expectedUID;
@end
@implementation TXAudio (TXOutputIdentity)
- (NSString*)outputUIDForDevice:(AudioDeviceID)device expectedUID:(NSString*)expectedUID {return [TXAudio uid:device];}
@end

// The built-in check uses this backend without opening any hardware or permission prompt.
@interface TXHALCheckAudio:TXAudio
@property(atomic) NSUInteger starts,stops,blockStart;
@property(atomic) BOOL usedMain,failMeters,failMonitor;
@property(nonatomic,strong) dispatch_semaphore_t firstStartGate;
@property(atomic,copy) NSDictionary<NSNumber*,NSString*> *liveUIDs,*UIDsAfterFailedStart;
@end
@implementation TXHALCheckAudio
- (NSString*)outputUIDForDevice:(AudioDeviceID)device expectedUID:(NSString*)expectedUID {return self.liveUIDs[@(device)]?:expectedUID;}
- (BOOL)startOnDevice:(AudioDeviceID)device groups:(NSArray*)groups {
    self.usedMain=self.usedMain||NSThread.isMainThread;self.starts++;
    if(self.starts==1||self.starts==self.blockStart)dispatch_semaphore_wait(self.firstStartGate,DISPATCH_TIME_FOREVER);
    if(self.failMonitor&&self.monitorOutputDevice){self.lastError=@"Simulated monitor failure";return NO;}
    if(self.failMeters&&self.meterOutputDevice){self.lastError=@"Simulated USB meter failure";if(self.UIDsAfterFailedStart)self.liveUIDs=self.UIDsAfterFailedStart;return NO;}self.lastError=@"";return YES;
}
- (BOOL)metering {return self.meterOutputDevice!=0&&!self.failMeters;}
- (BOOL)monitoring {return self.monitorOutputDevice!=0&&!self.failMonitor;}
- (void)stop {self.usedMain=self.usedMain||NSThread.isMainThread;self.stops++;}
@end

@interface TXSceneCheckDefaults:NSObject
@property(nonatomic,strong) NSMutableDictionary *values;
@end
@implementation TXSceneCheckDefaults
- (instancetype)init {if((self=[super init]))_values=[NSMutableDictionary dictionary];return self;}
- (id)objectForKey:(NSString*)key {return _values[key];}
- (void)setObject:(id)value forKey:(NSString*)key {_values[key]=value;}
@end
@interface TXSceneCheckAudio:TXHALCheckAudio
@property(nonatomic,strong) NSMutableArray *events;
@property(atomic) BOOL failAll,failTarget,wrongOrder;
@property(atomic) float expectedOldGain;
@property(atomic) BOOL expectOldStop;
@end
@implementation TXSceneCheckAudio
- (instancetype)init {if((self=[super init]))_events=[NSMutableArray array];return self;}
- (BOOL)startOnDevice:(AudioDeviceID)device groups:(NSArray*)groups {
    self.usedMain=self.usedMain||NSThread.isMainThread;self.starts++;[_events addObject:[NSString stringWithFormat:@"start:%u",device]];if(!atomic_load(&self.state->transitionMuted))self.wrongOrder=YES;
    if(self.starts==self.blockStart)dispatch_semaphore_wait(self.firstStartGate,DISPATCH_TIME_FOREVER);
    if(self.failAll||(self.failTarget&&device==2)||(self.failMeters&&self.meterOutputDevice)||(self.failMonitor&&self.monitorOutputDevice)){self.lastError=@"Simulated scene start failure";return NO;}
    atomic_store(&self.state->callbacks,1);atomic_store(&self.state->layoutFault,0);self.lastError=@"";return YES;
}
- (void)stop {self.usedMain=self.usedMain||NSThread.isMainThread;self.stops++;if(self.expectOldStop){if(fabs(atomic_load(&self.state->gain[1])-self.expectedOldGain)>.000001)self.wrongOrder=YES;self.expectOldStop=NO;}[_events addObject:@"stop"];atomic_store(&self.state->callbacks,0);}
@end
@interface TXSceneCheckGuard:TXAudioMuteGuard
@property(nonatomic,strong) TXSceneCheckAudio *audio;
@property(nonatomic) BOOL held,failBegin,failEnd,wrongRelease;
@property(atomic) BOOL ending;
@property(nonatomic,strong) dispatch_semaphore_t endGate;
@end
@implementation TXSceneCheckGuard
- (BOOL)active {return _held;}
- (BOOL)begin:(NSError**)error {[_audio.events addObject:@"begin"];if(_failBegin){if(error)*error=[NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulated begin failure"}];return NO;}_held=YES;return YES;}
- (BOOL)end:(NSError**)error {[_audio.events addObject:@"end"];if(_endGate){self.ending=YES;dispatch_semaphore_wait(_endGate,DISPATCH_TIME_FOREVER);self.ending=NO;}if(_failEnd){if(error)*error=[NSError errorWithDomain:@"fixture" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Simulated end failure"}];return NO;}_held=NO;return YES;}
@end

@interface TXApp:NSObject<NSApplicationDelegate,NSWindowDelegate,NSMenuDelegate,NSPopoverDelegate,NSTextFieldDelegate>
+ (BOOL)halSelfCheck;
+ (BOOL)sceneControllerSelfCheck;
- (void)finishSceneQuit;
- (void)replyToSceneTermination;
@end
@interface TXHALCheckApp:TXApp
@end
@interface TXSceneCheckApp:TXApp
@property(nonatomic,strong) TXSceneCheckDefaults *memoryDefaults;
@property(nonatomic) BOOL quitWaitRequested,quitDelegateReturned,quitRepliedEarly,defaultModeProbe;
@property(nonatomic) NSUInteger quitPollCount,quitReplyCount;
@end
@implementation TXApp {
    TXSceneStore *_sceneStore;NSPopUpButton *_sceneMenu;NSMenu *_sceneTrackingMenu;BOOL _sceneMenuRefreshPending;NSString *_selectedSceneID;NSMutableIndexSet *_sceneReservations;NSMutableArray *_pendingSources,*_sceneMIDI;NSDictionary *_sceneUndo,*_sceneBaseline,*_sceneRollbackRequest;BOOL _sceneApplying,_sceneProtected,_sceneOutputPinned,_sceneModelCommitted,_sceneStopping,_sceneQuitting,_sceneReplayingMIDI,_sceneMIDIOverflow;TXAudioMuteGuard *_sceneGuard;_Atomic(NSUInteger) _sceneGeneration;NSAlert *_sceneAlert;NSTextField *_sceneNameInput,*_sceneNameError;BOOL _sceneRenaming;
    TXAudio *_audio;TXMIDI *_midi;TXBrowserBridge *_browser;NSDate *_lastBrowserSend;NSTextField *_browserLabel;NSWindow *_window;TXCanvas *_canvas;NSStatusItem *_statusItem;
    NSMenu *_statusMenu;CABTLEMIDIWindowController *_bluetooth;
    NSPopUpButton *_outputMenu,*_monitorMenu,*_transportMenu,*_languageMenu;NSSlider *_monitorSlider;NSTextField *_monitorLevelLabel;NSWindow *_setupWindow;NSTextField *_setupDevice,*_setupAudio;NSButton *_setupStart;BOOL _sleepResume,_sleeping,_autoStart,_explicitStop,_retryExhausted,_audioStartConsent;NSUInteger _retryAttempt;NSDate *_retryAt,*_lastStatusWrite;NSButton *_autoStartButton;NSButton *_startButton,*_pickupButton,*_invertButton,*_masterMute,*_soundKey,*_autoButton,*_hudButton;TXHUDPanel *_hud;TXHUDView *_hudView;NSTimer *_hudDismiss;NSDictionary *_pendingHUD;BOOL _hudEnabled,_statusMenuTracking;NSPopover *_settingsPopover;TXDeviceContext _deviceContext;NSTextField *_deviceContextLabel,*_calibrationInput;NSButton *_resumeDeviceButton;
    TXLevelsController *_levelsController;TXLevelSnapshot _levelSnapshot;
    TXFader *_masterFader;NSArray<TXChannel*> *_channels;NSTextField *_remainderLabel;
    BOOL _browserTabMode,_controllerConnected,_followDefaultOutput,_usbMeters,_usbMetering;NSButton *_usbMetersButton;NSTextField *_usbMetersStatus;NSString *_usbMeterError,*_monitorError,*_monitorUID,*_monitorName;BOOL _monitoring;NSButton *_browserTabsButton;
    NSArray<NSDictionary*> *_outputs,*_processes;NSMutableArray<NSString*> *_assignments;NSString *_outputUID,*_signature,*_statusFile,*_lastMIDI;
    NSTimer *_poll,*_meter;BOOL _desiredRunning,_isBuilding,_pickup,_invert,_autoAssign;NSInteger _overflowCount;NSString *_outputMenuSignature,*_processMenuSignature;NSDate *_startedAt,*_progressAt;uint64_t _progressFrames;BOOL _latched[6][4];double _previous[6][4];BOOL _havePrevious[6][4];
    NSMenuItem *_masterMenuLabel;NSSlider *_menuMaster;NSMutableArray<NSMenuItem*> *_muteItems;NSDate *_lastSave,*_lastLimitDate;uint64_t _lastLimitedFrames;
    dispatch_queue_t _halQueue;BOOL _halBusy,_halSnapshotRequested,_halSnapshotReady,_audioReady,_halWaitReported,_halStopping;
    NSUInteger _halGeneration;NSDictionary *_pendingHALRequest,*_halSnapshot;NSString *_pendingAudioSignature,*_audioError;NSDate *_halStartedAt;
}
- (void)applicationDidFinishLaunching:(NSNotification*)note {
    _halQueue=dispatch_queue_create("local.tx6mac.hal",DISPATCH_QUEUE_SERIAL);_halSnapshot=@{};_audioError=@"";
    _audio=[TXAudio new];_midi=[TXMIDI new];_browser=[TXBrowserBridge new];_assignments=[NSMutableArray array];_outputs=@[];_processes=@[];_lastMIDI=TXL(@"아직 조작 신호가 없습니다");_deviceContext.suspended=YES;
    NSArray *args=NSProcessInfo.processInfo.arguments;NSUInteger index=[args indexOfObject:@"--status-file"];if(index!=NSNotFound&&index+1<args.count)_statusFile=args[index+1];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageDidChange:) name:TXLanguageDidChangeNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    _sceneStore=[[TXSceneStore alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];_sceneGuard=[TXAudioMuteGuard new];
    [self loadSettings];[self buildWindow];[self buildStatusItem];[self refreshDevices];[self requestHALSnapshot];
    __weak TXApp *weakSelf=self;_midi.received=^(NSString *source,UInt8 channel,UInt8 cc,UInt8 value){[weakSelf handleMIDI:source channel:channel cc:cc value:value];};
    _browser.changed=^{dispatch_async(dispatch_get_main_queue(),^{[weakSelf browserChanged];});};[_browser start];
    _midi.changed=^{dispatch_async(dispatch_get_main_queue(),^{[weakSelf deviceConnectionChanged];});};[_midi start];
    _poll=[NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    _meter=[NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_poll forMode:NSRunLoopCommonModes];[[NSRunLoop mainRunLoop] addTimer:_meter forMode:NSRunLoopCommonModes];
    [_window center];[_window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[self updateStatus];if(![[NSUserDefaults standardUserDefaults] boolForKey:@"TX6Mac.setupSeen"]||[args containsObject:@"--show-setup"])[self showSetup:nil];else if(TXMayAutoStart(_autoStart,_audioStartConsent,_explicitStop,_sleeping)){_desiredRunning=YES;[self rebuildAudio];}
}
- (void)loadSettings {
    id stored=[[NSUserDefaults standardUserDefaults] objectForKey:@"TX6Mac.profile"];NSMutableDictionary *d=[stored isKindOfClass:NSDictionary.class]?[stored mutableCopy]:[NSMutableDictionary dictionary];
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if(![defaults boolForKey:@"TX6Mac.autoStartConsentV1"]){if([stored isKindOfClass:NSDictionary.class]&&[defaults boolForKey:@"TX6Mac.setupSeen"])[defaults setBool:YES forKey:@"TX6Mac.audioStartConsent"];[defaults setBool:YES forKey:@"TX6Mac.autoStartConsentV1"];}_audioStartConsent=[defaults boolForKey:@"TX6Mac.audioStartConsent"];
    if(![d[@"assignments"] isKindOfClass:NSArray.class])d[@"assignments"]=@[];
    NSMutableArray *safeChannels=[NSMutableArray array];id rawChannels=d[@"channels"];
    if([rawChannels isKindOfClass:NSArray.class])for(id raw in rawChannels){NSMutableDictionary *channel=[NSMutableDictionary dictionary];if([raw isKindOfClass:NSDictionary.class]){for(NSString *key in @[@"gain",@"muted"])if([raw[key] isKindOfClass:NSNumber.class]&&isfinite([raw[key] doubleValue]))channel[key]=raw[key];NSMutableArray *eq=[NSMutableArray array];id rawEQ=raw[@"eq"];if([rawEQ isKindOfClass:NSArray.class])for(id value in rawEQ)[eq addObject:[value isKindOfClass:NSNumber.class]&&isfinite([value doubleValue])?value:@0];channel[@"eq"]=eq;if(raw[@"route"])channel[@"route"]=@(TXSavedRoute(raw[@"route"]));}[safeChannels addObject:channel];}d[@"channels"]=safeChannels;
    for(NSString *key in @[@"master",@"showHUD",@"autoAssign",@"chromeTabs",@"pickup",@"invert",@"autoStart",@"followDefaultOutput",@"usbMeters"])if(d[key]&&(![d[key] isKindOfClass:NSNumber.class]||!isfinite([d[key] doubleValue])))[d removeObjectForKey:key];
    if(![d[@"outputUID"] isKindOfClass:NSString.class])[d removeObjectForKey:@"outputUID"];
    if(![@[@"auto",@"usb",@"ble"] containsObject:d[@"transport"]?:@""])[d removeObjectForKey:@"transport"];
    NSArray *saved=d[@"assignments"];for(int i=0;i<6;i++)[_assignments addObject:(saved.count>(NSUInteger)i&&[saved[i] isKindOfClass:NSString.class])?saved[i]:@""];
    if([_assignments[0] isEqual:@"local.tx6mac.system-sounds"]){NSMutableSet *seen=[NSMutableSet setWithObject:@"local.tx6mac.system-sounds"];for(int i=1;i<6;i++){NSString *key=_assignments[i];if(key.length&&[seen containsObject:key])_assignments[i]=@"";else if(key.length)[seen addObject:key];}}
    else {NSMutableArray *migrated=[NSMutableArray array];for(NSString *key in _assignments)if(key.length&&![key isEqual:@"local.tx6mac.system-sounds"]&&![migrated containsObject:key])[migrated addObject:key];[_assignments removeAllObjects];[_assignments addObject:@"local.tx6mac.system-sounds"];for(int i=0;i<5;i++)[_assignments addObject:migrated.count>(NSUInteger)i?migrated[i]:@""]; }
    _monitorUID=[d[@"monitorUID"] isKindOfClass:NSString.class]?d[@"monitorUID"]:@"";_monitorName=[d[@"monitorName"] isKindOfClass:NSString.class]?d[@"monitorName"]:_monitorUID;atomic_store(&_audio.state->monitorGain,TXSavedMonitorGain(d[@"monitorGain"]));
    _outputUID=d[@"outputUID"]?:@"";_followDefaultOutput=d[@"followDefaultOutput"]?[d[@"followDefaultOutput"] boolValue]:!_outputUID.length;_midi.transport=d[@"transport"]?:@"auto";
    _usbMeters=[d[@"usbMeters"] boolValue];_browserTabMode=[d[@"chromeTabs"] boolValue];_hudEnabled=d[@"showHUD"]?[d[@"showHUD"] boolValue]:YES;_autoAssign=d[@"autoAssign"]?[d[@"autoAssign"] boolValue]:YES;_pickup=d[@"pickup"]?[d[@"pickup"] boolValue]:NO;_autoStart=d[@"autoStart"]?[d[@"autoStart"] boolValue]:YES;if(![[NSUserDefaults standardUserDefaults] boolForKey:@"TX6Mac.directControlV1"]){_pickup=NO;[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"TX6Mac.directControlV1"];}_invert=[d[@"invert"] boolValue];
    TXRenderState *s=_audio.state;atomic_store(&s->master,d[@"master"]?fmax(0,fmin(1,[d[@"master"] floatValue])):1);
    for(int i=0;i<6;i++){
        NSDictionary *ch=[d[@"channels"] count]>(NSUInteger)i?d[@"channels"][i]:@{};
        atomic_store(&s->gain[i],ch[@"gain"]?fmax(0,fmin(1,[ch[@"gain"] floatValue])):1);
        atomic_store(&s->muted[i],[ch[@"muted"] boolValue]);atomic_store(&s->route[i],TXSavedRoute(ch[@"route"]));
        for(int b=0;b<3;b++)atomic_store(&s->eq[i][b],[ch[@"eq"] count]>(NSUInteger)b?fmax(-18,fmin(18,[ch[@"eq"][b] floatValue])):0);
    }
    [self restoreSceneProfile:d];
    [self saveSettings];
}
- (NSUserDefaults*)profileDefaults {return NSUserDefaults.standardUserDefaults;}
- (void)saveSettings {
    if(_sceneApplying||_sceneStopping)return;[self refreshSceneMenu];
    [[self profileDefaults] setObject:[self profileSettings] forKey:@"TX6Mac.profile"];
    _lastSave=NSDate.date;[self sendBrowserControls];
}
- (NSDictionary*)profileSettings {
    NSMutableArray *channels=[NSMutableArray array];TXRenderState *s=_audio.state;
    for(int i=0;i<6;i++)[channels addObject:@{@"gain":@(atomic_load(&s->gain[i])),@"muted":@(atomic_load(&s->muted[i])),@"route":@(atomic_load(&s->route[i])),@"eq":@[@(atomic_load(&s->eq[i][0])),@(atomic_load(&s->eq[i][1])),@(atomic_load(&s->eq[i][2]))]}];
    return @{@"sceneReservations":[self sceneReservationNumbers],@"pendingSources":_pendingSources?:@[@"",@"",@"",@"",@"",@""],@"sceneOutputPinned":@(_sceneOutputPinned),@"sceneProtected":@(_sceneProtected),@"selectedSceneID":_selectedSceneID?:@"",@"assignments":_assignments,@"monitorUID":_monitorUID?:@"",@"monitorName":_monitorName?:@"",@"monitorGain":@(atomic_load(&s->monitorGain)),@"outputUID":_outputUID?:@"",@"followDefaultOutput":@(_followDefaultOutput),@"transport":_midi.transport?:@"auto",@"autoAssign":@(_autoAssign),@"chromeTabs":@(_browserTabMode),@"usbMeters":@(_usbMeters),@"autoStart":@(_autoStart),@"showHUD":@(_hudEnabled),@"pickup":@(_pickup),@"invert":@(_invert),@"master":@(atomic_load(&s->master)),@"channels":channels};
}
- (NSArray*)sceneReservationNumbers {
    NSMutableArray *numbers=[NSMutableArray array];[_sceneReservations enumerateIndexesUsingBlock:^(NSUInteger index,BOOL *stop){[numbers addObject:@(index)];}];return numbers;
}
- (void)restoreSceneProfile:(NSDictionary*)profile {
    _sceneReservations=[NSMutableIndexSet indexSet];_pendingSources=[@[@"",@"",@"",@"",@"",@""] mutableCopy];
    if([profile[@"sceneReservations"] isKindOfClass:NSArray.class])for(id value in profile[@"sceneReservations"])if([value isKindOfClass:NSNumber.class]&&[value integerValue]>0&&[value integerValue]<6)[_sceneReservations addIndex:[value unsignedIntegerValue]];
    id pending=profile[@"pendingSources"];if([pending isKindOfClass:NSArray.class]&&[pending count]==6)for(int i=1;i<6;i++)if([@[@"tab",@"process"] containsObject:pending[i]]&&(![pending[i] isEqual:@"tab"]||_browserTabMode)){_pendingSources[i]=pending[i];_assignments[i]=@"";[_sceneReservations addIndex:i];}
    _sceneOutputPinned=[profile[@"sceneOutputPinned"] isKindOfClass:NSNumber.class]&&[profile[@"sceneOutputPinned"] boolValue];_sceneProtected=[profile[@"sceneProtected"] boolValue]||_sceneOutputPinned||_sceneReservations.count>0;
    if([profile[@"selectedSceneID"] isKindOfClass:NSString.class]&&[_sceneStore sceneWithID:profile[@"selectedSceneID"]])_selectedSceneID=profile[@"selectedSceneID"];
}
- (NSDictionary*)sceneSnapshot {return [TXSceneStore canonicalSnapshot:[self runtimeSceneSnapshot] error:NULL];}
- (NSDictionary*)runtimeSceneSnapshot {
    NSMutableArray *channels=[NSMutableArray array];TXRenderState *state=_audio.state;
    for(int i=0;i<6;i++)[channels addObject:@{@"gain":@(atomic_load(&state->gain[i])),@"eq":@[@(atomic_load(&state->eq[i][0])),@(atomic_load(&state->eq[i][1])),@(atomic_load(&state->eq[i][2]))],@"muted":@(atomic_load(&state->muted[i])),@"route":@(atomic_load(&state->route[i]))}];
    return @{@"version":@1,@"assignments":_assignments?:@[],@"channels":channels,@"pendingSources":_pendingSources?:@[@"",@"",@"",@"",@"",@""],@"followDefaultOutput":@(_followDefaultOutput),@"outputUID":_outputUID?:@"",@"monitorUID":_monitorUID?:@"",@"monitorName":_monitorName?:@"",@"monitorGain":@(atomic_load(&state->monitorGain)),@"chromeTabs":@(_browserTabMode),@"sceneReservations":[self sceneReservationNumbers],@"sceneOutputPinned":@(_sceneOutputPinned)};
}
- (NSString*)sceneErrorText:(NSError*)error {
    if([error.domain isEqual:TXSceneErrorDomain]){switch(error.code){
        case TXSceneErrorInvalidName:return TXL(@"이름은 제어 문자 없이 1–32자로 입력하세요.");
        case TXSceneErrorDuplicateName:return TXL(@"이미 사용 중인 씬 이름입니다.");
        case TXSceneErrorLimitReached:return TXL(@"씬은 최대 16개까지 저장할 수 있습니다.");
        case TXSceneErrorUnsupportedVersion:case TXSceneErrorReadOnly:return TXL(@"씬 저장소를 읽을 수 없습니다. 현재 믹서는 계속 사용할 수 있습니다.");
        default:return TXL(@"씬 데이터가 올바르지 않아 변경하지 않았습니다.");
    }}return error.localizedDescription?:TXL(@"씬 전환 실패 · 중지 후 다시 시도하세요.");
}
- (BOOL)sceneDirty {NSDictionary *entry=[_sceneStore sceneWithID:_selectedSceneID];return entry&&![TXSceneStore snapshot:[self sceneSnapshot] equals:entry[@"snapshot"]];}
- (NSMenu*)sceneActionMenu {
    NSMenu *menu=[NSMenu new];menu.autoenablesItems=NO;NSDictionary *selected=[_sceneStore sceneWithID:_selectedSceneID];BOOL dirty=[self sceneDirty];
    NSString *title=selected?[selected[@"name"] stringByAppendingString:dirty?@" •":@""]:TXL(@"저장하지 않은 믹스");if(_sceneApplying)title=[title stringByAppendingFormat:@" · %@",TXL(@"적용 중")];
    NSMenuItem *current=[[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];current.enabled=NO;current.toolTip=selected[@"name"]?:title;[menu addItem:current];[menu addItem:NSMenuItem.separatorItem];
    for(NSDictionary *entry in _sceneStore.scenes){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[@"name"] action:@selector(sceneSelected:) keyEquivalent:@""];item.target=self;item.representedObject=entry[@"id"];item.state=[entry[@"id"] isEqual:_selectedSceneID]?NSControlStateValueOn:NSControlStateValueOff;item.toolTip=entry[@"name"];item.enabled=!_sceneStopping&&!_sceneQuitting;[menu addItem:item];}
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *commands=@[@[TXL(@"새 이름으로 저장…"),NSStringFromSelector(@selector(sceneSaveAs:))],@[TXL(@"선택한 씬 덮어쓰기"),NSStringFromSelector(@selector(sceneOverwrite:))],@[TXL(@"이름 변경…"),NSStringFromSelector(@selector(sceneRename:))],@[TXL(@"씬 삭제"),NSStringFromSelector(@selector(sceneDelete:))],@[TXL(@"씬 작업 실행 취소"),NSStringFromSelector(@selector(sceneUndo:))]];
    for(NSUInteger i=0;i<commands.count;i++){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:commands[i][0] action:NSSelectorFromString(commands[i][1]) keyEquivalent:@""];item.target=self;item.enabled=!_sceneApplying&&!_sceneStopping&&!_sceneQuitting&&!_sceneStore.readOnly&&(i==0?_sceneStore.scenes.count<16:i==4?_sceneUndo!=nil:selected!=nil);[menu addItem:item];}
    if(_sceneStore.readOnly){NSMenuItem *error=[[NSMenuItem alloc] initWithTitle:TXL(@"씬 저장소를 읽을 수 없습니다. 현재 믹서는 계속 사용할 수 있습니다.") action:nil keyEquivalent:@""];error.enabled=NO;[menu addItem:error];}return menu;
}
- (void)refreshSceneMenu {
    if(!_sceneMenu)return;if(_sceneTrackingMenu){_sceneMenuRefreshPending=YES;return;}_sceneMenuRefreshPending=NO;NSMenu *menu=[self sceneActionMenu];menu.delegate=self;_sceneMenu.menu=menu;[_sceneMenu selectItemAtIndex:0];_sceneMenu.toolTip=[_sceneStore sceneWithID:_selectedSceneID][@"name"]?:TXL(@"저장하지 않은 믹스");_sceneMenu.accessibilityValue=[NSString stringWithFormat:@"%@%@",_sceneMenu.toolTip,[self sceneDirty]?[@" · " stringByAppendingString:TXL(@"저장하지 않은 변경")]:@""];_sceneMenu.needsDisplay=YES;
}
- (void)sceneSelected:(NSMenuItem*)sender {NSDictionary *entry=[_sceneStore sceneWithID:sender.representedObject];if(entry)[self recallSnapshot:entry[@"snapshot"] sceneID:entry[@"id"] recordUndo:YES];}
- (BOOL)saveSceneName:(NSString*)name rename:(BOOL)rename error:(NSError**)error {
    if(_sceneApplying||_sceneStopping||_sceneQuitting)return NO;NSDictionary *before=[_sceneStore sceneWithID:_selectedSceneID];
    if(rename){if(![_sceneStore renameSceneID:_selectedSceneID name:name error:error])return NO;_sceneUndo=@{@"kind":@"rename",@"entry":before};}
    else{NSDictionary *entry=[_sceneStore addSceneNamed:name snapshot:[self sceneSnapshot] error:error];if(!entry)return NO;_sceneUndo=@{@"kind":@"add",@"id":entry[@"id"],@"selected":_selectedSceneID?:@""};_selectedSceneID=entry[@"id"];}
    [self saveSettings];[self refreshSceneMenu];return YES;
}
- (void)showSceneName:(BOOL)rename {
    if(_sceneAlert||_sceneApplying||_sceneStopping||_sceneQuitting||_sceneStore.readOnly)return;_sceneRenaming=rename;_sceneAlert=[NSAlert new];_sceneAlert.messageText=rename?TXL(@"이름 변경…"):TXL(@"새 이름으로 저장…");[_sceneAlert addButtonWithTitle:TXL(@"저장")];[_sceneAlert addButtonWithTitle:TXL(@"취소")];
    NSView *view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,340,72)];_sceneNameInput=[[NSTextField alloc] initWithFrame:NSMakeRect(0,40,340,26)];_sceneNameInput.stringValue=rename?([_sceneStore sceneWithID:_selectedSceneID][@"name"]?:@""):@"";_sceneNameInput.delegate=self;_sceneNameInput.accessibilityLabel=TXL(@"씬 이름");[view addSubview:_sceneNameInput];_sceneNameError=Label(@"",NSMakeRect(0,0,340,34),11,NO);_sceneNameError.textColor=NSColor.systemRedColor;_sceneNameError.maximumNumberOfLines=2;[view addSubview:_sceneNameError];_sceneAlert.accessoryView=view;
    NSButton *save=_sceneAlert.buttons.firstObject;save.target=self;save.action=@selector(confirmSceneName:);[_sceneAlert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){self->_sceneAlert=nil;self->_sceneNameInput=nil;self->_sceneNameError=nil;[self refreshSceneMenu];}];[_sceneAlert.window makeFirstResponder:_sceneNameInput];
}
- (void)confirmSceneName:(id)sender {NSError *error=nil;if([self saveSceneName:_sceneNameInput.stringValue rename:_sceneRenaming error:&error])[_window endSheet:_sceneAlert.window returnCode:NSAlertFirstButtonReturn];else _sceneNameError.stringValue=[self sceneErrorText:error];}
- (void)controlTextDidChange:(NSNotification*)notification {if(notification.object==_sceneNameInput)_sceneNameError.stringValue=@"";}
- (void)sceneSaveAs:(id)sender {[self showSceneName:NO];}
- (void)sceneRename:(id)sender {[self showSceneName:YES];}
- (void)sceneOverwrite:(id)sender {if(_sceneApplying||_sceneStopping||_sceneQuitting)return;NSDictionary *before=[_sceneStore sceneWithID:_selectedSceneID];NSError *error=nil;if([_sceneStore updateSceneID:_selectedSceneID snapshot:[self sceneSnapshot] error:&error])_sceneUndo=@{@"kind":@"overwrite",@"entry":before};else _canvas.message=[self sceneErrorText:error];[self refreshSceneMenu];}
- (void)sceneDelete:(id)sender {if(_sceneApplying||_sceneStopping||_sceneQuitting)return;NSDictionary *before=[_sceneStore sceneWithID:_selectedSceneID];if(!before)return;NSUInteger index=[_sceneStore.scenes indexOfObject:before];NSError *error=nil;if([_sceneStore removeSceneID:_selectedSceneID error:&error]){_sceneUndo=@{@"kind":@"delete",@"entry":before,@"index":@(index)};_selectedSceneID=nil;[self saveSettings];}else _canvas.message=[self sceneErrorText:error];[self refreshSceneMenu];}
- (void)sceneUndo:(id)sender {
    if(!_sceneUndo||_sceneApplying||_sceneStopping||_sceneQuitting)return;NSDictionary *undo=_sceneUndo;NSString *kind=undo[@"kind"];NSError *error=nil;BOOL ok=NO;
    if([kind isEqual:@"load"]){[self recallSnapshot:undo[@"snapshot"] sceneID:undo[@"selected"] recordUndo:NO runtime:YES];return;}
    if([kind isEqual:@"add"]){ok=[_sceneStore removeSceneID:undo[@"id"] error:&error];if(ok)_selectedSceneID=undo[@"selected"];}
    if([kind isEqual:@"delete"]){ok=[_sceneStore restoreEntry:undo[@"entry"] atIndex:[undo[@"index"] unsignedIntegerValue] error:&error];if(ok)_selectedSceneID=undo[@"entry"][@"id"];}
    if([kind isEqual:@"rename"])ok=[_sceneStore renameSceneID:undo[@"entry"][@"id"] name:undo[@"entry"][@"name"] error:&error];
    if([kind isEqual:@"overwrite"])ok=[_sceneStore updateSceneID:undo[@"entry"][@"id"] snapshot:undo[@"entry"][@"snapshot"] error:&error];
    if(ok){_sceneUndo=nil;[self saveSettings];}else _canvas.message=[self sceneErrorText:error];[self refreshSceneMenu];
}
- (void)applySceneDSP:(NSDictionary*)snapshot {
    TXRenderState *state=_audio.state;for(int i=0;i<6;i++){NSDictionary *channel=snapshot[@"channels"][i];atomic_store(&state->gain[i],[channel[@"gain"] floatValue]);atomic_store(&state->muted[i],[channel[@"muted"] boolValue]);atomic_store(&state->route[i],[channel[@"route"] unsignedIntValue]);for(int b=0;b<3;b++)atomic_store(&state->eq[i][b],[channel[@"eq"][b] floatValue]);}atomic_store(&state->monitorGain,[snapshot[@"monitorGain"] floatValue]);
}
- (void)commitSceneModel:(NSDictionary*)snapshot sceneID:(NSString*)sceneID {
    _assignments=[snapshot[@"assignments"] mutableCopy];_pendingSources=[snapshot[@"pendingSources"] mutableCopy];_sceneReservations=[NSMutableIndexSet indexSet];if(snapshot[@"sceneReservations"]){for(NSNumber *index in snapshot[@"sceneReservations"])if(index.integerValue>0&&index.integerValue<6)[_sceneReservations addIndex:index.unsignedIntegerValue];}else for(int i=1;i<6;i++)if([_assignments[i] length]||[_pendingSources[i] length])[_sceneReservations addIndex:i];
    _followDefaultOutput=[snapshot[@"followDefaultOutput"] boolValue];_outputUID=_followDefaultOutput?(_halSnapshot[@"defaultUID"]?:@""):snapshot[@"outputUID"];_sceneOutputPinned=snapshot[@"sceneOutputPinned"]?[snapshot[@"sceneOutputPinned"] boolValue]:!_followDefaultOutput;_monitorUID=snapshot[@"monitorUID"];_monitorName=snapshot[@"monitorName"]?:_monitorUID;_browserTabMode=[snapshot[@"chromeTabs"] boolValue];_selectedSceneID=sceneID.length?sceneID:nil;_sceneProtected=YES;_outputMenuSignature=nil;_processMenuSignature=nil;
    _browserTabsButton.state=_browserTabMode?NSControlStateValueOn:NSControlStateValueOff;_monitorSlider.doubleValue=[snapshot[@"monitorGain"] doubleValue];
    for(int i=0;i<6;i++){[self clearPickupForSlot:i];_channels[i].fader.value=atomic_load(&_audio.state->gain[i]);_channels[i].mute.state=atomic_load(&_audio.state->muted[i])?NSControlStateValueOn:NSControlStateValueOff;for(int b=0;b<3;b++)_channels[i].knobs[2-b].value=atomic_load(&_audio.state->eq[i][b]);}
}
- (NSDictionary*)sceneAudioRequest:(NSDictionary*)snapshot {
    NSString *uid=[snapshot[@"followDefaultOutput"] boolValue]?(_halSnapshot[@"defaultUID"]?:@""):snapshot[@"outputUID"];NSDictionary *main=nil,*monitor=nil,*meter=nil;
    for(NSDictionary *device in _outputs){if([device[@"uid"] isEqual:uid])main=device;if([device[@"uid"] isEqual:snapshot[@"monitorUID"]])monitor=device;}
    NSString *monitorError=@"";if([snapshot[@"monitorUID"] length]&&!monitor)monitorError=TXL(@"선택한 미리 듣기 장치가 연결되지 않음");if(monitor&&[monitor[@"uid"] isEqual:uid]){monitor=nil;monitorError=TXL(@"서로 다른 스테레오 모니터 장치가 필요합니다");}
    if(_usbMeters&&![snapshot[@"chromeTabs"] boolValue]&&!TXIsTX6Output(main)&&!TXIsTX6Output(monitor)){NSMutableArray *matches=[NSMutableArray array];for(NSDictionary *device in _outputs)if(TXIsTX6Output(device)&&[device[@"transport"] unsignedIntValue]==kAudioDeviceTransportTypeUSB&&[device[@"channels"] unsignedIntValue]==12&&![device[@"uid"] isEqual:uid]&&![device[@"uid"] isEqual:snapshot[@"monitorUID"]])[matches addObject:device];if(matches.count==1)meter=matches.firstObject;}
    NSArray *processes=TXBrowserProcesses(_halSnapshot[@"processes"]?:_processes?:@[],_browser.tabs?:@[],snapshot[@"assignments"],[snapshot[@"chromeTabs"] boolValue]);
    return @{@"device":main[@"id"]?:@0,@"mainUID":uid,@"monitorDevice":monitor[@"id"]?:@0,@"monitorUID":monitor[@"uid"]?:@"",@"meterDevice":meter[@"id"]?:@0,@"meterUID":meter[@"uid"]?:@"",@"monitorError":monitorError,@"groups":TXNativeGroups(processes,snapshot[@"assignments"])};
}
- (void)recallSnapshot:(NSDictionary*)value sceneID:(NSString*)sceneID recordUndo:(BOOL)recordUndo {[self recallSnapshot:value sceneID:sceneID recordUndo:recordUndo runtime:NO];}
- (void)recallSnapshot:(NSDictionary*)value sceneID:(NSString*)sceneID recordUndo:(BOOL)recordUndo runtime:(BOOL)runtime {
    if(_sceneStopping||_sceneQuitting)return;
    NSError *error=nil;NSDictionary *snapshot=[TXSceneStore canonicalSnapshot:value error:&error];if(!snapshot){_canvas.message=[self sceneErrorText:error];return;}
    if(_sceneMIDIOverflow){[_sceneMIDI removeAllObjects];_sceneMIDIOverflow=NO;}
    if(runtime)snapshot=CFBridgingRelease(CFPropertyListCreateDeepCopy(kCFAllocatorDefault,(__bridge CFPropertyListRef)value,kCFPropertyListImmutable));
    if(!_sceneBaseline||(_sceneApplying&&_sceneModelCommitted)){_sceneBaseline=[self runtimeSceneSnapshot];_sceneRollbackRequest=[self sceneAudioRequest:_sceneBaseline];}
    NSDictionary *undo=recordUndo?@{@"kind":@"load",@"snapshot":_sceneBaseline,@"selected":_selectedSceneID?:@""}:@{};
    _sceneModelCommitted=NO;_sceneApplying=YES;_isBuilding=YES;_retryAt=nil;_retryAttempt=0;_retryExhausted=NO;NSUInteger generation=atomic_fetch_add(&_sceneGeneration,1)+1;_halGeneration++;
    _pendingHALRequest=@{@"kind":@"scene",@"generation":@(generation),@"snapshot":snapshot,@"sceneID":sceneID?:@"",@"audio":[self sceneAudioRequest:snapshot],@"rollback":_sceneBaseline,@"rollbackAudio":_sceneRollbackRequest,@"running":@(_desiredRunning&&!_explicitStop&&!_sleeping),@"wasReady":@(_audioReady),@"clearUndo":@(runtime&&[_sceneUndo[@"kind"] isEqual:@"load"]&&value==_sceneUndo[@"snapshot"]),@"undo":undo};
    [self refreshDeviceMenus];_outputMenu.enabled=NO;_monitorMenu.enabled=NO;_monitorSlider.enabled=NO;_autoButton.enabled=NO;_browserTabsButton.enabled=NO;_usbMetersButton.enabled=NO;[self updateStatus];[self processHALWork];
}
- (NSDictionary*)startSceneAudio:(NSDictionary*)request generation:(NSUInteger)generation {
    TXAudio *backend=_audio;BOOL ok=NO;NSString *error=@"",*monitorError=request[@"monitorError"]?:@"",*meterError=@"";AudioDeviceID wantedMonitor=[request[@"monitorDevice"] unsignedIntValue],wantedMeter=[request[@"meterDevice"] unsignedIntValue];NSMutableSet *attempted=[NSMutableSet set];BOOL monitorLost=NO,meterLost=NO;
    for(NSArray *choice in @[@[@(wantedMonitor),@(wantedMeter)],@[@(wantedMonitor),@0],@[@0,@(wantedMeter)],@[@0,@0]]){
        if(atomic_load(&_sceneGeneration)!=generation)break;AudioDeviceID main=[request[@"device"] unsignedIntValue],monitor=[choice[0] unsignedIntValue],meter=[choice[1] unsignedIntValue];NSString *uid=request[@"mainUID"];
        if(!main||!uid.length||![[backend outputUIDForDevice:main expectedUID:uid] isEqual:uid]){error=TXL(@"선택한 출력 장치가 연결되지 않음");break;}
        if(monitor&&![[backend outputUIDForDevice:monitor expectedUID:request[@"monitorUID"]] isEqual:request[@"monitorUID"]]){monitorLost=YES;monitorError=TXL(@"선택한 미리 듣기 장치가 연결되지 않음");}
        if(meter&&![[backend outputUIDForDevice:meter expectedUID:request[@"meterUID"]] isEqual:request[@"meterUID"]]){meterLost=YES;meterError=TXL(@"선택한 USB 미터 장치가 변경되어 연결하지 않았습니다.");}
        if(monitorLost)monitor=0;if(meterLost)meter=0;NSString *key=[NSString stringWithFormat:@"%u:%u",monitor,meter];if([attempted containsObject:key])continue;[attempted addObject:key];
        backend.monitorOutputDevice=monitor;backend.meterOutputDevice=meter;ok=[backend startOnDevice:main groups:request[@"groups"]];if(ok){NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(!atomic_load(&backend.state->callbacks)&&!atomic_load(&backend.state->layoutFault)&&atomic_load(&_sceneGeneration)==generation&&deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.005];ok=atomic_load(&backend.state->callbacks)>0&&!atomic_load(&backend.state->layoutFault);if(ok)break;error=TXL(@"씬 전환 실패 · 중지 후 다시 시도하세요.");}else error=backend.lastError?:@"";
        if(monitor)monitorError=error;if(meter)meterError=error;[backend stop];
    }
    return @{@"ok":@(ok),@"error":ok?@"":error,@"monitoring":@(ok&&backend.monitoring),@"metering":@(ok&&backend.metering),@"monitorError":ok&&backend.monitoring?@"":monitorError,@"meterError":ok&&backend.metering?@"":meterError};
}
- (void)performSceneRequest:(NSDictionary*)request {
    _halBusy=YES;_halStartedAt=NSDate.date;NSUInteger generation=[request[@"generation"] unsignedIntegerValue];TXAudio *backend=_audio;if(!_sceneGuard)_sceneGuard=[TXAudioMuteGuard new];TXAudioMuteGuard *guard=_sceneGuard;
    dispatch_async(_halQueue,^{@autoreleasepool {
        if(atomic_load(&self->_sceneGeneration)!=generation){dispatch_async(dispatch_get_main_queue(),^{self->_halBusy=NO;[self processHALWork];});return;}
        NSError *guardError=nil;BOOL running=[request[@"running"] boolValue],acquired=!running||[guard begin:&guardError];BOOL rollback=NO,ready=NO,waiting=NO;NSDictionary *result=@{};
        if(acquired){atomic_store(&backend.state->transitionMuted,true);[backend stop];[self applySceneDSP:request[@"snapshot"]];
            if(running){waiting=[request[@"audio"][@"device"] unsignedIntValue]==0;if(!waiting){result=[self startSceneAudio:request[@"audio"] generation:generation];ready=[result[@"ok"] boolValue];}
                if(!ready&&!waiting&&atomic_load(&self->_sceneGeneration)==generation){[backend stop];[self applySceneDSP:request[@"rollback"]];NSDictionary *restored=[self startSceneAudio:request[@"rollbackAudio"] generation:generation];rollback=YES;ready=[restored[@"ok"] boolValue];NSMutableDictionary *merged=[restored mutableCopy];merged[@"error"]=result[@"error"]?:@"";result=merged;}
            }
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if(atomic_load(&self->_sceneGeneration)!=generation){self->_halBusy=NO;[self processHALWork];return;}
            if(acquired)self->_sceneProtected=YES;
            if(acquired&&!rollback){self->_sceneModelCommitted=YES;[self commitSceneModel:request[@"snapshot"] sceneID:request[@"sceneID"]];if([request[@"undo"] count])self->_sceneUndo=request[@"undo"];else if([request[@"clearUndo"] boolValue])self->_sceneUndo=nil;}
            self->_sceneModelCommitted=YES;
            self->_audioReady=acquired?ready:[request[@"wasReady"] boolValue];self->_monitoring=[result[@"monitoring"] boolValue];self->_usbMetering=[result[@"metering"] boolValue];self->_monitorError=result[@"monitorError"]?:@"";self->_usbMeterError=result[@"meterError"]?:@"";
            self->_audioError=!acquired?[self sceneErrorText:guardError]:(waiting?TXL(@"선택한 출력 장치 연결 대기 · 씬 전환 보호 중"):result[@"error"]?:@"");
            [self drainSceneMIDI];BOOL midiOverflow=self->_sceneMIDIOverflow;
            dispatch_async(self->_halQueue,^{
                NSError *endError=nil;BOOL validIO=!running||(ready&&atomic_load(&backend.state->callbacks)>0&&!atomic_load(&backend.state->layoutFault));BOOL canRelease=acquired&&validIO&&!midiOverflow&&atomic_load(&self->_sceneGeneration)==generation;BOOL released=!canRelease||[guard end:&endError];BOOL lostReady=acquired&&ready&&!validIO;
                dispatch_async(dispatch_get_main_queue(),^{
                    self->_halBusy=NO;self->_halStartedAt=nil;if(atomic_load(&self->_sceneGeneration)!=generation){[self processHALWork];return;}
                    [self drainSceneMIDI];if(self->_sceneMIDIOverflow)atomic_store(&backend.state->transitionMuted,true);BOOL finalReady=!running||(atomic_load(&backend.state->callbacks)>0&&!atomic_load(&backend.state->layoutFault));
                    if(canRelease&&released&&!self->_sceneMIDIOverflow&&finalReady)atomic_store(&backend.state->transitionMuted,false);
                    self->_sceneApplying=NO;self->_isBuilding=NO;self->_sceneBaseline=nil;self->_sceneRollbackRequest=nil;if(!released||lostReady||self->_sceneMIDIOverflow||(ready&&!finalReady)){self->_audioError=[self sceneErrorText:endError];self->_audioReady=NO;}
                    self->_signature=[self currentSignature];self->_startedAt=NSDate.date;self->_progressAt=NSDate.date;self->_progressFrames=0;self->_canvas.message=self->_audioError;self->_outputMenu.enabled=YES;self->_monitorMenu.enabled=YES;self->_monitorSlider.enabled=YES;self->_autoButton.enabled=YES;self->_usbMetersButton.enabled=YES;
                    [self refreshDeviceMenus];[self saveSettings];[self updateStatus];[self writeStatusNow];[self processHALWork];
                });
            });
        });
    }});
}
- (void)buildWindow {
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1060,850) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    _window.title=TXL(@"TX · MAC — 프로그램별 믹서");_window.contentMinSize=NSMakeSize(900,570);_window.delegate=self;_window.releasedWhenClosed=NO;_window.backgroundColor=Color(0xD8D9D4);
    _window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];_canvas=[[TXCanvas alloc] initWithFrame:NSMakeRect(0,0,1060,850)];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,1060,850)];scroll.hasVerticalScroller=YES;scroll.hasHorizontalScroller=YES;scroll.autohidesScrollers=YES;scroll.drawsBackground=NO;scroll.documentView=_canvas;scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_window.contentView=scroll;
    CGFloat available=(NSScreen.mainScreen.visibleFrame.size.height?:930)-80;if(available<850)[_window setContentSize:NSMakeSize(1060,MAX(570,available))];
    [_canvas addSubview:Label(@"MAIN",NSMakeRect(24,91,62,18),10,YES)];_outputMenu=[[TXPopup alloc] initWithFrame:NSMakeRect(83,83,310,28) pullsDown:NO];_outputMenu.target=self;_outputMenu.action=@selector(outputChanged:);_outputMenu.font=[NSFont systemFontOfSize:12];_outputMenu.accessibilityLabel=TXL(@"오디오 출력 장치");[_canvas addSubview:_outputMenu];
    [_canvas addSubview:Label(@"MONITOR",NSMakeRect(410,91,70,18),10,YES)];_monitorMenu=[[TXPopup alloc] initWithFrame:NSMakeRect(480,83,350,28) pullsDown:NO];_monitorMenu.target=self;_monitorMenu.action=@selector(monitorChanged:);_monitorMenu.font=[NSFont systemFontOfSize:12];_monitorMenu.accessibilityLabel=TXL(@"미리 듣기 출력 장치");[_canvas addSubview:_monitorMenu];
    [_canvas addSubview:Label(@"SCENE",NSMakeRect(865,65,167,15),9,YES)];_sceneMenu=[[TXPopup alloc] initWithFrame:NSMakeRect(865,83,167,28) pullsDown:NO];_sceneMenu.font=[NSFont systemFontOfSize:12];_sceneMenu.accessibilityLabel=TXL(@"씬");[_canvas addSubview:_sceneMenu];[self refreshSceneMenu];
    [_canvas addSubview:Button(TXL(@"오디오 권한…"),NSMakeRect(865,699,167,29),self,@selector(showPrivacy:))];
    _startButton=Button(TXL(@"믹서 시작"),NSMakeRect(865,259,167,36),self,@selector(primaryControl:));_startButton.bezelColor=Color(0xF36B2F);[_canvas addSubview:_startButton];
    NSMutableArray *channelViews=[NSMutableArray array];TXRenderState *s=_audio.state;
    NSArray *names=@[@"HIGH",@"MID",@"LOW"],*frequencies=@[@"8 kHz",@"1 kHz",@"120 Hz"];unsigned colors[3]={0x608CA6,0xF36B2F,0xF1F1E9};
    for(int i=0;i<6;i++){
        TXChannel *c=[[TXChannel alloc] initWithFrame:NSMakeRect(24+i*136,130,136,634)];c.slot=i;
        c.assignment=[[TXPopup alloc] initWithFrame:NSMakeRect(7,62,122,25) pullsDown:NO];c.assignment.font=[NSFont systemFontOfSize:11];c.assignment.target=self;c.assignment.action=@selector(assignmentChanged:);c.assignment.tag=i;c.assignment.accessibilityLabel=i==0?TXL(@"트랙 1 시스템 사운드 고정"):[NSString stringWithFormat:TXL(@"트랙 %d 프로그램"),i+1];c.assignment.enabled=i!=0;[c addSubview:c.assignment];
        NSMutableArray *knobs=[NSMutableArray array];for(int j=0;j<3;j++){
            TXKnob *k=[[TXKnob alloc] initWithFrame:NSMakeRect(30,110+j*90,76,92)];k.caption=names[j];k.frequency=frequencies[j];k.accent=Color(colors[j]);k.value=atomic_load(&s->eq[i][2-j]);k.tag=i*3+(2-j);k.target=self;k.action=@selector(eqChanged:);k.accessibilityRole=NSAccessibilitySliderRole;k.accessibilityLabel=[NSString stringWithFormat:TXL(@"트랙 %d %@ EQ"),i+1,names[j]];k.awaitingPickup=_pickup;k.toolTip=TXL(@"위아래 드래그 또는 스크롤. 두 번 클릭하면 0 dB. Shift로 미세 조절.");[knobs addObject:k];[c addSubview:k];}
        c.knobs=knobs;c.fader=[[TXFader alloc] initWithFrame:NSMakeRect(21,455,94,0)];
        for(int j=0;j<3;j++)c.knobs[j].frame=NSMakeRect(30,110+j*90,76,92);
        c.fader.frame=NSMakeRect(22,402,92,135);c.fader.value=atomic_load(&s->gain[i]);c.fader.awaitingPickup=_pickup;c.fader.tag=i;c.fader.target=self;c.fader.action=@selector(gainChanged:);c.fader.accessibilityRole=NSAccessibilitySliderRole;c.fader.accessibilityLabel=[NSString stringWithFormat:TXL(@"트랙 %d 음량"),i+1];[c addSubview:c.fader];
        c.activity=Label(TXL(@"미지정"),NSMakeRect(9,544,118,18),10,NO);c.activity.alignment=NSTextAlignmentCenter;[c addSubview:c.activity];
        c.route=[[TXPopup alloc] initWithFrame:NSMakeRect(12,568,112,24) pullsDown:NO];[c.route addItemsWithTitles:TXRouteTitles()];[c.route selectItemAtIndex:atomic_load(&s->route[i])];c.route.tag=i;c.route.font=[NSFont systemFontOfSize:11];c.route.target=self;c.route.action=@selector(routeChanged:);c.route.accessibilityLabel=[NSString stringWithFormat:TXL(@"트랙 %d 출력 경로"),i+1];[c addSubview:c.route];
        c.mute=Button(@"MUTE",NSMakeRect(18,600,100,31),self,@selector(muteChanged:));c.mute.tag=i;c.mute.buttonType=NSButtonTypePushOnPushOff;c.mute.state=atomic_load(&s->muted[i])?NSControlStateValueOn:NSControlStateValueOff;c.mute.font=Mono(10,NSFontWeightSemibold);c.mute.accessibilityLabel=[NSString stringWithFormat:TXL(@"트랙 %d 음소거"),i+1];[c addSubview:c.mute];
        [_canvas addSubview:c];[channelViews addObject:c];
    }_channels=channelViews;
    [_canvas addSubview:Label(@"SELECT",NSMakeRect(865,315,167,28),25,YES)];
    [_canvas addSubview:Label(@"ALL APPLICATIONS",NSMakeRect(865,342,167,16),9,YES)];
    _masterFader=[[TXFader alloc] initWithFrame:NSMakeRect(874,366,150,153)];_browserLabel.stringValue=_browser.connected?TXL(@"Chrome 오디오 탭 자동 감지 · 음소거 바로 가능\n개별 음량·EQ는 해당 탭에서 ⌘⇧6으로 연결"):TXL(@"Chrome 확장을 연결하면 재생 탭 자동 감지\n개별 음량·EQ 연결 단축키: ⌘⇧6");_remainderLabel.stringValue=_overflowCount>0?[NSString stringWithFormat:TXL(@"추가 %ld개 앱은 MASTER 적용"),(long)_overflowCount]:TXL(@"미지정 앱도 MASTER 적용");_masterFader.rotary=YES;_masterFader.value=atomic_load(&s->master);_masterFader.target=self;_masterFader.action=@selector(masterChanged:);_masterFader.accessibilityRole=NSAccessibilitySliderRole;_masterFader.accessibilityLabel=TXL(@"전체 음량");[_canvas addSubview:_masterFader];
    _soundKey=Button(@"FX I\nSOUND",NSMakeRect(865,540,78,44),self,@selector(soundKey:));[_canvas addSubview:_soundKey];_masterMute=Button(@"FX II\nMUTE",NSMakeRect(954,540,78,44),self,@selector(muteKey:));[_canvas addSubview:_masterMute];
    [_canvas addSubview:Label(@"MON LEVEL",NSMakeRect(865,602,110,15),9,YES)];_monitorLevelLabel=Label(@"",NSMakeRect(975,602,57,15),9,YES);_monitorLevelLabel.alignment=NSTextAlignmentRight;[_canvas addSubview:_monitorLevelLabel];_monitorSlider=[[TXMonitorSlider alloc] initWithFrame:NSMakeRect(865,620,167,22)];_monitorSlider.doubleValue=atomic_load(&s->monitorGain);_monitorSlider.target=self;_monitorSlider.action=@selector(monitorGainChanged:);_monitorSlider.accessibilityLabel=TXL(@"미리 듣기 음량");[_canvas addSubview:_monitorSlider];[self updateMonitorLevel];
    _autoButton=[NSButton checkboxWithTitle:TXL(@"자동 앱 매칭") target:self action:@selector(autoChanged:)];_autoButton.frame=NSMakeRect(863,673,167,21);_autoButton.state=_autoAssign?NSControlStateValueOn:NSControlStateValueOff;_autoButton.font=[NSFont systemFontOfSize:11];_autoButton.toolTip=TXL(@"재생 앱을 빈 채널에 배정합니다. 일시정지해도 채널과 물리 음량·EQ·음소거는 고정됩니다. 수동 지정하면 자동 매칭이 꺼집니다.");
    _pickupButton=[NSButton checkboxWithTitle:TXL(@"하드웨어 픽업") target:self action:@selector(settingsChanged:)];_pickupButton.frame=NSMakeRect(863,701,167,21);_pickupButton.state=_pickup?NSControlStateValueOn:NSControlStateValueOff;_pickupButton.font=[NSFont systemFontOfSize:11];_pickupButton.toolTip=TXL(@"기본은 꺼짐이며 페이더와 노브가 즉시 반응합니다. 켜면 현재 맥 값에 맞출 때까지 기다리는 소프트 픽업을 사용합니다.");
    _invertButton=[NSButton checkboxWithTitle:TXL(@"페이더 방향 반전") target:self action:@selector(settingsChanged:)];_invertButton.frame=NSMakeRect(863,729,167,21);_invertButton.state=_invert?NSControlStateValueOn:NSControlStateValueOff;_invertButton.font=[NSFont systemFontOfSize:11];NSViewController *settings=[NSViewController new];settings.view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,400,672)];
    [settings.view addSubview:Label(TXL(@"언어"),NSMakeRect(18,628,100,24),11,NO)];
    _languageMenu=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(122,626,260,28) pullsDown:NO];_languageMenu.target=self;_languageMenu.action=@selector(languageChanged:);_languageMenu.accessibilityLabel=TXL(@"언어");
    for(NSArray *entry in @[@[TXL(@"시스템 설정"),@"system"],@[@"English",@"en"],@[@"한국어",@"ko"],@[@"日本語",@"ja"]]){[_languageMenu addItemWithTitle:entry[0]];_languageMenu.lastItem.representedObject=entry[1];if([entry[1] isEqual:TXLanguageCode()])[_languageMenu selectItem:_languageMenu.lastItem];}[settings.view addSubview:_languageMenu];
    _autoStartButton=[NSButton checkboxWithTitle:TXL(@"믹서 자동 시작 및 연결 복구") target:self action:@selector(autoStartChanged:)];_autoStartButton.frame=NSMakeRect(18,582,364,25);_autoStartButton.state=_autoStart?NSControlStateValueOn:NSControlStateValueOff;[settings.view addSubview:_autoStartButton];
    [settings.view addSubview:Button(TXL(@"시작 안내 및 권한…"),NSMakeRect(18,536,364,30),self,@selector(showSetup:))];
    _browserTabsButton=[NSButton checkboxWithTitle:TXL(@"Chrome 탭별 채널 사용") target:self action:@selector(browserModeChanged:)];_browserTabsButton.frame=NSMakeRect(18,505,364,24);_browserTabsButton.state=_browserTabMode?NSControlStateValueOn:NSControlStateValueOff;_browserTabsButton.toolTip=TXL(@"기본은 Chrome 전체 한 채널입니다. 켜면 개별 탭만 표시합니다. 탭별 음량·EQ는 각 탭에서 ⌘⇧6 연결이 필요합니다.");[settings.view addSubview:_browserTabsButton];
    _autoButton.frame=NSMakeRect(18,473,364,24);_pickupButton.frame=NSMakeRect(18,437,324,24);_invertButton.frame=NSMakeRect(18,401,324,24);[settings.view addSubview:_autoButton];[settings.view addSubview:_pickupButton];[settings.view addSubview:_invertButton];_hudButton=[NSButton checkboxWithTitle:TXL(@"조절 시 상태 표시") target:self action:@selector(settingsChanged:)];_hudButton.frame=NSMakeRect(18,365,324,24);_hudButton.state=_hudEnabled?NSControlStateValueOn:NSControlStateValueOff;[settings.view addSubview:_hudButton];
    _deviceContextLabel=Label(TXL(@"TX-6 홈 화면 확인 필요"),NSMakeRect(18,311,324,40),11,NO);_deviceContextLabel.maximumNumberOfLines=2;_deviceContextLabel.lineBreakMode=NSLineBreakByWordWrapping;[settings.view addSubview:_deviceContextLabel];
    _resumeDeviceButton=Button(TXL(@"기기 홈 화면 확인 · TX-6 제어 재개"),NSMakeRect(18,276,324,29),self,@selector(resumeDeviceControls:));[settings.view addSubview:_resumeDeviceButton];
    [settings.view addSubview:Label(TXL(@"기기 현재 메인 숫자와 맞추기 (0~99)"),NSMakeRect(18,243,324,22),11,NO)];
    _calibrationInput=[[NSTextField alloc] initWithFrame:NSMakeRect(18,207,99,27)];_calibrationInput.placeholderString=@"0–99";_calibrationInput.font=Mono(12,NSFontWeightMedium);_calibrationInput.alignment=NSTextAlignmentCenter;_calibrationInput.target=self;_calibrationInput.action=@selector(calibrateMaster:);_calibrationInput.accessibilityLabel=TXL(@"TX-6 현재 메인 숫자 0부터 99");[settings.view addSubview:_calibrationInput];
    [settings.view addSubview:Button(TXL(@"맥 전체 음량에 맞춤"),NSMakeRect(130,207,212,28),self,@selector(calibrateMaster:))];NSTextField *calibrationNote=Label(TXL(@"입력한 숫자를 맥 전체 음량(0~99)으로 설정합니다.\n기기 자동 조회·상시 동기화 기능은 아닙니다."),NSMakeRect(18,151,324,46),10,NO);calibrationNote.maximumNumberOfLines=2;calibrationNote.lineBreakMode=NSLineBreakByWordWrapping;[settings.view addSubview:calibrationNote];[settings.view addSubview:Label(TXL(@"CH 01 시스템 사운드 고정 · CH 02–06 앱 / 탭"),NSMakeRect(18,109,324,24),10,NO)];_browserLabel=Label(TXL(@"Chrome 탭: 확장 아이콘에서 연결"),NSMakeRect(18,20,324,64),11,NO);_browserLabel.maximumNumberOfLines=2;_browserLabel.lineBreakMode=NSLineBreakByWordWrapping;[settings.view addSubview:_browserLabel];
    // Keep settings reachable on smaller displays as the optional hardware section grows.
    NSView *settingsDocument=settings.view;for(NSView *child in settingsDocument.subviews){NSRect frame=child.frame;frame.origin.y+=92;child.frame=frame;}settingsDocument.frame=NSMakeRect(0,0,400,924);
    _transportMenu=[[TXPopup alloc] initWithFrame:NSMakeRect(18,800,200,28) pullsDown:NO];for(NSArray *v in @[@[TXL(@"MIDI 자동"),@"auto"],@[@"USB MIDI",@"usb"],@[@"Bluetooth MIDI",@"ble"]]){[_transportMenu addItemWithTitle:v[0]];_transportMenu.lastItem.representedObject=v[1];}for(NSMenuItem *item in _transportMenu.itemArray)if([item.representedObject isEqual:_midi.transport])[_transportMenu selectItem:item];_transportMenu.target=self;_transportMenu.action=@selector(transportChanged:);[settingsDocument addSubview:_transportMenu];
    [settingsDocument addSubview:Button(TXL(@"Bluetooth 연결…"),NSMakeRect(230,800,152,28),self,@selector(showBluetooth:))];
    [settingsDocument addSubview:Button(TXL(@"EQ 초기화"),NSMakeRect(18,842,364,29),self,@selector(resetEQ:))];
    _usbMetersButton=[NSButton checkboxWithTitle:TXL(@"TX-6 USB 채널 미터") target:self action:@selector(usbMetersChanged:)];_usbMetersButton.frame=NSMakeRect(18,65,364,24);_usbMetersButton.state=_usbMeters?NSControlStateValueOn:NSControlStateValueOff;[settingsDocument addSubview:_usbMetersButton];
    _usbMetersStatus=Label(@"",NSMakeRect(18,10,364,50),10,NO);_usbMetersStatus.maximumNumberOfLines=3;_usbMetersStatus.lineBreakMode=NSLineBreakByWordWrapping;[settingsDocument addSubview:_usbMetersStatus];
    [settingsDocument addSubview:Button(TXL(@"레벨…"),NSMakeRect(18,884,364,29),self,@selector(showLevels:))];
    CGFloat settingsHeight=MIN(924,MAX(400,NSScreen.mainScreen.visibleFrame.size.height-100));NSScrollView *settingsScroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,400,settingsHeight)];settingsScroll.hasVerticalScroller=YES;settingsScroll.autohidesScrollers=YES;settingsScroll.drawsBackground=NO;settingsScroll.documentView=settingsDocument;settings.view=settingsScroll;[settingsDocument scrollPoint:NSMakePoint(0,924-settingsHeight)];
    _settingsPopover=[NSPopover new];_settingsPopover.behavior=NSPopoverBehaviorSemitransient;_settingsPopover.delegate=self;_settingsPopover.contentViewController=settings;
    [_canvas addSubview:Button(TXL(@"SETUP / 설정"),NSMakeRect(865,653,167,29),self,@selector(showSettings:))];
    _remainderLabel=Label(TXL(@"미지정 앱도 MASTER 적용"),NSMakeRect(865,748,167,22),10,NO);[_canvas addSubview:_remainderLabel];
    NSMenu *main=[NSMenu new],*appMenu=[NSMenu new];NSMenuItem *appItem=[NSMenuItem new];appItem.submenu=appMenu;[main addItem:appItem];[appMenu addItemWithTitle:TXL(@"TX · MAC 정보") action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];[appMenu addItem:NSMenuItem.separatorItem];NSMenuItem *preferences=[appMenu addItemWithTitle:TXL(@"설정…") action:@selector(openPreferences:) keyEquivalent:@","];preferences.target=self;NSMenuItem *guide=[appMenu addItemWithTitle:TXL(@"시작 안내 및 권한…") action:@selector(showSetup:) keyEquivalent:@""];guide.target=self;[appMenu addItem:NSMenuItem.separatorItem];[appMenu addItemWithTitle:TXL(@"TX · MAC 숨기기") action:@selector(hide:) keyEquivalent:@"h"];[appMenu addItemWithTitle:TXL(@"TX · MAC 종료") action:@selector(terminate:) keyEquivalent:@"q"];NSApp.mainMenu=main;
}
- (NSView*)sliderViewForSlot:(NSInteger)slot band:(NSInteger)band {
    NSView *v=[[NSView alloc] initWithFrame:NSMakeRect(0,0,280,38)];NSSlider *slider=band<0?[[TXVolumeSlider alloc] initWithFrame:NSMakeRect(15,8,205,22)]:[NSSlider sliderWithValue:0 minValue:-18 maxValue:18 target:self action:@selector(menuSliderChanged:)];if(band<0){slider.minValue=0;slider.maxValue=1;slider.continuous=YES;slider.target=self;slider.action=@selector(menuSliderChanged:);}slider.frame=NSMakeRect(15,8,205,22);slider.tag=slot*10+band+1;
    slider.enabled=slot==6||[self canAdjustVolumeForSlot:slot];if(!slider.enabled)slider.toolTip=TXL(@"음소거 가능 · 음량/EQ는 Chrome 탭에서 ⌘⇧6으로 연결");slider.doubleValue=slot==6?atomic_load(&_audio.state->master):(band<0?atomic_load(&_audio.state->gain[slot]):atomic_load(&_audio.state->eq[slot][band]));[v addSubview:slider];
    NSTextField *value=Label(band<0?TXVolumeText(slider.doubleValue):[NSString stringWithFormat:@"%+.0f",slider.doubleValue],NSMakeRect(225,11,48,18),11,YES);value.tag=999;[v addSubview:value];return v;
}
- (void)buildStatusItem {
    _statusItem=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];_statusItem.button.image=[self menuIcon];_statusItem.button.imagePosition=NSImageOnly;_statusItem.button.toolTip=TXL(@"TX · MAC — 프로그램별 음량과 EQ");
    _statusMenu=[NSMenu new];_statusMenu.autoenablesItems=NO;_statusMenu.delegate=self;_statusItem.menu=_statusMenu;
}
- (NSImage*)menuIcon {
    NSImage *image=[[NSImage alloc] initWithSize:NSMakeSize(22,18)];[image lockFocus];[[NSColor blackColor] setStroke];
    for(int i=0;i<6;i++){CGFloat x=2+i*3.5,y=4+(i%3)*4;NSBezierPath *line=[NSBezierPath bezierPath];line.lineWidth=1;[line moveToPoint:NSMakePoint(x,2)];[line lineToPoint:NSMakePoint(x,16)];[line stroke];[[NSColor blackColor] setFill];NSRectFill(NSMakeRect(x-1.3,y,2.6,3));}
    [image unlockFocus];image.template=YES;return image;
}
- (void)menuWillOpen:(NSMenu*)menu {
    if(menu==_sceneMenu.menu){_sceneTrackingMenu=menu;return;}
    if(menu!=_statusMenu)return;
    _statusMenuTracking=YES;[self hideHUD:nil];_pendingHUD=nil;[menu removeAllItems];NSMenuItem *title=[[NSMenuItem alloc] initWithTitle:@"TX · MAC / SIX CHANNEL" action:nil keyEquivalent:@""];title.enabled=NO;[menu addItem:title];
    NSMenuItem *status=[[NSMenuItem alloc] initWithTitle:_audioReady?(atomic_load(&_audio.state->callbacks)>0?TXL(@"● 믹서 실행 중"):TXL(@"○ 오디오 대기 · 권한 확인")):(_isBuilding?TXL(@"○ 오디오 대기 · 권한 확인"):TXL(@"○ 믹서 대기 중")) action:nil keyEquivalent:@""];status.enabled=NO;[menu addItem:status];if(_deviceContext.suspended||_deviceContext.shiftDown){NSMenuItem *resume=[[NSMenuItem alloc] initWithTitle:TXL(@"홈 화면 확인 후 TX-6 제어 재개") action:@selector(resumeDeviceControls:) keyEquivalent:@""];resume.target=self;[menu addItem:resume];}
    NSMenuItem *scene=[[NSMenuItem alloc] initWithTitle:TXL(@"씬") action:nil keyEquivalent:@""];scene.submenu=[self sceneActionMenu];[menu addItem:scene];
    [menu addItem:NSMenuItem.separatorItem];[menu addItemWithTitle:TXL(@"전체 음량") action:nil keyEquivalent:@""];
    NSMenuItem *master=[NSMenuItem new];master.view=[self sliderViewForSlot:6 band:-1];[menu addItem:master];
    NSMenuItem *mute=[[NSMenuItem alloc] initWithTitle:TXL(@"전체 음소거") action:@selector(masterMenuMute:) keyEquivalent:@""];mute.target=self;mute.state=atomic_load(&_audio.state->masterMuted)?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:mute];
    [menu addItem:NSMenuItem.separatorItem];
    for(int i=0;i<6;i++){
        NSString *name=[self nameForKey:_assignments[i]];NSMenuItem *channel=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%02d  %@",i+1,name.length?name:TXL(@"앱 미지정")] action:nil keyEquivalent:@""];NSMenu *sub=[NSMenu new];sub.autoenablesItems=NO;channel.submenu=sub;channel.enabled=!_sceneApplying&&!_sceneStopping;
        NSMenuItem *chMute=[[NSMenuItem alloc] initWithTitle:TXL(@"음소거") action:@selector(menuMute:) keyEquivalent:@""];chMute.tag=i;chMute.target=self;chMute.state=atomic_load(&_audio.state->muted[i])?NSControlStateValueOn:NSControlStateValueOff;[sub addItem:chMute];
        NSMenuItem *routeItem=[[NSMenuItem alloc] initWithTitle:TXL(@"출력 경로") action:nil keyEquivalent:@""];NSMenu *routes=[NSMenu new];routes.autoenablesItems=NO;routeItem.submenu=routes;for(int r=0;r<4;r++){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:TXRouteTitles()[r] action:@selector(menuRoute:) keyEquivalent:@""];item.target=self;item.tag=i*4+r;item.state=atomic_load(&_audio.state->route[i])==(UInt32)r?NSControlStateValueOn:NSControlStateValueOff;item.enabled=![_assignments[i] hasPrefix:@"chrome-tab:"]&&![_pendingSources[i] isEqual:@"tab"];if(!item.enabled)item.toolTip=TXL(@"개별 Chrome 탭은 별도 미리 듣기를 지원하지 않습니다. Chrome 전체 채널을 사용하세요.");[routes addItem:item];}[sub addItem:routeItem];
        for(int b=-1;b<3;b++){[sub addItemWithTitle:b<0?TXL(@"음량"):@[@"LOW · 120 Hz",@"MID · 1 kHz",@"HIGH · 8 kHz"][b] action:nil keyEquivalent:@""];NSMenuItem *s=[NSMenuItem new];s.view=[self sliderViewForSlot:i band:b];[sub addItem:s];}
        [menu addItem:channel];
    }
    [menu addItem:NSMenuItem.separatorItem];NSMenuItem *output=[[NSMenuItem alloc] initWithTitle:TXL(@"출력 장치") action:nil keyEquivalent:@""];NSMenu *outs=[NSMenu new];output.submenu=outs;
    NSMenuItem *systemOutput=[[NSMenuItem alloc] initWithTitle:[self systemOutputTitle] action:@selector(menuOutput:) keyEquivalent:@""];systemOutput.target=self;systemOutput.representedObject=@"";systemOutput.state=_followDefaultOutput?NSControlStateValueOn:NSControlStateValueOff;[outs addItem:systemOutput];[outs addItem:NSMenuItem.separatorItem];
    for(NSDictionary *d in _outputs){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:TXOutputDeviceTitle(d,_outputs) action:@selector(menuOutput:) keyEquivalent:@""];item.target=self;item.representedObject=d[@"uid"];item.state=!_followDefaultOutput&&[d[@"uid"] isEqual:_outputUID]?NSControlStateValueOn:NSControlStateValueOff;[outs addItem:item];}[menu addItem:output];
    NSMenuItem *monitor=[[NSMenuItem alloc] initWithTitle:TXL(@"미리 듣기 출력 장치") action:nil keyEquivalent:@""];NSMenu *monitorDevices=[NSMenu new];monitor.submenu=monitorDevices;NSMenuItem *off=[[NSMenuItem alloc] initWithTitle:TXL(@"끔") action:@selector(menuMonitor:) keyEquivalent:@""];off.target=self;off.representedObject=@"";off.state=!_monitorUID.length?NSControlStateValueOn:NSControlStateValueOff;[monitorDevices addItem:off];for(NSDictionary *device in _outputs){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:TXOutputDeviceTitle(device,_outputs) action:@selector(menuMonitor:) keyEquivalent:@""];item.target=self;item.representedObject=device[@"uid"];item.state=[device[@"uid"] isEqual:_monitorUID]?NSControlStateValueOn:NSControlStateValueOff;[monitorDevices addItem:item];}if(_monitorUID.length&&![self selectedMonitor]){NSMenuItem *offline=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:TXL(@"%@ (연결 안 됨)"),_monitorName?:_monitorUID] action:nil keyEquivalent:@""];offline.state=NSControlStateValueOn;[monitorDevices addItem:offline];}[menu addItem:monitor];
    NSMenuItem *trim=[[NSMenuItem alloc] initWithTitle:TXL(@"미리 듣기 음량") action:nil keyEquivalent:@""];NSMenu *levels=[NSMenu new];trim.submenu=levels;for(NSNumber *level in @[@0,@25,@50,@75,@99]){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:level.stringValue action:@selector(menuMonitorGain:) keyEquivalent:@""];item.target=self;item.tag=level.integerValue;item.state=fabs(atomic_load(&_audio.state->monitorGain)-TXVolumeGain(level.integerValue))<.000001?NSControlStateValueOn:NSControlStateValueOff;[levels addItem:item];}[menu addItem:trim];
    for(NSArray *entry in @[@[TXL(@"레벨…"),NSStringFromSelector(@selector(showLevels:))],@[TXL(@"믹서 창 열기"),NSStringFromSelector(@selector(showWindow:))],@[TXL(@"Bluetooth 연결…"),NSStringFromSelector(@selector(showBluetooth:))],@[_desiredRunning?TXL(@"믹서 중지 · 원음 복구"):TXL(@"믹서 시작"),NSStringFromSelector(@selector(toggleMixer:))]]){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];item.target=self;[menu addItem:item];}
    [menu addItem:NSMenuItem.separatorItem];NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:TXL(@"종료 · 원음 복구") action:@selector(terminate:) keyEquivalent:@"q"];[menu addItem:quit];
}
- (void)menuDidClose:(NSMenu*)menu {
    if(menu==_sceneTrackingMenu){_sceneTrackingMenu=nil;if(_sceneMenuRefreshPending)dispatch_async(dispatch_get_main_queue(),^{if(self->_sceneMenuRefreshPending)[self refreshSceneMenu];});return;}
    if(menu!=_statusMenu)return;
    _statusMenuTracking=NO;[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(displayPendingHUD) object:nil];[self performSelector:@selector(displayPendingHUD) withObject:nil afterDelay:0.12 inModes:@[NSRunLoopCommonModes]];
}
- (void)showHUDForSlot:(NSInteger)slot message:(NSString*)message {
    NSString *name=slot>=0&&slot<6?[self nameForKey:_assignments[slot]]:TXL(@"전체 오디오");if(!name.length)name=TXL(@"앱 미지정");if(!_audioError.length){_canvas.message=[NSString stringWithFormat:@"%@ · %@",name,message?:@""];_canvas.needsDisplay=YES;}if(!_hudEnabled)return;
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
- (NSString*)nameForKey:(NSString*)key {if([key isEqual:@"local.tx6mac.system-sounds"])return TXL(@"시스템 사운드");for(NSDictionary *p in _processes)if([p[@"key"] isEqual:key])return p[@"name"];if(!key.length)return @"";if([key hasPrefix:@"chrome-tab:"])return TXL(@"Chrome 탭 연결 대기");NSURL *url=[[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:key];return url?[[NSFileManager defaultManager] displayNameAtPath:url.path]:key;}
- (void)refreshDevices {
    _outputs=_halSnapshot[@"outputs"]?:@[];NSMutableArray *native=[(_halSnapshot[@"processes"]?:@[]) mutableCopy];BOOL hasChrome=NO;
    for(NSDictionary *process in native)if([process[@"key"] isEqual:@"com.google.Chrome"]){hasChrome=YES;break;}
    if(!hasChrome)for(NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications)if([application.bundleIdentifier isEqual:@"com.google.Chrome"]){[native addObject:@{@"key":@"com.google.Chrome",@"name":application.localizedName?:@"Google Chrome",@"ids":@[],@"bundles":@[@"com.google.Chrome"],@"active":@NO}];break;}
    _processes=TXBrowserProcesses(native,_browser.tabs,_assignments,_browserTabMode);[self autoMatch];
    [self refreshDeviceMenus];
}
- (NSString*)systemOutputTitle {
    NSString *title=TXL(@"시스템 기본 출력");for(NSDictionary *device in _outputs)if([device[@"uid"] isEqual:_halSnapshot[@"defaultUID"]])return [title stringByAppendingFormat:@" · %@",TXOutputDeviceTitle(device,_outputs)];return title;
}
- (void)updateOutputDeviceHelp {
    NSDictionary *output=[self selectedOutput];if(_followDefaultOutput){output=nil;for(NSDictionary *device in _outputs)if([device[@"uid"] isEqual:_halSnapshot[@"defaultUID"]]){output=device;break;}}
    _outputMenu.toolTip=TXOutputDeviceHelp(output,_outputMenu.titleOfSelectedItem,nil);_outputMenu.accessibilityHelp=_outputMenu.toolTip;
    _monitorMenu.toolTip=TXOutputDeviceHelp([self selectedMonitor],_monitorMenu.titleOfSelectedItem,_monitorError);_monitorMenu.accessibilityHelp=_monitorMenu.toolTip;
}
- (void)refreshDeviceMenus {
    NSString *outSig=[NSString stringWithFormat:@"%@|%@|%@|%d",_outputs,[_outputUID stringByAppendingFormat:@"|%@",_monitorUID?:@""],_halSnapshot[@"defaultUID"],_followDefaultOutput];BOOL outputChanged=![_outputMenuSignature isEqual:outSig];_outputMenuSignature=outSig;
    NSMutableArray *processMenu=[NSMutableArray array];for(NSDictionary *p in _processes)[processMenu addObject:@[p[@"key"],p[@"name"]]];NSString *processSig=[NSString stringWithFormat:@"%@|%@",processMenu,_assignments];BOOL processesChanged=![_processMenuSignature isEqual:processSig];_processMenuSignature=processSig;
    if(outputChanged){[_outputMenu removeAllItems];NSMenuItem *system=[[NSMenuItem alloc] initWithTitle:[self systemOutputTitle] action:nil keyEquivalent:@""];system.representedObject=@"";[_outputMenu.menu addItem:system];if(_followDefaultOutput)[_outputMenu selectItem:system];[_outputMenu.menu addItem:NSMenuItem.separatorItem];for(NSDictionary *d in _outputs){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@  ·  %@ ch",TXOutputDeviceTitle(d,_outputs),d[@"channels"]] action:nil keyEquivalent:@""];item.representedObject=d[@"uid"];[_outputMenu.menu addItem:item];if(!_followDefaultOutput&&[d[@"uid"] isEqual:_outputUID])[_outputMenu selectItem:item];}
    BOOL found=NO;for(NSDictionary *d in _outputs)if([d[@"uid"] isEqual:_outputUID])found=YES;
    if(!found&&!_followDefaultOutput){NSMenuItem *offline=[[NSMenuItem alloc] initWithTitle:TXL(@"선택한 출력 장치가 연결되지 않음") action:nil keyEquivalent:@""];offline.representedObject=_outputUID;[_outputMenu.menu addItem:offline];[_outputMenu selectItem:offline];}}
    if(outputChanged){[_monitorMenu removeAllItems];NSMenuItem *off=[[NSMenuItem alloc] initWithTitle:TXL(@"끔") action:nil keyEquivalent:@""];off.representedObject=@"";[_monitorMenu.menu addItem:off];BOOL found=!_monitorUID.length;for(NSDictionary *device in _outputs){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:TXOutputDeviceTitle(device,_outputs) action:nil keyEquivalent:@""];item.representedObject=device[@"uid"];[_monitorMenu.menu addItem:item];if([device[@"uid"] isEqual:_monitorUID]){_monitorName=device[@"name"];[_monitorMenu selectItem:item];found=YES;}}if(!found){NSMenuItem *offline=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:TXL(@"%@ (연결 안 됨)"),_monitorName.length?_monitorName:_monitorUID] action:nil keyEquivalent:@""];offline.representedObject=_monitorUID;[_monitorMenu.menu addItem:offline];[_monitorMenu selectItem:offline];}}
    [self updateOutputDeviceHelp];
    if(processesChanged)for(int i=0;i<6;i++){
        TXChannel *c=_channels[i];[c.assignment removeAllItems];[c.assignment addItemWithTitle:_autoAssign?TXL(@"재생 앱 대기…"):TXL(@"앱 지정…")];c.assignment.lastItem.representedObject=@"";BOOL present=!_assignments[i].length;
        for(NSDictionary *p in _processes){NSString *key=p[@"key"];if(![p[@"isSystemSound"] boolValue]&&![self isAutomaticCandidate:p]&&![key isEqual:_assignments[i]])continue;BOOL used=NO;for(int j=0;j<6;j++)if(j!=i&&[_assignments[j] isEqual:key])used=YES;if(used)continue;
            [c.assignment addItemWithTitle:[key isEqual:@"local.tx6mac.system-sounds"]?[self nameForKey:key]:p[@"name"]];c.assignment.lastItem.representedObject=key;if([key isEqual:_assignments[i]]){[c.assignment selectItem:c.assignment.lastItem];present=YES;}}
        c.assignment.toolTip=TXL(@"실행 중인 앱 또는 연결된 Chrome 탭을 지정합니다.");for(NSDictionary *p in _processes)if([p[@"key"] isEqual:_assignments[i]])c.assignment.toolTip=p[@"fullTitle"]?:p[@"name"];
        if([_pendingSources[i] length]){[c.assignment addItemWithTitle:TXL(@"다시 지정 필요")];c.assignment.lastItem.representedObject=@"";[c.assignment selectItem:c.assignment.lastItem];}
        if(!present){[c.assignment addItemWithTitle:i==0?TXL(@"시스템 사운드"):[NSString stringWithFormat:TXL(@"%@ (대기)"),[self nameForKey:_assignments[i]]]];c.assignment.lastItem.representedObject=_assignments[i];[c.assignment selectItem:c.assignment.lastItem];}
    }
    [self refreshChannelControls];
}
- (NSString*)sceneControlHint {
    if(_sceneStopping)return TXL(@"중지 중");if(_sceneApplying)return TXL(@"씬 전환 중");return nil;
}
- (void)refreshChannelControls {
    NSString *busyHint=[self sceneControlHint];BOOL busy=busyHint!=nil;
    for(int i=0;i<6;i++){
        TXChannel *c=_channels[i];BOOL tabRoute=[_assignments[i] hasPrefix:@"chrome-tab:"]||[_pendingSources[i] isEqual:@"tab"],captured=[self canAdjustVolumeForSlot:i];
        c.assignment.enabled=i!=0&&!busy;c.assignment.accessibilityHelp=busyHint?:c.assignment.toolTip;c.mute.enabled=!busy;c.mute.toolTip=busyHint;c.mute.accessibilityHelp=busyHint;
        c.route.enabled=!busy&&!tabRoute;c.route.toolTip=busyHint?:(tabRoute?TXL(@"개별 Chrome 탭은 별도 미리 듣기를 지원하지 않습니다. Chrome 전체 채널을 사용하세요."):TXL(@"이 트랙의 출력 경로를 선택합니다."));c.route.accessibilityHelp=c.route.toolTip;[c.route selectItemAtIndex:atomic_load(&_audio.state->route[i])];c.route.accessibilityValue=TXRouteTitles()[atomic_load(&_audio.state->route[i])];
        c.fader.enabled=!busy&&captured;c.fader.needsDisplay=YES;c.fader.toolTip=busyHint?:(captured?TXL(@"음량을 드래그하거나 스크롤하여 조절합니다."):TXL(@"음소거는 바로 조절됩니다. 개별 음량·EQ는 해당 Chrome 탭에서 ⌘⇧6으로 연결하세요."));c.fader.accessibilityHelp=c.fader.toolTip;
        for(TXKnob *knob in c.knobs){knob.enabled=c.fader.enabled;knob.needsDisplay=YES;knob.toolTip=busyHint?:(captured?TXL(@"위아래 드래그 또는 스크롤. 두 번 클릭하면 0 dB. Shift로 미세 조절."):c.fader.toolTip);knob.accessibilityHelp=knob.toolTip;}
    }
}
- (NSString*)keyForTab:(NSDictionary*)tab {return [NSString stringWithFormat:@"chrome-tab:%@:%@",tab[@"session"],tab[@"id"]];}
- (void)browserChanged {
    [self refreshDevices];if(_desiredRunning&&![_signature isEqual:[self currentSignature]])[self rebuildAudio];[self updateStatus];[self writeStatus];
}
- (void)sendBrowserControls {
    if(!_browser||_sceneApplying||_sceneStopping)return;if(_lastBrowserSend&&[NSDate.date timeIntervalSinceDate:_lastBrowserSend]<0.05){[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendBrowserControls) object:nil];[self performSelector:@selector(sendBrowserControls) withObject:nil afterDelay:0.05 inModes:@[NSRunLoopCommonModes]];return;}NSMutableArray *controls=[NSMutableArray array];TXRenderState *s=_audio.state;
    for(NSDictionary *tab in _browser.tabs){NSString *key=[self keyForTab:tab];NSUInteger slot=[_assignments indexOfObject:key];BOOL mapped=slot!=NSNotFound&&slot<6;
        [controls addObject:@{@"tabId":tab[@"id"],@"session":tab[@"session"],@"gain":mapped?@(atomic_load(&s->gain[slot])):@1,@"muted":mapped?@(atomic_load(&s->muted[slot])):@NO,@"eq":mapped?@[@(atomic_load(&s->eq[slot][0])),@(atomic_load(&s->eq[slot][1])),@(atomic_load(&s->eq[slot][2]))]:@[@0,@0,@0]}];
    }
    [_browser sendControls:controls enabled:_audioReady];_lastBrowserSend=NSDate.date;
}
- (NSDictionary*)processForSlot:(NSInteger)slot {
    if(slot<0||slot>=6)return nil;for(NSDictionary *process in _processes)if([process[@"key"] isEqual:_assignments[slot]])return process;return nil;
}
- (BOOL)canAdjustVolumeForSlot:(NSInteger)slot {
    NSDictionary *process=[self processForSlot:slot];if(slot>=0&&slot<6&&[_assignments[slot] hasPrefix:@"chrome-tab:"])return [process[@"canVolume"] boolValue];return ![process[@"isBrowserTab"] boolValue]||[process[@"canVolume"] boolValue];
}
- (void)showBrowserCaptureHint:(NSInteger)slot {
    _canvas.message=TXL(@"Chrome 탭 음소거는 바로 조절됩니다. 개별 음량·EQ는 해당 탭에서 ⌘⇧6을 한 번 눌러 연결하세요.");[self showHUDForSlot:slot message:TXL(@"음량·EQ 연결: ⌘⇧6")];_canvas.needsDisplay=YES;
}
- (BOOL)isAutomaticCandidate:(NSDictionary*)process {
    NSString *key=process[@"key"];if([process[@"isBrowserTab"] boolValue])return YES;if([process[@"isSystemSound"] boolValue]||[key isEqual:@"local.tx6mac.system-sounds"])return NO;if(!key.length||[key hasPrefix:@"pid:"]||[key isEqual:NSBundle.mainBundle.bundleIdentifier])return NO;
    return [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:key]!=nil;
}
- (void)clearPickupForSlot:(NSInteger)slot {
    memset(_latched[slot],0,sizeof(_latched[slot]));memset(_havePrevious[slot],0,sizeof(_havePrevious[slot]));
    _channels[slot].fader.awaitingPickup=_pickup;for(TXKnob *knob in _channels[slot].knobs)knob.awaitingPickup=_pickup;
}
- (void)autoMatch {
    if(_sceneApplying||_sceneStopping)return;
    NSMutableSet *present=[NSMutableSet set];NSMutableArray *candidateProcesses=[NSMutableArray array];BOOL chromeRunning=NO;
    for(NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications)if(application.bundleIdentifier.length){[present addObject:application.bundleIdentifier];if([application.bundleIdentifier isEqual:@"com.google.Chrome"])chromeRunning=YES;}
    for(NSDictionary *process in _processes){NSString *key=process[@"key"];if(key.length)[present addObject:key];if(([key isEqual:@"com.google.Chrome"]||[process[@"active"] boolValue]||([process[@"isBrowserTab"] boolValue]&&[process[@"canVolume"] boolValue]))&&[self isAutomaticCandidate:process])[candidateProcesses addObject:process];}
    [candidateProcesses sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSInteger left=TXAutomaticPriority(a),right=TXAutomaticPriority(b);if(left<right)return NSOrderedAscending;if(left>right)return NSOrderedDescending;return [a[@"key"] compare:b[@"key"]];}];
    NSMutableArray *candidates=[NSMutableArray array];for(NSDictionary *process in candidateProcesses)[candidates addObject:process[@"key"]];
    if(_browserTabMode){[present removeObject:@"com.google.Chrome"];if(!_browser.connected&&chromeRunning)for(NSString *key in _assignments)if([key hasPrefix:@"chrome-tab:"])[present addObject:key];}
    NSArray *previous=[_assignments copy];NSArray *family=TXResolveChromeFamily(previous,candidates,_browserTabMode);NSArray *next=TXStableAssignments(family,present,candidates,_autoAssign,_sceneReservations);
    NSInteger unassigned=0,empty=0;for(int i=1;i<6;i++)if(![next[i] length])empty++;for(NSString *key in candidates)if(![next containsObject:key])unassigned++;_overflowCount=MAX(0,unassigned-empty);
    if([next isEqual:previous])return;
    if(_audioReady&&!_sceneProtected){[self stopAudio];_signature=nil;}_assignments=[next mutableCopy];[self saveSettings];
}
- (void)autoStartChanged:(NSButton*)sender {
    _autoStart=sender.state==NSControlStateValueOn;if(_autoStart){_explicitStop=NO;_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;if(_audioStartConsent){_desiredRunning=YES;[self rebuildAudio];}else [self showSetup:nil];}else _retryAt=nil;[self saveSettings];[self updateStatus];[self writeStatusNow];
}
- (void)autoChanged:(NSButton*)sender {if(_sceneApplying||_sceneStopping)return;
    _autoAssign=sender.state==NSControlStateValueOn;[self refreshDevices];[self saveSettings];if(_desiredRunning&&![_signature isEqual:[self currentSignature]])[self rebuildAudio];[self updateStatus];
}
- (void)browserModeChanged:(NSButton*)sender {if(_sceneApplying||_sceneStopping)return;for(int i=1;i<6;i++)if([_pendingSources[i] isEqual:@"tab"]||[_assignments[i] isEqual:@"com.google.Chrome"]||[_assignments[i] hasPrefix:@"chrome-tab:"]){_pendingSources[i]=@"";[_sceneReservations removeIndex:i];}_browserTabMode=sender.state==NSControlStateValueOn;_processMenuSignature=nil;[self refreshDevices];[self saveSettings];if(_desiredRunning)[self rebuildAudio];[self updateStatus];[self writeStatus];}
- (NSArray*)currentGroups {
    return TXNativeGroups(_processes,_assignments);
}
- (NSDictionary*)selectedMonitor {if(!_monitorUID.length)return nil;for(NSDictionary *device in _outputs)if([device[@"uid"] isEqual:_monitorUID])return device;return nil;}
- (NSDictionary*)selectedOutput {for(NSDictionary *d in _outputs)if([d[@"uid"] isEqual:_outputUID])return d;return nil;}
- (BOOL)isTX6Output:(NSDictionary*)device {return TXIsTX6Output(device);}
- (NSDictionary*)usbMeterDevice {
    if(!_usbMeters||_browserTabMode||([self isTX6Output:[self selectedOutput]]||[self isTX6Output:[self selectedMonitor]]))return nil;
    NSMutableArray *matches=[NSMutableArray array];for(NSDictionary *device in _outputs)if([self isTX6Output:device]&&[device[@"transport"] unsignedIntValue]==kAudioDeviceTransportTypeUSB&&[device[@"channels"] unsignedIntValue]==12&&![device[@"uid"] isEqual:_outputUID]&&![device[@"uid"] isEqual:_monitorUID])[matches addObject:device];
    // An ambiguous pair of devices must not receive audio without an explicit device choice.
    return matches.count==1?matches.firstObject:nil;
}
- (NSString*)usbMeterStatus {
    if(!_usbMeters)return TXL(@"선택 기능 · TX-6 USB 12 IN 채널 미터");
    if(_browserTabMode)return TXL(@"Chrome 탭별 모드에서는 대기 · 맥 믹서는 계속 동작합니다.");
    if([self isTX6Output:[self selectedOutput]]||[self isTX6Output:[self selectedMonitor]])return TXL(@"TX-6를 오디오 출력에 사용 중 · 별도 미터 경로는 대기합니다.");
    if(![self usbMeterDevice])return TXL(@"TX-6 USB 12 IN 연결 대기 · Bluetooth만으로는 지원하지 않습니다.");
    if(_usbMeterError.length)return _audioReady?TXL(@"USB 미터 연결 실패 · 맥 믹서는 계속 동작합니다."):TXL(@"USB 미터 연결 실패 · 믹서 오디오 상태를 확인하세요.");
    if(_audioReady&&_usbMetering)return TXL(@"USB 채널 미터 연결 · CH 01–06 앱 오디오 전송 중");
    return TXL(@"USB 미터 준비 · 믹서를 시작하면 채널 오디오를 전송합니다.");
}
- (void)usbMetersChanged:(NSButton*)sender {if(_sceneApplying||_sceneStopping)return;_usbMeters=sender.state==NSControlStateValueOn;_usbMeterError=@"";if(_desiredRunning){_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;[self rebuildAudio];}[self saveSettings];[self updateStatus];[self writeStatusNow];}
- (NSString*)currentSignature {
    NSDictionary *d=[self selectedOutput];double rate=[d[@"rate"] doubleValue];
    NSDictionary *meter=[self usbMeterDevice];return [[NSString stringWithFormat:@"%@|%@|%.0f|%@|usb:%d:%@:%@",_outputUID,d[@"id"]?:@0,rate,[self currentGroups],_usbMeters,meter[@"id"]?:@0,meter[@"rate"]?:@0] stringByAppendingFormat:@"|monitor:%@:%@:%@",_monitorUID?:@"",[self selectedMonitor][@"id"]?:@0,[self selectedMonitor][@"rate"]?:@0];
}
- (void)scheduleRecovery {
    if(!_desiredRunning||_explicitStop||_sleeping||_retryAt)return;if(!TXMayAutoStart(_autoStart,_audioStartConsent,_explicitStop,_sleeping)){_retryExhausted=YES;return;}
    NSTimeInterval delay=TXRetryDelay(_retryAttempt);if(delay>0){_retryAt=[NSDate dateWithTimeIntervalSinceNow:delay];_retryAttempt++;}else _retryExhausted=YES;
}
- (void)requestHALSnapshot {
    _halSnapshotRequested=YES;[self processHALWork];
}
- (void)applyHALSnapshot:(NSDictionary*)snapshot {
    if(_sceneApplying){_halSnapshot=snapshot?:@{};_halSnapshotReady=YES;return;}
    NSDictionary *previousOutput=[self selectedOutput];BOOL hadOutput=previousOutput!=nil;NSString *previousUID=_outputUID;
    _halSnapshot=snapshot?:@{};_halSnapshotReady=YES;
    NSString *defaultUID=_halSnapshot[@"defaultUID"]?:@"";BOOL selectedPresent=NO,defaultPresent=NO;
    for(NSDictionary *device in _halSnapshot[@"outputs"]){if([device[@"uid"] isEqual:_outputUID])selectedPresent=YES;if([device[@"uid"] isEqual:defaultUID])defaultPresent=YES;}
    if(defaultPresent&&(_followDefaultOutput||(!selectedPresent&&!_sceneOutputPinned))){_outputUID=defaultUID;_followDefaultOutput=YES;}
    [self refreshDevices];
    BOOL routeChanged=![previousUID isEqual:_outputUID]||![previousOutput[@"id"] isEqual:[self selectedOutput][@"id"]];
    if((!hadOutput||routeChanged)&&[self selectedOutput]&&_desiredRunning&&!_explicitStop){_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;}
    if(_desiredRunning&&!_sleeping&&!_explicitStop&&!_retryAt&&(!_audioReady||![_signature isEqual:[self currentSignature]]))[self rebuildAudio];
}
- (void)processHALWork {
    NSAssert(NSThread.isMainThread,@"HAL request state belongs to the main thread");
    if(_halBusy||(!_pendingHALRequest&&!_halSnapshotRequested))return;
    NSDictionary *request=_pendingHALRequest;_pendingHALRequest=nil;
    if([request[@"kind"] isEqual:@"scene"]){[self performSceneRequest:request];return;}
    BOOL snapshot=request==nil;if(snapshot)_halSnapshotRequested=NO;
    _halBusy=YES;_halStartedAt=NSDate.date;_halWaitReported=NO;
    TXAudio *backend=_audio;NSUInteger generation=[request[@"generation"] unsignedIntegerValue];
    __weak TXApp *weakSelf=self;
    dispatch_async(_halQueue,^{@autoreleasepool {
        BOOL ok=NO,metering=NO,monitoring=NO;NSString *error=@"",*meterError=@"",*monitorError=request[@"monitorError"]?:@"";NSDictionary *discovered=nil;
        if(snapshot){
            NSMutableArray *outputs=[NSMutableArray array];
            for(NSDictionary *output in TXAudio.outputs){
                NSMutableDictionary *entry=[output mutableCopy];Float64 rate=0;UInt32 size=sizeof(rate);
                AudioObjectPropertyAddress address={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
                AudioObjectGetPropertyData([output[@"id"] unsignedIntValue],&address,0,NULL,&size,&rate);entry[@"rate"]=@(rate);[outputs addObject:entry];
            }
            discovered=@{@"outputs":outputs,@"processes":TXAudio.processes,@"defaultUID":[TXAudio uid:TXAudio.defaultOutput]?:@""};
        }else if([request[@"kind"] isEqual:@"start"]){
            AudioDeviceID wantedMeter=[request[@"meterDevice"] unsignedIntValue],wantedMonitor=[request[@"monitorDevice"] unsignedIntValue];
            NSArray *choices=@[@[@(wantedMonitor),@(wantedMeter)],@[@(wantedMonitor),@0],@[@0,@(wantedMeter)],@[@0,@0]];NSMutableSet *attempted=[NSMutableSet set];
            BOOL monitorIdentityLost=NO,meterIdentityLost=NO;
            for(NSArray *choice in choices){
                AudioDeviceID main=[request[@"device"] unsignedIntValue],monitor=[choice[0] unsignedIntValue],meter=[choice[1] unsignedIntValue];
                NSString *mainUID=request[@"mainUID"];
                if(!mainUID.length||![[backend outputUIDForDevice:main expectedUID:mainUID] isEqual:mainUID]){[backend stop];backend.monitorOutputDevice=0;backend.meterOutputDevice=0;error=TXL(@"메인 출력 장치가 변경되어 오디오 연결을 중지했습니다.");break;}
                NSString *monitorUID=request[@"monitorUID"],*meterUID=request[@"meterUID"];
                if(monitor&&(!monitorUID.length||![[backend outputUIDForDevice:monitor expectedUID:monitorUID] isEqual:monitorUID])){monitorIdentityLost=YES;monitorError=TXL(@"선택한 미리 듣기 장치가 연결되지 않음");}
                if(meter&&(!meterUID.length||![[backend outputUIDForDevice:meter expectedUID:meterUID] isEqual:meterUID])){meterIdentityLost=YES;meterError=TXL(@"선택한 USB 미터 장치가 변경되어 연결하지 않았습니다.");}
                if(monitorIdentityLost)monitor=0;if(meterIdentityLost)meter=0;
                NSString *key=[NSString stringWithFormat:@"%u:%u",monitor,meter];if([attempted containsObject:key])continue;[attempted addObject:key];
                backend.monitorOutputDevice=monitor;backend.meterOutputDevice=meter;ok=[backend startOnDevice:main groups:request[@"groups"]];if(ok)break;
                if(monitor)monitorError=backend.lastError?:@"";if(meter)meterError=backend.lastError?:@"";
            }
            if(!error.length)error=backend.lastError?:@"";metering=ok&&backend.metering;monitoring=ok&&backend.monitoring;if(metering)meterError=@"";if(monitoring)monitorError=@"";
        }else {[backend stop];TXApp *owner=weakSelf;if([request[@"restore"] count])[owner applySceneDSP:request[@"restore"]];NSError *guardError=nil;if(owner&&owner->_sceneGuard&&![owner->_sceneGuard end:&guardError])error=guardError.localizedDescription?:TXL(@"씬 전환 보호 해제 실패 · 중지 후 다시 시도하세요.");else atomic_store(&backend.state->transitionMuted,false);}
        dispatch_async(dispatch_get_main_queue(),^{
            TXApp *app=weakSelf;if(!app)return;
            app->_halBusy=NO;app->_halStartedAt=nil;
            if(snapshot){
                [app applyHALSnapshot:discovered];
            }else if(generation==app->_halGeneration){
                app->_isBuilding=NO;app->_pendingAudioSignature=nil;
                if([request[@"kind"] isEqual:@"start"]){
                    app->_audioReady=ok;app->_audioError=error;app->_usbMetering=metering;app->_usbMeterError=meterError;app->_monitoring=monitoring;app->_monitorError=monitorError;
                    if(ok){app->_startedAt=NSDate.date;app->_progressAt=NSDate.date;app->_progressFrames=0;app->_signature=request[@"signature"];app->_canvas.message=TXL(@"믹서 실행 중 · 앱별 음량과 EQ가 선택한 출력에 적용됩니다.");}
                    else{app->_canvas.message=error;[app scheduleRecovery];}
                }else{app->_halStopping=NO;app->_sceneStopping=NO;[app saveSettings];[app refreshDeviceMenus];app->_outputMenu.enabled=YES;app->_monitorMenu.enabled=YES;app->_monitorSlider.enabled=YES;app->_autoButton.enabled=YES;app->_usbMetersButton.enabled=YES;if(error.length)app->_audioError=error;if(!app->_sleeping)app->_canvas.message=app->_audioError.length?app->_audioError:TXL(@"믹서 중지 · 프로그램의 원래 출력이 복구되었습니다.");}
            }
            [app sendBrowserControls];[app updateStatus];[app writeStatusNow];[app processHALWork];
        });
    }});
}
+ (BOOL)sceneControllerSelfCheck {
    TXSceneCheckApp *fixture=[TXSceneCheckApp new];fixture.memoryDefaults=[TXSceneCheckDefaults new];TXApp *app=fixture;TXSceneCheckAudio *audio=[TXSceneCheckAudio new];TXSceneCheckGuard *guard=[TXSceneCheckGuard new];guard.audio=audio;
    app->_audio=audio;app->_sceneGuard=guard;app->_sceneStore=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)[TXSceneCheckDefaults new]];app->_halQueue=dispatch_queue_create("local.tx6mac.scene-check",DISPATCH_QUEUE_SERIAL);app->_halSnapshotReady=YES;
    app->_assignments=[@[@"local.tx6mac.system-sounds",@"closed.native.app",@"",@"",@"",@""] mutableCopy];app->_pendingSources=[@[@"",@"",@"",@"",@"",@""] mutableCopy];app->_processes=@[];app->_outputUID=@"fixtureA";app->_monitorUID=@"";app->_outputs=@[@{@"id":@1,@"uid":@"fixtureA",@"name":@"A",@"rate":@48000,@"channels":@2},@{@"id":@2,@"uid":@"fixtureB",@"name":@"B",@"rate":@48000,@"channels":@2}];app->_halSnapshot=@{@"outputs":app->_outputs,@"processes":@[],@"defaultUID":@"fixtureA"};
    BOOL (^until)(BOOL(^)(void))=^BOOL(BOOL(^condition)(void)){NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:4];while(!condition()&&limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];return condition();};
    BOOL (^done)(void)=^BOOL{return !app->_halBusy&&!app->_pendingHALRequest&&!app->_sceneApplying;};
    __block BOOL ok=YES;void (^check)(BOOL,NSString*)=^(BOOL value,NSString *label){if(!value){fprintf(stderr,"Scene controller self-check failed: %s\n",label.UTF8String);ok=NO;}};
    atomic_store(&audio.state->master,.4);atomic_store(&audio.state->masterMuted,true);atomic_store(&audio.state->gain[1],.8);
    NSError *error=nil;check([app saveSceneName:@"Desk" rename:NO error:&error],@"controller save");NSString *desk=app->_selectedSceneID;NSDictionary *original=[app sceneSnapshot];atomic_store(&audio.state->gain[1],.5);check([app sceneDirty],@"dirty state");[app sceneOverwrite:nil];check(![app sceneDirty],@"overwrite");[app sceneUndo:nil];check([app sceneDirty],@"undo overwrite");check([app saveSceneName:@"Renamed" rename:YES error:&error],@"rename");[app sceneUndo:nil];check([[app->_sceneStore sceneWithID:desk][@"name"] isEqual:@"Desk"],@"undo rename");[app sceneDelete:nil];check(!app->_selectedSceneID&&app->_sceneStore.scenes.count==0,@"delete");[app sceneUndo:nil];check([app->_selectedSceneID isEqual:desk]&&app->_sceneStore.scenes.count==1,@"undo delete");
    check(![app saveSceneName:@"  " rename:NO error:&error]&&error.code==TXSceneErrorInvalidName,@"inline invalid name");check(![app saveSceneName:@"desk" rename:NO error:&error]&&error.code==TXSceneErrorDuplicateName,@"inline duplicate name");
    app->_desiredRunning=NO;app->_explicitStop=YES;[app recallSnapshot:original sceneID:desk recordUndo:YES];check(until(done)&&audio.starts==0&&!atomic_load(&audio.state->transitionMuted),@"explicit stop remains stopped");check([app->_sceneReservations containsIndex:1],@"closed app reservation");
    NSDictionary *profile=[app profileSettings];app->_sceneReservations=nil;[app restoreSceneProfile:profile];check([app->_sceneReservations containsIndex:1],@"reservation profile restart");NSArray *reserved=TXStableAssignments(app->_assignments,[NSSet setWithObject:@"local.tx6mac.system-sounds"],@[@"other"],YES,app->_sceneReservations);check([reserved[1] isEqual:@"closed.native.app"]&&[reserved[2] isEqual:@"other"],@"closed slot preserves priority");
    NSPopUpButton *assignment=[NSPopUpButton new];assignment.tag=1;[assignment addItemWithTitle:@"None"];assignment.selectedItem.representedObject=@"";[app assignmentChanged:assignment];check(![app->_sceneReservations containsIndex:1],@"manual assignment releases reservation");
    NSMutableDictionary *volatileScene=[original mutableCopy];volatileScene[@"chromeTabs"]=@YES;volatileScene[@"assignments"]=@[@"local.tx6mac.system-sounds",@"chrome-tab:stale:42",@"pid:888",@"",@"",@""];[app recallSnapshot:volatileScene sceneID:desk recordUndo:YES];check(until(done)&&[app->_pendingSources[1] isEqual:@"tab"]&&[app->_pendingSources[2] isEqual:@"process"]&&[app->_assignments[1] length]==0,@"volatile IDs are not reused");NSButton *mode=[NSButton new];mode.state=NSControlStateValueOff;[app browserModeChanged:mode];check(![app->_pendingSources[1] length]&&![app->_sceneReservations containsIndex:1]&&[app->_sceneReservations containsIndex:2],@"Chrome mode clears incompatible intent only");
    NSDictionary *unchanged=[app sceneSnapshot];NSUInteger stops=audio.stops;NSMutableDictionary *future=[original mutableCopy];future[@"version"]=@3;[app recallSnapshot:future sceneID:desk recordUndo:YES];check([TXSceneStore snapshot:unchanged equals:[app sceneSnapshot]]&&audio.stops==stops&&!app->_sceneApplying,@"future snapshot has no side effects");
    app->_explicitStop=NO;app->_desiredRunning=YES;app->_audioReady=YES;[app applySceneDSP:original];[app commitSceneModel:original sceneID:desk];NSMutableDictionary *target=[original mutableCopy];target[@"outputUID"]=@"fixtureB";NSMutableArray *channels=[original[@"channels"] mutableCopy];NSMutableDictionary *channel=[channels[1] mutableCopy];channel[@"gain"]=@.2;channels[1]=channel;target[@"channels"]=channels;
    guard.failBegin=YES;stops=audio.stops;[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(done)&&audio.stops==stops&&fabs(atomic_load(&audio.state->gain[1])-.8)<.000001&&app->_audioReady,@"begin failure keeps old backend and DSP");guard.failBegin=NO;
    [audio.events removeAllObjects];audio.expectOldStop=YES;audio.expectedOldGain=.8;[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(done)&&app->_audioReady&&!guard.active&&!atomic_load(&audio.state->transitionMuted)&&!audio.wrongOrder&&!audio.usedMain,@"guarded ready commit");check([audio.events isEqual:@[@"begin",@"stop",@"start:2",@"end"]],@"begin stop target start ready end order");check(fabs(atomic_load(&audio.state->master)-.4)<.000001&&atomic_load(&audio.state->masterMuted),@"global master and FX II remain unchanged");[app sceneUndo:nil];check(until(done)&&[app->_outputUID isEqual:@"fixtureA"]&&fabs(atomic_load(&audio.state->gain[1])-.8)<.000001,@"load undo restores mix");
    audio.failTarget=YES;[audio.events removeAllObjects];[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(done)&&app->_audioReady&&[app->_outputUID isEqual:@"fixtureA"]&&!guard.active&&[audio.events isEqual:@[@"begin",@"stop",@"start:2",@"stop",@"stop",@"start:1",@"end"]],@"failed target rolls back under same guard");audio.failTarget=NO;
    audio.firstStartGate=dispatch_semaphore_create(0);audio.blockStart=audio.starts+1;[audio.events removeAllObjects];[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(^BOOL{return audio.starts==audio.blockStart;}),@"rapid first request blocked");[app recallSnapshot:original sceneID:desk recordUndo:YES];NSMutableDictionary *latest=[target mutableCopy];latest[@"monitorGain"]=@.3;[app recallSnapshot:latest sceneID:desk recordUndo:YES];[app handleMIDI:@"fixture" channel:0 cc:2 value:50];[app handleMIDI:@"fixture" channel:0 cc:26 value:127];[app handleMIDI:@"fixture" channel:0 cc:26 value:0];check(guard.active&&atomic_load(&audio.state->transitionMuted),@"stale render stays gated");dispatch_semaphore_signal(audio.firstStartGate);check(until(done)&&[app->_outputUID isEqual:@"fixtureB"]&&fabs(atomic_load(&audio.state->monitorGain)-.3)<.000001&&fabs(atomic_load(&audio.state->gain[1])-50.0/127)<.000001&&atomic_load(&audio.state->muted[1]),@"latest wins with full MIDI press and fader replay");check([[audio.events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'end'"]] count]==1,@"only latest releases guard");
    NSMutableDictionary *missing=[original mutableCopy];missing[@"outputUID"]=@"offline-main";missing[@"monitorUID"]=@"offline-monitor";[app recallSnapshot:missing sceneID:desk recordUndo:YES];check(until(done)&&!app->_audioReady&&guard.active&&atomic_load(&audio.state->transitionMuted)&&[app->_outputUID isEqual:@"offline-main"]&&[app->_monitorUID isEqual:@"offline-monitor"],@"offline main waits guarded without speaker fallback");[app applyHALSnapshot:app->_halSnapshot];check(until(done)&&[app->_outputUID isEqual:@"offline-main"]&&guard.active,@"snapshot cannot redirect pinned main");
    app->_desiredRunning=NO;app->_explicitStop=YES;[app stopAudio];check(until(done)&&!guard.active&&!atomic_load(&audio.state->transitionMuted),@"explicit stop releases protection");
    app->_explicitStop=NO;app->_desiredRunning=YES;audio.failAll=YES;[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(done)&&!app->_audioReady&&guard.active&&atomic_load(&audio.state->transitionMuted),@"target and rollback failure stays muted");audio.failAll=NO;
    [app recallSnapshot:original sceneID:desk recordUndo:YES];check(until(done)&&app->_audioReady&&!guard.active,@"retry recovers held guard");guard.failEnd=YES;[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(done)&&guard.active&&!app->_audioReady&&atomic_load(&audio.state->transitionMuted)&&app->_audioError.length,@"guard end failure remains visible and gated");guard.failEnd=NO;app->_desiredRunning=NO;[app stopAudio];check(until(done)&&!guard.active,@"guard end retry on stop");
    app->_desiredRunning=YES;app->_explicitStop=NO;[app recallSnapshot:original sceneID:desk recordUndo:YES];check(until(done),@"prepare protected rebuild");
    [app->_sceneReservations removeIndex:1];app->_sceneOutputPinned=NO;[audio.events removeAllObjects];[app rebuildAudio];check(until(done)&&![app->_sceneReservations containsIndex:1]&&!app->_sceneOutputPinned&&[audio.events isEqual:@[@"begin",@"stop",@"start:1",@"end"]],@"normal rebuild retains manual policy under guard");
    NSMutableDictionary *fallback=[original mutableCopy];fallback[@"monitorUID"]=@"fixtureB";app->_usbMeters=YES;NSDictionary *usb=@{@"id":@42,@"uid":@"usb-tx6",@"name":@"TX-6",@"channels":@12,@"transport":@(kAudioDeviceTransportTypeUSB),@"rate":@48000};app->_outputs=[app->_outputs arrayByAddingObject:usb];app->_halSnapshot=@{@"outputs":app->_outputs,@"processes":@[],@"defaultUID":@"fixtureA"};audio.failMeters=YES;[audio.events removeAllObjects];[app recallSnapshot:fallback sceneID:desk recordUndo:YES];check(until(done)&&app->_audioReady&&app->_monitoring&&!app->_usbMetering&&!guard.active&&[[audio.events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'begin'"]] count]==1&&[[audio.events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'end'"]] count]==1,@"meter fallback remains inside one guard");audio.failMeters=NO;audio.failMonitor=YES;[app recallSnapshot:fallback sceneID:desk recordUndo:YES];check(until(done)&&app->_audioReady&&!app->_monitoring&&app->_usbMetering&&!guard.active,@"monitor fallback keeps meter and guard");audio.failMonitor=NO;app->_usbMeters=NO;
    NSDictionary *beforeStop=[app runtimeSceneSnapshot];NSString *beforeStopID=app->_selectedSceneID;audio.firstStartGate=dispatch_semaphore_create(0);audio.blockStart=audio.starts+1;[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(^BOOL{return audio.starts==audio.blockStart;}),@"stop test blocks target");NSDictionary *savedDuringRecall=[fixture.memoryDefaults objectForKey:@"TX6Mac.profile"];[app saveSettings];check([[fixture.memoryDefaults objectForKey:@"TX6Mac.profile"] isEqual:savedDuringRecall],@"autosave cannot persist partial scene");app->_desiredRunning=NO;app->_explicitStop=YES;[app stopAudio];dispatch_semaphore_signal(audio.firstStartGate);check(until(done)&&!guard.active&&!atomic_load(&audio.state->transitionMuted)&&[TXSceneStore snapshot:beforeStop equals:[app sceneSnapshot]]&&[app->_selectedSceneID isEqual:beforeStopID],@"stop during recall restores coherent prior profile");
    check([[[fixture.memoryDefaults objectForKey:@"TX6Mac.profile"] objectForKey:@"assignments"] isEqual:app->_assignments],@"committed profile assignments match DSP model");
    TXSceneCheckDefaults *badDefaults=[TXSceneCheckDefaults new];[badDefaults setObject:@{@"version":@99,@"entries":@[]} forKey:@"TX6Mac.scenes"];TXSceneStore *goodStore=app->_sceneStore;app->_sceneStore=[[TXSceneStore alloc] initWithDefaults:(NSUserDefaults*)(id)badDefaults];NSMenu *readOnly=[app sceneActionMenu];check(app->_sceneStore.readOnly&&![readOnly.itemArray[2] isEnabled]&&[TXSceneStore snapshot:beforeStop equals:[app sceneSnapshot]],@"read-only storage disables mutation without changing mix");app->_sceneStore=goodStore;
    app->_desiredRunning=YES;app->_explicitStop=NO;app->_pickup=YES;NSMutableDictionary *pickupScene=[original mutableCopy];NSMutableArray *pickupChannels=[original[@"channels"] mutableCopy];NSMutableDictionary *pickupChannel=[pickupChannels[1] mutableCopy];pickupChannel[@"gain"]=@.5;pickupChannels[1]=pickupChannel;pickupScene[@"channels"]=pickupChannels;
    audio.firstStartGate=dispatch_semaphore_create(0);audio.blockStart=audio.starts+1;[app recallSnapshot:pickupScene sceneID:desk recordUndo:YES];check(until(^BOOL{return audio.starts==audio.blockStart;}),@"pickup regression blocks start");[app handleMIDI:@"fixture" channel:0 cc:2 value:20];[app handleMIDI:@"fixture" channel:0 cc:2 value:100];[app handleMIDI:@"fixture" channel:0 cc:26 value:127];[app handleMIDI:@"fixture" channel:0 cc:26 value:0];float masterBeforeEncoder=atomic_load(&audio.state->master);[app handleMIDI:@"fixture" channel:0 cc:31 value:1];[app handleMIDI:@"fixture" channel:0 cc:31 value:127];check(fabs(atomic_load(&audio.state->master)-masterBeforeEncoder)<.000001,@"relative encoder stays live and ordered");dispatch_semaphore_signal(audio.firstStartGate);check(until(done)&&app->_latched[1][0]&&fabs(atomic_load(&audio.state->gain[1])-100.0/127)<.000001&&atomic_load(&audio.state->muted[1]),@"ordered queued pickup crossing and button press release");app->_pickup=NO;
    guard.endGate=dispatch_semaphore_create(0);[app recallSnapshot:original sceneID:desk recordUndo:YES];check(until(^BOOL{return guard.ending;}),@"late MIDI regression blocks guard end");[app handleMIDI:@"fixture" channel:0 cc:2 value:90];[app handleMIDI:@"fixture" channel:0 cc:26 value:127];[app handleMIDI:@"fixture" channel:0 cc:26 value:0];[app handleMIDI:@"fixture" channel:0 cc:31 value:1];float liveMaster=atomic_load(&audio.state->master);dispatch_semaphore_signal(guard.endGate);check(until(done)&&app->_sceneMIDI.count==0&&fabs(atomic_load(&audio.state->gain[1])-90.0/127)<.000001&&atomic_load(&audio.state->muted[1])&&fabs(atomic_load(&audio.state->master)-liveMaster)<.000001,@"guard end MIDI drains before final unlock and save");NSDictionary *lateProfile=[fixture.memoryDefaults objectForKey:@"TX6Mac.profile"];check(fabs([lateProfile[@"channels"][1][@"gain"] doubleValue]-90.0/127)<.000001&&[lateProfile[@"channels"][1][@"muted"] boolValue]&&fabs([lateProfile[@"master"] doubleValue]-liveMaster)<.000001,@"late MIDI and current master persist together");guard.endGate=nil;atomic_store(&audio.state->master,.4);
    for(int repeat=0;repeat<2;repeat++){
        [app->_sceneMIDI removeAllObjects];[app applySceneDSP:original];[app commitSceneModel:original sceneID:desk];app->_sceneStopping=NO;app->_desiredRunning=YES;app->_explicitStop=NO;audio.firstStartGate=dispatch_semaphore_create(0);audio.blockStart=audio.starts+1;[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(^BOOL{return audio.starts==audio.blockStart;}),@"stop race blocks start");app->_desiredRunning=NO;app->_explicitStop=YES;[app stopAudio];NSDictionary *pendingStop=app->_pendingHALRequest;for(NSMenuItem *item in [app sceneActionMenu].itemArray)if(item.action)check(!item.enabled,@"scene actions disabled during stop cleanup");
        if(repeat==0){NSUInteger sceneCount=app->_sceneStore.scenes.count;NSError *blockedError=nil;[app recallSnapshot:original sceneID:desk recordUndo:YES];BOOL saved=[app saveSceneName:@"Must not save during stop" rename:NO error:&blockedError];check(!saved&&app->_sceneStore.scenes.count==sceneCount&&[app->_pendingHALRequest isEqual:pendingStop],@"stop rejects recall and save without replacing cleanup");}
        else {[app stopAudio];check([app->_pendingHALRequest isEqual:pendingStop],@"repeated stop preserves original rollback request");check([app applicationShouldTerminate:NSApp]==NSTerminateLater&&[app applicationShouldTerminate:NSApp]==NSTerminateLater&&app->_sceneQuitting&&[app->_pendingHALRequest isEqual:pendingStop],@"repeated quit retains pending stop rollback and waits");}
        dispatch_semaphore_signal(audio.firstStartGate);check(until(done)&&!app->_sceneStopping&&!app->_halStopping&&!guard.active&&[TXSceneStore snapshot:original equals:[app sceneSnapshot]],repeat==0?@"stop then recall finishes cleanly":@"repeated stop restores prior DSP and model");app->_sceneQuitting=NO;
    }
    app->_desiredRunning=YES;app->_explicitStop=NO;audio.firstStartGate=dispatch_semaphore_create(0);audio.blockStart=audio.starts+1;[app recallSnapshot:target sceneID:desk recordUndo:YES];check(until(^BOOL{return audio.starts==audio.blockStart;}),@"overflow test blocks start");for(NSUInteger i=0;i<=TXSceneMIDILimit;i++)[app handleMIDI:@"fixture" channel:0 cc:2 value:(UInt8)(i%128)];check(app->_sceneMIDI.count==TXSceneMIDILimit&&app->_sceneMIDIOverflow,@"pre-commit MIDI queue is bounded");dispatch_semaphore_signal(audio.firstStartGate);check(until(done)&&guard.active&&atomic_load(&audio.state->transitionMuted)&&!app->_audioReady&&app->_audioError.length,@"overflow fails closed instead of losing gestures silently");NSUInteger overflowStarts=audio.starts;[app rebuildAudio];check(!app->_pendingHALRequest&&audio.starts==overflowStarts,@"overflow suppresses automatic retry");app->_desiredRunning=NO;app->_explicitStop=YES;[app stopAudio];check(until(done)&&!guard.active&&!app->_sceneMIDIOverflow,@"stop recovers MIDI overflow");
    app->_desiredRunning=YES;app->_explicitStop=NO;guard.endGate=dispatch_semaphore_create(0);[app recallSnapshot:original sceneID:desk recordUndo:YES];check(until(^BOOL{return guard.ending;}),@"large late queue blocks end");for(NSUInteger i=0;i<=TXSceneMIDILimit;i++)[app handleMIDI:@"fixture" channel:0 cc:2 value:(UInt8)(i%128)];check(app->_sceneMIDI.count<=TXSceneMIDILimit&&!app->_sceneMIDIOverflow&&atomic_load(&audio.state->transitionMuted),@"committed MIDI batches drain in order without overflow");dispatch_semaphore_signal(guard.endGate);check(until(done)&&app->_sceneMIDI.count==0&&atomic_load(&audio.state->gain[1])==0&&!atomic_load(&audio.state->transitionMuted),@"late batch tail replays before gate release");guard.endGate=nil;app->_desiredRunning=NO;[app stopAudio];check(until(done),@"MIDI race fixture cleanup");
    TXApp *hints=[TXHALCheckApp new];hints->_audio=[TXAudio new];hints->_assignments=[@[@"local.tx6mac.system-sounds",@"native.fixture",@"chrome-tab:uncaptured",@"chrome-tab:captured",@"",@""] mutableCopy];hints->_pendingSources=[@[@"",@"",@"",@"",@"",@"tab"] mutableCopy];hints->_processes=@[@{@"key":@"native.fixture"},@{@"key":@"chrome-tab:uncaptured",@"isBrowserTab":@YES,@"canVolume":@NO},@{@"key":@"chrome-tab:captured",@"isBrowserTab":@YES,@"canVolume":@YES}];NSMutableArray *hintChannels=[NSMutableArray array];
    for(int i=0;i<6;i++){TXChannel *c=[TXChannel new];c.assignment=[TXPopup new];c.fader=[TXFader new];c.knobs=@[[TXKnob new],[TXKnob new],[TXKnob new]];c.mute=[NSButton new];c.route=[TXPopup new];[c.route addItemsWithTitles:TXRouteTitles()];[hintChannels addObject:c];}hints->_channels=hintChannels;
    [hints refreshChannelControls];for(int i=0;i<2;i++)check(hints->_channels[i].fader.enabled&&hints->_channels[i].route.enabled&&![hints->_channels[i].fader.toolTip containsString:@"Chrome"]&&![hints->_channels[i].route.accessibilityHelp containsString:@"Chrome"],@"native and system controls retain normal help");check(!hints->_channels[2].fader.enabled&&[hints->_channels[2].fader.accessibilityHelp containsString:@"Chrome"]&&[hints->_channels[2].route.accessibilityHelp containsString:@"Chrome"]&&hints->_channels[3].fader.enabled&&!hints->_channels[3].route.enabled&&!hints->_channels[5].route.enabled,@"actual Chrome capture and route help stays specific");
    hints->_sceneApplying=YES;[hints refreshChannelControls];for(TXChannel *c in hints->_channels)check(!c.fader.enabled&&!c.route.enabled&&[c.fader.accessibilityHelp isEqual:TXL(@"씬 전환 중")]&&[c.knobs[0].toolTip isEqual:TXL(@"씬 전환 중")]&&[c.route.accessibilityHelp isEqual:TXL(@"씬 전환 중")],@"scene transition help takes priority over source restrictions");hints->_sceneApplying=NO;hints->_sceneStopping=YES;[hints updateStatus];for(TXChannel *c in hints->_channels)check(!c.fader.enabled&&!c.mute.enabled&&[c.fader.toolTip isEqual:TXL(@"중지 중")]&&[c.knobs[2].accessibilityHelp isEqual:TXL(@"중지 중")]&&[c.route.toolTip isEqual:TXL(@"중지 중")],@"stop status refresh updates control help");hints->_sceneStopping=NO;[hints refreshChannelControls];check(hints->_channels[0].fader.enabled&&![hints->_channels[0].fader.accessibilityHelp containsString:@"Chrome"]&&[hints->_channels[2].fader.accessibilityHelp containsString:@"Chrome"],@"source-specific help returns after transition");
    NSDictionary *idleStatus=[app statusSnapshot];check([idleStatus[@"selectedSceneID"] isEqual:desk]&&[idleStatus[@"selectedSceneName"] isEqual:@"Desk"]&&![idleStatus[@"sceneTransitioning"] boolValue]&&![idleStatus[@"sceneStopping"] boolValue]&&![idleStatus[@"transitionMuted"] boolValue],@"status snapshot identifies selected scene and idle state");app->_sceneApplying=YES;atomic_store(&audio.state->transitionMuted,true);NSDictionary *transitionStatus=[app statusSnapshot];check([transitionStatus[@"sceneTransitioning"] boolValue]&&[transitionStatus[@"transitionMuted"] boolValue]&&![transitionStatus[@"sceneStopping"] boolValue],@"status snapshot reports transition gate atomically");app->_sceneApplying=NO;app->_sceneStopping=YES;NSDictionary *stopStatus=[app statusSnapshot];check([stopStatus[@"sceneStopping"] boolValue]&&![stopStatus[@"sceneTransitioning"] boolValue]&&[NSJSONSerialization isValidJSONObject:stopStatus],@"status snapshot reports stop and remains JSON serializable");app->_sceneStopping=NO;atomic_store(&audio.state->transitionMuted,false);
    TXSceneCheckApp *quitFixture=[TXSceneCheckApp new];quitFixture.memoryDefaults=[TXSceneCheckDefaults new];TXApp *quitApp=quitFixture;TXSceneCheckAudio *quitAudio=[TXSceneCheckAudio new];TXSceneCheckGuard *quitGuard=[TXSceneCheckGuard new];quitGuard.audio=quitAudio;quitApp->_audio=quitAudio;quitApp->_sceneGuard=quitGuard;quitApp->_halQueue=dispatch_queue_create("local.tx6mac.quit-check",DISPATCH_QUEUE_SERIAL);quitApp->_assignments=[original[@"assignments"] mutableCopy];quitApp->_pendingSources=[@[@"",@"",@"",@"",@"",@""] mutableCopy];quitApp->_halBusy=YES;
    NSApplicationTerminateReply quitReply=[quitApp applicationShouldTerminate:NSApp];check(quitReply==NSTerminateLater&&quitFixture.quitPollCount==0&&quitFixture.quitReplyCount==0,@"quit work waits until delegate returns Later");quitFixture.quitDelegateReturned=YES;
    CFRunLoopAddCommonMode(CFRunLoopGetMain(),(__bridge CFStringRef)NSModalPanelRunLoopMode);[quitFixture performSelector:@selector(recordDefaultModeProbe) withObject:nil afterDelay:.002];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.01*NSEC_PER_SEC)),dispatch_get_main_queue(),^{quitApp->_halBusy=NO;[quitApp processHALWork];});NSDate *quitDeadline=[NSDate dateWithTimeIntervalSinceNow:1];while(!quitFixture.quitReplyCount&&quitDeadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSModalPanelRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    check(!quitFixture.defaultModeProbe,@"modal loop does not run default-mode delayed selectors");check(quitFixture.quitReplyCount==1&&!quitFixture.quitRepliedEarly&&!quitApp->_halBusy&&!quitApp->_halStopping&&!quitApp->_pendingHALRequest&&quitAudio.stops==1,@"quit reply completes in modal mode after HAL cleanup");[NSObject cancelPreviousPerformRequestsWithTarget:quitFixture selector:@selector(recordDefaultModeProbe) object:nil];[NSObject cancelPreviousPerformRequestsWithTarget:quitFixture selector:@selector(finishSceneQuit) object:nil];quitApp->_sceneQuitting=NO;
    app->_sceneMenu=[TXPopup new];[app->_sceneStore updateSceneID:desk snapshot:[app sceneSnapshot] error:nil];[app refreshSceneMenu];NSMenu *trackingMenu=app->_sceneMenu.menu;NSMenuItem *trackingItem=trackingMenu.itemArray[2];NSString *trackingTitle=trackingMenu.itemArray[0].title;check(trackingMenu.delegate==app,@"scene popup installs tracking delegate");app->_statusMenuTracking=YES;[app menuWillOpen:trackingMenu];[app updateStatus];[app saveSettings];atomic_store(&audio.state->gain[1],.37);[app saveSceneName:@"Menu Renamed" rename:YES error:nil];app->_sceneStopping=YES;[app updateStatus];check(app->_sceneMenu.menu==trackingMenu&&app->_sceneMenu.menu.itemArray[2]==trackingItem&&[trackingMenu.itemArray[0].title isEqual:trackingTitle],@"open scene menu and item identities survive status save rename and dirty changes");check([[app statusSnapshot][@"sceneStopping"] boolValue]&&[app sceneDirty],@"scene tracking does not suppress live controller status");[app menuDidClose:trackingMenu];check(until(^BOOL{return app->_sceneMenu.menu!=trackingMenu;})&&[app->_sceneMenu.titleOfSelectedItem isEqual:@"Menu Renamed •"]&&[app->_sceneMenu.toolTip isEqual:@"Menu Renamed"]&&[app->_sceneMenu.accessibilityValue containsString:TXL(@"저장하지 않은 변경")],@"scene close applies deferred name and dirty state");for(NSMenuItem *item in app->_sceneMenu.menu.itemArray)if(item.action)check(!item.enabled,@"deferred scene menu reflects stop restrictions");check(app->_statusMenuTracking,@"scene menu close preserves status-menu tracking");app->_statusMenuTracking=NO;app->_sceneStopping=NO;[app updateStatus];check(app->_sceneMenu.menu.itemArray[2].enabled&&app->_sceneMenu.menu.delegate==app,@"closed scene menu refresh restores available actions");
    check(fabs(atomic_load(&audio.state->master)-.4)<.000001&&atomic_load(&audio.state->masterMuted),@"all failures preserve global controls");fprintf(stderr,"TX6Mac scene controller and guarded recall self-check: %s\n",ok?"PASS":"FAIL");return ok;
}
+ (BOOL)halSelfCheck {
    TXApp *menus=[TXHALCheckApp new];menus->_audio=[TXAudio new];menus->_assignments=[@[@"local.tx6mac.system-sounds",@"",@"",@"",@"",@""] mutableCopy];menus->_processes=@[];menus->_outputs=@[@{@"id":@101,@"uid":@"studioA",@"name":@"Studio Display",@"channels":@2},@{@"id":@102,@"uid":@"studioB",@"name":@"Studio Display",@"channels":@2}];menus->_outputMenu=[[TXPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];menus->_monitorMenu=[[TXPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
    BOOL duplicateMenusOK=YES;for(NSString *uid in @[@"studioA",@"studioB"]){menus->_outputUID=uid;menus->_monitorUID=uid;menus->_outputMenuSignature=nil;[menus refreshDeviceMenus];if(menus->_outputMenu.numberOfItems!=4||menus->_monitorMenu.numberOfItems!=3||![menus->_outputMenu.selectedItem.representedObject isEqual:uid]||![menus->_monitorMenu.selectedItem.representedObject isEqual:uid]||![menus->_outputUID isEqual:uid]||![menus->_monitorUID isEqual:uid])duplicateMenusOK=NO;}
    NSString *studioTitleA=menus->_monitorMenu.itemArray[1].title,*studioTitleB=menus->_monitorMenu.itemArray[2].title;
    if([studioTitleA isEqual:studioTitleB]){duplicateMenusOK=NO;fprintf(stderr,"Duplicate-name device visible title regression: FAIL\n");}
    for(NSString *uid in @[@"studioA",@"studioB"]){menus->_outputUID=uid;menus->_monitorUID=uid;menus->_outputs=[[menus->_outputs reverseObjectEnumerator] allObjects];menus->_outputMenuSignature=nil;[menus refreshDeviceMenus];NSString *expected=[uid isEqual:@"studioA"]?@"Studio Display · EC30F4":@"Studio Display · ACF72A";if(![menus->_monitorMenu.selectedItem.title isEqual:expected]||![menus->_outputMenu.selectedItem.title isEqual:[expected stringByAppendingString:@"  ·  2 ch"]]||![menus->_monitorMenu.selectedItem.representedObject isEqual:uid]||![menus->_outputMenu.selectedItem.representedObject isEqual:uid]||![menus->_monitorUID isEqual:uid]||![menus->_outputUID isEqual:uid])duplicateMenusOK=NO;}
    if(!duplicateMenusOK)fprintf(stderr,"Duplicate-name device UID menu regression: FAIL\n");
    NSDictionary *txA=@{@"id":@201,@"uid":@"studioA",@"name":@"TX-6",@"channels":@12},*txB=@{@"id":@202,@"uid":@"studioB",@"name":@"TX-6",@"channels":@12},*generic=@{@"id":@203,@"uid":@"headphones",@"name":@"USB Headphones",@"channels":@2};menus->_outputs=@[txA,txB,generic];menus->_halSnapshot=@{@"defaultUID":@"studioA"};BOOL scopeMenusOK=YES;
    NSString *scope=TXL(@"스테레오 출력입니다. 기기 페이더와 EQ도 적용됩니다. 앱의 6트랙 독립 출력 및 TX-6 AUX/CUE 라우팅은 지원하지 않습니다.");
    for(NSString *uid in @[@"studioA",@"studioB"]){menus->_outputUID=uid;menus->_monitorUID=uid;menus->_followDefaultOutput=NO;menus->_outputMenuSignature=nil;[menus refreshDeviceMenus];NSString *title=TXOutputDeviceTitle([menus selectedOutput],menus->_outputs);if(![menus->_outputMenu.selectedItem.title hasPrefix:title]||![menus->_monitorMenu.selectedItem.title isEqual:title]||![menus->_outputMenu.selectedItem.representedObject isEqual:uid]||![menus->_monitorMenu.selectedItem.representedObject isEqual:uid]||![menus->_outputMenu.toolTip containsString:scope]||![menus->_monitorMenu.toolTip containsString:scope]||![menus->_outputMenu.accessibilityHelp isEqual:menus->_outputMenu.toolTip]||![menus->_monitorMenu.accessibilityHelp isEqual:menus->_monitorMenu.toolTip])scopeMenusOK=NO;}
    menus->_followDefaultOutput=YES;menus->_outputUID=@"studioA";[menus refreshDeviceMenus];if(![menus->_outputMenu.selectedItem.representedObject isEqual:@""]||![menus->_outputMenu.selectedItem.title isEqual:[menus systemOutputTitle]]||![menus->_outputMenu.selectedItem.title containsString:TXL(@"스테레오 출력")]||![menus->_outputMenu.toolTip containsString:scope]||![menus->_outputMenu.accessibilityHelp containsString:scope])scopeMenusOK=NO;
    menus->_monitorError=@"offline";[menus updateStatus];if(![menus->_monitorMenu.toolTip containsString:scope]||![menus->_monitorMenu.toolTip hasSuffix:@" · offline"]||![menus->_monitorMenu.accessibilityHelp isEqual:menus->_monitorMenu.toolTip]||![menus->_outputMenu.accessibilityHelp containsString:scope])scopeMenusOK=NO;
    menus->_monitorError=@"";menus->_followDefaultOutput=NO;menus->_outputUID=@"headphones";menus->_monitorUID=@"headphones";[menus refreshDeviceMenus];[menus updateStatus];if(![menus->_outputMenu.selectedItem.title isEqual:@"USB Headphones  ·  2 ch"]||![menus->_outputMenu.toolTip isEqual:menus->_outputMenu.selectedItem.title]||![menus->_outputMenu.accessibilityHelp isEqual:menus->_outputMenu.selectedItem.title]||![menus->_monitorMenu.toolTip isEqual:@"USB Headphones"]||![menus->_monitorMenu.accessibilityHelp isEqual:@"USB Headphones"])scopeMenusOK=NO;
    menus->_followDefaultOutput=YES;menus->_halSnapshot=@{@"defaultUID":@"headphones"};[menus refreshDeviceMenus];if(![menus->_outputMenu.selectedItem.title isEqual:[TXL(@"시스템 기본 출력") stringByAppendingString:@" · USB Headphones"]]||![menus->_outputMenu.accessibilityHelp isEqual:menus->_outputMenu.selectedItem.title])scopeMenusOK=NO;
    fprintf(stderr,"TX-6 stereo output labels and popup help: %s\n",scopeMenusOK?"PASS":"FAIL");
    TXApp *app=[TXHALCheckApp new];TXHALCheckAudio *backend=[TXHALCheckAudio new];backend.firstStartGate=dispatch_semaphore_create(0);
    app->_audio=backend;app->_halQueue=dispatch_queue_create("local.tx6mac.hal-check",DISPATCH_QUEUE_SERIAL);app->_halSnapshotReady=YES;
    app->_assignments=[@[@"local.tx6mac.system-sounds",@"",@"",@"",@"",@""] mutableCopy];app->_processes=@[];app->_audioError=@"";
    app->_outputUID=@"fixtureA";app->_outputs=@[@{@"id":@1,@"uid":@"fixtureA",@"name":@"fixture",@"rate":@48000}];app->_desiredRunning=YES;
    BOOL (^until)(BOOL(^)(void))=^BOOL(BOOL(^condition)(void)){
        NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:2];
        while(!condition()&&limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        return condition();
    };
    [app rebuildAudio];
    if(!until(^BOOL{return backend.starts==1;})){dispatch_semaphore_signal(backend.firstStartGate);return NO;}
    // Two output changes must coalesce while the simulated HAL permission call is blocked.
    app->_outputUID=@"fixtureB";app->_outputs=@[@{@"id":@2,@"uid":@"fixtureB",@"name":@"fixture",@"rate":@48000}];[app rebuildAudio];
    app->_outputUID=@"fixtureC";app->_outputs=@[@{@"id":@3,@"uid":@"fixtureC",@"name":@"fixture",@"rate":@48000}];[app rebuildAudio];
    app->_desiredRunning=NO;[app stopAudio];
    __block BOOL mainProgress=NO;dispatch_async(dispatch_get_main_queue(),^{mainProgress=YES;});
    BOOL responsive=until(^BOOL{return mainProgress;})&&app->_halBusy&&!app->_audioReady&&backend.stops==0;
    dispatch_semaphore_signal(backend.firstStartGate);
    if(!responsive||!until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;}))return NO;
    if(backend.starts!=1||backend.stops!=1||backend.usedMain||app->_audioReady||app->_isBuilding)return NO;
    // The obsolete successful start cannot publish running; a fresh request can.
    app->_desiredRunning=YES;[app rebuildAudio];
    if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||backend.starts!=2)return NO;
    app->_desiredRunning=NO;[app stopAudio];
    if(!until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})||app->_audioReady||backend.stops!=2||backend.usedMain)return NO;
    // Async discovery must recover a reconnected output even after retry exhaustion.
    app->_outputs=@[];app->_desiredRunning=YES;app->_retryExhausted=YES;app->_retryAttempt=3;
    [app applyHALSnapshot:@{@"outputs":@[@{@"id":@3,@"uid":@"fixtureC",@"name":@"fixture",@"rate":@48000}],@"processes":@[],@"defaultUID":@"fixtureC"}];
    if(app->_retryExhausted||app->_retryAttempt||!until(^BOOL{return app->_audioReady&&!app->_halBusy;}))return NO;
    app->_desiredRunning=NO;[app stopAudio];
    if(!until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})||app->_audioReady||backend.stops!=3||backend.usedMain)return NO;
    TXApp *routing=[TXApp new];routing->_audio=[TXAudio new];routing->_assignments=[@[@"local.tx6mac.system-sounds",@"",@"",@"",@"",@""] mutableCopy];routing->_outputs=@[];routing->_processes=@[];routing->_outputUID=@"disconnected-output";
    [routing applyHALSnapshot:@{@"outputs":@[@{@"id":@1,@"uid":@"fixtureA",@"name":@"fixture",@"rate":@48000}],@"processes":@[],@"defaultUID":@"fixtureA"}];
    if(![routing->_outputUID isEqual:@"fixtureA"]){fprintf(stderr,"Disconnected output did not fall back to the system output\n");return NO;}
    NSArray *devices=@[@{@"id":@1,@"uid":@"fixtureA",@"name":@"A",@"rate":@48000},@{@"id":@2,@"uid":@"fixtureB",@"name":@"B",@"rate":@48000}];
    NSDictionary *defaultB=@{@"outputs":devices,@"processes":@[],@"defaultUID":@"fixtureB"};
    [routing applyHALSnapshot:defaultB];if(!routing->_followDefaultOutput||![routing->_outputUID isEqual:@"fixtureB"])return NO;
    routing->_followDefaultOutput=NO;routing->_outputUID=@"fixtureA";
    [routing applyHALSnapshot:defaultB];if(routing->_followDefaultOutput||![routing->_outputUID isEqual:@"fixtureA"])return NO;
    routing->_followDefaultOutput=YES;
    [routing applyHALSnapshot:@{@"outputs":devices,@"processes":@[],@"defaultUID":@"not-enumerated-yet"}];if(![routing->_outputUID isEqual:@"fixtureA"])return NO;
    routing->_outputUID=@"";[routing applyHALSnapshot:@{@"outputs":@[],@"processes":@[],@"defaultUID":@""}];if([routing selectedOutput])return NO;
    routing->_desiredRunning=YES;routing->_explicitStop=YES;[routing applyHALSnapshot:defaultB];if(![routing->_outputUID isEqual:@"fixtureB"]||routing->_isBuilding||routing->_pendingHALRequest)return NO;
    app->_followDefaultOutput=YES;app->_desiredRunning=YES;app->_retryExhausted=YES;app->_retryAttempt=3;
    [app applyHALSnapshot:defaultB];if(app->_retryExhausted||app->_retryAttempt||!until(^BOOL{return app->_audioReady&&!app->_halBusy;}))return NO;
    app->_desiredRunning=NO;[app stopAudio];if(!until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})||backend.stops!=4)return NO;
    app->_followDefaultOutput=NO;app->_desiredRunning=YES;app->_retryExhausted=YES;app->_retryAttempt=3;
    [app applyHALSnapshot:@{@"outputs":@[@{@"id":@22,@"uid":@"fixtureB",@"name":@"B",@"rate":@48000}],@"processes":@[],@"defaultUID":@"fixtureB"}];
    if(app->_retryExhausted||app->_retryAttempt||!until(^BOOL{return app->_audioReady&&!app->_halBusy;}))return NO;
    app->_desiredRunning=NO;[app stopAudio];if(!until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})||backend.stops!=5)return NO;
    // Optional USB metering must not prevent the main route from starting.
    NSDictionary *usb=@{@"id":@42,@"uid":@"TX-6-meter",@"name":@"TX-6",@"channels":@12,@"transport":@(kAudioDeviceTransportTypeUSB),@"rate":@48000};
    app->_outputs=[devices arrayByAddingObject:usb];app->_usbMeters=YES;app->_desiredRunning=YES;backend.failMeters=YES;
    if([[app usbMeterDevice][@"id"] unsignedIntValue]!=42)return NO;
    NSUInteger before=backend.starts;[app rebuildAudio];
    if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||backend.starts!=before+2||app->_usbMetering||!app->_usbMeterError.length||backend.meterOutputDevice)return NO;
    NSString *enabledSignature=[app currentSignature];app->_usbMeters=NO;if([enabledSignature isEqual:[app currentSignature]]||[app usbMeterDevice])return NO;
    app->_usbMeters=YES;app->_browserTabMode=YES;if([app usbMeterDevice])return NO;app->_browserTabMode=NO;
    app->_outputUID=usb[@"uid"];if([app usbMeterDevice])return NO;app->_outputUID=@"fixtureB";
    app->_outputs=[app->_outputs arrayByAddingObject:@{@"id":@43,@"uid":@"TX-6-other",@"name":@"TX-6",@"channels":@12,@"transport":@(kAudioDeviceTransportTypeUSB),@"rate":@48000}];if([app usbMeterDevice])return NO;
    app->_outputs=[devices arrayByAddingObject:usb];backend.failMeters=NO;[app rebuildAudio];
    if(!until(^BOOL{return app->_audioReady&&app->_usbMetering&&!app->_halBusy;})||app->_usbMeterError.length)return NO;
    app->_desiredRunning=NO;[app stopAudio];if(!until(^BOOL{return !app->_halBusy;})||app->_usbMetering||backend.usedMain)return NO;
    // Monitor identity never follows the default output, including after reconnect.
    routing->_monitorUID=@"fixtureA";routing->_monitorName=@"A";[routing applyHALSnapshot:@{@"outputs":@[devices[1]],@"processes":@[],@"defaultUID":@"fixtureB"}];if([routing selectedMonitor]||![routing->_monitorUID isEqual:@"fixtureA"]||![routing->_monitorName isEqual:@"A"])return NO;
    [routing applyHALSnapshot:defaultB];if([[routing selectedMonitor][@"id"] unsignedIntValue]!=1||![routing->_monitorUID isEqual:@"fixtureA"])return NO;
    NSDictionary *monitorC=@{@"id":@3,@"uid":@"monitorC",@"name":@"Monitor C",@"channels":@2,@"rate":@48000};NSDictionary *monitorD=@{@"id":@4,@"uid":@"monitorD",@"name":@"Monitor D",@"channels":@2,@"rate":@48000};
    app->_outputs=[devices arrayByAddingObjectsFromArray:@[usb,monitorC,monitorD]];app->_monitorUID=@"fixtureA";app->_desiredRunning=YES;backend.failMeters=YES;before=backend.starts;[app rebuildAudio];
    if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||backend.starts!=before+2||!app->_monitoring||app->_usbMetering||app->_monitorError.length||!app->_usbMeterError.length)return NO;
    backend.failMeters=NO;backend.failMonitor=YES;before=backend.starts;[app rebuildAudio];
    if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||backend.starts!=before+3||app->_monitoring||!app->_usbMetering||!app->_monitorError.length||app->_usbMeterError.length)return NO;
    backend.failMeters=YES;before=backend.starts;[app rebuildAudio];
    if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||backend.starts!=before+4||app->_monitoring||app->_usbMetering||!app->_monitorError.length||!app->_usbMeterError.length)return NO;
    backend.failMeters=NO;backend.failMonitor=NO;app->_monitorUID=app->_outputUID;before=backend.starts;[app rebuildAudio];
    if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||backend.starts!=before+1||app->_monitoring||backend.monitorOutputDevice||!app->_monitorError.length)return NO;
    app->_monitorUID=@"missing-monitor";before=backend.starts;[app rebuildAudio];if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||backend.starts!=before+1||app->_monitoring||!app->_monitorError.length||![app->_monitorUID isEqual:@"missing-monitor"])return NO;
    app->_monitorUID=@"fixtureA";backend.firstStartGate=dispatch_semaphore_create(0);backend.blockStart=backend.starts+1;[app rebuildAudio];if(!until(^BOOL{return backend.starts==backend.blockStart;})){dispatch_semaphore_signal(backend.firstStartGate);return NO;}
    app->_monitorUID=@"monitorC";[app rebuildAudio];app->_monitorUID=@"monitorD";[app rebuildAudio];NSString *latest=[app currentSignature];dispatch_semaphore_signal(backend.firstStartGate);
    if(!until(^BOOL{return app->_audioReady&&!app->_halBusy;})||!app->_monitoring||backend.monitorOutputDevice!=4||![app->_signature isEqual:latest]||![[app selectedMonitor][@"name"] isEqual:@"Monitor D"]||app->_monitorError.length)return NO;
    before=backend.starts;NSUInteger generation=app->_halGeneration;NSString *unchanged=[app currentSignature];[app setRoute:TXOutputMonitor slot:0];TXMonitorSlider *trim=[[TXMonitorSlider alloc] initWithFrame:NSMakeRect(865,620,167,22)];trim.doubleValue=.25;trim.target=app;trim.action=@selector(monitorGainChanged:);app->_monitorSlider=trim;app->_monitorLevelLabel=Label(@"",NSZeroRect,9,YES);[app monitorGainChanged:trim];
    if(backend.starts!=before||app->_halGeneration!=generation||![unchanged isEqual:[app currentSignature]]||atomic_load(&backend.state->route[0])!=TXOutputMonitor||atomic_load(&backend.state->monitorGain)!=.25)return NO;
    if(trim.minValue!=0||trim.maxValue!=1||![trim.cell isKindOfClass:TXMonitorSliderCell.class]||![trim.accessibilityValueDescription isEqual:@"25"]||![app->_monitorLevelLabel.stringValue isEqual:@"25"]||trim.target!=app||trim.action!=@selector(monitorGainChanged:))return NO;
    trim.doubleValue=1;if(![trim.accessibilityValueDescription isEqual:@"99"])return NO;trim.doubleValue=0;if(![trim.accessibilityValueDescription isEqual:@"0"])return NO;trim.doubleValue=.25;app->_monitorUID=@"";[app updateMonitorLevel];if(![trim.toolTip isEqual:[NSString stringWithFormat:TXL(@"미리 듣기 출력 꺼짐 · 저장된 음량 %@"),@"25"]]||backend.starts!=before||app->_halGeneration!=generation||atomic_load(&backend.state->route[0])!=TXOutputMonitor||atomic_load(&backend.state->monitorGain)!=.25)return NO;
    NSMenuItem *preset=[NSMenuItem new];for(NSNumber *level in @[@0,@25,@50,@75,@99]){preset.tag=level.integerValue;[app menuMonitorGain:preset];if(fabs(atomic_load(&backend.state->monitorGain)-level.doubleValue/99)>1e-7||![trim.accessibilityValueDescription isEqual:level.stringValue])return NO;}if(atomic_load(&backend.state->monitorGain)!=1)return NO;
    app->_calibrationInput=[NSTextField new];app->_calibrationInput.stringValue=@"99";[app calibrateMaster:nil];if(atomic_load(&backend.state->master)!=1)return NO;atomic_store(&backend.state->master,.37f);app->_calibrationInput.stringValue=@"100";[app calibrateMaster:nil];if(fabs(atomic_load(&backend.state->master)-.37)>1e-7)return NO;app->_calibrationInput.stringValue=@"50";[app calibrateMaster:nil];if(fabs(atomic_load(&backend.state->master)-50.0/99)>1e-7)return NO;
    atomic_store(&backend.state->master,0);[app handleMIDI:@"fixture" channel:0 cc:31 value:1];if(fabs(atomic_load(&backend.state->master)-TXVolumeStep)>1e-7)return NO;[app handleMIDI:@"fixture" channel:0 cc:31 value:127];if(fabs(atomic_load(&backend.state->master))>1e-7)return NO;[app handleMIDI:@"fixture" channel:0 cc:1 value:127];if(atomic_load(&backend.state->gain[0])!=1)return NO;
    NSView *masterMenu=[app sliderViewForSlot:6 band:-1];NSSlider *masterSlider=(NSSlider*)masterMenu.subviews.firstObject;atomic_store(&backend.state->master,1);masterSlider.doubleValue=1;[app menuSliderChanged:masterSlider];if(![masterSlider.accessibilityValueDescription isEqual:@"99"]||![[(NSTextField*)[masterMenu viewWithTag:999] stringValue] isEqual:@"99"]||atomic_load(&backend.state->master)!=1||backend.starts!=before||app->_halGeneration!=generation)return NO;
    printf("TX6Mac volume 0-99 scale, controls and unity mapping: PASS\n");
    app->_monitorUID=usb[@"uid"];if([app usbMeterDevice])return NO;
    app->_desiredRunning=NO;[app stopAudio];if(!until(^BOOL{return !app->_halBusy;})||app->_monitoring||backend.usedMain)return NO;
    app->_desiredRunning=YES;app->_usbMeters=NO;app->_monitorUID=@"fixtureA";backend.liveUIDs=@{@1:@"recycled-speaker"};before=backend.starts;[app rebuildAudio];
    BOOL monitorIdentityOK=until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})&&app->_audioReady&&!app->_monitoring&&backend.monitorOutputDevice==0&&app->_monitorError.length&&backend.starts==before+1&&atomic_load(&backend.state->route[0])==TXOutputMonitor;
    if(!monitorIdentityOK)fprintf(stderr,"Recycled monitor device ID regression: FAIL\n");
    backend.liveUIDs=@{@42:@"recycled-meter"};app->_usbMeters=YES;app->_monitorUID=@"";before=backend.starts;[app rebuildAudio];BOOL meterIdentityOK=until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})&&app->_audioReady&&!app->_usbMetering&&backend.meterOutputDevice==0&&app->_usbMeterError.length&&backend.starts==before+1;
    if(!meterIdentityOK)fprintf(stderr,"Recycled meter device ID regression: FAIL\n");
    backend.liveUIDs=nil;backend.UIDsAfterFailedStart=@{@1:@"recycled-monitor-during-fallback"};backend.failMeters=YES;app->_monitorUID=@"fixtureA";before=backend.starts;[app rebuildAudio];BOOL retryIdentityOK=until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})&&app->_audioReady&&!app->_monitoring&&!app->_usbMetering&&backend.monitorOutputDevice==0&&app->_monitorError.length&&backend.starts==before+2;
    if(!retryIdentityOK)fprintf(stderr,"Fallback monitor identity recheck regression: FAIL\n");backend.UIDsAfterFailedStart=nil;backend.failMeters=NO;app->_usbMeters=NO;app->_monitorUID=@"";
    backend.liveUIDs=nil;backend.UIDsAfterFailedStart=@{@2:@"recycled-main-during-fallback"};backend.failMeters=YES;app->_usbMeters=YES;before=backend.starts;NSUInteger retryStopped=backend.stops;[app rebuildAudio];BOOL mainRetryIdentityOK=until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})&&!app->_audioReady&&backend.starts==before+1&&backend.stops==retryStopped+1&&app->_audioError.length;
    if(!mainRetryIdentityOK)fprintf(stderr,"Fallback main identity recheck regression: FAIL\n");backend.UIDsAfterFailedStart=nil;backend.failMeters=NO;app->_usbMeters=NO;
    backend.liveUIDs=@{@2:@"recycled-main"};app->_retryExhausted=NO;before=backend.starts;NSUInteger stopped=backend.stops;[app rebuildAudio];BOOL mainIdentityOK=until(^BOOL{return !app->_halBusy&&!app->_pendingHALRequest;})&&!app->_audioReady&&backend.starts==before&&backend.stops==stopped+1&&app->_audioError.length;
    if(!mainIdentityOK)fprintf(stderr,"Recycled main device ID regression: FAIL\n");
    app->_desiredRunning=NO;[app stopAudio];if(!until(^BOOL{return !app->_halBusy;}))return NO;
    return duplicateMenusOK&&scopeMenusOK&&monitorIdentityOK&&meterIdentityOK&&retryIdentityOK&&mainRetryIdentityOK&&mainIdentityOK;
}
- (void)stopAudio {
    if(_halStopping)return;
    NSDictionary *restore=_sceneApplying&&!_sceneModelCommitted?_sceneBaseline:nil;_sceneStopping=YES;_sceneMIDIOverflow=NO;
    atomic_fetch_add(&_sceneGeneration,1);_sceneApplying=NO;_sceneBaseline=nil;_sceneRollbackRequest=nil;[_sceneMIDI removeAllObjects];
    _audioReady=NO;_usbMetering=NO;_monitoring=NO;_isBuilding=NO;_halStopping=YES;_pendingAudioSignature=nil;_halGeneration++;
    _pendingHALRequest=@{@"kind":@"stop",@"generation":@(_halGeneration),@"restore":restore?:@{}};[self processHALWork];
}
- (void)rebuildAudio {
    if(_sceneApplying||_sceneStopping||_sceneMIDIOverflow)return;
    if(_sceneProtected&&_desiredRunning&&!_sleeping&&!_explicitStop&&!_retryAt){[self recallSnapshot:[self runtimeSceneSnapshot] sceneID:_selectedSceneID recordUndo:NO runtime:YES];return;}
    if(!_desiredRunning||_sleeping||_explicitStop||_retryAt||(!_audioReady&&_retryExhausted))return;
    if(!_halSnapshotReady){[self requestHALSnapshot];return;}
    NSDictionary *device=[self selectedOutput];
    if(!device){[self stopAudio];_audioError=TXL(@"출력 장치 연결이 해제되어 믹서를 중지하고 원음을 복구했습니다.");_canvas.message=_audioError;[self scheduleRecovery];[self updateStatus];[self writeStatusNow];return;}
    NSString *signature=[self currentSignature];if(_isBuilding&&[_pendingAudioSignature isEqual:signature])return;
    _audioReady=NO;_usbMetering=NO;_monitoring=NO;_usbMeterError=@"";_monitorError=@"";_isBuilding=YES;_halStopping=NO;_pendingAudioSignature=signature;_halGeneration++;
    NSMutableArray *groups=[NSMutableArray array];for(NSArray *group in [self currentGroups])[groups addObject:[group copy]];
    NSDictionary *monitor=[self selectedMonitor];NSString *monitorError=@"";if(_monitorUID.length&&!monitor)monitorError=TXL(@"선택한 미리 듣기 장치가 연결되지 않음");if(monitor&&[monitor[@"uid"] isEqual:device[@"uid"]]){monitor=nil;monitorError=TXL(@"서로 다른 스테레오 모니터 장치가 필요합니다");}
    _pendingHALRequest=@{@"mainUID":device[@"uid"]?:@"",@"monitorUID":monitor[@"uid"]?:@"",@"meterUID":[self usbMeterDevice][@"uid"]?:@"",@"monitorDevice":monitor[@"id"]?:@0,@"monitorError":monitorError,@"kind":@"start",@"generation":@(_halGeneration),@"device":device[@"id"],@"meterDevice":[self usbMeterDevice][@"id"]?:@0,@"groups":[groups copy],@"signature":signature};
    _canvas.message=TXL(@"오디오 연결 중 · macOS 응답을 기다립니다.");
    [self sendBrowserControls];[self updateStatus];[self writeStatusNow];[self processHALWork];
}
- (void)toggleMixer:(id)sender {
    if(_desiredRunning){_explicitStop=YES;_desiredRunning=NO;_retryAt=nil;[self stopAudio];_audioError=@"";_canvas.message=TXL(@"오디오 연결 해제 중 · 원래 재생을 복구하고 있습니다.");}
    else{_explicitStop=NO;_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;_desiredRunning=YES;_audioStartConsent=YES;[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"TX6Mac.audioStartConsent"];[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"TX6Mac.setupSeen"];[self refreshDevices];[self saveSettings];[self rebuildAudio];}[self sendBrowserControls];[self updateStatus];[self writeStatusNow];
}
- (void)poll:(id)sender {
    BOOL hadOutput=[self selectedOutput]!=nil;[self requestHALSnapshot];[self refreshDevices];[_midi refresh];
    if(!hadOutput&&[self selectedOutput]&&_desiredRunning&&!_explicitStop){_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;}
    if(_desiredRunning&&(!_audioReady||![_signature isEqual:[self currentSignature]])&&!_retryAt&&(_audioReady||(_retryAttempt==0&&!_retryExhausted)))[self rebuildAudio];[self updateStatus];[self writeStatus];
}
- (void)tick:(id)sender {
    if(_halBusy&&!_audioReady&&_halStartedAt&&!_halWaitReported&&[NSDate.date timeIntervalSinceDate:_halStartedAt]>10){_halWaitReported=YES;_canvas.message=TXL(@"macOS 오디오 연결 응답을 기다립니다. 권한 요청을 확인하거나 믹서를 중지·종료할 수 있습니다.");_canvas.needsDisplay=YES;[self writeStatusNow];}
    if(_retryAt&&[_retryAt timeIntervalSinceNow]<=0){_retryAt=nil;[self rebuildAudio];}
    [self updateSetupStatus];TXRenderState *s=_audio.state;if(!_lastBrowserSend||[NSDate.date timeIntervalSinceDate:_lastBrowserSend]>=1)[self sendBrowserControls];
    if(_audioReady&&!_sceneApplying&&!_sceneStopping){uint64_t frames=atomic_load(&s->frames);if(frames!=_progressFrames){_progressFrames=frames;_progressAt=NSDate.date;_retryAttempt=0;_retryExhausted=NO;}BOOL active=NO;for(NSDictionary *p in _processes)if([p[@"active"] boolValue])active=YES;NSTimeInterval timeout=frames?6:10;if(active&&_progressAt&&[NSDate.date timeIntervalSinceDate:_progressAt]>timeout){if(_sceneProtected){_audioReady=NO;[self rebuildAudio];}else{[self stopAudio];[self scheduleRecovery];}_audioError=_sceneProtected?TXL(@"씬 전환 실패 · 중지 후 다시 시도하세요."):TXL(@"오디오 처리 응답이 없어 원음을 복구했습니다. 시스템 오디오 권한과 출력 장치를 확인해 주세요.");_canvas.message=_audioError;[self updateStatus];}}
    int fault=atomic_load(&s->layoutFault);if(_audioReady&&!_sceneApplying&&!_sceneStopping&&fault){if(_sceneProtected){_audioReady=NO;[self rebuildAudio];}else{[self stopAudio];[self scheduleRecovery];}_audioError=_sceneProtected?TXL(@"씬 전환 실패 · 중지 후 다시 시도하세요."):[NSString stringWithFormat:TXL(@"오디오 채널 구조가 변경되어 원음을 복구했습니다. 다시 시작해 주세요. (%d)"),fault];_canvas.message=_audioError;[self updateStatus];}
    [self updateLevels];
    for(int i=0;i<6;i++){TXChannel *c=_channels[i];float peak=_audioReady?atomic_load(&s->peak[i]):0;for(NSDictionary *tab in _browser.tabs)if([[self keyForTab:tab] isEqual:_assignments[i]])peak=_audioReady&&!atomic_load(&s->muted[i])?[tab[@"peak"] floatValue]*atomic_load(&s->gain[i]):0;c.fader.peakHold=_levelSnapshot.available[i]&&_levelSnapshot.resetApplied==_levelSnapshot.resetRequested?_levelSnapshot.hold[i]:0;c.fader.muted=atomic_load(&s->muted[i]);c.fader.peak=MAX(peak,c.fader.peak*0.82);c.fader.needsDisplay=YES;BOOL active=NO;for(NSDictionary *p in _processes)if([p[@"key"] isEqual:_assignments[i]])active=[p[@"active"] boolValue];c.activity.stringValue=[_pendingSources[i] length]?TXL(@"다시 지정 필요"):![self canAdjustVolumeForSlot:i]?TXL(@"음소거 가능 · 연결 필요"):(i==0?TXL(@"시스템 효과음 · 고정"):(_assignments[i].length?(active?TXL(@"오디오 활성"):TXL(@"소리 재생 대기")):(_autoAssign?TXL(@"재생 앱 대기"):TXL(@"미지정"))));}
    uint64_t limited=atomic_load(&s->limitedFrames);if(limited>_lastLimitedFrames)_lastLimitDate=NSDate.date;_lastLimitedFrames=limited;_canvas.limited=_lastLimitDate&&[NSDate.date timeIntervalSinceDate:_lastLimitDate]<1;_canvas.needsDisplay=YES;
    _masterFader.peak=MAX(_audioReady?atomic_load(&s->outputPeak):0,_masterFader.peak*0.82);_masterFader.needsDisplay=YES;
}
- (void)updateStatus {
    [self refreshSceneMenu];[self refreshChannelControls];
    [self updateMonitorLevel];_usbMetersStatus.stringValue=[self usbMeterStatus];_usbMetersStatus.toolTip=_usbMeterError.length?_usbMeterError:_usbMetersStatus.stringValue;
    if(_halStopping)_canvas.message=TXL(@"오디오 연결 해제 중 · 원래 재생을 복구하고 있습니다.");
    _browserTabsButton.enabled=!_sceneApplying&&(_browser.connected||_browserTabMode);
    TXRenderState *s=_audio.state;_canvas.running=_audioReady&&atomic_load(&s->callbacks)>0;_canvas.audioWaiting=_isBuilding||_halStopping||(_audioReady&&atomic_load(&s->callbacks)==0);_canvas.master=atomic_load(&s->master);_canvas.muted=atomic_load(&s->masterMuted);
    _canvas.connection=_midi.sources.count?[_midi.sources componentsJoinedByString:@" / "]:TXL(@"MIDI 연결 대기");_canvas.output=[@"MAIN · " stringByAppendingString:[self selectedOutput][@"name"]?:TXL(@"출력 장치 연결 대기")];
    NSString *monitorStatus=!_monitorUID.length?TXL(@"끔"):(_monitoring&&_audioReady?([self selectedMonitor][@"name"]?:_monitorName):[NSString stringWithFormat:TXL(@"%@ · 대기"),_monitorName.length?_monitorName:_monitorUID]);_canvas.monitor=[@"MON · " stringByAppendingString:monitorStatus];_canvas.toolTip=[NSString stringWithFormat:@"MAIN · %@\nMONITOR · %@%@",[self selectedOutput][@"name"]?:TXL(@"연결 대기"),monitorStatus,_monitorError.length?[@" · " stringByAppendingString:_monitorError]:@""];[self updateOutputDeviceHelp];_canvas.needsDisplay=YES;
    _browserLabel.stringValue=_browser.connected?TXL(@"Chrome 오디오 탭 자동 감지 · 음소거 바로 가능\n개별 음량·EQ는 해당 탭에서 ⌘⇧6으로 연결"):TXL(@"Chrome 확장을 연결하면 재생 탭 자동 감지\n개별 음량·EQ 연결 단축키: ⌘⇧6");_remainderLabel.stringValue=_overflowCount>0?[NSString stringWithFormat:TXL(@"추가 %ld개 앱은 MASTER 적용"),(long)_overflowCount]:TXL(@"미지정 앱도 MASTER 적용");_masterFader.value=atomic_load(&s->master);_masterMute.state=atomic_load(&s->masterMuted)?NSControlStateValueOn:NSControlStateValueOff;_startButton.title=_desiredRunning?TXL(@"믹서 중지"):TXL(@"믹서 시작");
    _resumeDeviceButton.enabled=_midi.sources.count&&(_deviceContext.suspended||_deviceContext.shiftDown);_deviceContextLabel.stringValue=!_midi.sources.count?TXL(@"MIDI 연결 대기"):(_deviceContext.suspended||_deviceContext.shiftDown)?(_deviceContext.reason?TXL(@"기기 메뉴 조작 중 · 맥 제어 일시정지\nSHIFT를 단독으로 눌렀다 떼면 홈 제어 재개"):TXL(@"기기 홈 화면 확인 필요 · 맥 제어 일시정지\nSHIFT를 단독으로 눌렀다 떼면 홈 제어 재개")):TXL(@"TX-6 홈 화면 제어 중\n메뉴 진입 신호가 오면 맥 조절을 보호합니다.");
    _statusItem.button.toolTip=[NSString stringWithFormat:@"TX · MAC · %@ · %@",_audioReady?TXL(@"실행"):TXL(@"대기"),TXVolumeText(atomic_load(&s->master))];
}
- (void)writeStatusNow {_lastStatusWrite=nil;[self writeStatus];}
- (void)writeStatus {
    if(!_statusFile.length)return;if(_lastStatusWrite&&[NSDate.date timeIntervalSinceDate:_lastStatusWrite]<0.1){[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(writeStatus) object:nil];[self performSelector:@selector(writeStatus) withObject:nil afterDelay:0.1 inModes:@[NSRunLoopCommonModes]];return;}_lastStatusWrite=NSDate.date;NSDictionary *d=[self statusSnapshot];
    NSData *json=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:_statusFile options:NSDataWritingAtomic error:nil];
}
- (NSDictionary*)statusSnapshot {
    NSAssert(NSThread.isMainThread,@"Status snapshot belongs to the main thread");
    NSMutableArray *channels=[NSMutableArray array];TXRenderState *s=_audio.state;for(int i=0;i<6;i++)[channels addObject:@{@"slot":@(i+1),@"application":_assignments[i],@"gain":@(atomic_load(&s->gain[i])),@"muted":@(atomic_load(&s->muted[i])),@"eqLowMidHigh":@[@(atomic_load(&s->eq[i][0])),@(atomic_load(&s->eq[i][1])),@(atomic_load(&s->eq[i][2]))],@"peak":@(atomic_load(&s->peak[i])),@"usbPeak":@(atomic_load(&s->usbPeak[i])),@"usbRMS":@(atomic_load(&s->usbRMS[i])),@"route":@(atomic_load(&s->route[i]))}];
    NSDictionary *d=@{@"selectedSceneID":_selectedSceneID?:@"",@"selectedSceneName":[_sceneStore sceneWithID:_selectedSceneID][@"name"]?:@"",@"sceneTransitioning":@(_sceneApplying),@"sceneStopping":@(_sceneStopping),@"transitionMuted":@(atomic_load(&s->transitionMuted)),@"monitorUID":_monitorUID?:@"",@"monitorName":[self selectedMonitor][@"name"]?:_monitorName?:@"",@"monitoring":@(_monitoring&&_audioReady),@"monitorError":_monitorError?:@"",@"monitorGain":@(atomic_load(&s->monitorGain)),@"monitorPeak":@(atomic_load(&s->monitorPeak)),@"language":TXLanguageCode(),@"setupVisible":@(_setupWindow.visible),@"autoStart":@(_autoStart),@"audioStartConsent":@(_audioStartConsent),@"desiredRunning":@(_desiredRunning),@"explicitlyStopped":@(_explicitStop),@"retryAttempt":@(_retryAttempt),@"retryExhausted":@(_retryExhausted),@"retryPending":@(_retryAt!=nil),@"pickup":@(_pickup),@"running":@(_audioReady),@"audioBusy":@(_halBusy),@"usbMeters":@(_usbMeters),@"usbMetering":@(_usbMetering&&_audioReady),@"usbMeterDevice":[self usbMeterDevice][@"id"]?:@0,@"usbMeterError":_usbMeterError?:@"",@"audioStarting":@(_isBuilding),@"audioRequestGeneration":@(_halGeneration),@"autoAssign":@(_autoAssign),@"controllerSuspended":@(_deviceContext.suspended||_deviceContext.shiftDown),@"controllerShiftHeld":@(_deviceContext.shiftDown),@"controllerContextReasonCC":@(_deviceContext.reason),@"hudEnabled":@(_hudEnabled),@"hudVisible":@(_hud.isVisible),@"hudTitle":_hudView.application?:@"",@"hudMessage":_hudView.message?:@"",@"overflowApps":@(_overflowCount),@"browserConnected":@(_browser.connected),@"browserTabs":_browser.tabs?:@[],@"outputUID":_outputUID?:@"",@"outputName":[self selectedOutput][@"name"]?:@"",@"midiSources":_midi.sources?:@[],@"midiConnection":_midi.diagnostics?:@{},@"lastMIDI":_lastMIDI?:@"",@"master":@(atomic_load(&s->master)),@"masterMuted":@(atomic_load(&s->masterMuted)),@"callbacks":@(atomic_load(&s->callbacks)),@"frames":@(atomic_load(&s->frames)),@"limitedFrames":@(atomic_load(&s->limitedFrames)),@"remainderPeak":@(atomic_load(&s->peak[6])),@"outputPeak":@(atomic_load(&s->outputPeak)),@"sampleRate":@(s->sampleRate),@"physicalInputChannels":@(s->physicalInputChannels),@"tapCount":@(s->tapCount),@"layoutFault":@(atomic_load(&s->layoutFault)),@"error":_audioError?:@"",@"channels":channels};
    return d;
}
- (void)assignmentChanged:(NSPopUpButton*)sender {if(sender.tag==0||_sceneApplying||_sceneStopping)return;[_sceneReservations removeIndex:sender.tag];if(_pendingSources)_pendingSources[sender.tag]=@"";_autoAssign=NO;_autoButton.state=NSControlStateValueOff;_assignments[sender.tag]=sender.selectedItem.representedObject?:@"";memset(_latched[sender.tag],0,sizeof(_latched[sender.tag]));memset(_havePrevious[sender.tag],0,sizeof(_havePrevious[sender.tag]));[self saveSettings];[self refreshDevices];if(_desiredRunning)[self rebuildAudio];}
- (void)selectOutputPreference:(NSString*)uid {if(_sceneApplying||_sceneStopping)return;_sceneOutputPinned=NO;if(_desiredRunning){_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;}_followDefaultOutput=!uid.length;if(uid.length)_outputUID=uid;[self applyHALSnapshot:_halSnapshot];[self saveSettings];[self updateStatus];}
- (void)selectMonitorPreference:(NSString*)uid {if(_sceneApplying||_sceneStopping)return;_monitorUID=uid?:@"";_monitorName=[self selectedMonitor][@"name"]?:_monitorUID;_monitorError=@"";_outputMenuSignature=nil;[self refreshDeviceMenus];[self saveSettings];if(_desiredRunning){_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;[self rebuildAudio];}[self updateStatus];[self writeStatusNow];}
- (void)monitorChanged:(NSPopUpButton*)sender {[self selectMonitorPreference:sender.selectedItem.representedObject];}
- (void)updateMonitorLevel {
    NSString *value=TXVolumeText(atomic_load(&_audio.state->monitorGain));_monitorLevelLabel.stringValue=value;_monitorSlider.toolTip=[NSString stringWithFormat:_monitorUID.length?TXL(@"미리 듣기 음량 %@"):TXL(@"미리 듣기 출력 꺼짐 · 저장된 음량 %@"),value];_monitorLevelLabel.toolTip=_monitorSlider.toolTip;
}
- (void)monitorGainChanged:(NSSlider*)sender {if(_sceneApplying||_sceneStopping)return;atomic_store(&_audio.state->monitorGain,fmax(0,fmin(1,sender.doubleValue)));_monitorSlider.doubleValue=atomic_load(&_audio.state->monitorGain);[self updateMonitorLevel];[self saveSettings];[self writeStatusNow];}
- (void)setRoute:(UInt32)route slot:(NSInteger)slot {if(_sceneApplying||_sceneStopping)return;if(slot<0||slot>=6||route>TXOutputOff||[_assignments[slot] hasPrefix:@"chrome-tab:"]||[_pendingSources[slot] isEqual:@"tab"])return;atomic_store(&_audio.state->route[slot],route);[_channels[slot].route selectItemAtIndex:route];_channels[slot].route.accessibilityValue=TXRouteTitles()[route];[self showHUDForSlot:slot message:TXRouteTitles()[route]];[self saveSettings];[self writeStatusNow];}
- (void)routeChanged:(NSPopUpButton*)sender {[self setRoute:(UInt32)sender.indexOfSelectedItem slot:sender.tag];}
- (void)outputChanged:(NSPopUpButton*)sender {[self selectOutputPreference:sender.selectedItem.representedObject];}
- (void)transportChanged:(NSPopUpButton*)sender {_midi.transport=sender.selectedItem.representedObject;[_midi refresh];[self saveSettings];[self updateStatus];}
- (void)settingsChanged:(id)sender {BOOL pickup=_pickupButton.state==NSControlStateValueOn,invert=_invertButton.state==NSControlStateValueOn;if(_pickup!=pickup||_invert!=invert){_pickup=pickup;_invert=invert;for(int i=0;i<6;i++)[self clearPickupForSlot:i];}_hudEnabled=_hudButton.state==NSControlStateValueOn;if(!_hudEnabled){_pendingHUD=nil;[self hideHUD:nil];}[self saveSettings];}
- (void)gainChanged:(TXFader*)sender {if(_sceneApplying||_sceneStopping)return;int i=(int)sender.tag;if(![self canAdjustVolumeForSlot:i]){sender.value=atomic_load(&_audio.state->gain[i]);[self showBrowserCaptureHint:i];return;}atomic_store(&_audio.state->gain[i],sender.value);_latched[i][0]=NO;sender.awaitingPickup=_pickup;[self showHUDForSlot:i message:TXVolumeHUD(sender.value)];[self saveSettings];}
- (void)eqChanged:(TXKnob*)sender {if(_sceneApplying||_sceneStopping)return;int i=(int)sender.tag/3,b=(int)sender.tag%3;if(![self canAdjustVolumeForSlot:i]){sender.value=atomic_load(&_audio.state->eq[i][b]);[self showBrowserCaptureHint:i];return;}atomic_store(&_audio.state->eq[i][b],sender.value);_latched[i][b+1]=NO;sender.awaitingPickup=_pickup;[self showHUDForSlot:i message:[NSString stringWithFormat:@"%@ %+.1f dB",@[@"LOW",@"MID",@"HIGH"][b],sender.value]];[self saveSettings];}
- (void)masterChanged:(TXFader*)sender {atomic_store(&_audio.state->master,sender.value);[self showHUDForSlot:-1 message:TXVolumeHUD(sender.value)];[self saveSettings];[self updateStatus];}
- (void)muteChanged:(NSButton*)sender {if(_sceneApplying||_sceneStopping)return;atomic_store(&_audio.state->muted[sender.tag],sender.state==NSControlStateValueOn);[self showHUDForSlot:sender.tag message:sender.state==NSControlStateValueOn?TXL(@"음소거"):TXL(@"음소거 해제")];[self saveSettings];}
- (void)masterMuteChanged:(NSButton*)sender {atomic_store(&_audio.state->masterMuted,sender.state==NSControlStateValueOn);[self showHUDForSlot:-1 message:sender.state==NSControlStateValueOn?TXL(@"전체 음소거"):TXL(@"전체 음소거 해제")];[self updateStatus];}
- (void)resetEQ:(id)sender {if(_sceneApplying||_sceneStopping)return;for(int i=0;i<6;i++)for(int b=0;b<3;b++){atomic_store(&_audio.state->eq[i][b],0);_latched[i][b+1]=NO;_channels[i].knobs[2-b].value=0;_channels[i].knobs[2-b].awaitingPickup=_pickup;}[self showHUDForSlot:-1 message:@"EQ ALL · 0 dB"];[self saveSettings];}
- (void)menuSliderChanged:(NSSlider*)sender {
    if((_sceneApplying||_sceneStopping)&&sender.tag/10<6)return;
    int slot=(int)sender.tag/10,b=(int)sender.tag%10-1;if(slot<6&&![self canAdjustVolumeForSlot:slot]){[self showBrowserCaptureHint:slot];return;}
    if(slot==6){atomic_store(&_audio.state->master,sender.doubleValue);[self updateStatus];}
    else if(b<0){atomic_store(&_audio.state->gain[slot],sender.doubleValue);_channels[slot].fader.value=sender.doubleValue;_latched[slot][0]=NO;_channels[slot].fader.awaitingPickup=_pickup;}
    else {atomic_store(&_audio.state->eq[slot][b],sender.doubleValue);_channels[slot].knobs[2-b].value=sender.doubleValue;_latched[slot][b+1]=NO;_channels[slot].knobs[2-b].awaitingPickup=_pickup;}
    NSTextField *label=[sender.superview viewWithTag:999];label.stringValue=b<0?TXVolumeText(sender.doubleValue):[NSString stringWithFormat:@"%+.0f",sender.doubleValue];[self showHUDForSlot:slot==6?-1:slot message:b<0?TXVolumeHUD(sender.doubleValue):[NSString stringWithFormat:@"%@ %+.1f dB",@[@"LOW",@"MID",@"HIGH"][b],sender.doubleValue]];[self saveSettings];
}
- (void)menuMute:(NSMenuItem*)sender {if(_sceneApplying||_sceneStopping)return;int slot=(int)sender.tag;BOOL mute=!atomic_load(&_audio.state->muted[slot]);atomic_store(&_audio.state->muted[slot],mute);_channels[slot].mute.state=mute?NSControlStateValueOn:NSControlStateValueOff;sender.state=_channels[slot].mute.state;[self showHUDForSlot:slot message:mute?TXL(@"음소거"):TXL(@"음소거 해제")];[self saveSettings];}
- (void)masterMenuMute:(NSMenuItem*)sender {atomic_store(&_audio.state->masterMuted,!atomic_load(&_audio.state->masterMuted));sender.state=atomic_load(&_audio.state->masterMuted)?NSControlStateValueOn:NSControlStateValueOff;[self showHUDForSlot:-1 message:atomic_load(&_audio.state->masterMuted)?TXL(@"전체 음소거"):TXL(@"전체 음소거 해제")];[self updateStatus];}
- (void)menuRoute:(NSMenuItem*)sender {[self setRoute:(UInt32)(sender.tag%4) slot:sender.tag/4];}
- (void)menuMonitor:(NSMenuItem*)sender {[self selectMonitorPreference:sender.representedObject];}
- (void)menuMonitorGain:(NSMenuItem*)sender {if(_sceneApplying||_sceneStopping)return;atomic_store(&_audio.state->monitorGain,TXVolumeGain(sender.tag));_monitorSlider.doubleValue=TXVolumeGain(sender.tag);[self updateMonitorLevel];[self saveSettings];[self writeStatusNow];}
- (void)menuOutput:(NSMenuItem*)sender {[self selectOutputPreference:sender.representedObject];}
- (void)deviceConnectionChanged {
    if(_midi.sources.count&&TXMayAutoStart(_autoStart,_audioStartConsent,_explicitStop,_sleeping)&&!_audioReady){_desiredRunning=YES;_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;[self rebuildAudio];}
    BOOL connected=_midi.sources.count>0;
    if(!connected||!_controllerConnected){_deviceContext=(TXDeviceContext){.suspended=YES};_canvas.message=connected?TXL(@"TX-6 화면을 확인해 주세요. SHIFT를 단독으로 누르고 떼면 홈 제어를 재개합니다."):TXL(@"MIDI 연결 대기");}
    _controllerConnected=connected;[self updateStatus];[self writeStatus];
}
- (void)primaryControl:(id)sender {[self toggleMixer:sender];}
- (void)resumeDeviceControls:(id)sender {
    _deviceContext=(TXDeviceContext){0};for(int i=0;i<6;i++)[self clearPickupForSlot:i];_canvas.message=TXL(@"TX-6 홈 화면 제어를 재개했습니다. 페이더와 노브는 현재 맥 값에서 픽업합니다.");[self showHUDForSlot:-1 message:TXL(@"TX-6 제어 재개")];[self updateStatus];[self writeStatus];
}
- (void)calibrateMaster:(id)sender {
    NSString *text=[[_calibrationInput.stringValue stringByApplyingTransform:NSStringTransformFullwidthToHalfwidth reverse:NO] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSScanner *scanner=[NSScanner scannerWithString:text];double number=0;
    if(![scanner scanDouble:&number]||!scanner.isAtEnd||!isfinite(number)||number<0||number>99||floor(number)!=number){_canvas.message=TXL(@"TX-6에 표시된 현재 메인 숫자 0~99를 입력해 주세요.");[self showHUDForSlot:-1 message:TXL(@"0~99 숫자 입력")];_canvas.needsDisplay=YES;return;}
    atomic_store(&_audio.state->master,number/99);_canvas.message=TXL(@"입력한 기기 숫자에 맥 전체 음량을 맞췄습니다. 자동 조회나 상시 동기화는 아닙니다.");[self showHUDForSlot:-1 message:TXVolumeHUD(number/99)];[self saveSettings];[self updateStatus];[self writeStatus];
}
- (BOOL)consumeDeviceContextCC:(UInt8)cc value:(UInt8)value {
    BOOL wasBlocked=_deviceContext.suspended||_deviceContext.shiftDown;BOOL suppress=TXConsumeDeviceContext(&_deviceContext,cc,value);BOOL blocked=_deviceContext.suspended||_deviceContext.shiftDown;
    if(!suppress)return NO;
    if(wasBlocked&&!blocked){for(int i=0;i<6;i++)[self clearPickupForSlot:i];_canvas.message=TXL(@"SHIFT 단독 홈 복귀를 확인해 TX-6의 맥 제어를 재개했습니다.");[self showHUDForSlot:-1 message:TXL(@"TX-6 제어 재개")];}
    else if(blocked){_canvas.message=_deviceContext.reason?TXL(@"기기 메뉴 조작 중 · 맥 제어 일시정지. SHIFT를 단독으로 누르고 떼면 홈 제어를 재개합니다."):TXL(@"기기 홈 화면 확인 필요 · 맥 제어 일시정지. SHIFT를 단독으로 누르고 떼면 홈 제어를 재개합니다.");[self showHUDForSlot:-1 message:_deviceContext.reason?TXL(@"기기 메뉴 · 제어 정지"):TXL(@"홈 확인 · 제어 정지")];}
    [self updateStatus];[self writeStatus];return YES;
}
- (BOOL)pickupValue:(double)value slot:(int)slot parameter:(int)parameter current:(double)current {
    if(!_pickup||_latched[slot][parameter])return YES;double tolerance=parameter?0.7:0.035;
    BOOL hit=fabs(value-current)<=tolerance||(_havePrevious[slot][parameter]&&(_previous[slot][parameter]-current)*(value-current)<=0);
    _previous[slot][parameter]=value;_havePrevious[slot][parameter]=YES;if(hit)_latched[slot][parameter]=YES;return hit;
}
- (void)drainSceneMIDI {
    if(_sceneMIDIOverflow)return;NSArray *queued=[_sceneMIDI copy];[_sceneMIDI removeAllObjects];_sceneReplayingMIDI=YES;
    for(NSDictionary *event in queued)[self handleMIDI:event[@"source"] channel:0 cc:[event[@"cc"] unsignedCharValue] value:[event[@"value"] unsignedCharValue]];
    _sceneReplayingMIDI=NO;
}
- (void)handleMIDI:(NSString*)source channel:(UInt8)channel cc:(UInt8)cc value:(UInt8)value {
    _lastMIDI=[NSString stringWithFormat:@"%@ · CH %d / CC %d / %d",source,channel+1,cc,value];if(_audioError.length)_canvas.message=_audioError;
    if(channel!=0){[self updateStatus];return;}if(!_sceneReplayingMIDI&&[self consumeDeviceContextCC:cc value:value])return;if(_sceneApplying&&!_sceneReplayingMIDI&&cc>=1&&cc<=30){if(!_sceneMIDI)_sceneMIDI=[NSMutableArray array];if(_sceneMIDI.count==TXSceneMIDILimit&&_sceneModelCommitted&&!_sceneMIDIOverflow)[self drainSceneMIDI];if(_sceneMIDI.count<TXSceneMIDILimit&&!_sceneMIDIOverflow)[_sceneMIDI addObject:@{@"source":source?:@"",@"cc":@(cc),@"value":@(value)}];else _sceneMIDIOverflow=YES;return;}TXRenderState *s=_audio.state;
    if(cc>=1&&cc<=6){int i=cc-1;if(![self canAdjustVolumeForSlot:i]){[self showBrowserCaptureHint:i];[self writeStatus];return;}double v=(_invert?127-value:value)/127.0;BOOL hit=[self pickupValue:v slot:i parameter:0 current:atomic_load(&s->gain[i])];_channels[i].fader.awaitingPickup=!hit;if(!hit)_canvas.message=[NSString stringWithFormat:TXL(@"픽업 대기 · 트랙 %d 페이더를 %.0f 위치까지 움직이면 연결됩니다."),i+1,(double)TXVolumeValue(atomic_load(&s->gain[i]))];if(hit){atomic_store(&s->gain[i],v);_channels[i].fader.value=v;}[self showHUDForSlot:i message:hit?TXVolumeHUD(v):[NSString stringWithFormat:TXL(@"픽업 대기 · %.0f"),(double)TXVolumeValue(atomic_load(&s->gain[i]))]];}
    else if(cc>=7&&cc<=24){int bank=(cc-7)/6,i=(cc-7)%6,b=2-bank;if(![self canAdjustVolumeForSlot:i]){[self showBrowserCaptureHint:i];[self writeStatus];return;}double db=abs((int)value-64)<=1?0:(value/127.0*36-18);TXKnob *k=_channels[i].knobs[bank];BOOL hit=[self pickupValue:db slot:i parameter:b+1 current:atomic_load(&s->eq[i][b])];k.awaitingPickup=!hit;if(!hit)_canvas.message=[NSString stringWithFormat:TXL(@"픽업 대기 · 트랙 %d %@ 노브를 %+.1f dB에 맞추면 연결됩니다."),i+1,k.caption,atomic_load(&s->eq[i][b])];if(hit){atomic_store(&s->eq[i][b],db);k.value=db;}[self showHUDForSlot:i message:hit?[NSString stringWithFormat:@"%@ %+.1f dB",k.caption,db]:[NSString stringWithFormat:TXL(@"%@ 픽업 · %+.1f dB"),k.caption,atomic_load(&s->eq[i][b])]];}
    else if(cc>=25&&cc<=30&&value>=64){int i=cc-25;BOOL mute=!atomic_load(&s->muted[i]);atomic_store(&s->muted[i],mute);_channels[i].mute.state=mute?NSControlStateValueOn:NSControlStateValueOff;[self showHUDForSlot:i message:mute?TXL(@"음소거"):TXL(@"음소거 해제")];}
    else if(cc==31){int delta=value<64?value:(int)value-128;float master=fmaxf(0,fminf(1,atomic_load(&s->master)+delta*TXVolumeStep));atomic_store(&s->master,master);[self showHUDForSlot:-1 message:TXVolumeHUD(master)];}
    else if(cc==33&&value>=64){atomic_store(&s->masterMuted,false);[self showHUDForSlot:-1 message:TXL(@"전체 음소거 해제")];}
    else if(cc==34&&value>=64){atomic_store(&s->masterMuted,true);[self showHUDForSlot:-1 message:TXL(@"전체 음소거")];}
    [self sendBrowserControls];if(cc>=25)[self updateStatus];else _canvas.needsDisplay=YES;[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveSettings) object:nil];[self performSelector:@selector(saveSettings) withObject:nil afterDelay:0.4 inModes:@[NSRunLoopCommonModes]];[self writeStatus];
}
- (void)updateLevels {
    _levelSnapshot=TXReadLevels(_audio.state,_audioReady,_desiredRunning,_monitorUID.length>0,_monitoring);for(int i=0;i<6;i++)if([_assignments[i] hasPrefix:@"chrome-tab:"]){_levelSnapshot.unsupported[i]=YES;_levelSnapshot.available[i]=NO;}if(!_levelsController)return;NSMutableArray *names=[NSMutableArray array];for(int i=0;i<6;i++){NSString *name=_assignments[i].length?_channels[i].assignment.titleOfSelectedItem:nil;[names addObject:name.length?name:TXL(@"앱 미지정")];}[_levelsController updateSnapshot:_levelSnapshot channelNames:names];
}
- (void)showLevels:(id)sender {[_settingsPopover close];if(!_levelsController)_levelsController=[[TXLevelsController alloc] initWithRenderState:_audio.state];[self updateLevels];[_levelsController showWindow:sender];}
- (void)openPreferences:(id)sender {[self showWindow:nil];[self showSettings:_startButton];}
- (void)showSettings:(NSButton*)sender {if(_settingsPopover.shown){[_settingsPopover close];return;}[NSApp activateIgnoringOtherApps:YES];[_window makeKeyAndOrderFront:nil];[_settingsPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMinX];}
- (void)popoverDidShow:(NSNotification*)notification {if(notification.object!=_settingsPopover)return;[_calibrationInput.window makeKeyWindow];[_calibrationInput.window makeFirstResponder:_calibrationInput];}
- (void)soundKey:(id)sender {atomic_store(&_audio.state->masterMuted,false);[self showHUDForSlot:-1 message:TXL(@"전체 음소거 해제")];[self updateStatus];}
- (void)muteKey:(id)sender {atomic_store(&_audio.state->masterMuted,true);[self showHUDForSlot:-1 message:TXL(@"전체 음소거")];[self updateStatus];}
- (void)showBluetooth:(id)sender {if(!_bluetooth)_bluetooth=[CABTLEMIDIWindowController new];[_bluetooth showWindow:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)showPrivacy:(id)sender {[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]];}
- (void)languageChanged:(NSPopUpButton*)sender {TXSetLanguageCode(sender.selectedItem.representedObject);}
- (void)languageDidChange:(NSNotification*)notification {
    BOOL visible=_window.visible,setupVisible=_setupWindow.visible,hudVisible=_hud.visible;NSRect frame=_window.frame;NSString *calibration=_calibrationInput.stringValue;NSWindow *previous=_window;
    [_settingsPopover close];[_hudDismiss invalidate];_pendingHUD=nil;[_hud orderOut:nil];_hud=nil;_hudView=nil;
    [self buildWindow];[_window setFrame:frame display:NO];previous.delegate=nil;[previous close];_calibrationInput.stringValue=calibration;_canvas.message=@"";
    _outputMenuSignature=nil;_processMenuSignature=nil;[self refreshDeviceMenus];[self updateStatus];[self tick:nil];
    for(int i=0;i<6;i++){_channels[i].fader.awaitingPickup=_pickup&&!_latched[i][0];for(int b=0;b<3;b++)_channels[i].knobs[2-b].awaitingPickup=_pickup&&!_latched[i][b+1];}
    if(visible)[_window makeKeyAndOrderFront:nil];_setupWindow.delegate=nil;[_setupWindow close];_setupWindow=nil;if(setupVisible)[self showSetup:nil];if(hudVisible)[self showHUDForSlot:-1 message:TXVolumeHUD(atomic_load(&_audio.state->master))];[self writeStatus];
}
- (void)showSetup:(id)sender {
    [_settingsPopover close];if(_setupWindow){[_setupWindow makeKeyAndOrderFront:nil];return;}
    _setupWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,620,570) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];_setupWindow.title=TXL(@"TX · MAC 시작 안내");_setupWindow.releasedWhenClosed=NO;_setupWindow.delegate=self;_setupWindow.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSView *view=_setupWindow.contentView;[view addSubview:Label(TXL(@"TX · MAC 연결하기"),NSMakeRect(24,515,572,32),22,NO)];
    NSTextField *(^paragraph)(NSString*,NSRect)=^NSTextField*(NSString *text,NSRect rect){NSTextField *field=Label(text,rect,12,NO);field.maximumNumberOfLines=0;field.lineBreakMode=NSLineBreakByWordWrapping;[view addSubview:field];return field;};
    paragraph(TXL(@"1  TX-6 연결"),NSMakeRect(24,472,572,24));_setupDevice=paragraph(@"",NSMakeRect(24,424,572,44));[view addSubview:Button(TXL(@"Bluetooth 연결…"),NSMakeRect(24,386,190,30),self,@selector(showBluetooth:))];
    paragraph(TXL(@"2  시스템 오디오"),NSMakeRect(24,344,572,24));paragraph(TXL(@"앱별 음량과 EQ를 적용하기 위해 macOS 시스템 오디오 접근을 요청합니다. 오디오는 이 Mac에서 실시간 처리하며 녹음하거나 외부로 전송하지 않습니다. 화면이나 마이크 접근은 요청하지 않습니다."),NSMakeRect(24,260,572,76));
    _setupAudio=paragraph(@"",NSMakeRect(24,204,572,48));_setupStart=Button(TXL(@"계속 · 오디오 시작"),NSMakeRect(24,163,250,32),self,@selector(setupStart:));[view addSubview:_setupStart];[view addSubview:Button(TXL(@"개인정보 보호 설정 열기"),NSMakeRect(286,163,310,32),self,@selector(showPrivacy:))];
    paragraph(TXL(@"3  Chrome 탭별 조절 (선택 사항)"),NSMakeRect(24,118,572,24));paragraph(TXL(@"확장을 연결하면 재생 탭과 음소거를 자동 감지합니다. 개별 음량·EQ는 해당 탭에서 ⌘⇧6 또는 확장 아이콘으로 연결하세요."),NSMakeRect(24,65,572,48));
    [view addSubview:Button(TXL(@"Chrome 확장 설정…"),NSMakeRect(24,20,220,30),self,@selector(openChromeSetup:))];[view addSubview:Button(TXL(@"나중에"),NSMakeRect(362,20,104,30),self,@selector(finishSetup:))];[view addSubview:Button(TXL(@"완료"),NSMakeRect(478,20,118,30),self,@selector(finishSetup:))];
    [self updateSetupStatus];[_setupWindow center];[_setupWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)updateSetupStatus {
    if(!_setupWindow)return;_setupDevice.stringValue=_midi.sources.count?[NSString stringWithFormat:TXL(@"연결된 TX-6 MIDI: %@"),[_midi.sources componentsJoinedByString:@" / "]]:TXL(@"TX-6 MIDI 연결 대기. USB 케이블을 연결하거나 Bluetooth 연결을 여세요. 오디오 출력은 메인 창에서 별도로 선택합니다.");
    BOOL callbacks=_audioReady&&atomic_load(&_audio.state->callbacks)>0;BOOL signal=NO;for(int i=0;i<TX_SLOTS;i++)if(atomic_load(&_audio.state->peak[i])>0.00001)signal=YES;
    _setupAudio.stringValue=_halStopping?TXL(@"오디오 연결 해제 중 · 원래 재생을 복구하고 있습니다."):(_audioError.length?_audioError:(_isBuilding?TXL(@"캡처 응답 대기 중입니다. 권한 상태는 아직 확인되지 않았습니다."):(!_audioReady?TXL(@"아직 시작하지 않았습니다. 계속을 누르면 macOS가 필요한 경우 권한을 요청합니다."):(!callbacks?TXL(@"캡처 응답 대기 중입니다. 권한 상태는 아직 확인되지 않았습니다."):(signal?TXL(@"캡처 응답과 처리된 오디오 신호가 관측되었습니다."):TXL(@"캡처 응답이 있습니다. 처리 신호는 무음입니다. 권한 허용 여부를 단정할 수 없습니다. 앱 재생과 음량·음소거를 확인하세요."))))));
    _setupStart.enabled=!_audioReady&&!_isBuilding&&!_halStopping;_setupStart.title=_audioReady?TXL(@"오디오 실행 중"):TXL(@"계속 · 오디오 시작");
}
- (void)setupStart:(id)sender {if(!_desiredRunning)[self toggleMixer:sender];[self updateSetupStatus];}
- (void)finishSetup:(id)sender {[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"TX6Mac.setupSeen"];[_setupWindow orderOut:nil];}
- (void)openChromeSetup:(id)sender {
    NSURL *extensionURL=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"BrowserExtension"];[[NSWorkspace sharedWorkspace] openURL:extensionURL];
    NSAlert *alert=[NSAlert new];alert.messageText=TXL(@"Chrome 확장 설정");alert.informativeText=TXL(@"먼저 제공된 install.command로 앱과 네이티브 호스트를 설치하세요. Chrome에서 chrome://extensions를 열고 개발자 모드를 켠 뒤 ‘압축해제된 확장 프로그램 로드’로 열린 BrowserExtension 폴더를 선택합니다. 설치 후 이 앱을 다시 열어 연결하세요.");[alert addButtonWithTitle:TXL(@"확인")];[alert beginSheetModalForWindow:_setupWindow completionHandler:nil];
}
- (void)willSleep:(NSNotification*)notification {_sleeping=YES;_sleepResume=_desiredRunning;[self stopAudio];[self sendBrowserControls];[self updateStatus];}
- (void)didWake:(NSNotification*)notification {_sleeping=NO;if(_sleepResume&&_desiredRunning&&!_explicitStop){_sleepResume=NO;_retryAttempt=0;_retryExhausted=NO;_retryAt=nil;[self refreshDevices];[self rebuildAudio];}[self updateStatus];}
- (void)showWindow:(id)sender {[_window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (BOOL)windowShouldClose:(NSWindow*)window {[window orderOut:nil];return NO;}
- (BOOL)applicationShouldHandleReopen:(NSApplication*)app hasVisibleWindows:(BOOL)visible {[self showWindow:nil];return YES;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {if(_sceneQuitting)return (_halBusy||_halStopping||_pendingHALRequest)?NSTerminateLater:NSTerminateNow;_sceneQuitting=YES;[_poll invalidate];[_meter invalidate];_desiredRunning=NO;_explicitStop=YES;[self stopAudio];dispatch_async(dispatch_get_main_queue(),^{[self finishSceneQuit];});return NSTerminateLater;}
- (void)finishSceneQuit {if(!_sceneQuitting)return;if(_halBusy||_halStopping||_pendingHALRequest){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.02*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self finishSceneQuit];});return;}[self saveSettings];[self replyToSceneTermination];}
- (void)replyToSceneTermination {[NSApp replyToApplicationShouldTerminate:YES];}
- (void)applicationWillTerminate:(NSNotification*)notification {[_poll invalidate];[_meter invalidate];[_hudDismiss invalidate];[_hud orderOut:nil];[self saveSettings];[self stopAudio];[_browser stop];[_midi stop];[self writeStatus];}
@end

@implementation TXSceneCheckApp
- (void)finishSceneQuit {self.quitWaitRequested=YES;self.quitPollCount++;[super finishSceneQuit];}
- (void)replyToSceneTermination {self.quitReplyCount++;if(!self.quitDelegateReturned)self.quitRepliedEarly=YES;}
- (void)recordDefaultModeProbe {self.defaultModeProbe=YES;}
- (NSUserDefaults*)profileDefaults {return (NSUserDefaults*)(id)self.memoryDefaults;}
@end

@implementation TXHALCheckApp
- (void)saveSettings {}
@end

int main(void) {
    @autoreleasepool {
        NSArray *args=NSProcessInfo.processInfo.arguments;
        if([args containsObject:@"--probe-audio-mute-guard"])return TXProbeAudioMuteGuard();
        if([args containsObject:@"--quiet-usb-source"])return TXQuietUSBSource();
        if([args containsObject:@"--hold-audio-mute-guard"])return TXHoldAudioMuteGuard();
        if([args containsObject:@"--check-usb-meter-route"])return TXCheckUSBMeterRoute([args containsObject:@"--direct"]);
        if([args containsObject:@"--measure-usb-return"])return TXMeasureUSBReturn([args containsObject:@"--request-microphone"]);
        if([args containsObject:@"--ble-services"]||[args containsObject:@"--ble-observe"]||[args containsObject:@"--ble-ping"]||[args containsObject:@"--ble-ping-radio"]){NSUInteger target=[args containsObject:@"--ble-ping-radio"]?3:([args containsObject:@"--ble-ping"]?1:0);TXPrintBLEServices([args containsObject:@"--request-bluetooth"],target!=0||[args containsObject:@"--ble-observe"],target);return 0;}
        if([args containsObject:@"--self-check"]){BOOL ok=TXRunSelfCheck() && TXRunMIDISelfCheck() && TXRunBrowserSelfCheck() && TXRunUIModelSelfCheck() && TXRunDeviceContextSelfCheck() && TXRunLocalizationSelfCheck() && TXRunLevelsSelfCheck() && TXRunSceneStoreSelfCheck() && [TXApp halSelfCheck] && [TXApp sceneControllerSelfCheck];printf("TX6Mac DSP/render self-check: %s\n",ok?"PASS":"FAIL");return ok?0:1;}
        if([args containsObject:@"--diagnose"]){NSData *json=[NSJSONSerialization dataWithJSONObject:TXAudio.diagnostics options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");return 0;}
        for(NSRunningApplication *running in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier])if(running.processIdentifier!=NSProcessInfo.processInfo.processIdentifier){[running activateWithOptions:NSApplicationActivateAllWindows];return 0;}
        NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];__attribute__((objc_precise_lifetime)) TXApp *delegate=[TXApp new];app.delegate=delegate;[app run];
    }return 0;
}
