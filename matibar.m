#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <Accelerate/Accelerate.h>
#import <os/lock.h>

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
  kViz=@"com.mati.mb.viz", kFlex=@"NSTouchBarItemIdentifierFlexibleSpace";
static double BATT_W=806.0, NOW_W=160.0, VIZ_W=880.0;
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

// ---------- mute del sistema (CoreAudio: rapido, sin procesos) ----------
static AudioDeviceID defOut(void){ AudioDeviceID d=0; UInt32 sz=sizeof(d);
    AudioObjectPropertyAddress a={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&sz,&d); return d; }
static int muteGet(void){ AudioDeviceID d=defOut(); UInt32 m=0,sz=sizeof(m);
    AudioObjectPropertyAddress a={kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};
    if(!d||!AudioObjectHasProperty(d,&a))return -1; return AudioObjectGetPropertyData(d,&a,0,NULL,&sz,&m)==noErr?(int)m:-1; }
static void muteSet(BOOL on){ AudioDeviceID d=defOut(); UInt32 m=on?1:0;
    AudioObjectPropertyAddress a={kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};
    if(d&&AudioObjectHasProperty(d,&a)) AudioObjectSetPropertyData(d,&a,0,NULL,sizeof(m),&m);
    else runOSA(on?@"set volume with output muted":@"set volume without output muted"); }

// ---------- SF Symbol en un color fijo (los template salen negros si se dibujan directo) ----------
static NSImage* symColor(NSString *name,CGFloat pt,NSFontWeight w,NSColor *c){
    NSImage *i=[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]; if(!i)return nil;
    NSImageSymbolConfiguration *cf=[[NSImageSymbolConfiguration configurationWithPointSize:pt weight:w] configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[c]]];
    return [i imageWithSymbolConfiguration:cf]; }

// ---------- altitud real de la luna (algoritmo de SunCalc), en radianes ----------
static double moonAlt(NSDate *date,double lat,double lng){
    double rad=M_PI/180.0,e=rad*23.4397, d=[date timeIntervalSince1970]/86400.0-0.5+2440588.0-2451545.0;
    double L=rad*(218.316+13.176396*d),M=rad*(134.963+13.064993*d),F=rad*(93.272+13.229350*d);
    double l=L+rad*6.289*sin(M),b=rad*5.128*sin(F);
    double ra=atan2(sin(l)*cos(e)-tan(b)*sin(e),cos(l)),dec=asin(sin(b)*cos(e)+cos(b)*sin(e)*sin(l));
    double H=rad*(280.16+360.9856235*d)-rad*(-lng)-ra, phi=rad*lat;
    return asin(sin(phi)*sin(dec)+cos(phi)*cos(dec)*cos(H)); }

// ---------- luna con su fase real (hemisferio-aware) ----------
static double moonPhase(void);
static void drawMoon(CGFloat x,CGFloat y,CGFloat r,BOOL southern){
    double mp=moonPhase(),k=(1-cos(2*M_PI*mp))/2; BOOL litRight=((mp<0.5)!=southern);
    NSBezierPath *disk=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-r,y-r,2*r,2*r)];
    [NSGraphicsContext saveGraphicsState]; [disk addClip];
    [[NSColor colorWithWhite:0.96 alpha:1] setFill]; [disk fill];
    CGFloat dx=(litRight?-1:1)*2*r*k; [[NSColor colorWithWhite:0.18 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x+dx-r,y-r,2*r,2*r)] fill];
    [NSGraphicsContext restoreGraphicsState]; }

