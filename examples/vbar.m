#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

extern void DFRElementSetControlStripPresenceForIdentifier(NSString *identifier, BOOL present);
extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL show);
@interface NSTouchBarItem (P)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
@end
@interface NSTouchBar (P)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar systemTrayItemIdentifier:(NSString *)ident;
@end

static NSTouchBarItemIdentifier const kTray   = @"com.mati.vbar.tray";
static NSTouchBarItemIdentifier const kClock  = @"com.mati.vbar.clock";
static NSTouchBarItemIdentifier const kVideo  = @"com.mati.vbar.video";
static NSTouchBarItemIdentifier const kClaude = @"com.mati.vbar.claude";

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
@end
@implementation AppDelegate {
    NSTouchBar *_bar; NSButton *_clock; NSTimer *_t;
    AVQueuePlayer *_qp; AVPlayerLooper *_loop; // refs fuertes (gotcha clásico)
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSCustomTouchBarItem *tray = [[NSCustomTouchBarItem alloc] initWithIdentifier:kTray];
    NSButton *tb = [NSButton buttonWithTitle:@"⚡" target:self action:@selector(present)];
    tb.bezelColor=[NSColor systemOrangeColor]; tray.view=tb;
    [NSTouchBarItem addSystemTrayItem:tray];
    DFRElementSetControlStripPresenceForIdentifier(kTray, YES);
    _bar=[NSTouchBar new]; _bar.delegate=self;
    _bar.defaultItemIdentifiers=@[kClock,@"NSTouchBarItemIdentifierFlexibleSpace",kVideo,@"NSTouchBarItemIdentifierFlexibleSpace",kClaude];
    [self present];
    _t=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tickClock) userInfo:nil repeats:YES];
    [self tickClock];
    NSLog(@"vbar presentada");
}
- (void)present { DFRSystemModalShowsCloseBoxWhenFrontMost(NO); [NSTouchBar presentSystemModalTouchBar:_bar systemTrayItemIdentifier:kTray]; }
- (void)tickClock { NSDateFormatter *df=[NSDateFormatter new]; df.dateFormat=@"HH:mm"; _clock.title=[df stringFromDate:[NSDate date]]; }
- (NSTouchBarItem *)touchBar:(NSTouchBar *)t makeItemForIdentifier:(NSTouchBarItemIdentifier)id {
    NSCustomTouchBarItem *it=[[NSCustomTouchBarItem alloc] initWithIdentifier:id];
    if ([id isEqual:kClock]) {
        _clock=[NSButton buttonWithTitle:@"--:--" target:self action:@selector(noop)];
        _clock.bordered=NO; _clock.font=[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightMedium];
        it.view=_clock;
    } else if ([id isEqual:kVideo]) {
        NSView *v=[[NSView alloc] initWithFrame:NSMakeRect(0,0,620,30)];
        v.wantsLayer=YES; v.layer.cornerRadius=6; v.layer.masksToBounds=YES;
        NSArray *av=NSProcessInfo.processInfo.arguments; // video: primer argumento, o assets/plasma.mp4 desde la carpeta actual
        NSURL *url=[NSURL fileURLWithPath:av.count>1?av[1]:@"assets/plasma.mp4"];
        AVPlayerItem *pi=[AVPlayerItem playerItemWithURL:url];
        _qp=[AVQueuePlayer queuePlayerWithItems:@[]]; _qp.muted=YES;
        _loop=[AVPlayerLooper playerLooperWithPlayer:_qp templateItem:pi];
        AVPlayerLayer *pl=[AVPlayerLayer playerLayerWithPlayer:_qp];
        pl.frame=v.bounds; pl.videoGravity=AVLayerVideoGravityResize; // estira a lo largo y alto
        pl.autoresizingMask=kCALayerWidthSizable|kCALayerHeightSizable;
        [v.layer addSublayer:pl];
        [_qp play];
        [v.widthAnchor constraintEqualToConstant:620].active=YES;
        [v.heightAnchor constraintEqualToConstant:30].active=YES;
        it.view=v;
    } else if ([id isEqual:kClaude]) {
        NSButton *c=[NSButton buttonWithTitle:@"Claude" target:self action:@selector(openClaude)];
        c.bezelColor=[NSColor colorWithRed:0.85 green:0.47 blue:0.34 alpha:1.0]; c.font=[NSFont boldSystemFontOfSize:14];
        it.view=c;
    }
    return it;
}
- (void)noop {}
- (void)openClaude { NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/open"; t.arguments=@[@"-b",@"com.anthropic.claudefordesktop"]; @try{[t launch];}@catch(__unused NSException *e){} }
@end
int main(void){ @autoreleasepool { NSApplication *a=[NSApplication sharedApplication]; AppDelegate *d=[AppDelegate new]; a.delegate=d; [a setActivationPolicy:NSApplicationActivationPolicyAccessory]; [a run]; } return 0; }
