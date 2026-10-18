#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>

extern void DFRElementSetControlStripPresenceForIdentifier(NSString *identifier, BOOL present);
extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL show);
@interface NSTouchBarItem (P)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
@end
@interface NSTouchBar (P)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar placement:(long long)placement systemTrayItemIdentifier:(NSString *)ident;
@end

static NSTouchBarItemIdentifier const kTray=@"com.mati.mb.tray", kClock=@"com.mati.mb.clock", kBatt=@"com.mati.mb.batt",
  kAudio=@"com.mati.mb.audio", kClaude=@"com.mati.mb.claude", kAppIcon=@"com.mati.mb.appicon", kPrev=@"com.mati.mb.prev",
  kPlay=@"com.mati.mb.play", kNext=@"com.mati.mb.next", kNow=@"com.mati.mb.now", kScrub=@"com.mati.mb.scrub",
  kBright=@"com.mati.mb.bright", kVol=@"com.mati.mb.vol", kVolDn=@"com.mati.mb.voldn", kVolUp=@"com.mati.mb.volup",
  kBright10=@"com.mati.mb.bright10", kBrDn=@"com.mati.mb.brdn", kBrUp=@"com.mati.mb.brup",
  kWeather=@"com.mati.mb.weather",
  kFlex=@"NSTouchBarItemIdentifierFlexibleSpace";
static double BATT_W=806.0, NOW_W=160.0;
NSImage* claudeMark(CGFloat s, NSColor *color);

static NSString* runOSA(NSString *src){
    NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/osascript"; t.arguments=@[@"-e",src];
    NSPipe *p=[NSPipe pipe]; t.standardOutput=p; t.standardError=[NSPipe pipe];
    @try{[t launch];}@catch(__unused NSException *e){return nil;}
    NSData *d=[p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
static NSString* activePlayer(void){
    NSArray *apps=[NSWorkspace sharedWorkspace].runningApplications;
    for(NSRunningApplication *a in apps) if([a.bundleIdentifier isEqualToString:@"com.spotify.client"]) return @"Spotify";
    for(NSRunningApplication *a in apps) if([a.bundleIdentifier isEqualToString:@"com.apple.Music"]) return @"Music";
    return nil;
}
static void transport(NSString *player, NSString *verb){ if(!player)return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0), ^{ runOSA([NSString stringWithFormat:@"tell application \"%@\" to %@",player,verb]); }); }

static int (*_dsGet)(uint32_t,float*); static int (*_dsSet)(uint32_t,float);
static void dsInit(void){ void*h=dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",RTLD_NOW);
    if(h){ _dsGet=dlsym(h,"DisplayServicesGetBrightness"); _dsSet=dlsym(h,"DisplayServicesSetBrightness"); } }
static float brightGet(void){ float b=1; if(_dsGet)_dsGet(CGMainDisplayID(),&b); return b; }
static void brightSet(float v){ if(_dsSet)_dsSet(CGMainDisplayID(), v<0.08?0.08:(v>1?1:v)); }

typedef struct { double level; BOOL charging, external, lowPower; } BattInfo;
static BattInfo readBatt(void){
    BattInfo b={0,NO,YES,NO};
    CFTypeRef info=IOPSCopyPowerSourcesInfo();
    if(info){ CFArrayRef list=IOPSCopyPowerSourcesList(info);
        if(list && CFArrayGetCount(list)>0){ CFDictionaryRef ps=IOPSGetPowerSourceDescription(info,CFArrayGetValueAtIndex(list,0));
            int cur=0,max=100; CFNumberRef c=(CFNumberRef)CFDictionaryGetValue(ps,CFSTR(kIOPSCurrentCapacityKey)),m=(CFNumberRef)CFDictionaryGetValue(ps,CFSTR(kIOPSMaxCapacityKey));
            if(c)CFNumberGetValue(c,kCFNumberIntType,&cur); if(m)CFNumberGetValue(m,kCFNumberIntType,&max); b.level=max>0?(double)cur/max:0; }
        if(list)CFRelease(list); CFRelease(info); }
    io_service_t svc=IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if(svc){ CFMutableDictionaryRef pr=NULL;
        if(IORegistryEntryCreateCFProperties(svc,&pr,kCFAllocatorDefault,0)==KERN_SUCCESS && pr){
            CFBooleanRef chg=(CFBooleanRef)CFDictionaryGetValue(pr,CFSTR("IsCharging")), ext=(CFBooleanRef)CFDictionaryGetValue(pr,CFSTR("ExternalConnected"));
            if(chg)b.charging=CFBooleanGetValue(chg); if(ext)b.external=CFBooleanGetValue(ext); CFRelease(pr); }
        IOObjectRelease(svc); }
    b.lowPower=[NSProcessInfo processInfo].isLowPowerModeEnabled; return b;
}

typedef CFMutableDictionaryRef (*IORCopy)(CFStringRef,CFStringRef,uint64_t,uint64_t,uint64_t);
typedef void* (*IORSubF)(void*,CFMutableDictionaryRef,CFMutableDictionaryRef*,uint64_t,CFTypeRef);
typedef CFDictionaryRef (*IORSamp)(void*,CFMutableDictionaryRef,CFTypeRef);
typedef CFDictionaryRef (*IORDelta)(CFDictionaryRef,CFDictionaryRef,CFTypeRef);
typedef void (*IORIter)(CFDictionaryRef,int(^)(CFDictionaryRef));
typedef CFStringRef (*IORStr)(CFDictionaryRef); typedef int64_t (*IORVal)(CFDictionaryRef,int);
static IORCopy _iCopy; static IORSubF _iSub; static IORSamp _iSamp; static IORDelta _iDelta; static IORIter _iIter; static IORStr _iName,_iUnit; static IORVal _iVal;
static void *_iSubscription; static CFMutableDictionaryRef _iChans; static CFDictionaryRef _iPrev; static double _iPrevT;
static void iorInit(void){ void*h=dlopen("/usr/lib/libIOReport.dylib",RTLD_NOW); if(!h)return;
    _iCopy=dlsym(h,"IOReportCopyChannelsInGroup"); _iSub=dlsym(h,"IOReportCreateSubscription"); _iSamp=dlsym(h,"IOReportCreateSamples");
    _iDelta=dlsym(h,"IOReportCreateSamplesDelta"); _iIter=dlsym(h,"IOReportIterate"); _iName=dlsym(h,"IOReportChannelGetChannelName");
    _iUnit=dlsym(h,"IOReportChannelGetUnitLabel"); _iVal=dlsym(h,"IOReportSimpleGetIntegerValue");
    if(!_iCopy||!_iSub||!_iSamp)return; CFMutableDictionaryRef ch=_iCopy(CFSTR("Energy Model"),NULL,0,0,0); if(!ch)return;
    CFMutableDictionaryRef s2=NULL; _iSubscription=_iSub(NULL,ch,&s2,0,NULL); _iChans=s2?s2:ch;
    if(_iSubscription){ _iPrev=_iSamp(_iSubscription,_iChans,NULL); _iPrevT=CFAbsoluteTimeGetCurrent(); } }