// ---------- visualizador: captura del audio del sistema (Core Audio tap, macOS 14.2+) + FFT ----------
// Tap global de todo lo que suena (Spotify, navegador, juegos), excluyendo a MatiBar. Solo corre mientras
// el visualizador está abierto; al cerrarlo se destruyen la tap y el dispositivo agregado.
#define VZ_BANDS 5
#define VZ_N 1024     // ventana corta: 5 bandas (el bombo que hace latir al espejo)
#define VZ_RING 4096  // ventana larga: espectro fino (graves bien separados)
#define VZ_SPEC 80    // columnas de frecuencia del espejo (30 Hz -> 16 kHz, logarítmicas)
#define VZ_FINE 800   // puntos del mapa de frecuencias del reactor (una frecuencia fija por píxel)
static float gBand[VZ_BANDS], gSmooth[VZ_BANDS], gPeakDb[VZ_BANDS]={-60,-60,-60,-60,-60}, gMeanDb[VZ_BANDS]={-60,-60,-60,-60,-60};
static os_unfair_lock gBandLock=OS_UNFAIR_LOCK_INIT;
static AudioObjectID gTap=kAudioObjectUnknown, gAgg=kAudioObjectUnknown; static AudioDeviceIOProcID gProc=NULL;
static FFTSetup gFFT; static float gWin[VZ_N], gWin4[VZ_RING], gRing[VZ_RING], gSpec[VZ_FINE], gSpecS[VZ_FINE], gSpecPeak=-60; static volatile int gSpecN, gSpecBal; static int gRingPos, gNew; static double gSR=48000;
// gSpecN: puntos del espectro que se calculan (0 = apagado, VZ_SPEC espejo, VZ_FINE reactor)
static NSString *gTapErr; static volatile float gRms;
// Espectro logarítmico de n puntos (80 espejo / 800 reactor) con FFT de 4096. Ganancia automática global + inclinación
// de +4.5 dB/octava (la música trae mucha más energía en graves; sin esto los agudos nunca se encenderían).
// Frecuencia del punto j (de n). Logarítmica: cada octava recibe los mismos puntos (graves con muy pocas tajadas
// de la FFT por punto, agudos con cientos). Balanceada (estilo 5): lineal, una tajada exacta por punto, hasta el cruce
// donde la escala log ya da >= 1 tajada por punto; de ahí hacia arriba log. Ningún punto comparte ni inventa datos.
static double vzFreqAt(double j,int n,BOOL bal,double bin){
    if(!bal) return 30*pow(16000.0/30.0,j/(n-1));
    static double cBin=0,cN=0,f0,fc,nlin;
    if(cBin!=bin||cN!=n){ cBin=bin; cN=n; f0=3*bin; double lo=f0+bin,hi=16000;          // f0: centro de la tajada 3 (~35 Hz)
        for(int it=0;it<60;it++){ double m=(lo+hi)/2, tot=(m-f0)/bin+log(16000.0/m)*m/bin; if(tot>n-1)hi=m; else lo=m; }
        fc=(lo+hi)/2; nlin=(fc-f0)/bin; }
    return j<=nlin ? f0+j*bin : fc*exp((j-nlin)*bin/fc);
}
static void vizSpectrum(float *out,int n,float rms){
    static float buf[VZ_RING],re[VZ_RING/2],im[VZ_RING/2],pw[VZ_RING/2];
    for(int i=0;i<VZ_RING;i++) buf[i]=gRing[(gRingPos+i)&(VZ_RING-1)];
    vDSP_vmul(buf,1,gWin4,1,buf,1,VZ_RING);
    DSPSplitComplex sc={re,im}; vDSP_ctoz((DSPComplex*)buf,2,&sc,1,VZ_RING/2); vDSP_fft_zrip(gFFT,&sc,1,12,FFT_FORWARD);
    vDSP_zvmags(&sc,1,pw,1,VZ_RING/2);
    const double bin=gSR/VZ_RING; const BOOL bal=gSpecBal; float db[VZ_FINE], mx=-200;
    for(int j=0;j<n;j++){
        double fc=vzFreqAt(j,n,bal,bin), kl=vzFreqAt(j-0.5,n,bal,bin)/bin, kh=vzFreqAt(j+0.5,n,bal,bin)/bin, p=0;
        if(kh-kl<1.5){ double k=fc/bin; int k0=(int)k; double u=k-k0; if(k0<1)k0=1; if(k0>VZ_RING/2-2)k0=VZ_RING/2-2; p=pw[k0]*(1-u)+pw[k0+1]*u; }  // graves: interpolar entre bins
        else { int a=(int)ceil(kl),b=(int)floor(kh); if(b>VZ_RING/2-1)b=VZ_RING/2-1; for(int k=a;k<=b;k++)p+=pw[k]; p/=fmax(1,b-a+1); }
        db[j]=10*log10f((float)p+1e-12f)+4.5f*log2f((float)fc/1000); if(db[j]>mx)mx=db[j]; }
    gSpecPeak=fmaxf(mx,gSpecPeak-0.05f); if(gSpecPeak<-59 && rms>=2e-4f)gSpecPeak=mx;
    for(int j=0;j<n;j++){ float e=(db[j]-(gSpecPeak-34))/34; e=e<0?0:(e>1?1:e); e=powf(e,1.6f); if(rms<2e-4f)e=0;
        gSpecS[j]+=(e-gSpecS[j])*(e>gSpecS[j]?0.7f:0.3f); out[j]=gSpecS[j]; }
}
static void vizAnalyze(void){
    float buf[VZ_N],re[VZ_N/2],im[VZ_N/2],rms=0;
    for(int i=0;i<VZ_N;i++) buf[i]=gRing[(gRingPos-VZ_N+i)&(VZ_RING-1)];
    vDSP_rmsqv(buf,1,&rms,VZ_N); gRms=rms;
    vDSP_vmul(buf,1,gWin,1,buf,1,VZ_N);
    DSPSplitComplex sc={re,im}; vDSP_ctoz((DSPComplex*)buf,2,&sc,1,VZ_N/2); vDSP_fft_zrip(gFFT,&sc,1,10,FFT_FORWARD);
    static const float edges[VZ_BANDS+1]={30,120,400,1500,5000,16000}; // graves -> agudos
    float out[VZ_BANDS];
    for(int b=0;b<VZ_BANDS;b++){
        int k0=(int)fmax(1,edges[b]*VZ_N/gSR), k1=(int)fmin(VZ_N/2-1,edges[b+1]*VZ_N/gSR); double p=0;
        for(int k=k0;k<=k1;k++) p+=re[k]*re[k]+im[k]*im[k];
        p/=fmax(1,k1-k0+1); float db=10*log10f((float)p+1e-12f);
        gPeakDb[b]=fmaxf(db,gPeakDb[b]-0.03f);                              // ganancia automática por banda
        if(gMeanDb[b]<-59 && rms>=2e-4f){ gMeanDb[b]=db; gPeakDb[b]=db+6; }   // primer audio: arrancar sin destello
        gMeanDb[b]+=(db-gMeanDb[b])*0.03f;                                   // promedio reciente (~0.4 s)
        float lvl=(db-(gPeakDb[b]-30))/30; lvl=lvl<0?0:(lvl>1?1:lvl);
        float hit=(db-gMeanDb[b]-1.5f)/8; hit=hit<0?0:(hit>1?1:hit);              // golpe: cuánto sobresale del promedio
        float e=0.3f*lvl*lvl*lvl+0.8f*hit; e=e>1?1:e; if(rms<2e-4f)e=0;     // nivel sostenido tenue, golpes brillantes
        gSmooth[b]+= (e-gSmooth[b])*(e>gSmooth[b]?0.7f:0.18f);               // sube rápido, baja suave
        out[b]=gSmooth[b]; }
    static int hop; static float spec[VZ_FINE]; int sn=gSpecN; BOOL doSpec=sn>0 && (++hop&1); if(doSpec) vizSpectrum(spec,sn,rms); // ~47 veces/s alcanza para 30 fps
    os_unfair_lock_lock(&gBandLock); memcpy(gBand,out,sizeof out); if(doSpec && sn==gSpecN)memcpy(gSpec,spec,sizeof(float)*sn); os_unfair_lock_unlock(&gBandLock);
    // (sn!=gSpecN: cambió de estilo a mitad del cálculo -> ese espectro se descarta)
}
static inline void vizPush(float v){ gRing[gRingPos]=v; gRingPos=(gRingPos+1)&(VZ_RING-1); if(++gNew>=VZ_N/2){ gNew=0; vizAnalyze(); } }
static void vizConsume(const AudioBufferList *in,AudioStreamBasicDescription fmt){
    if(!in||in->mNumberBuffers==0||fmt.mBitsPerChannel!=32||!(fmt.mFormatFlags&kAudioFormatFlagIsFloat))return;
    // el dispositivo agregado entrega varios streams (el de la tap y el del dispositivo de salida, mudo): se mezclan todos
    UInt32 n=0; for(UInt32 k=0;k<in->mNumberBuffers;k++){ UInt32 ch=in->mBuffers[k].mNumberChannels?:1; UInt32 m=in->mBuffers[k].mDataByteSize/4/ch; if(m>n)n=m; }
    if(!n)return; if(n>4096)n=4096; float mix[n]; memset(mix,0,sizeof(float)*n); UInt32 tot=0;
    for(UInt32 k=0;k<in->mNumberBuffers;k++){ const float *d=in->mBuffers[k].mData; if(!d)continue; UInt32 ch=in->mBuffers[k].mNumberChannels?:1, m=in->mBuffers[k].mDataByteSize/4/ch;
        for(UInt32 i=0;i<m&&i<n;i++) for(UInt32 c=0;c<ch;c++) mix[i]+=d[i*ch+c];
        tot+=ch; }
    if(!tot)return; float inv=2.0f/tot; for(UInt32 i=0;i<n;i++) vizPush(mix[i]*inv);
}
static void vizStop(void){
    if(gAgg!=kAudioObjectUnknown){ if(gProc){ AudioDeviceStop(gAgg,gProc); AudioDeviceDestroyIOProcID(gAgg,gProc); gProc=NULL; }
        AudioHardwareDestroyAggregateDevice(gAgg); gAgg=kAudioObjectUnknown; }
    if(gTap!=kAudioObjectUnknown){ if(@available(macOS 14.2,*)) AudioHardwareDestroyProcessTap(gTap); gTap=kAudioObjectUnknown; }
    os_unfair_lock_lock(&gBandLock); memset(gBand,0,sizeof gBand); os_unfair_lock_unlock(&gBandLock); memset(gSmooth,0,sizeof gSmooth);
    for(int b=0;b<VZ_BANDS;b++){ gMeanDb[b]=-60; gPeakDb[b]=-60; } memset(gSpecS,0,sizeof gSpecS); gSpecPeak=-60;
    os_unfair_lock_lock(&gBandLock); memset(gSpec,0,sizeof gSpec); os_unfair_lock_unlock(&gBandLock);
}
static BOOL vizStart(void){
    if(gAgg!=kAudioObjectUnknown)return YES; gTapErr=nil;
    if(@available(macOS 14.2,*)){
        CATapDescription *d=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
        d.UUID=[NSUUID UUID]; d.name=@"MatiBar visualizer"; d.privateTap=YES; d.muteBehavior=CATapUnmuted;
        OSStatus st=AudioHardwareCreateProcessTap(d,&gTap);
        if(st!=noErr){ gTap=kAudioObjectUnknown; gTapErr=[NSString stringWithFormat:@"No se pudo crear la captura de audio (%d)",(int)st]; return NO; }
        UInt32 sz;
        // Solo la tap, sin subdispositivo de salida: con una salida virtual por defecto (Background Music, Loopback)
        // el agregado queda mudo, y sincronizado a los parlantes físicos puede trabar a coreaudiod.
        NSDictionary *agg=@{@"name":@"MatiBar Tap",@"uid":[NSUUID UUID].UUIDString,@"private":@YES,@"stacked":@NO,@"tapautostart":@YES,
                            @"subdevices":@[], @"taps":@[@{@"drift":@YES,@"uid":d.UUID.UUIDString}]};
        st=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg,&gAgg);
        if(st!=noErr){ gAgg=kAudioObjectUnknown; vizStop(); gTapErr=[NSString stringWithFormat:@"No se pudo armar el dispositivo de captura (%d)",(int)st]; return NO; }
        __block AudioStreamBasicDescription fmt={0}; sz=sizeof(fmt);
        AudioObjectPropertyAddress fa={kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if(AudioObjectGetPropertyData(gTap,&fa,0,NULL,&sz,&fmt)!=noErr || fmt.mSampleRate<=0 || fmt.mBitsPerChannel!=32){
            vizStop(); gTapErr=@"Formato de audio no soportado por el visualizador"; return NO; }
        gSR=fmt.mSampleRate;
        if(!gFFT){ gFFT=vDSP_create_fftsetup(12,kFFTRadix2); vDSP_hann_window(gWin,VZ_N,vDSP_HANN_NORM); vDSP_hann_window(gWin4,VZ_RING,vDSP_HANN_NORM); }
        AudioStreamBasicDescription f2=fmt;
        st=AudioDeviceCreateIOProcIDWithBlock(&gProc,gAgg,dispatch_queue_create("com.mati.mb.viz",DISPATCH_QUEUE_SERIAL),
            ^(const AudioTimeStamp*n,const AudioBufferList*in,const AudioTimeStamp*it,AudioBufferList*o,const AudioTimeStamp*ot){ vizConsume(in,f2); });
        if(st==noErr) st=AudioDeviceStart(gAgg,gProc);
        if(st!=noErr){ vizStop(); gTapErr=[NSString stringWithFormat:@"No se pudo iniciar la captura (%d)",(int)st]; return NO; }
        return YES;
    }
    gTapErr=@"El visualizador necesita macOS 14.2 o superior"; return NO;
}

// punto sobre el perimetro de un rect (sentido horario desde arriba-izq)
static NSPoint perim(NSRect r,double t){ CGFloat W=r.size.width,H=r.size.height;
    if(t<W)return NSMakePoint(NSMinX(r)+t,NSMaxY(r)); t-=W;
    if(t<H)return NSMakePoint(NSMaxX(r),NSMaxY(r)-t); t-=H;
    if(t<W)return NSMakePoint(NSMaxX(r)-t,NSMinY(r)); t-=W;
    return NSMakePoint(NSMinX(r),NSMinY(r)+t); }

static int (*_dsGet)(uint32_t,float*); static int (*_dsSet)(uint32_t,float);
static void dsInit(void){ void*h=dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",RTLD_NOW);
    if(h){ _dsGet=dlsym(h,"DisplayServicesGetBrightness"); _dsSet=dlsym(h,"DisplayServicesSetBrightness"); } }
static float brightGet(void){ float b=1; if(_dsGet)_dsGet(CGMainDisplayID(),&b); return b; }
static void brightSet(float v){ if(_dsSet)_dsSet(CGMainDisplayID(), v<0.08?0.08:(v>1?1:v)); }
static void brightSetRaw(float v){ if(_dsSet)_dsSet(CGMainDisplayID(), v<0?0:(v>1?1:v)); } // sin piso: solo para el blackout

// ---------- luz del teclado (CoreBrightness, privado) ----------
static id _kbdC; static unsigned long long _kbdID;
static BOOL kbdInit(void){ if(_kbdC)return YES;
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",RTLD_NOW);
    Class K=NSClassFromString(@"KeyboardBrightnessClient"); if(!K)return NO; id c=[K new];
    NSArray *a=((id(*)(id,SEL))objc_msgSend)(c,NSSelectorFromString(@"copyKeyboardBacklightIDs")); if(!a.count)return NO;
    _kbdC=c; _kbdID=[a[0] unsignedLongLongValue]; return YES; }
static float kbdGet(void){ if(!kbdInit())return -1; return ((float(*)(id,SEL,unsigned long long))objc_msgSend)(_kbdC,NSSelectorFromString(@"brightnessForKeyboard:"),_kbdID); }
static void kbdSet(float v){ if(!kbdInit())return; ((void(*)(id,SEL,float,unsigned long long))objc_msgSend)(_kbdC,NSSelectorFromString(@"setBrightness:forKeyboard:"),v,_kbdID); }
static BOOL kbdAutoGet(void){ if(!kbdInit())return NO; return ((BOOL(*)(id,SEL,unsigned long long))objc_msgSend)(_kbdC,NSSelectorFromString(@"isAutoBrightnessEnabledForKeyboard:"),_kbdID); }
static void kbdAutoSet(BOOL on){ if(!kbdInit())return; ((void(*)(id,SEL,BOOL,unsigned long long))objc_msgSend)(_kbdC,NSSelectorFromString(@"enableAutoBrightness:forKeyboard:"),on,_kbdID); }

