#import <AppKit/AppKit.h>

// --- API privada C (DFRFoundation) ---
extern void DFRElementSetControlStripPresenceForIdentifier(NSString *identifier, BOOL present);

// --- método privado de AppKit ---
@interface NSTouchBarItem (DFRPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
@end

static NSTouchBarItemIdentifier const kBtnId = @"com.mati.matibar.hello";

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSCustomTouchBarItem *_trayItem;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:kBtnId];
    NSButton *b = [NSButton buttonWithTitle:@"⚡ MATI" target:self action:@selector(tap:)];
    b.bezelColor = [NSColor systemOrangeColor];
    item.view = b;
    _trayItem = item;

    [NSTouchBarItem addSystemTrayItem:item];
    DFRElementSetControlStripPresenceForIdentifier(kBtnId, YES);
    NSLog(@"MatiBar PoC: tray item registrado en el control strip");
}
- (void)tap:(id)sender { NSLog(@"MatiBar: TAP recibido"); }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [[AppDelegate alloc] init];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