static double iorWatts(void){ if(!_iSubscription||!_iPrev)return -1;
    CFDictionaryRef cur=_iSamp(_iSubscription,_iChans,NULL); if(!cur)return -1;
    double now=CFAbsoluteTimeGetCurrent(),dt=now-_iPrevT; if(dt<=0.05){CFRelease(cur);return -1;}
    CFDictionaryRef d=_iDelta(_iPrev,cur,NULL); __block double mJ=0;
    _iIter(d, ^int(CFDictionaryRef c){ char nm[64]={0},un[16]={0};
        CFStringRef n=_iName(c); if(n)CFStringGetCString(n,nm,64,kCFStringEncodingUTF8);
        if(strcmp(nm,"CPU Energy")&&strcmp(nm,"GPU Energy")&&strcmp(nm,"ANE Energy")&&strcmp(nm,"DRAM"))return 0;
        CFStringRef u=_iUnit(c); if(u)CFStringGetCString(u,un,16,kCFStringEncodingUTF8); double v=(double)_iVal(c,0);
        if(!strcmp(un,"mJ"))mJ+=v; else if(!strcmp(un,"uJ"))mJ+=v/1e3; else if(!strcmp(un,"nJ"))mJ+=v/1e6; else if(!strcmp(un,"J"))mJ+=v*1e3; return 0; });
    if(d)CFRelease(d); CFRelease(_iPrev); _iPrev=cur; _iPrevT=now; return (mJ/1000.0)/dt; }

@interface BatteryView : NSView
@property double level,target,phase,watts; @property BOOL charging,discharging,lowPower;
@end
@implementation BatteryView
- (NSSize)intrinsicContentSize{ return NSMakeSize(BATT_W,30); }
- (void)drawRect:(NSRect)d{
    NSRect b=self.bounds; CGFloat pad=3,nub=4; NSRect body=NSMakeRect(pad,pad+1,b.size.width-pad*2-nub,b.size.height-pad*2-2);
    NSColor *shell=[NSColor colorWithWhite:0.85 alpha:0.9];
    NSBezierPath *bd=[NSBezierPath bezierPathWithRoundedRect:body xRadius:6 yRadius:6]; bd.lineWidth=1.5; [shell setStroke]; [bd stroke];
    [shell setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMaxX(body)+1.5,NSMidY(body)-4,nub,8) xRadius:2 yRadius:2] fill];
    NSRect inner=NSInsetRect(body,2.5,2.5); CGFloat w=inner.size.width*self.level; NSRect fr=NSMakeRect(inner.origin.x,inner.origin.y,fmax(w,0),inner.size.height);
    BOOL low=(!self.charging && self.level<0.20), animate=self.charging||self.discharging; NSColor *col; BOOL darkFill;
    if(self.charging){col=[NSColor systemGreenColor];darkFill=YES;} else if(low){col=[NSColor systemRedColor];darkFill=YES;}
    else if(self.lowPower){col=[NSColor systemYellowColor];darkFill=NO;} else {col=[NSColor colorWithWhite:0.92 alpha:1];darkFill=NO;}
    if(w>1){ NSBezierPath *fp=[NSBezierPath bezierPathWithRoundedRect:fr xRadius:3.5 yRadius:3.5]; [col setFill]; [fp fill];
        if(animate){ [NSGraphicsContext saveGraphicsState]; [fp addClip]; CGFloat sw=60,x=inner.origin.x-sw+self.phase*(w+sw); CGFloat tone=darkFill?1:0.45;
            NSGradient *g=[[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:tone alpha:0],[NSColor colorWithWhite:tone alpha:0.55],[NSColor colorWithWhite:tone alpha:0]]];
            [g drawInRect:NSMakeRect(x,inner.origin.y,sw,inner.size.height) angle:0]; [NSGraphicsContext restoreGraphicsState]; } }
    NSMutableString *ex=[NSMutableString string]; if(self.watts>0.3)[ex appendFormat:@"  %.1fW",self.watts];
    NSString *s=[NSString stringWithFormat:@"%d%%%@",(int)round(self.level*100),ex];
    NSMutableParagraphStyle *ps=[NSMutableParagraphStyle new]; ps.alignment=NSTextAlignmentCenter; NSFont *f=[NSFont boldSystemFontOfSize:13];
    NSRect tr=NSMakeRect(body.origin.x,NSMidY(body)-7.5,body.size.width,15);
    [s drawInRect:tr withAttributes:@{NSFontAttributeName:f,NSForegroundColorAttributeName:[NSColor whiteColor],NSParagraphStyleAttributeName:ps}];
    if(w>1){ [NSGraphicsContext saveGraphicsState]; [[NSBezierPath bezierPathWithRect:fr] addClip];
        NSColor *of=darkFill?[NSColor whiteColor]:[NSColor colorWithWhite:0.12 alpha:1];
        [s drawInRect:tr withAttributes:@{NSFontAttributeName:f,NSForegroundColorAttributeName:of,NSParagraphStyleAttributeName:ps}]; [NSGraphicsContext restoreGraphicsState]; }
}
@end

// scrubber fino (NSSlider con cell custom: lindo + arrastra nativo)
@interface ScrubCell : NSSliderCell @end
@implementation ScrubCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped{
    NSRect b=self.controlView.bounds; CGFloat cy=NSMidY(b),h=3; NSRect tr=NSMakeRect(5,cy-h/2,b.size.width-10,h);
    [[NSColor colorWithWhite:0.35 alpha:1] setFill]; [[NSBezierPath bezierPathWithRoundedRect:tr xRadius:1.5 yRadius:1.5] fill];
    double f=(self.maxValue>self.minValue)?(self.doubleValue-self.minValue)/(self.maxValue-self.minValue):0;
    [[NSColor whiteColor] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(tr.origin.x,cy-h/2,tr.size.width*f,h) xRadius:1.5 yRadius:1.5] fill];
}
- (void)drawKnob:(NSRect)knobRect{
    NSRect b=self.controlView.bounds; CGFloat cy=NSMidY(b);
    double f=(self.maxValue>self.minValue)?(self.doubleValue-self.minValue)/(self.maxValue-self.minValue):0;
    CGFloat x=5+(b.size.width-10)*f; [[NSColor whiteColor] setFill]; NSRectFill(NSMakeRect(x-1.5,cy-8,3,16));
}
@end