// ---------- blackout: archivo-latido + restauracion (compartido por la app y el guardian) ----------
// Mientras dure el blackout existe blackout.json con el brillo previo. La app lo "toca" cada 2s.
// Si la app muere o se cuelga, el guardian (launchd) lo ve viejo y devuelve el brillo.
static NSString* blackoutPath(void){
    NSString *d=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MatiBar"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return [d stringByAppendingPathComponent:@"blackout.json"]; }
static void shRun(NSString *cmd){ NSTask *t=[NSTask new]; t.launchPath=@"/bin/sh"; t.arguments=@[@"-c",cmd]; @try{[t launch]; [t waitUntilExit];}@catch(__unused NSException *e){} }
static void blackoutRestore(BOOL safetyFloor,BOOL restoreAppleStrip){
    NSString *p=blackoutPath(); if(![[NSFileManager defaultManager] fileExistsAtPath:p])return;
    NSData *d=[NSData dataWithContentsOfFile:p]; NSDictionary *j=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;
    if(![j isKindOfClass:[NSDictionary class]]){ j=@{}; safetyFloor=YES; } // ilegible: devolver un brillo seguro y borrarlo igual
    float b=[j[@"bright"] floatValue]; if(safetyFloor && b<0.35)b=0.5; // en emergencia, nunca volver a algo casi invisible
    dsInit(); brightSetRaw(b>0.05?b:0.5);
    if(j[@"kbd"]){ float k=[j[@"kbd"] floatValue]; if(k>=0)kbdSet(k); } if([j[@"kbdAuto"] boolValue])kbdAutoSet(YES);
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    if(restoreAppleStrip) shRun(@"defaults write com.apple.touchbar.agent PresentationModeGlobal -string appWithControlStrip; killall ControlStrip 2>/dev/null");
}
static BOOL otherMatiBarRunning(void){
    NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/pgrep"; t.arguments=@[@"-x",@"MatiBar"]; NSPipe *pp=[NSPipe pipe]; t.standardOutput=pp;
    @try{[t launch];}@catch(__unused NSException *e){ return YES; }
    NSData *d=[pp.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    for(NSString *l in [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]) if(l.length && l.intValue!=getpid()) return YES;
    return NO; }
// Guardian: lo lanza launchd SOLO mientras existe blackout.json (KeepAlive PathState). Sin costo el resto del tiempo.
static int runGuard(void){ @autoreleasepool{
    NSString *p=blackoutPath(); NSFileManager *fm=[NSFileManager defaultManager];
    double last=CFAbsoluteTimeGetCurrent(), grace=0;
    while([fm fileExistsAtPath:p]){
        double now=CFAbsoluteTimeGetCurrent(); if(now-last>6) grace=now+6; last=now; // volvió del sueño: 6 s para que la app renueve el latido
        NSDate *mt=[[fm attributesOfItemAtPath:p error:nil] fileModificationDate]; double age=mt?-[mt timeIntervalSinceNow]:999;
        BOOL alive=otherMatiBarRunning();
        if(!alive||(age>12 && now>grace)){ NSLog(@"MatiBar guard: devuelvo el brillo (app viva=%d, latido hace %.0fs)",alive,age); blackoutRestore(YES,!alive); return 0; }
        sleep(2);
    }
    return 0; } }

typedef struct { double level; BOOL charging, external, lowPower; } BattInfo;
static BattInfo readBatt(void){
    BattInfo b={0,NO,YES,NO}; BOOL acNow=NO,chgNow=NO;
    CFTypeRef info=IOPSCopyPowerSourcesInfo();
    if(info){ CFArrayRef list=IOPSCopyPowerSourcesList(info);
        if(list && CFArrayGetCount(list)>0){ CFDictionaryRef ps=IOPSGetPowerSourceDescription(info,CFArrayGetValueAtIndex(list,0));
            int cur=0,max=100; CFNumberRef c=(CFNumberRef)CFDictionaryGetValue(ps,CFSTR(kIOPSCurrentCapacityKey)),m=(CFNumberRef)CFDictionaryGetValue(ps,CFSTR(kIOPSMaxCapacityKey));
            if(c)CFNumberGetValue(c,kCFNumberIntType,&cur); if(m)CFNumberGetValue(m,kCFNumberIntType,&max); b.level=max>0?(double)cur/max:0;
            // IOPS se actualiza en el mismo instante que el chime de carga (antes que AppleSmartBattery)
            CFStringRef st=(CFStringRef)CFDictionaryGetValue(ps,CFSTR(kIOPSPowerSourceStateKey));
            if(st) acNow=(CFStringCompare(st,CFSTR(kIOPSACPowerValue),0)==kCFCompareEqualTo);
            CFBooleanRef ic=(CFBooleanRef)CFDictionaryGetValue(ps,CFSTR(kIOPSIsChargingKey)); if(ic) chgNow=CFBooleanGetValue(ic); }
        if(list)CFRelease(list); CFRelease(info); }
    io_service_t svc=IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if(svc){ CFMutableDictionaryRef pr=NULL;
        if(IORegistryEntryCreateCFProperties(svc,&pr,kCFAllocatorDefault,0)==KERN_SUCCESS && pr){
            CFBooleanRef chg=(CFBooleanRef)CFDictionaryGetValue(pr,CFSTR("IsCharging")), ext=(CFBooleanRef)CFDictionaryGetValue(pr,CFSTR("ExternalConnected"));
            if(chg)b.charging=CFBooleanGetValue(chg); if(ext)b.external=CFBooleanGetValue(ext); CFRelease(pr); }
        IOObjectRelease(svc); }
    b.external=b.external||acNow; b.charging=b.charging||chgNow;
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

// Boton con long-press: toque corto = action; mantener >= 1s = onLong.
// El Touch Bar entrega toques directos (no clics de mouse), asi que hace falta un gesture recognizer
// con allowedTouchTypes = Direct. Tras un long-press se descarta el toque corto que llega al soltar.
@interface LPButton : NSButton
@property (copy,nonatomic) void(^onLong)(void);
@end
@implementation LPButton{ NSPressGestureRecognizer *_lpRec; BOOL _swallow; int _lpGen; }
- (void)setOnLong:(void(^)(void))b{
    _onLong=[b copy];
    if(b && !_lpRec){ _lpRec=[[NSPressGestureRecognizer alloc] initWithTarget:self action:@selector(lpFired:)];
        _lpRec.minimumPressDuration=1.0; _lpRec.allowedTouchTypes=NSTouchTypeMaskDirect; [self addGestureRecognizer:_lpRec]; }
}
- (void)lpFired:(NSPressGestureRecognizer*)g{
    if(g.state==NSGestureRecognizerStateEnded||g.state==NSGestureRecognizerStateCancelled){ // al soltar: el toque que llegue ahora se descarta;
        int gen=++_lpGen;                                                                   // si no llega, el filtro se apaga solo
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if(self->_lpGen==gen)self->_swallow=NO; });
        return; }
    if(g.state!=NSGestureRecognizerStateBegan)return;
    _swallow=YES; _lpGen++; self.alphaValue=0.35; // destello de confirmación
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.18*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ self.alphaValue=1; });
    if(_onLong)_onLong();
}
- (BOOL)sendAction:(SEL)a to:(id)t{ if(_swallow){ _swallow=NO; return NO; } return [super sendAction:a to:t]; } // un long-press nunca dispara también el toque
@end