// Now info: carátula + título·artista (clickable -> abre Spotify)
@interface NowView : NSButton
@property (strong) NSImage *art; @property (copy) NSString *song,*artist;
@end
@implementation NowView
- (NSSize)intrinsicContentSize{ return NSMakeSize(NOW_W,30); }
- (void)drawRect:(NSRect)d{
    NSRect b=self.bounds; CGFloat h=b.size.height; CGFloat as=h-6; NSRect ar=NSMakeRect(0,3,as,as);
    [NSGraphicsContext saveGraphicsState]; [[NSBezierPath bezierPathWithRoundedRect:ar xRadius:4 yRadius:4] addClip];
    if(self.art) [self.art drawInRect:ar fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    else { [[NSColor colorWithWhite:0.3 alpha:1] setFill]; NSRectFill(ar);
        [@"♪" drawAtPoint:NSMakePoint(ar.origin.x+as/2-4,ar.origin.y+as/2-9) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:[NSColor colorWithWhite:0.7 alpha:1]}]; }
    [NSGraphicsContext restoreGraphicsState];
    CGFloat x=NSMaxX(ar)+8; NSString *info=(self.song.length?self.song:@"Nada sonando"); if(self.artist.length) info=[NSString stringWithFormat:@"%@  ·  %@",self.song,self.artist];
    NSMutableParagraphStyle *ps=[NSMutableParagraphStyle new]; ps.lineBreakMode=NSLineBreakByTruncatingTail;
    [info drawInRect:NSMakeRect(x,NSMidY(b)-8,b.size.width-x,16) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:[NSColor colorWithWhite:0.95 alpha:1],NSParagraphStyleAttributeName:ps}];
}
@end

// barras de segmentos como NSSliderCell (el NSSlider SÍ recibe toques en el Touch Bar)
@interface SegCell : NSSliderCell @property int segs; @end
@implementation SegCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped{
    NSRect b=self.controlView.bounds; int N=self.segs; CGFloat gap=3, x0=2, avail=b.size.width-x0-2, bw=(avail-gap*(N-1))/N;
    int level=(int)llround(self.doubleValue);
    for(int i=0;i<N;i++){ NSRect r=NSMakeRect(x0+i*(bw+gap),6,bw,b.size.height-12);
        [(i<level?[NSColor whiteColor]:[NSColor colorWithWhite:0.3 alpha:1]) setFill]; [[NSBezierPath bezierPathWithRoundedRect:r xRadius:2 yRadius:2] fill]; }
}
- (void)drawKnob:(NSRect)knobRect{} // sin knob, solo barras
@end

// ===== clima / visualización del día =====
static NSString* wmoIcon(int c){ if(c==0)return @"sun.max.fill"; if(c<=2)return @"cloud.sun.fill"; if(c==3)return @"cloud.fill";
    if(c==45||c==48)return @"cloud.fog.fill"; if(c>=51&&c<=57)return @"cloud.drizzle.fill";
    if((c>=61&&c<=67)||(c>=80&&c<=82))return @"cloud.rain.fill"; if((c>=71&&c<=77)||c==85||c==86)return @"cloud.snow.fill";
    if(c>=95)return @"cloud.bolt.rain.fill"; return @"cloud.fill"; }

static int wmoCat(int c){ if(c<=1)return 0; if(c==2||c==3||c==45||c==48)return 1;
    if((c>=51&&c<=67)||(c>=80&&c<=82))return 2; if((c>=71&&c<=77)||c==85||c==86)return 3; if(c>=95)return 4; return 1; }
static NSColor* lerpC(NSColor*a,NSColor*b,double t){ t=t<0?0:(t>1?1:t);
    a=[a colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]]; b=[b colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]]; // evita crash con colores grayscale
    return [NSColor colorWithRed:a.redComponent+(b.redComponent-a.redComponent)*t green:a.greenComponent+(b.greenComponent-a.greenComponent)*t blue:a.blueComponent+(b.blueComponent-a.blueComponent)*t alpha:1]; }
// fase lunar real: 0=nueva, 0.5=llena
static double moonPhase(void){ double now=[[NSDate date] timeIntervalSince1970]; double syn=29.530588853*86400.0;
    double p=fmod(now-947182440.0,syn)/syn; if(p<0)p+=1; return p; }
// icono segun codigo y dia/noche
static NSString* wxIcon(int c,BOOL night){ if(c<=1)return night?@"moon.stars.fill":@"sun.max.fill";
    if(c==2)return night?@"cloud.moon.fill":@"cloud.sun.fill"; if(c==3)return @"cloud.fill";
    if(c==45||c==48)return @"cloud.fog.fill"; if(c>=51&&c<=57)return @"cloud.drizzle.fill";
    if((c>=61&&c<=67)||(c>=80&&c<=82))return @"cloud.rain.fill"; if((c>=71&&c<=77)||c==85||c==86)return @"cloud.snow.fill";
    if(c>=95)return @"cloud.bolt.rain.fill"; return @"cloud.fill"; }