// Now info: carátula + título·artista. Tap = abre el player; mantener = loop de la canción.
@interface NowView : LPButton
@property (strong) NSImage *art; @property (copy) NSString *song,*artist; @property BOOL loop; @property int loopStyle; @property double phase; @property (strong) NSColor *loopTint;
@end
@implementation NowView
- (NSSize)intrinsicContentSize{ return NSMakeSize(NOW_W,30); }
- (BOOL)isFlipped{ return NO; }
- (void)drawRect:(NSRect)d{
    NSRect b=self.bounds; CGFloat as=b.size.height-9; NSRect ar=NSMakeRect(5,4.5,as,as);
    [NSGraphicsContext saveGraphicsState]; [[NSBezierPath bezierPathWithRoundedRect:ar xRadius:4 yRadius:4] addClip];
    if(self.art) [self.art drawInRect:ar fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    else { [[NSColor colorWithWhite:0.3 alpha:1] setFill]; NSRectFill(ar);
        [@"♪" drawAtPoint:NSMakePoint(ar.origin.x+as/2-4,ar.origin.y+as/2-9) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:[NSColor colorWithWhite:0.7 alpha:1]}]; }
    [NSGraphicsContext restoreGraphicsState];
    CGFloat x=NSMaxX(ar)+7, tw=b.size.width-x-6; if(self.loop&&(self.loopStyle==3||self.loopStyle==5))tw-=13;
    NSString *info=(self.song.length?self.song:@"Nada sonando"); if(self.artist.length) info=[NSString stringWithFormat:@"%@  ·  %@",self.song,self.artist];
    NSMutableParagraphStyle *ps=[NSMutableParagraphStyle new]; ps.lineBreakMode=NSLineBreakByTruncatingTail;
    [info drawInRect:NSMakeRect(x,NSMidY(b)-8,tw,16) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:[NSColor colorWithWhite:0.95 alpha:1],NSParagraphStyleAttributeName:ps}];
    if(self.loop)[self drawLoop:b art:ar textEnd:x+tw];
}
// 4 estilos de "modo loop", todos sin fondo de color
- (void)drawLoop:(NSRect)b art:(NSRect)ar textEnd:(CGFloat)te{
    NSRect fr=NSInsetRect(b,1,1.5); CGFloat rr=7; int s=self.loopStyle<1?1:self.loopStyle; NSColor *T=self.loopTint?:[NSColor whiteColor];
    BOOL frame1=(s==1), orbit=(s==2||s==5), corners=(s==3), glyph=(s==3||s==5), badge=(s==4);
    if(frame1){ // 1) marco con flechas: el símbolo de repetir estirado alrededor de la canción
        NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:fr xRadius:rr yRadius:rr]; p.lineWidth=1; [[T colorWithAlphaComponent:0.7] setStroke]; [p stroke];
        CGFloat cx=NSMidX(fr),ty=NSMaxY(fr),by=NSMinY(fr); [[T colorWithAlphaComponent:0.95] setFill];
        NSBezierPath *a1=[NSBezierPath bezierPath]; [a1 moveToPoint:NSMakePoint(cx+3.5,ty)]; [a1 lineToPoint:NSMakePoint(cx-1.5,ty+3)]; [a1 lineToPoint:NSMakePoint(cx-1.5,ty-3)]; [a1 closePath]; [a1 fill];
        NSBezierPath *a2=[NSBezierPath bezierPath]; [a2 moveToPoint:NSMakePoint(cx-3.5,by)]; [a2 lineToPoint:NSMakePoint(cx+1.5,by+3)]; [a2 lineToPoint:NSMakePoint(cx+1.5,by-3)]; [a2 closePath]; [a2 fill]; }
    if(orbit){ // 2) órbita con borde tenue y 1 punto · 5) sin borde, 2 puntos opuestos persiguiéndose
        if(s==2){ NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:fr xRadius:rr yRadius:rr]; p.lineWidth=1; [[T colorWithAlphaComponent:0.22] setStroke]; [p stroke]; }
        double per=2*(fr.size.width+fr.size.height); int balls=(s==5)?2:1;
        for(int n=0;n<balls;n++) for(int k=0;k<6;k++){ double t=fmod(self.phase*110+n*per/2-k*5,per); if(t<0)t+=per; NSPoint q=perim(fr,t); CGFloat r=1.9-k*0.25;
            [[T colorWithAlphaComponent:0.95-k*0.16] setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(q.x-r,q.y-r,2*r,2*r)] fill]; } }
    if(corners){ // 3) esquinas tipo visor
        CGFloat L=6,x0=NSMinX(fr),x1=NSMaxX(fr),y0=NSMinY(fr),y1=NSMaxY(fr);
        NSBezierPath *c=[NSBezierPath bezierPath]; c.lineWidth=1.2;
        [c moveToPoint:NSMakePoint(x0,y1-L)]; [c lineToPoint:NSMakePoint(x0,y1)]; [c lineToPoint:NSMakePoint(x0+L,y1)];
        [c moveToPoint:NSMakePoint(x1-L,y1)]; [c lineToPoint:NSMakePoint(x1,y1)]; [c lineToPoint:NSMakePoint(x1,y1-L)];
        [c moveToPoint:NSMakePoint(x1,y0+L)]; [c lineToPoint:NSMakePoint(x1,y0)]; [c lineToPoint:NSMakePoint(x1-L,y0)];
        [c moveToPoint:NSMakePoint(x0+L,y0)]; [c lineToPoint:NSMakePoint(x0,y0)]; [c lineToPoint:NSMakePoint(x0,y0+L)];
        [[T colorWithAlphaComponent:0.85] setStroke]; [c stroke]; }
    if(glyph){ // 3/5) glifo repeat.1 al final del título
        NSImage *g=symColor(@"repeat.1",10,NSFontWeightSemibold,T);
        [g drawInRect:NSMakeRect(te+1,NSMidY(b)-5.5,12,11) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.95]; }
    if(badge){ // 4) insignia mínima en la esquina de la carátula, sin marco
        NSShadow *sh=[NSShadow new]; sh.shadowColor=[NSColor colorWithWhite:0 alpha:0.9]; sh.shadowBlurRadius=2.5;
        [NSGraphicsContext saveGraphicsState]; [sh set];
        NSImage *g=symColor(@"repeat.1",9,NSFontWeightBold,T);
        [g drawInRect:NSMakeRect(NSMaxX(ar)-8,NSMinY(ar)-2.5,11,10) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState]; }
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

@interface WeatherView : LPButton
@property BOOL loaded,southern; @property double tempC,hi,lo,phase,lat,lon; @property int code,sunriseMin,sunsetMin; @property (copy) NSString *city,*dateStr; @property (strong) NSArray *rainProb;
@end
@implementation WeatherView
- (NSSize)intrinsicContentSize{ return NSMakeSize(930,30); }
- (BOOL)isFlipped{ return NO; }
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
    NSString *icn=wxIcon(c,night); NSImage *ic;
    if([icn isEqualToString:@"cloud.fill"]||[icn isEqualToString:@"cloud.fog.fill"]) ic=symColor(icn,14,NSFontWeightRegular,[NSColor colorWithWhite:0.92 alpha:1]); // sin variante multicolor -> blanco
    else { ic=[NSImage imageWithSystemSymbolName:icn accessibilityDescription:nil];
        ic=[ic imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular] configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationPreferringMulticolor]]]; }
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
    // trayectoria real de la luna (azul-gris, punteada) calculada para tu ubicación
    CGFloat nowX=tlL+tlW*(nowMin/1440.0); double moonNow=-1, moonMax=0.0001;
    if(self.lat!=0||self.lon!=0){
        NSDate *d0=[[NSCalendar currentCalendar] startOfDayForDate:[NSDate date]]; double alts[145];
        for(int i=0;i<145;i++){ alts[i]=moonAlt([d0 dateByAddingTimeInterval:i*600.0],self.lat,self.lon); if(alts[i]>moonMax)moonMax=alts[i]; }
        NSBezierPath *mpth=[NSBezierPath bezierPath]; BOOL pen=NO;
        for(int i=0;i<145;i++){ CGFloat qx=tlL+tlW*(i/144.0);
            if(alts[i]>0){ NSPoint q=NSMakePoint(qx,baseY+(amp-1)*(alts[i]/moonMax)); if(!pen){ [mpth moveToPoint:NSMakePoint(qx,baseY)]; pen=YES; } [mpth lineToPoint:q]; }
            else if(pen){ [mpth lineToPoint:NSMakePoint(qx,baseY)]; pen=NO; } }
        mpth.lineWidth=1.3; CGFloat md[2]={3,2}; [mpth setLineDash:md count:2 phase:0];
        [[NSColor colorWithRed:0.64 green:0.75 blue:1.0 alpha:0.85] setStroke]; [mpth stroke];
        moonNow=moonAlt([d0 dateByAddingTimeInterval:nowMin*60.0],self.lat,self.lon);
    }
    // marcador de ahora: sol sobre su arco (de día) y luna con su fase sobre su arco (si está arriba)
    BOOL day=nowMin>=sr&&nowMin<=ss;
    [[NSColor colorWithWhite:1 alpha:0.5] setFill]; NSRectFill(NSMakeRect(nowX,baseY,1,amp+2));
    if(moonNow>0) drawMoon(nowX,baseY+(amp-1)*(moonNow/moonMax),4.5,self.southern);
    if(day){ CGFloat sy=baseY+amp*sin(M_PI*((double)(nowMin-sr)/(ss-sr))); [[NSColor colorWithRed:1 green:0.92 blue:0.45 alpha:1] setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(nowX-4,sy-4,8,8)] fill]; }
}
@end

@class AppDelegate; static void psCB(void *ctx);
// Visualizador: 5 filas de píxeles cuadrados que reaccionan al audio del sistema. Tres estilos
// (`defaults write com.mati.matibar visualizer espejo|vertical|horizontal`; mantener los píxeles los rota):
//  - espejo: cada columna es una frecuencia; graves rojos al centro, agudos azules a los bordes; crece en alto.
//  - vertical / horizontal (reactor balanceado): cada píxel tiene una frecuencia fija y ve una cantidad parecida de
//    tajadas de la FFT (lineal hasta ~3.9 kHz, log arriba). Vertical: se leen por columnas (graves a la izquierda);
//    horizontal: por filas (graves abajo). Se encienden con los golpes y se enfrían en el lugar.
enum { VZS_ESPEJO=1, VZS_VERTICAL=2, VZS_HORIZONTAL=3, VZS_COUNT=3 }; // por defecto: horizontal
#define VZ_COLS 200
@interface VizView : NSView
@property (copy,nonatomic) NSString *msg;
@property int style;
- (void)spectrum:(const float*)sp kick:(float)k;
- (void)reactor:(const float*)spec;
- (void)resetState;
- (void)render;
@property (copy,nonatomic) void(^onLong)(void);
@end
@implementation VizView{ uint8_t *_buf; int _bw; NSTextField *_label; float _sp[VZ_SPEC], _hold[VZ_COLS], _kick, _heat[VZ_BANDS][VZ_COLS], _avg[VZ_BANDS][VZ_COLS]; BOOL _avgReady; LPButton *_press; }
- (void)dealloc{ free(_buf); }
// El Touch Bar no entrega toques a un NSView: un botón transparente encima recibe el "mantener".
- (void)setOnLong:(void(^)(void))b{ _onLong=[b copy];
    if(!_press){ _press=[LPButton buttonWithTitle:@"" target:nil action:nil]; _press.bordered=NO; _press.transparent=YES;
        _press.frame=self.bounds; _press.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; [self addSubview:_press]; }
    _press.onLong=b; }
- (void)setMsg:(NSString*)m{ _msg=[m copy];
    if(m.length && !_label){ _label=[NSTextField labelWithString:@""]; _label.font=[NSFont systemFontOfSize:11]; _label.textColor=[NSColor colorWithWhite:0.55 alpha:1];
        _label.frame=NSMakeRect(10,7,self.bounds.size.width-20,16); [self addSubview:_label]; }
    _label.stringValue=m?:@""; _label.hidden=!m.length; }