@interface WeatherView : NSView
@property BOOL loaded,southern; @property double tempC,hi,lo,phase; @property int code,sunriseMin,sunsetMin; @property (copy) NSString *city,*dateStr; @property (strong) NSArray *rainProb;
@end
@implementation WeatherView
- (NSSize)intrinsicContentSize{ return NSMakeSize(930,30); }
- (void)drawRect:(NSRect)d{
    NSRect b=self.bounds; CGFloat W=b.size.width,Hh=b.size.height;
    NSDateComponents *co=[[NSCalendar currentCalendar] components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:[NSDate date]];
    int nowMin=(int)(co.hour*60+co.minute); {char*e=getenv("MATIBAR_WXMIN"); if(e)nowMin=atoi(e);}
    int sr=self.sunriseMin,ss=self.sunsetMin; if(ss<=sr){sr=360;ss=1080;}
    int c=self.code; {char*e=getenv("MATIBAR_WXCODE"); if(e)c=atoi(e);}
    int cat=self.loaded?wmoCat(c):1; BOOL fog=(c==45||c==48);
    double w=55.0;
    double dayness=(nowMin<=sr-w||nowMin>=ss+w)?0:(nowMin>=sr+w&&nowMin<=ss-w)?1:(nowMin<sr+w?(nowMin-(sr-w))/(2*w):((ss+w)-nowMin)/(2*w));
    if(dayness<0)dayness=0; if(dayness>1)dayness=1;
    double tw=fmax(exp(-pow((nowMin-sr)/w,2)),exp(-pow((nowMin-ss)/w,2)));
    double cloud=cat==0?0.0:(cat==1?(fog?0.6:0.42):(cat==3?0.5:(cat==2?0.72:0.92)));
    // ---- gradiente de cielo ----
    NSColor *nTop=[NSColor colorWithRed:0.03 green:0.04 blue:0.12 alpha:1],*nBot=[NSColor colorWithRed:0.09 green:0.11 blue:0.26 alpha:1];
    NSColor *dTop=[NSColor colorWithRed:0.16 green:0.48 blue:0.86 alpha:1],*dBot=[NSColor colorWithRed:0.60 green:0.82 blue:0.97 alpha:1];
    NSColor *tTop=[NSColor colorWithRed:0.97 green:0.45 blue:0.28 alpha:1],*tBot=[NSColor colorWithRed:0.33 green:0.24 blue:0.45 alpha:1];
    NSColor *gTop=[NSColor colorWithRed:0.32 green:0.35 blue:0.40 alpha:1],*gBot=[NSColor colorWithRed:0.50 green:0.53 blue:0.57 alpha:1];
    NSColor *top=lerpC(nTop,dTop,dayness),*bot=lerpC(nBot,dBot,dayness);
    top=lerpC(top,tTop,tw*0.85); bot=lerpC(bot,tBot,tw*0.85);
    top=lerpC(top,gTop,cloud*0.72); bot=lerpC(bot,gBot,cloud*0.72);
    if(cat==4){ top=lerpC(top,[NSColor colorWithWhite:0.13 alpha:1],0.72); bot=lerpC(bot,[NSColor colorWithWhite:0.24 alpha:1],0.72); }
    [[[NSGradient alloc] initWithStartingColor:top endingColor:bot] drawInRect:b angle:-90];
    // glow del sol (día despejado/parcial)
    if(dayness>0.25 && cat<=1 && !fog && ss>sr){ double sp=(double)(nowMin-sr)/(ss-sr); if(sp>0&&sp<1){ CGFloat gx=W*0.5+ (W*0.32)*(sp-0.5)*2; CGFloat gy=Hh*0.85;
        NSGradient *gl=[[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithRed:1 green:0.95 blue:0.6 alpha:0.35*dayness],0.0,[NSColor colorWithWhite:1 alpha:0],1.0,nil];
        [gl drawFromCenter:NSMakePoint(gx,gy) radius:0 toCenter:NSMakePoint(gx,gy) radius:60 options:0]; } }
    // relámpago
    if(cat==4){ double f=fmod(self.phase,2.6); if(f<0.10){ [[NSColor colorWithWhite:1 alpha:(0.10-f)*2.8] setFill]; NSRectFill(b); } }
    // estrellas (noche despejada/parcial) con titileo
    if(dayness<0.35 && cat<=1 && !fog){ srand48(7); double sa=0.55*(1-dayness)*(cat==0?1:0.55);
        for(int i=0;i<44;i++){ CGFloat stx=drand48()*W,sty=Hh*0.25+drand48()*Hh*0.75; double tk=0.55+0.45*sin(self.phase*2.2+i*1.7);
            [[NSColor colorWithWhite:1 alpha:sa*tk] setFill]; NSRectFill(NSMakeRect(stx,sty,1,1)); } }
    // niebla
    if(fog){ for(int i=0;i<5;i++){ CGFloat fy=4+i*5; CGFloat off=fmod(self.phase*8+i*30,40)-20; [[NSColor colorWithWhite:0.72 alpha:0.09] setFill]; NSRectFill(NSMakeRect(off,fy,W+40,3)); } }
    // nubes
    if(cat>=1 && !fog){ CGFloat drift=fmod(self.phase*12,W+140)-70;
        for(int i=0;i<4;i++){ CGFloat cx=fmod(drift+i*270,W+140)-70,cy=Hh-11-i*3,alpha=0.08+(cat>=2?0.09:0.05);
            [[NSColor colorWithWhite:(cat>=2?0.5:0.9) alpha:alpha] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx,cy,95,14)] fill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx+32,cy-4,72,17)] fill]; } }
    // lluvia / nieve
    if(cat==2||cat==4){ [[NSColor colorWithWhite:0.85 alpha:0.32] setStroke];
        for(int i=0;i<36;i++){ double s=(i*53%100)/100.0; CGFloat rx=fmod(s*W+i*37,W),ph=fmod(self.phase*100+s*44,Hh+8);
            NSBezierPath *ln=[NSBezierPath bezierPath]; ln.lineWidth=1; [ln moveToPoint:NSMakePoint(rx,Hh-ph)]; [ln lineToPoint:NSMakePoint(rx-2,Hh-ph-6)]; [ln stroke]; } }
    else if(cat==3){ [[NSColor colorWithWhite:1 alpha:0.78] setFill];
        for(int i=0;i<26;i++){ double s=(i*61%100)/100.0; CGFloat rx=fmod(s*W+i*41+sin(self.phase+i)*4,W),ph=fmod(self.phase*34+s*44,Hh+6); NSRectFill(NSMakeRect(rx,Hh-ph,1.8,1.8)); } }

    NSShadow *sh=[NSShadow new]; sh.shadowColor=[NSColor colorWithWhite:0 alpha:0.6]; sh.shadowBlurRadius=2.5; sh.shadowOffset=NSMakeSize(0,-0.5);
    CGFloat mid=NSMidY(b);
    if(!self.loaded){ [@"Loading weather…" drawAtPoint:NSMakePoint(8,mid-7) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:[NSColor whiteColor],NSShadowAttributeName:sh}]; return; }

    // ---- bloque izquierdo: fecha / temp / icono / ciudad ----
    CGFloat x=7;
    NSDictionary *da=@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],NSForegroundColorAttributeName:[NSColor colorWithWhite:0.92 alpha:1],NSShadowAttributeName:sh};
    NSString *ds=self.dateStr?:@""; [ds drawAtPoint:NSMakePoint(x,mid+3) withAttributes:da];
    NSFont *tf=[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]; NSString *t=[NSString stringWithFormat:@"%.0f°",self.tempC];
    [t drawAtPoint:NSMakePoint(x,mid-13) withAttributes:@{NSFontAttributeName:tf,NSForegroundColorAttributeName:[NSColor whiteColor],NSShadowAttributeName:sh}];
    x+=fmax([t sizeWithAttributes:@{NSFontAttributeName:tf}].width,[ds sizeWithAttributes:da].width)+8;
    BOOL night=dayness<0.5;
    NSImage *ic=[NSImage imageWithSystemSymbolName:wxIcon(c,night) accessibilityDescription:nil];
    NSImageSymbolConfiguration *icfg=[[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular] configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationPreferringMulticolor]];
    ic=[ic imageWithSymbolConfiguration:icfg]; [[NSColor whiteColor] set]; // fallback para símbolos monocromos
    [ic drawInRect:NSMakeRect(x,mid-8,17,17) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1]; x+=22;
    NSFont *cf=[NSFont systemFontOfSize:11]; NSString *cl=[NSString stringWithFormat:@"%@  H:%.0f° L:%.0f°",self.city?:@"",self.hi,self.lo];
    [cl drawAtPoint:NSMakePoint(x,mid-6) withAttributes:@{NSFontAttributeName:cf,NSForegroundColorAttributeName:[NSColor colorWithWhite:0.97 alpha:1],NSShadowAttributeName:sh}];
    x+=[cl sizeWithAttributes:@{NSFontAttributeName:cf}].width+18;

    // ---- línea de tiempo del día (00:00 -> 23:59), clara y a todo lo ancho ----
    CGFloat tlL=x+14,tlR=W-6,tlW=tlR-tlL; if(tlW<120)tlW=120; CGFloat baseY=9,amp=10;
    // baseline
    [[NSColor colorWithWhite:1 alpha:0.22] setFill]; NSRectFill(NSMakeRect(tlL,baseY,tlW,1));
    // marcas + etiquetas (cada hora marca, cada 6h etiqueta)
    NSDictionary *la=@{NSFontAttributeName:[NSFont systemFontOfSize:8],NSForegroundColorAttributeName:[NSColor colorWithWhite:0.96 alpha:0.92],NSShadowAttributeName:sh};
    for(int h=0;h<=24;h++){ CGFloat hx=tlL+tlW*(h/24.0); BOOL major=(h%6==0); CGFloat th=major?5:3;
        [[NSColor colorWithWhite:1 alpha:major?0.42:0.17] setFill]; NSRectFill(NSMakeRect(hx,baseY,1,th));
        if(major){ NSString *lb=(h==24)?@"23:59":[NSString stringWithFormat:@"%02d:00",h]; NSSize lz=[lb sizeWithAttributes:la];
            CGFloat lx=hx-lz.width/2; if(lx<tlL)lx=tlL; if(lx+lz.width>tlR)lx=tlR-lz.width; [lb drawAtPoint:NSMakePoint(lx,0) withAttributes:la]; } }
    // arco del sol HACIA ARRIBA, solo en la franja de luz
    CGFloat srX=tlL+tlW*(sr/1440.0),ssX=tlL+tlW*(ss/1440.0),sunW=ssX-srX;
    NSBezierPath *arc=[NSBezierPath bezierPath]; [arc moveToPoint:NSMakePoint(srX,baseY)];
    for(double p=0;p<=1.001;p+=0.03)[arc lineToPoint:NSMakePoint(srX+sunW*p,baseY+amp*sin(M_PI*p))];
    arc.lineWidth=1.6; [[NSColor colorWithRed:1 green:0.86 blue:0.42 alpha:0.9] setStroke]; [arc stroke];
    // íconos de lluvia en horas futuras con chance alta
    if([self.rainProb isKindOfClass:[NSArray class]]){ for(NSUInteger h=co.hour+1;h<24&&h<self.rainProb.count;h++){ if([self.rainProb[h] intValue]>=45){
        CGFloat hx=tlL+tlW*(h/24.0); [[NSColor colorWithRed:0.55 green:0.78 blue:1 alpha:0.95] setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(hx-2,baseY+amp+4,4,5.5)] fill]; } } }
    // marcador de ahora: sol (día) o luna (noche)
    CGFloat nowX=tlL+tlW*(nowMin/1440.0); BOOL day=nowMin>=sr&&nowMin<=ss;
    [[NSColor colorWithWhite:1 alpha:0.5] setFill]; NSRectFill(NSMakeRect(nowX,baseY,1,amp+2));
    if(day){ CGFloat sy=baseY+amp*sin(M_PI*((double)(nowMin-sr)/(ss-sr))); [[NSColor colorWithRed:1 green:0.92 blue:0.45 alpha:1] setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(nowX-4,sy-4,8,8)] fill]; }
    else { CGFloat mcx=nowX,mcy=baseY+amp-1,mr=5; double mp=moonPhase(),k=(1-cos(2*M_PI*mp))/2; BOOL wax=mp<0.5; BOOL litRight=(wax!=self.southern);
        NSBezierPath *disk=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(mcx-mr,mcy-mr,2*mr,2*mr)];
        [NSGraphicsContext saveGraphicsState]; [disk addClip];
        [[NSColor colorWithWhite:0.96 alpha:1] setFill]; [disk fill];
        CGFloat dx=(litRight?-1:1)*2*mr*k; [[NSColor colorWithWhite:0.18 alpha:1] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(mcx+dx-mr,mcy-mr,2*mr,2*mr)] fill];
        [NSGraphicsContext restoreGraphicsState]; }
}
@end