- (void)spectrum:(const float*)sp kick:(float)k{ memcpy(_sp,sp,sizeof _sp); _kick=k; [self render]; }
// Reactor, determinista: cada píxel tiene una frecuencia fija (35 Hz -> 16 kHz). Se enciende cuando su frecuencia
// sobresale de su propio promedio reciente (una nota que entra, un golpe) y se enfría en el lugar.
// Sin azar: el mismo sonido dibuja siempre el mismo patrón.
#define VZ_GATE   0.25f   // energía mínima de la frecuencia (debajo: nada; en silencio no parpadea)
#define VZ_HIT_MIN 0.12f  // lo que tiene que sobresalir de su promedio para empezar a encender
#define VZ_HIT    0.26f   // ...y lo que tiene que sobresalir para llegar al blanco
#define VZ_SUSTAIN 0.65f  // nivel desde el que una nota sostenida sigue brillando (tenue)
#define VZ_KNEE   0.40f   // lo que no llega a esto queda en negro (una tajada sola es ruidosa: sin alfombra)
#define VZ_COOL   0.85f   // enfriamiento por cuadro a 30 fps (~0.3 s hasta apagarse)
#define VZ_GLOW   0.50f   // resplandor máximo que un píxel le presta a sus vecinos (no los enciende)
#define VZ_GLOW_V 0.20f   // vertical: resplandor suave a los vecinos
- (void)resetState{ memset(_heat,0,sizeof _heat); memset(_avg,0,sizeof _avg); memset(_hold,0,sizeof _hold); _avgReady=NO; }
- (void)reactor:(const float*)spec{
    int cols=(int)((self.bounds.size.width*2-4)/11); if(cols>VZ_COLS)cols=VZ_COLS; if(cols<8)return;
    BOOL any=NO; for(int i=0;i<VZ_FINE;i++) if(spec[i]>0.01f){ any=YES; break; }
    BOOL seed=!_avgReady && any; if(seed)_avgReady=YES;                 // primer audio: el promedio arranca ahí (sin destello)
    for(int r=0;r<VZ_BANDS;r++) for(int c=0;c<cols;c++){
        // vertical: las frecuencias avanzan por columnas; horizontal: por filas
        float x=(self.style==VZS_VERTICAL ? (c+(r+0.5f)/VZ_BANDS)/cols : (r+(c+0.5f)/cols)/VZ_BANDS)*(VZ_FINE-1); int i=(int)x; if(i>VZ_FINE-2)i=VZ_FINE-2; float u=x-i;
        float e=spec[i]*(1-u)+spec[i+1]*u; if(seed)_avg[r][c]=e; float m=_avg[r][c];
        _avg[r][c]=m+(e-m)*0.06f;                                    // promedio reciente de esta frecuencia (~0.5 s)
        float hit=(e-m-VZ_HIT_MIN)/VZ_HIT, sus=(e-VZ_SUSTAIN)/(1-VZ_SUSTAIN)*0.45f;
        float ign=e<VZ_GATE?0:fmaxf(hit,sus); ign=ign<VZ_KNEE?0:(ign>1?1:ign);  // se enciende lo que entra o golpea
        _heat[r][c]=fmaxf(_heat[r][c]*VZ_COOL,ign); }
    [self render];
}
static void vzGrad(float t,float o[3]);
// reactor: mismo degradé, pero lo más caliente llega al blanco
static void vzGradHot(float t,float o[3]){
    if(t<=0.9f){ vzGrad(t,o); return; } float u=(t-0.9f)/0.1f; if(u>1)u=1;
    static const float R[3]={255,45,40}, Wt[3]={255,235,215}; for(int k=0;k<3;k++) o[k]=R[k]+(Wt[k]-R[k])*u;
}
static void vzGrad(float t,float o[3]){
    static const float P[5]={0,0.28,0.5,0.66,0.9};
    static const float C[5][3]={{10,28,95},{30,115,230},{80,210,255},{255,120,30},{255,45,40}};
    t=t<0?0:(t>1?1:t); int i=0; while(i<3 && t>P[i+1])i++;
    float u=(t-P[i])/(P[i+1]-P[i]); if(u>1)u=1;
    for(int k=0;k<3;k++) o[k]=C[i][k]+(C[i+1][k]-C[i][k])*u;
}
// suma saturada de un rectángulo de color (en píxeles reales, origen arriba-izquierda)
static void vzAdd(uint8_t *buf,int W,int H,int x0,int y0,int w,int h,const float rgb[3],float a){
    for(int y=y0>0?y0:0;y<y0+h&&y<H;y++){ uint8_t *row=buf+(size_t)y*W*4;
        for(int x=x0>0?x0:0;x<x0+w&&x<W;x++){ uint8_t *p=row+x*4;
            for(int k=0;k<3;k++){ int v=p[k]+(int)(rgb[k]*a); p[k]=v>255?255:v; } } }
}
// un píxel cuadrado de 9x9 px con esquinas suaves + halo sumado (bloom)
static void vzCell(uint8_t *buf,int W,int H,int x,int y,const float rgb[3]){
    const int SQ=9;
    vzAdd(buf,W,H,x-4,y-4,SQ+8,SQ+8,rgb,0.07f);                    // halo ancho
    vzAdd(buf,W,H,x-2,y-2,SQ+4,SQ+4,rgb,0.12f);                    // halo cercano
    vzAdd(buf,W,H,x,y+1,SQ,SQ-2,rgb,1); vzAdd(buf,W,H,x+1,y,SQ-2,1,rgb,1); vzAdd(buf,W,H,x+1,y+SQ-1,SQ-2,1,rgb,1);
    vzAdd(buf,W,H,x,y,1,1,rgb,0.45f); vzAdd(buf,W,H,x+SQ-1,y,1,1,rgb,0.45f); vzAdd(buf,W,H,x,y+SQ-1,1,1,rgb,0.45f); vzAdd(buf,W,H,x+SQ-1,y+SQ-1,1,1,rgb,0.45f);
}
// Raster manual (no CoreGraphics por celda): 5 filas de cuadrados de 9x9 px exactos, paso 11 px.
- (void)render{
    const int H=60, P=11; int W=(int)(self.bounds.size.width*2); if(W<=0)return;
    if(!_buf||W!=_bw){ free(_buf); _buf=calloc((size_t)W*H,4); _bw=W; }
    memset(_buf,0,(size_t)W*H*4);
    int cols=(W-4)/P; if(cols>VZ_COLS)cols=VZ_COLS;
    if(self.style==VZS_ESPEJO && cols>=3){ // espectro espejado: crece desde la fila del medio hacia arriba y abajo
        float c0=(cols-1)/2.0f; static const float th[3]={0.08f,0.4f,0.72f};
        for(int c=0;c<cols;c++){ float f=fabsf(c-c0)/c0, x=f*(VZ_SPEC-1); int i=(int)x; if(i>VZ_SPEC-2)i=VZ_SPEC-2; float u=x-i;
            float e=_sp[i]*(1-u)+_sp[i+1]*u; _hold[c]=fmaxf(e,_hold[c]-0.027f); float e2=_hold[c];
            float rgb0[3]; vzGrad(0.92f-f*0.75f,rgb0);
            for(int r=0;r<VZ_BANDS;r++){ float v=(e2-th[abs(r-2)])/0.28f; if(v<=0)continue;
                float br=fminf(1,0.35f+v*0.65f)*(0.75f+0.25f*_kick); if(br<0.12f)continue;
                float k=0.35f+0.65f*br, rgb[3]={rgb0[0]*k,rgb0[1]*k,rgb0[2]*k};
                vzCell(_buf,W,H,3+c*P,H-2-(r+1)*P+1,rgb); } }
    } else if(self.style!=VZS_ESPEJO){ // reactor
        for(int r=0;r<VZ_BANDS;r++) for(int c=0;c<cols;c++){ float h=_heat[r][c], n=0;
            if(c>0)n=fmaxf(n,_heat[r][c-1]); if(c<cols-1)n=fmaxf(n,_heat[r][c+1]);
            if(r>0)n=fmaxf(n,_heat[r-1][c]); if(r<VZ_BANDS-1)n=fmaxf(n,_heat[r+1][c]);
            BOOL vert=self.style==VZS_VERTICAL; float g=n*(vert?VZ_GLOW_V:VZ_GLOW); if(h<0.24f)h=0;  // el píxel propio se apaga bajo 24%...
            h=fmaxf(h,g>=(vert?0.08f:0.24f)?g:0); if(h<0.08f)continue;                      // ...el halo: vertical 20% (visible desde 8%), horizontal 50%
            float rgb[3]; vzGradHot(h,rgb); float k=0.35f+0.65f*h; rgb[0]*=k; rgb[1]*=k; rgb[2]*=k;
            vzCell(_buf,W,H,3+c*P,H-2-(r+1)*P+1,rgb); }
    }
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bc=CGBitmapContextCreate(_buf,W,H,8,(size_t)W*4,cs,kCGImageAlphaNoneSkipLast|kCGBitmapByteOrderDefault);
    CGImageRef img=CGBitmapContextCreateImage(bc); CGContextRelease(bc); CGColorSpaceRelease(cs);
    self.layer.contents=(__bridge id)img; CGImageRelease(img);
}
- (BOOL)wantsUpdateLayer{ return YES; }
- (void)updateLayer{ self.layer.backgroundColor=NSColor.blackColor.CGColor; self.layer.magnificationFilter=kCAFilterNearest; self.layer.contentsGravity=kCAGravityResize; }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTouchBarDelegate, CLLocationManagerDelegate>
- (void)powerChanged;
@end
@implementation AppDelegate{
    NSTouchBar *_bar; NSButton *_clock,*_playBtn; LPButton *_audioBtn; BatteryView *_batt; NowView *_now; NSSlider *_scrub,*_volSlider,*_brightSlider;
    WeatherView *_weather; VizView *_viz; double _wlat,_wlon,_wfetchT,_locT; BOOL _haveFix; NSString *_wcity; CLLocationManager *_loc; CLGeocoder *_geo;
    BOOL _muted,_loop,_muteVis,_lastExt,_blackout; CFTimeInterval _plugT; int _preBlackMode; LPButton *_brightBtn; int _loopStyle; NSString *_loopTrack; NSColor *_loopTint;
    NSMutableDictionary *_cache; NSTimer *_anim,*_watch; dispatch_source_t _vzSrc,_hbSrc; int _vzSilent,_vzGen; int _tick,_mode,_lastVol; dispatch_queue_t _mq; double _dur,_elapsed,_lastScrub; BOOL _playing; NSString *_artTrack,*_player;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n{
    // si la app murio en pleno blackout, lo primero es devolver el brillo
    if([[NSFileManager defaultManager] fileExistsAtPath:blackoutPath()]){ blackoutRestore(YES,NO); NSLog(@"MatiBar: blackout previo recuperado al arrancar"); }
    { NSString *pm=(__bridge_transfer NSString*)CFPreferencesCopyAppValue(CFSTR("PresentationModeGlobal"),CFSTR("com.apple.touchbar.agent"));
      if(![pm isEqualToString:@"app"]) shRun(@"defaults write com.apple.touchbar.agent PresentationModeGlobal -string app; killall ControlStrip 2>/dev/null"); } // barra a todo el ancho
    _lastExt=readBatt().external; _plugT=-100; _cache=[NSMutableDictionary new]; _mq=dispatch_queue_create("com.mati.mb.media",DISPATCH_QUEUE_SERIAL); iorInit(); dsInit();
    NSCustomTouchBarItem *tray=[[NSCustomTouchBarItem alloc] initWithIdentifier:kTray];
    NSButton *tb=[NSButton buttonWithTitle:@"⚡" target:self action:@selector(present)]; tb.bezelColor=[NSColor systemOrangeColor]; tray.view=tb;
    [NSTouchBarItem addSystemTrayItem:tray]; DFRElementSetControlStripPresenceForIdentifier(kTray,YES);
    _bar=[NSTouchBar new]; _bar.delegate=self; [self applyMode];
    _anim=[NSTimer scheduledTimerWithTimeInterval:1.0/30.0 target:self selector:@selector(frame) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_anim forMode:NSRunLoopCommonModes]; // sigue animando mientras mantenés un botón o arrastrás
    // preset del indicador de loop: `defaults write com.mati.matibar loopStyle -int 1..5` y `loopColor white|red`
    { NSUserDefaults *ud=[NSUserDefaults standardUserDefaults]; char *ls=getenv("MATIBAR_LOOPSTYLE"),*lc=getenv("MATIBAR_LOOPCOLOR");
      _loopStyle=ls?atoi(ls):(int)[ud integerForKey:@"loopStyle"]; if(_loopStyle<1||_loopStyle>5)_loopStyle=1;
      NSString *col=lc?@(lc):[ud stringForKey:@"loopColor"];
      BOOL red=(_loopStyle==4)||[col isEqualToString:@"red"]; // el estilo 4 siempre va en rojo
      _loopTint=red?[NSColor colorWithRed:1.0 green:0.27 blue:0.25 alpha:1]:[NSColor whiteColor]; }
    _muted=(muteGet()==1);
    // Re-presentar SOLO en eventos reales (no cada 3s -> sin parpadeo).
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(present) name:NSWorkspaceDidWakeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(present) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    CFRunLoopSourceRef s=IOPSNotificationCreateRunLoopSource(psCB,(__bridge void*)self); if(s){CFRunLoopAddSource(CFRunLoopGetMain(),s,kCFRunLoopCommonModes);CFRelease(s);}
    [self frame];
    if(getenv("MATIBAR_AUDIOMODE"))[self performSelector:@selector(goAudio) withObject:nil afterDelay:1.5];
    if(getenv("MATIBAR_BRIGHTMODE"))[self performSelector:@selector(goBright) withObject:nil afterDelay:1.5];
    if(getenv("MATIBAR_VIZCYCLE")){ double every=atof(getenv("MATIBAR_VIZCYCLE")); // prueba: rota de estilo cada N s (como mantener los píxeles)
        if(every>0) [NSTimer scheduledTimerWithTimeInterval:every repeats:YES block:^(NSTimer *t){ [self cycleVizStyle]; }]; }
    if(getenv("MATIBAR_VIZ")){ double secs=atof(getenv("MATIBAR_VIZ")); // prueba: abre el visualizador a los 1.5s y lo cierra a los 1.5+N s (N<=1: no cierra)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self goAudio]; [self toggleViz]; });
        if(secs>1) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((1.5+secs)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self toggleViz]; }); }
    if(getenv("MATIBAR_WEATHERMODE"))[self performSelector:@selector(toggleWeather) withObject:nil afterDelay:1.5];
    // ganchos de prueba SOLO visuales (no tocan Spotify ni el audio real)
    if(getenv("MATIBAR_LOOPVIS")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ self->_loop=YES; self->_now.loop=YES; self->_now.needsDisplay=YES; });
    if(getenv("MATIBAR_BLACKOUTTEST")){ double secs=atof(getenv("MATIBAR_BLACKOUTTEST")); // prueba: entra a los 2.5s y sale a los 2.5+N s (N=0: no sale)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self enterBlackout]; });
        if(secs>0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((2.5+secs)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self exitBlackout]; }); }
    if(getenv("MATIBAR_MUTEVIS")){ _muteVis=YES; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ self->_muted=YES; [self updateAudioIcon]; }); }
}
- (void)applyMode{
    if(_mode==0) _bar.defaultItemIdentifiers=@[kClock,kBatt,kFlex,kAudio,kClaude];
    else if(_mode==1) _bar.defaultItemIdentifiers=@[kPrev,kPlay,kNext,kNow,kScrub,kVolDn,kVol,kVolUp,kFlex,kBright,kAudio,kClaude];
    else if(_mode==2) _bar.defaultItemIdentifiers=@[kFlex,kBrDn,kBright10,kBrUp,kFlex,kBright,kAudio,kClaude];
    else if(_mode==3) _bar.defaultItemIdentifiers=@[kClock,kWeather]; // modo clima: solo reloj + panel del día
    else if(_mode==5) _bar.defaultItemIdentifiers=@[kPrev,kPlay,kNext,kViz]; // visualizador: transporte + píxeles
    else _bar.defaultItemIdentifiers=@[kFlex,kBright,kAudio,kClaude]; // blackout: solo los 3 botones
    [self present];
}
- (void)present{ DFRSystemModalShowsCloseBoxWhenFrontMost(NO); [NSTouchBar presentSystemModalTouchBar:_bar placement:1 systemTrayItemIdentifier:nil]; }
- (void)goAudio{ _mode=1; [self applyMode]; [self refreshMedia]; }
- (void)goBright{ _mode=2; [self applyMode]; if(_brightSlider){ _brightSlider.doubleValue=fmax(1,round(brightGet()*10)); [_brightSlider setNeedsDisplay:YES]; } }
- (void)toggleAudio{ if(_blackout){ [self mPlay]; return; } _mode=(_mode==0)?1:0; [self applyMode]; if(_mode==1)[self refreshMedia]; }
- (void)toggleBright{ if(_mode==1)[self goBright]; else [self goAudio]; }
// El visualizador tiene su propio timer GCD estricto (30 fps): el NSTimer general de una app de fondo
// queda "coalesced" por macOS a ~10 fps, y sus animaciones ya están afinadas a ese ritmo.
- (void)vizFrame{
    if(_mode!=5 || !_viz)return; float b[VZ_BANDS];
    // música sonando pero la captura entrega silencio 5s seguidos = permiso de audio denegado: avisar cómo activarlo
    _vzSilent=(_playing && gRms<1e-6f)?_vzSilent+1:0;
    if(_vzSilent==150) _viz.msg=@"Sin audio: activá MatiBar en Ajustes › Privacidad › Grabación de audio del sistema";
    else if(_vzSilent==0 && _viz.msg.length && gRms>=1e-6f) _viz.msg=nil;
    if(_viz.msg.length)return;
    os_unfair_lock_lock(&gBandLock); memcpy(b,gBand,sizeof b); os_unfair_lock_unlock(&gBandLock);
    if(_viz.style==VZS_ESPEJO){ float sp[VZ_SPEC]; os_unfair_lock_lock(&gBandLock); memcpy(sp,gSpec,sizeof sp); os_unfair_lock_unlock(&gBandLock);
        [_viz spectrum:sp kick:b[0]]; return; }
    static float sp[VZ_FINE]; os_unfair_lock_lock(&gBandLock); memcpy(sp,gSpec,sizeof sp); os_unfair_lock_unlock(&gBandLock);
    [_viz reactor:sp];
}
- (void)vizTimer:(BOOL)on{
    if(on && !_vzSrc){ _vzSrc=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,DISPATCH_TIMER_STRICT,dispatch_get_main_queue());
        dispatch_source_set_timer(_vzSrc,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/30,NSEC_PER_MSEC);
        __weak AppDelegate *w=self; dispatch_source_set_event_handler(_vzSrc,^{ [w vizFrame]; }); dispatch_resume(_vzSrc); }
    else if(!on && _vzSrc){ dispatch_source_cancel(_vzSrc); _vzSrc=nil; }
}
static NSString *const vzKeys[VZS_COUNT]={@"espejo",@"vertical",@"horizontal"};
// estilo guardado (`visualizer` = espejo|vertical|horizontal); MATIBAR_VIZSTYLE acepta el nombre (pruebas)
- (int)vizStyleSetting{ char *vs=getenv("MATIBAR_VIZSTYLE"); NSString *k=vs?@(vs):[[NSUserDefaults standardUserDefaults] stringForKey:@"visualizer"];
    for(int i=0;i<VZS_COUNT;i++) if([k isEqualToString:vzKeys[i]]) return i+1;
    return VZS_HORIZONTAL; } // sin preferencia: horizontal balanceado
- (void)vizApplyStyle:(int)st{ gSpecN=(st==VZS_ESPEJO)?VZ_SPEC:VZ_FINE; gSpecBal=(st!=VZS_ESPEJO); _viz.style=st; [_viz resetState];
    os_unfair_lock_lock(&gBandLock); memset(gSpec,0,sizeof gSpec); os_unfair_lock_unlock(&gBandLock); } // sin restos del estilo anterior (evita destello)
// La captura se arma y se destruye en una cola de fondo: si el servicio de audio (coreaudiod) se traba,
// el Touch Bar sigue respondiendo. La cola es serial, así que cerrar mientras arranca queda en orden.
// mantener los píxeles: rota entre los estilos y lo guarda para la próxima vez
- (void)cycleVizStyle{
    if(_mode!=5 || !_viz)return; int st=_viz.style%VZS_COUNT+1;
    [[NSUserDefaults standardUserDefaults] setObject:vzKeys[st-1] forKey:@"visualizer"];
    [self vizApplyStyle:st]; [_viz render]; // render: borra al instante lo del estilo anterior
}
- (void)toggleViz{
    static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once,^{ q=dispatch_queue_create("com.mati.mb.vizctl",DISPATCH_QUEUE_SERIAL); });
    if(_mode==5){ [self vizTimer:NO]; _vzGen++; _mode=1; [self applyMode]; [self refreshMedia]; dispatch_async(q,^{ vizStop(); }); return; }
    if(_mode!=1)return;
    int st=[self vizStyleSetting]; _vzSilent=0; gRms=0;
    if(!_viz)[self touchBar:_bar makeItemForIdentifier:kViz]; // la vista existe antes de escribirle el aviso
    _mode=5; [self applyMode]; [self vizApplyStyle:st]; _viz.msg=@"Conectando con el audio…"; int gen=++_vzGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(self->_vzGen==gen && !self->_vzSrc && self->_mode==5) self->_viz.msg=@"El audio del sistema no responde — probá cerrar y abrir de nuevo"; });
    dispatch_async(q,^{ BOOL ok=vizStart(); NSString *err=gTapErr;
        dispatch_async(dispatch_get_main_queue(),^{
            if(self->_vzGen!=gen || self->_mode!=5)return; // ya se cerró: el vizStop encolado limpia
            self->_viz.msg=ok?nil:err; [self vizTimer:ok]; if(!ok)NSLog(@"MatiBar: %@",err); }); });
}
- (void)toggleWeather{ _mode=(_mode==3)?0:3; [self applyMode]; if(_mode==3)[self fetchWeather]; }
- (void)powerChanged{ [self applyBatt:readBatt()]; }
// Al enchufar (mismo instante que el chime) pasa a verde ya; macOS tarda ~2s en marcar "cargando",
// asi que durante 6s se confia en "conectado". Despues manda el estado real (ej: tope de 80% -> blanco).
- (void)applyBatt:(BattInfo)bi{
    if(!_batt)return; CFTimeInterval now=CACurrentMediaTime();
    if(bi.external && !_lastExt) _plugT=now;
    _lastExt=bi.external;
    BOOL grace=bi.external && (now-_plugT<6.0);
    _batt.charging=bi.charging||(grace&&bi.level<0.995); _batt.discharging=!bi.external;
    _batt.target=bi.level; _batt.lowPower=bi.lowPower; _batt.needsDisplay=YES; }