@class AppDelegate; static void psCB(void *ctx);
@interface AppDelegate : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
- (void)powerChanged;
@end
@implementation AppDelegate{
    NSTouchBar *_bar; NSButton *_clock,*_playBtn; BatteryView *_batt; NowView *_now; NSSlider *_scrub,*_volSlider,*_brightSlider;
    WeatherView *_weather; double _wlat,_wlon,_wfetchT; NSString *_wcity;
    NSMutableDictionary *_cache; NSTimer *_anim,*_watch; int _tick,_mode,_lastVol; dispatch_queue_t _mq; double _dur,_elapsed,_lastScrub; BOOL _playing; NSString *_artTrack,*_player;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n{
    _cache=[NSMutableDictionary new]; _mq=dispatch_queue_create("com.mati.mb.media",DISPATCH_QUEUE_SERIAL); iorInit(); dsInit();
    NSCustomTouchBarItem *tray=[[NSCustomTouchBarItem alloc] initWithIdentifier:kTray];
    NSButton *tb=[NSButton buttonWithTitle:@"⚡" target:self action:@selector(present)]; tb.bezelColor=[NSColor systemOrangeColor]; tray.view=tb;
    [NSTouchBarItem addSystemTrayItem:tray]; DFRElementSetControlStripPresenceForIdentifier(kTray,YES);
    _bar=[NSTouchBar new]; _bar.delegate=self; [self applyMode];
    _anim=[NSTimer scheduledTimerWithTimeInterval:1.0/30.0 target:self selector:@selector(frame) userInfo:nil repeats:YES];
    // Re-presentar SOLO en eventos reales (no cada 3s -> sin parpadeo).
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(present) name:NSWorkspaceDidWakeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(present) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    CFRunLoopSourceRef s=IOPSNotificationCreateRunLoopSource(psCB,(__bridge void*)self); if(s){CFRunLoopAddSource(CFRunLoopGetMain(),s,kCFRunLoopDefaultMode);CFRelease(s);}
    [self frame];
    if(getenv("MATIBAR_AUDIOMODE"))[self performSelector:@selector(goAudio) withObject:nil afterDelay:1.5];
    if(getenv("MATIBAR_BRIGHTMODE"))[self performSelector:@selector(goBright) withObject:nil afterDelay:1.5];
    if(getenv("MATIBAR_WEATHERMODE"))[self performSelector:@selector(toggleWeather) withObject:nil afterDelay:1.5];
    NSLog(@"MatiBar v11");
}
- (void)applyMode{
    if(_mode==0) _bar.defaultItemIdentifiers=@[kClock,kBatt,kFlex,kAudio,kClaude];
    else if(_mode==1) _bar.defaultItemIdentifiers=@[kPrev,kPlay,kNext,kNow,kScrub,kVolDn,kVol,kVolUp,kFlex,kBright,kAudio,kClaude];
    else if(_mode==2) _bar.defaultItemIdentifiers=@[kFlex,kBrDn,kBright10,kBrUp,kFlex,kBright,kAudio,kClaude];
    else _bar.defaultItemIdentifiers=@[kClock,kWeather]; // modo clima: solo reloj + panel del día
    [self present];
}
- (void)present{ DFRSystemModalShowsCloseBoxWhenFrontMost(NO); [NSTouchBar presentSystemModalTouchBar:_bar placement:1 systemTrayItemIdentifier:nil]; }
- (void)goAudio{ _mode=1; [self applyMode]; [self refreshMedia]; }
- (void)goBright{ _mode=2; [self applyMode]; if(_brightSlider){ _brightSlider.doubleValue=fmax(1,round(brightGet()*10)); [_brightSlider setNeedsDisplay:YES]; } }
- (void)toggleAudio{ _mode=(_mode==0)?1:0; [self applyMode]; if(_mode==1)[self refreshMedia]; }
- (void)toggleBright{ if(_mode==1)[self goBright]; else [self goAudio]; }
- (void)toggleWeather{ _mode=(_mode==3)?0:3; [self applyMode]; if(_mode==3)[self fetchWeather]; }
- (void)powerChanged{ if(!_batt)return; BattInfo bi=readBatt(); _batt.charging=bi.charging; _batt.discharging=!bi.external; _batt.target=bi.level; _batt.lowPower=bi.lowPower; _batt.needsDisplay=YES; }

- (void)frame{ _tick++;
    if(_batt){ if(_tick%45==1){ BattInfo bi=readBatt(); _batt.target=bi.level; _batt.charging=bi.charging; _batt.discharging=!bi.external; _batt.lowPower=bi.lowPower; }
        if(_tick%30==10){ double w=iorWatts(); if(w>=0)_batt.watts=w; }
        double df=_batt.target-_batt.level; if(fabs(df)>0.002)_batt.level+=df*0.08; else _batt.level=_batt.target;
        if(_batt.charging)_batt.phase+=0.012; else if(_batt.discharging){ double sp=0.004+fmin(_batt.watts,30)*0.0007; _batt.phase-=sp; }
        if(_batt.phase>1)_batt.phase-=1; if(_batt.phase<0)_batt.phase+=1; _batt.needsDisplay=YES; }
    if(_clock && _tick%30==0){ NSDateFormatter *df=[NSDateFormatter new]; df.dateFormat=@"HH:mm"; _clock.title=[df stringFromDate:[NSDate date]]; }
    if(_mode==3 && _weather){ _weather.phase+=1.0/30.0; _weather.needsDisplay=YES; if(CFAbsoluteTimeGetCurrent()-_wfetchT>600)[self fetchWeather]; }
    if(_mode==1 && _tick%30==5)[self refreshMedia];
    if(_mode==1 && _playing && _dur>0 && _tick%30!=5){ _elapsed+=1.0/30.0;
        if(_scrub && CFAbsoluteTimeGetCurrent()-_lastScrub>0.5) _scrub.doubleValue=fmin(1.0,_elapsed/_dur); }
}

- (NSButton*)imgBtn:(NSString*)sym sel:(SEL)sel{ NSButton *b=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil] target:self action:sel]; b.bordered=NO; b.imagePosition=NSImageOnly; return b; }
- (NSTouchBarItem *)touchBar:(NSTouchBar *)t makeItemForIdentifier:(NSTouchBarItemIdentifier)id{
    if(_cache[id])return _cache[id]; NSTouchBarItem *out=nil; NSCustomTouchBarItem *it=[[NSCustomTouchBarItem alloc] initWithIdentifier:id];
    if([id isEqual:kClock]){ _clock=[NSButton buttonWithTitle:@"--:--" target:self action:@selector(toggleWeather)]; _clock.bordered=NO; _clock.font=[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightMedium]; it.view=_clock; out=it; }
    else if([id isEqual:kWeather]){ _weather=[[WeatherView alloc] initWithFrame:NSMakeRect(0,0,930,30)]; _weather.wantsLayer=YES; [_weather.widthAnchor constraintEqualToConstant:930].active=YES; it.view=_weather; out=it; }
    else if([id isEqual:kBatt]){ _batt=[[BatteryView alloc] initWithFrame:NSMakeRect(0,0,BATT_W,30)]; _batt.wantsLayer=YES; BattInfo bi=readBatt(); _batt.target=_batt.level=bi.level; _batt.charging=bi.charging; _batt.discharging=!bi.external; _batt.lowPower=bi.lowPower; it.view=_batt; out=it; }
    else if([id isEqual:kAudio]){ NSButton *a=[self imgBtn:@"speaker.wave.2.fill" sel:@selector(toggleAudio)]; [a.widthAnchor constraintEqualToConstant:46].active=YES; it.view=a; out=it; }
    else if([id isEqual:kClaude]){ NSButton *c=[NSButton buttonWithImage:claudeMark(27,[NSColor colorWithRed:0.85 green:0.47 blue:0.34 alpha:1]) target:self action:@selector(openClaude)]; c.bordered=NO; c.imagePosition=NSImageOnly; c.imageScaling=NSImageScaleNone; [c.widthAnchor constraintEqualToConstant:50].active=YES; it.view=c; out=it; }
    else if([id isEqual:kPrev]){ it.view=[self imgBtn:@"backward.fill" sel:@selector(mPrev)]; out=it; }
    else if([id isEqual:kPlay]){ _playBtn=[self imgBtn:@"play.fill" sel:@selector(mPlay)]; _playBtn.contentTintColor=[NSColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:1]; it.view=_playBtn; out=it; }
    else if([id isEqual:kNext]){ it.view=[self imgBtn:@"forward.fill" sel:@selector(mNext)]; out=it; }
    else if([id isEqual:kNow]){ _now=[[NowView alloc] initWithFrame:NSMakeRect(0,0,NOW_W,30)]; _now.wantsLayer=YES; _now.bordered=NO; _now.title=@""; [_now setButtonType:NSButtonTypeMomentaryChange]; _now.target=self; _now.action=@selector(openPlayer); [_now.widthAnchor constraintEqualToConstant:NOW_W].active=YES; it.view=_now; out=it; }
    else if([id isEqual:kScrub]){ ScrubCell *cell=[ScrubCell new]; _scrub=[[NSSlider alloc] initWithFrame:NSMakeRect(0,0,320,30)]; [_scrub setCell:cell]; _scrub.minValue=0; _scrub.maxValue=1; _scrub.continuous=NO; _scrub.doubleValue=0; _scrub.target=self; _scrub.action=@selector(seekScrub); [_scrub.widthAnchor constraintEqualToConstant:320].active=YES; it.view=_scrub; out=it; }
    else if([id isEqual:kBright]){ it.view=[self imgBtn:@"sun.max.fill" sel:@selector(toggleBright)]; out=it; }
    else if([id isEqual:kVolDn]){ it.view=[self imgBtn:@"speaker.wave.1.fill" sel:@selector(volDn)]; out=it; } // icono nativo bajar volumen
    else if([id isEqual:kVolUp]){ it.view=[self imgBtn:@"speaker.wave.3.fill" sel:@selector(volUp)]; out=it; } // subir volumen
    else if([id isEqual:kBrDn]){ it.view=[self imgBtn:@"sun.min.fill" sel:@selector(brDn)]; out=it; } // bajar brillo
    else if([id isEqual:kBrUp]){ it.view=[self imgBtn:@"sun.max.fill" sel:@selector(brUp)]; out=it; } // subir brillo
    else if([id isEqual:kVol]){ SegCell *sc=[SegCell new]; sc.segs=10; _volSlider=[[NSSlider alloc] initWithFrame:NSMakeRect(0,0,124,30)]; [_volSlider setCell:sc]; _volSlider.minValue=0; _volSlider.maxValue=10; _volSlider.continuous=YES; _volSlider.target=self; _volSlider.action=@selector(volSlid);
        NSString *v=runOSA(@"output volume of (get volume settings)"); _volSlider.doubleValue=round((v?v.doubleValue:40)/10.0); _lastVol=(int)_volSlider.doubleValue;
        [_volSlider.widthAnchor constraintEqualToConstant:124].active=YES; it.view=_volSlider; out=it; }
    else if([id isEqual:kBright10]){ SegCell *sc=[SegCell new]; sc.segs=10; _brightSlider=[[NSSlider alloc] initWithFrame:NSMakeRect(0,0,520,30)]; [_brightSlider setCell:sc]; _brightSlider.minValue=1; _brightSlider.maxValue=10; _brightSlider.continuous=YES; _brightSlider.target=self; _brightSlider.action=@selector(brightSlid);
        _brightSlider.doubleValue=fmax(1,round(brightGet()*10)); [_brightSlider.widthAnchor constraintEqualToConstant:520].active=YES; it.view=_brightSlider; out=it; }
    if(out)_cache[id]=out; return out;
}
- (void)noop{}
- (void)openClaude{ NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/open"; t.arguments=@[@"-b",@"com.anthropic.claudefordesktop"]; @try{[t launch];}@catch(__unused NSException *e){} }
- (void)mPrev{ transport(_player,@"previous track"); }
- (void)mNext{ transport(_player,@"next track"); }
- (void)mPlay{ transport(_player,@"playpause"); }
- (void)openPlayer{ NSString *b=[_player isEqualToString:@"Spotify"]?@"com.spotify.client":([_player isEqualToString:@"Music"]?@"com.apple.Music":nil); if(!b)return;
    NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/open"; t.arguments=@[@"-b",b]; @try{[t launch];}@catch(__unused NSException *e){} }
- (void)fetchWeather{
    _wfetchT=CFAbsoluteTimeGetCurrent();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        double lat=_wlat, lon=_wlon; NSString *city=_wcity;
        if(lat==0 && lon==0){
            NSData *g=[NSData dataWithContentsOfURL:[NSURL URLWithString:@"https://ipapi.co/json/"]];
            if(g){ NSDictionary *j=[NSJSONSerialization JSONObjectWithData:g options:0 error:nil];
                if([j[@"latitude"] isKindOfClass:[NSNumber class]]){ lat=[j[@"latitude"] doubleValue]; lon=[j[@"longitude"] doubleValue]; city=j[@"city"]; } }
            if(lat==0 && lon==0)return; // sin ubicación: se reintenta en el próximo refresco
            _wlat=lat; _wlon=lon; _wcity=city;
        }
        NSString *u=[NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code&hourly=precipitation_probability&daily=sunrise,sunset,temperature_2m_max,temperature_2m_min,weather_code&timezone=auto&forecast_days=1",lat,lon];
        NSData *w=[NSData dataWithContentsOfURL:[NSURL URLWithString:u]]; if(!w)return;
        NSDictionary *j=[NSJSONSerialization JSONObjectWithData:w options:0 error:nil]; if(!j)return;
        NSDictionary *cur=j[@"current"],*day=j[@"daily"]; if(!cur||!day)return;
        double temp=[cur[@"temperature_2m"] doubleValue]; int code=[cur[@"weather_code"] intValue];
        NSString *sr=[day[@"sunrise"] firstObject],*ss=[day[@"sunset"] firstObject];
        double hi=[[day[@"temperature_2m_max"] firstObject] doubleValue], lo=[[day[@"temperature_2m_min"] firstObject] doubleValue];
        int srM=(sr.length>=16)?[[sr substringWithRange:NSMakeRange(11,2)] intValue]*60+[[sr substringWithRange:NSMakeRange(14,2)] intValue]:0;
        int ssM=(ss.length>=16)?[[ss substringWithRange:NSMakeRange(11,2)] intValue]*60+[[ss substringWithRange:NSMakeRange(14,2)] intValue]:0;
        NSArray *rain=j[@"hourly"][@"precipitation_probability"]; if(![rain isKindOfClass:[NSArray class]])rain=nil;
        NSDateFormatter *df=[NSDateFormatter new]; df.dateFormat=@"dd/MM/yy"; NSString *dateStr=[df stringFromDate:[NSDate date]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(_weather){ _weather.tempC=temp; _weather.code=code; _weather.city=_wcity; _weather.hi=hi; _weather.lo=lo; _weather.sunriseMin=srM; _weather.sunsetMin=ssM; _weather.rainProb=rain; _weather.dateStr=dateStr; _weather.southern=(_wlat<0); _weather.loaded=YES; _weather.needsDisplay=YES; }
        });
    });
}
- (void)seekScrub{ double f=_scrub.doubleValue; NSString *p=_player; double dur=_dur; _lastScrub=CFAbsoluteTimeGetCurrent(); _elapsed=f*dur; if(!p||dur<=0)return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0), ^{ runOSA([NSString stringWithFormat:@"tell application \"%@\" to set player position to %.1f",p,f*dur]); }); }
- (void)setVol10:(int)lv{ dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0), ^{ runOSA([NSString stringWithFormat:@"set volume output volume %d",lv*10]); }); }
- (void)volSlid{ int lv=(int)llround(_volSlider.doubleValue); if(lv!=_lastVol){ _lastVol=lv; [self setVol10:lv]; } [_volSlider setNeedsDisplay:YES]; }
- (void)brightSlid{ int lv=(int)llround(_brightSlider.doubleValue); brightSet(lv*0.1f); [_brightSlider setNeedsDisplay:YES]; }
- (void)volDn{ int lv=(int)llround(_volSlider.doubleValue)-1; if(lv<0)lv=0; _volSlider.doubleValue=lv; _lastVol=lv; [_volSlider setNeedsDisplay:YES]; [self setVol10:lv]; }
- (void)volUp{ int lv=(int)llround(_volSlider.doubleValue)+1; if(lv>10)lv=10; _volSlider.doubleValue=lv; _lastVol=lv; [_volSlider setNeedsDisplay:YES]; [self setVol10:lv]; }
- (void)brDn{ int lv=(int)llround(_brightSlider.doubleValue)-1; if(lv<1)lv=1; _brightSlider.doubleValue=lv; [_brightSlider setNeedsDisplay:YES]; brightSet(lv*0.1f); }
- (void)brUp{ int lv=(int)llround(_brightSlider.doubleValue)+1; if(lv>10)lv=10; _brightSlider.doubleValue=lv; [_brightSlider setNeedsDisplay:YES]; brightSet(lv*0.1f); }