- (void)frame{ _tick++;
    if(_batt){ BOOL fast=(CACurrentMediaTime()-_plugT<8.0); if(_tick%(fast?8:45)==1)[self applyBatt:readBatt()]; // mas rapido justo despues de enchufar
        if(_tick%30==10){ double w=iorWatts(); if(w>=0)_batt.watts=w; }
        double df=_batt.target-_batt.level; if(fabs(df)>0.002)_batt.level+=df*0.08; else _batt.level=_batt.target;
        if(_batt.charging)_batt.phase+=0.012; else if(_batt.discharging){ double sp=0.004+fmin(_batt.watts,30)*0.0007; _batt.phase-=sp; }
        if(_batt.phase>1)_batt.phase-=1; if(_batt.phase<0)_batt.phase+=1; _batt.needsDisplay=YES; }
    if(_clock && _tick%30==0){ NSDateFormatter *df=[NSDateFormatter new]; df.dateFormat=@"HH:mm"; _clock.title=[df stringFromDate:[NSDate date]]; }
    if(_mode==3 && _weather){ _weather.phase+=1.0/30.0; _weather.needsDisplay=YES; if(CFAbsoluteTimeGetCurrent()-_wfetchT>600)[self fetchWeather]; }
    if((_mode==1||_mode==5) && _tick%30==5)[self refreshMedia];
    if(_mode==1 && _playing && _dur>0 && _tick%30!=5){ _elapsed+=1.0/30.0;
        if(_scrub && CFAbsoluteTimeGetCurrent()-_lastScrub>0.5) _scrub.doubleValue=fmin(1.0,_elapsed/_dur); }
    // loop: vigilar fin de canción (Spotify, cada 0.5s) / cambio de canción (sale del loop)
    if(_loop){ int iv=[_player isEqualToString:@"Spotify"]?15:30; if(_tick%iv==7)[self loopTick];
        if(_mode==1 && _now && (_loopStyle==2||_loopStyle==5)){ _now.phase+=1.0/30.0; _now.needsDisplay=YES; } }
    // mute: sincronizar si se cambió desde afuera (teclado, Centro de Control)
    if(!_muteVis && _tick%60==20){ int m=muteGet(); if(m>=0 && (m==1)!=_muted){ _muted=(m==1); [self updateAudioIcon]; } }
}

- (NSButton*)imgBtn:(NSString*)sym sel:(SEL)sel{ NSButton *b=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil] target:self action:sel]; b.bordered=NO; b.imagePosition=NSImageOnly; return b; }
- (NSTouchBarItem *)touchBar:(NSTouchBar *)t makeItemForIdentifier:(NSTouchBarItemIdentifier)id{
    if(_cache[id])return _cache[id]; NSTouchBarItem *out=nil; NSCustomTouchBarItem *it=[[NSCustomTouchBarItem alloc] initWithIdentifier:id];
    __weak AppDelegate *ws=self;
    if([id isEqual:kClock]){ LPButton *cb=[LPButton buttonWithTitle:@"--:--" target:self action:@selector(toggleWeather)]; cb.bordered=NO; cb.font=[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightMedium];
        cb.onLong=^{ [ws openBundle:@"com.apple.iCal"]; }; _clock=cb; it.view=cb; out=it; } // mantener -> Calendario
    else if([id isEqual:kWeather]){ _weather=[[WeatherView alloc] initWithFrame:NSMakeRect(0,0,930,30)]; _weather.wantsLayer=YES; _weather.bordered=NO; _weather.title=@""; [_weather setButtonType:NSButtonTypeMomentaryChange];
        _weather.onLong=^{ [ws openBundle:@"com.apple.weather"]; }; // mantener -> app Clima
        [_weather.widthAnchor constraintEqualToConstant:930].active=YES; it.view=_weather; out=it; }
    else if([id isEqual:kBatt]){ _batt=[[BatteryView alloc] initWithFrame:NSMakeRect(0,0,BATT_W,30)]; _batt.wantsLayer=YES; BattInfo bi=readBatt(); _batt.target=_batt.level=bi.level; _batt.charging=bi.charging; _batt.discharging=!bi.external; _batt.lowPower=bi.lowPower; it.view=_batt; out=it; }
    else if([id isEqual:kAudio]){ _audioBtn=[LPButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:nil] target:self action:@selector(toggleAudio)];
        _audioBtn.bordered=NO; _audioBtn.imagePosition=NSImageOnly; _audioBtn.onLong=^{ [ws toggleMute]; }; // mantener -> mute
        [_audioBtn.widthAnchor constraintEqualToConstant:46].active=YES; [self updateAudioIcon]; it.view=_audioBtn; out=it; }
    else if([id isEqual:kClaude]){ LPButton *c=[LPButton buttonWithImage:claudeMark(27,[NSColor colorWithRed:0.85 green:0.47 blue:0.34 alpha:1]) target:self action:@selector(openClaude)]; c.bordered=NO; c.imagePosition=NSImageOnly; c.imageScaling=NSImageScaleNone;
        c.onLong=^{ [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"claude://claude.ai/new?surface=chat"]]; }; // mantener -> chat nuevo
        [c.widthAnchor constraintEqualToConstant:50].active=YES; it.view=c; out=it; }
    else if([id isEqual:kPrev]){ it.view=[self imgBtn:@"backward.fill" sel:@selector(mPrev)]; out=it; }
    else if([id isEqual:kPlay]){ LPButton *pb=[LPButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil] target:self action:@selector(mPlay)];
        pb.bordered=NO; pb.imagePosition=NSImageOnly; pb.onLong=^{ [ws toggleViz]; }; _playBtn=pb; // mantener -> visualizador (easter egg)
        _playBtn.contentTintColor=[NSColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:1]; it.view=_playBtn; out=it; }
    else if([id isEqual:kViz]){ _viz=[[VizView alloc] initWithFrame:NSMakeRect(0,0,VIZ_W,30)]; _viz.wantsLayer=YES;
        _viz.onLong=^{ [ws cycleVizStyle]; }; // mantener los píxeles -> siguiente estilo
        _viz.style=[self vizStyleSetting];
        [_viz.widthAnchor constraintEqualToConstant:VIZ_W].active=YES; it.view=_viz; out=it; }
    else if([id isEqual:kNext]){ it.view=[self imgBtn:@"forward.fill" sel:@selector(mNext)]; out=it; }
    else if([id isEqual:kNow]){ _now=[[NowView alloc] initWithFrame:NSMakeRect(0,0,NOW_W,30)]; _now.wantsLayer=YES; _now.bordered=NO; _now.title=@""; [_now setButtonType:NSButtonTypeMomentaryChange]; _now.target=self; _now.action=@selector(openPlayer);
        _now.onLong=^{ [ws toggleLoop]; }; _now.loopStyle=_loopStyle; _now.loopTint=_loopTint; _now.loop=_loop; // mantener -> loop de la canción
        [_now.widthAnchor constraintEqualToConstant:NOW_W].active=YES; it.view=_now; out=it; }
    else if([id isEqual:kScrub]){ ScrubCell *cell=[ScrubCell new]; _scrub=[[NSSlider alloc] initWithFrame:NSMakeRect(0,0,320,30)]; [_scrub setCell:cell]; _scrub.minValue=0; _scrub.maxValue=1; _scrub.continuous=NO; _scrub.doubleValue=0; _scrub.target=self; _scrub.action=@selector(seekScrub); [_scrub.widthAnchor constraintEqualToConstant:320].active=YES; it.view=_scrub; out=it; }
    else if([id isEqual:kBright]){ _brightBtn=[LPButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:nil] target:self action:@selector(brightTap)];
        _brightBtn.bordered=NO; _brightBtn.imagePosition=NSImageOnly; _brightBtn.onLong=^{ [ws toggleBlackout]; }; // mantener -> blackout
        it.view=_brightBtn; out=it; }
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
- (void)openClaude{ if(_blackout)[self exitBlackout]; NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/open"; t.arguments=@[@"-b",@"com.anthropic.claudefordesktop"]; @try{[t launch];}@catch(__unused NSException *e){} }
- (void)mPrev{ if(_loop)[self setLoop:NO]; transport(_player,@"previous track"); } // cambiar de canción saca del loop
- (void)mNext{ if(_loop)[self setLoop:NO]; transport(_player,@"next track"); }
- (void)openBundle:(NSString*)b{ NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/open"; t.arguments=@[@"-b",b]; @try{[t launch];}@catch(__unused NSException *e){} }
// ---- blackout (mantener ☀): pantalla en 0, teclado apagado, solo ☀ 🔊 ✳ ----
- (void)brightTap{ if(_blackout)[self exitBlackout]; else [self toggleBright]; }
- (void)toggleBlackout{ if(_blackout)[self exitBlackout]; else [self enterBlackout]; }
- (void)updateBrightIcon{ _brightBtn.image=[NSImage imageWithSystemSymbolName:(_blackout?@"sun.min":@"sun.max.fill") accessibilityDescription:nil]; }
- (float)blackoutTarget{ return getenv("MATIBAR_BLACKOUTDRY")?0.3f:0.0f; } // modo prueba: 30% en vez de 0
- (void)enterBlackout{
    if(_blackout)return; float b=brightGet(),k=kbdGet(); BOOL ka=kbdAutoGet();
    NSData *j=[NSJSONSerialization dataWithJSONObject:@{@"bright":@(b),@"kbd":@(k),@"kbdAuto":@(ka)} options:0 error:nil];
    if(![j writeToFile:blackoutPath() atomically:YES]){ NSLog(@"MatiBar: no pude escribir blackout.json, cancelo el blackout"); return; } // sin salvavidas no hay blackout
    _blackout=YES; _preBlackMode=_mode;
    if(ka)kbdAutoSet(NO); kbdSet(0); brightSetRaw([self blackoutTarget]);
    _mode=4; [self applyMode]; [self updateBrightIcon]; [self heartbeatTimer:YES];
}
// latido cada 2 s con timer GCD estricto: el guardián devuelve el brillo si pasa 12 s sin latido
- (void)heartbeatTimer:(BOOL)on{
    if(on && !_hbSrc){ _hbSrc=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,DISPATCH_TIMER_STRICT,dispatch_get_main_queue());
        dispatch_source_set_timer(_hbSrc,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),2*NSEC_PER_SEC,100*NSEC_PER_MSEC);
        __weak AppDelegate *w=self; dispatch_source_set_event_handler(_hbSrc,^{ [w blackoutHeartbeat]; }); dispatch_resume(_hbSrc); }
    else if(!on && _hbSrc){ dispatch_source_cancel(_hbSrc); _hbSrc=nil; }
}
- (void)exitBlackout{
    if(!_blackout)return; _blackout=NO; [self heartbeatTimer:NO]; blackoutRestore(NO,NO);
    _mode=(_preBlackMode==4)?0:_preBlackMode; [self applyMode]; [self updateBrightIcon];
}
- (void)blackoutHeartbeat{
    NSString *p=blackoutPath();
    if(![[NSFileManager defaultManager] fileExistsAtPath:p]){ [self heartbeatTimer:NO]; _blackout=NO; _mode=(_preBlackMode==4)?0:_preBlackMode; [self applyMode]; [self updateBrightIcon]; return; } // el guardian ya restauro
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:[NSDate date]} ofItemAtPath:p error:nil];
    float t=[self blackoutTarget]; if(brightGet()>t+0.02)brightSetRaw(t); // si el brillo automatico lo sube, lo vuelvo a bajar
    if(kbdGet()>0.01)kbdSet(0);
}
// ---- mute (mantener audio) ----
- (void)updateAudioIcon{ _audioBtn.image=[NSImage imageWithSystemSymbolName:(_muted?@"speaker.slash.fill":@"speaker.wave.2.fill") accessibilityDescription:nil]; }
- (void)toggleMute{ _muted=!_muted; muteSet(_muted); [self updateAudioIcon]; }
// ---- loop de la canción (mantener la carátula/título) ----
- (void)toggleLoop{ [self setLoop:!_loop]; }
- (void)setLoop:(BOOL)on{
    _loop=on; _loopTrack=on?_now.song:nil; if(_now){ _now.loop=on; _now.needsDisplay=YES; }
    NSString *p=_player?:activePlayer(); _player=p;
    if([p isEqualToString:@"Music"]) dispatch_async(_mq,^{ runOSA([NSString stringWithFormat:@"tell application \"Music\" to set song repeat to %@",on?@"one":@"off"]); }); // Music: repeat-one nativo
}
- (void)loopTick{ // Spotify no tiene repeat-one por AppleScript: al llegar al final, vuelve a 0:00
    NSString *p=_player,*lt=_loopTrack; if(!p||!_loop)return;
    dispatch_async(_mq,^{
        NSString *durExpr=[p isEqualToString:@"Spotify"]?@"((duration of current track)/1000)":@"(duration of current track)";
        NSString *r=runOSA([NSString stringWithFormat:@"tell application \"%@\"\nset o to \"\"\ntry\nset o to (name of current track) & \"@@@\" & (player position) & \"@@@\" & %@\nend try\nreturn o\nend tell",p,durExpr]);
        NSArray *f=[r componentsSeparatedByString:@"@@@"]; if(f.count<3)return;
        NSString *name=f[0]; double pos=[f[1] doubleValue],dur=[f[2] doubleValue];
        if(lt.length && ![name isEqualToString:lt]){ dispatch_async(dispatch_get_main_queue(),^{ [self setLoop:NO]; }); return; } // cambió la canción -> fuera del loop
        if([p isEqualToString:@"Spotify"] && dur>0 && pos>=dur-1.6) runOSA(@"tell application \"Spotify\" to set player position to 0");
    });
}
- (void)mPlay{ transport(_player,@"playpause"); }
- (void)openPlayer{ NSString *b=[_player isEqualToString:@"Spotify"]?@"com.spotify.client":([_player isEqualToString:@"Music"]?@"com.apple.Music":nil); if(!b)return;
    NSTask *t=[NSTask new]; t.launchPath=@"/usr/bin/open"; t.arguments=@[@"-b",b]; @try{[t launch];}@catch(__unused NSException *e){} }
// ---- ubicación precisa (CoreLocation). Si no hay permiso o falla, queda la ubicación por IP ----
- (void)ensureLocation{
    if(!_loc){ if(![CLLocationManager locationServicesEnabled])return;
        _loc=[CLLocationManager new]; _loc.delegate=self; _loc.desiredAccuracy=kCLLocationAccuracyKilometer;
        [_loc requestWhenInUseAuthorization]; [_loc requestLocation]; _locT=CFAbsoluteTimeGetCurrent(); return; }
    if(CFAbsoluteTimeGetCurrent()-_locT>1800){ _locT=CFAbsoluteTimeGetCurrent(); [_loc requestLocation]; } // refrescar cada 30 min
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager*)m{
    if(m.authorizationStatus==kCLAuthorizationStatusAuthorizedAlways)[m requestLocation]; }
- (void)locationManager:(CLLocationManager*)m didUpdateLocations:(NSArray<CLLocation*>*)locs{
    CLLocation *L=locs.lastObject; if(!L)return;
    _haveFix=YES; _wlat=L.coordinate.latitude; _wlon=L.coordinate.longitude;
    if(!_geo)_geo=[CLGeocoder new];
    [_geo reverseGeocodeLocation:L completionHandler:^(NSArray<CLPlacemark*>*pms,NSError*err){
        NSString *c=pms.firstObject.locality?:pms.firstObject.name; if(c.length)self->_wcity=c;
        dispatch_async(dispatch_get_main_queue(),^{ [self fetchWeather]; }); }];
}
- (void)locationManager:(CLLocationManager*)m didFailWithError:(NSError*)e{ NSLog(@"MatiBar: location no disponible (%@), uso IP",e.localizedDescription); }
- (void)fetchWeather{
    [self ensureLocation];
    _wfetchT=CFAbsoluteTimeGetCurrent();
    double lat0=_wlat, lon0=_wlon; NSString *city0=_wcity;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        double lat=lat0, lon=lon0; NSString *city=city0;
        if(lat==0 && lon==0){
            NSData *g=[NSData dataWithContentsOfURL:[NSURL URLWithString:@"https://ipapi.co/json/"]];
            if(g){ NSDictionary *j=[NSJSONSerialization JSONObjectWithData:g options:0 error:nil];
                if([j[@"latitude"] isKindOfClass:[NSNumber class]]){ lat=[j[@"latitude"] doubleValue]; lon=[j[@"longitude"] doubleValue]; city=j[@"city"]; } }
            if(lat==0 && lon==0)return; // sin ubicación: se reintenta en el próximo refresco
            dispatch_async(dispatch_get_main_queue(),^{ if(!self->_haveFix){ self->_wlat=lat; self->_wlon=lon; self->_wcity=city; } });
        }
        NSString *u=[NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&current=temperature_2m,weather_code&hourly=precipitation_probability&daily=sunrise,sunset,temperature_2m_max,temperature_2m_min,weather_code&timezone=auto&forecast_days=1",lat,lon];
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
            if(_weather){ _weather.tempC=temp; _weather.code=code; _weather.city=self->_wcity?:city; _weather.hi=hi; _weather.lo=lo; _weather.sunriseMin=srM; _weather.sunsetMin=ssM; _weather.rainProb=rain; _weather.dateStr=dateStr; _weather.southern=(lat<0); _weather.lat=lat; _weather.lon=lon; _weather.loaded=YES; _weather.needsDisplay=YES; }
        });
    });
}
- (void)seekScrub{ double f=_scrub.doubleValue; NSString *p=_player; double dur=_dur; _lastScrub=CFAbsoluteTimeGetCurrent(); _elapsed=f*dur; if(!p||dur<=0)return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0), ^{ runOSA([NSString stringWithFormat:@"tell application \"%@\" to set player position to %.1f",p,f*dur]); }); }
- (void)setVol10:(int)lv{ if(_muted){ _muted=NO; muteSet(NO); [self updateAudioIcon]; } // tocar el volumen saca el mute
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0), ^{ runOSA([NSString stringWithFormat:@"set volume output volume %d",lv*10]); }); }
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

int main(int argc,const char **argv){ if(argc>1 && !strcmp(argv[1],"--guard")) return runGuard(); @autoreleasepool { NSApplication *a=[NSApplication sharedApplication]; AppDelegate *d=[AppDelegate new]; a.delegate=d; [a setActivationPolicy:NSApplicationActivationPolicyAccessory]; [a run]; } return 0; }