- (void)refreshMedia{
    NSString *p=activePlayer(); _player=p;
    if(!p){ if(_now){_now.song=nil;_now.artist=nil;_now.art=nil;_now.needsDisplay=YES;} _playing=NO; _dur=0; return; }
    dispatch_async(_mq, ^{
        NSString *durExpr=[p isEqualToString:@"Spotify"]?@"((duration of current track)/1000)":@"(duration of current track)";
        NSString *artExpr=[p isEqualToString:@"Spotify"]?@"(artwork url of current track)":@"\"\"";
        NSString *script=[NSString stringWithFormat:@"tell application \"%@\"\nset o to \"\"\ntry\nset o to (player state as text) & \"@@@\" & (name of current track) & \"@@@\" & (artist of current track) & \"@@@\" & (player position) & \"@@@\" & %@ & \"@@@\" & %@\nend try\nreturn o\nend tell",p,durExpr,artExpr];
        NSString *r=runOSA(script); NSArray *f=[r componentsSeparatedByString:@"@@@"];
        NSString *state=f.count>0?f[0]:@"", *title=f.count>1?f[1]:@"", *artist=f.count>2?f[2]:@"", *arturl=f.count>5?f[5]:@"";
        double pos=f.count>3?[f[3] doubleValue]:0, dur=f.count>4?[f[4] doubleValue]:0; BOOL playing=[state isEqualToString:@"playing"];
        __block NSImage *art=nil; NSString *key=[NSString stringWithFormat:@"%@|%@",title,artist];
        if(arturl.length && ![key isEqualToString:_artTrack]){ NSData *dd=[NSData dataWithContentsOfURL:[NSURL URLWithString:arturl]]; if(dd)art=[[NSImage alloc] initWithData:dd]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            _dur=dur; _playing=playing; if(CFAbsoluteTimeGetCurrent()-_lastScrub>1.2) _elapsed=pos;
            if(_playBtn)_playBtn.image=[NSImage imageWithSystemSymbolName:(playing?@"pause.fill":@"play.fill") accessibilityDescription:nil];
            if(_scrub && dur>0 && CFAbsoluteTimeGetCurrent()-_lastScrub>1.2) _scrub.doubleValue=fmin(1.0,pos/dur);
            if(_now){ _now.song=title; _now.artist=artist; if(art){ _now.art=art; _artTrack=key; } if(!arturl.length)_now.art=nil; _now.needsDisplay=YES; }
        });
    });
}
@end
static void psCB(void *ctx){ AppDelegate *d=(__bridge AppDelegate*)ctx; dispatch_async(dispatch_get_main_queue(),^{[d powerChanged];}); }

NSImage* claudeMark(CGFloat s, NSColor *color){ NSImage *img=[[NSImage alloc] initWithSize:NSMakeSize(s,s)]; [img lockFocus]; [color set];
    NSPoint c=NSMakePoint(s/2,s/2); int N=11; CGFloat inner=s*0.06,base=s*0.44,wdt=s*0.072;
    for(int i=0;i<N;i++){ CGFloat a=(2*M_PI*i)/N-M_PI/2, len=base*(0.80+0.20*((i%2)?1.0:0.62)); NSBezierPath *sp=[NSBezierPath bezierPath]; sp.lineWidth=wdt; sp.lineCapStyle=NSLineCapStyleRound;
        [sp moveToPoint:NSMakePoint(c.x+cos(a)*inner,c.y+sin(a)*inner)]; [sp lineToPoint:NSMakePoint(c.x+cos(a)*len,c.y+sin(a)*len)]; [sp stroke]; }
    [img unlockFocus]; return img; }

int main(void){ @autoreleasepool { NSApplication *a=[NSApplication sharedApplication]; AppDelegate *d=[AppDelegate new]; a.delegate=d; [a setActivationPolicy:NSApplicationActivationPolicyAccessory]; [a run]; } return 0; }
