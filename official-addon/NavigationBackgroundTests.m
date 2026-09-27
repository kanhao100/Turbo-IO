// Runs the actual lifecycle include with small OS doubles, not an iOS runtime.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "NavigationBackground.h"
#include <assert.h>
typedef NSUInteger UIBackgroundTaskIdentifier;
static const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid=NSUIntegerMax;
typedef NS_ENUM(int, CLAuthorizationStatus){kCLAuthorizationStatusDenied=2,kCLAuthorizationStatusAuthorizedAlways=3,kCLAuthorizationStatusAuthorizedWhenInUse=4};
@interface CLLocationManager:NSObject
@property CLAuthorizationStatus authorizationStatus;
@end
@implementation CLLocationManager
@end
@interface UIApplication:NSObject
@property NSUInteger begins,ends;
@property BOOL deny;
@property(copy) void(^expiry)(void);
+ (instancetype)sharedApplication;
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void(^)(void))handler;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)t;
@end
@implementation UIApplication
+ (instancetype)sharedApplication{static UIApplication *s;static dispatch_once_t o;dispatch_once(&o,^{s=[UIApplication new];});return s;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)n expirationHandler:(void(^)(void))h{self.begins++;self.expiry=h;return self.deny?UIBackgroundTaskInvalid:self.begins;}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)t{assert(t!=UIBackgroundTaskInvalid);self.ends++;}
@end
@interface TIONavigationPanel:NSObject
@property BOOL navigationStarted,fixture,simulated,backgroundLocationEnabled;
@property NSUInteger backgroundEpoch,stops;
@property UIBackgroundTaskIdentifier navigationBackgroundTask;
@property CLLocationManager *permission;
@property NSString *note;
- (void)stopUser;
- (void)refresh;
@end
@implementation TIONavigationPanel
- (instancetype)init{if((self=[super init])){_navigationBackgroundTask=UIBackgroundTaskInvalid;_permission=[CLLocationManager new];}return self;}
- (void)refresh{}
- (void)stopUser{self.stops++;self.navigationStarted=NO;self.backgroundLocationEnabled=NO;[self endNavigationBackgroundTask];}
#include "NavigationBackground.inc"
@end
int main(void){@autoreleasepool{
    unsigned cases=0;
    for(int started=0;started<2;started++)for(int fixture=0;fixture<2;fixture++)for(int sim=0;sim<2;sim++)for(int enabled=0;enabled<2;enabled++)for(int auth=0;auth<2;auth++){
        TIONavBackgroundAction expected=fixture?TIONavBackgroundStop:!started?TIONavBackgroundIdle:sim?TIONavBackgroundSimulation:(enabled&&auth)?TIONavBackgroundLocation:TIONavBackgroundStop;
        assert(TIONavBackgroundPolicy(started,fixture,sim,enabled,auth)==expected);cases++;
    }
    UIApplication *app=UIApplication.sharedApplication;TIONavigationPanel *p=[TIONavigationPanel new];
    [p background];assert(!p.stops&&!app.begins); // Ready/planning/idle never starts location.
    p.navigationStarted=YES;p.backgroundLocationEnabled=YES;p.permission.authorizationStatus=kCLAuthorizationStatusAuthorizedWhenInUse;
    [p background];assert(p.navigationStarted&&!p.stops&&!app.begins); // No STOP on Home/lock.
    p.permission.authorizationStatus=kCLAuthorizationStatusDenied;[p background];assert(p.stops==1&&!p.navigationStarted);
    p.navigationStarted=YES;p.simulated=YES;[p background];assert(p.navigationStarted&&app.begins==1);
    [p background];assert(app.begins==1);void(^old)(void)=[app.expiry copy];
    [p navigationForeground];assert(p.navigationStarted&&app.ends==1);old();assert(p.stops==1);
    [p background];assert(app.begins==2);old();assert(p.navigationStarted);app.expiry();assert(p.stops==2&&app.ends==2&&!p.navigationStarted);
    app.expiry();assert(p.stops==2&&app.ends==2); // Exactly-once cleanup.
    p.navigationStarted=YES;app.deny=YES;[p background];assert(p.stops==3&&app.ends==2&&!p.navigationStarted);
    app.deny=NO;p.navigationStarted=YES;[p background];NSUInteger epoch=p.backgroundEpoch;[p expireNavigationBackgroundTask:epoch];assert(p.stops==4&&app.ends==3);
    p.navigationStarted=YES;[p background];old=[app.expiry copy];[p stopUser];old();assert(p.stops==5&&app.ends==4);
    p.navigationStarted=YES;p.simulated=NO;p.backgroundLocationEnabled=YES;[p navigationForeground];assert(p.stops==6); // Permission revoked in Settings.
    p.navigationStarted=YES;[p locationManagerDidChangeAuthorization:[CLLocationManager new]];assert(p.stops==6);
    [p locationManagerDidChangeAuthorization:p.permission];assert(p.stops==7&&!p.navigationStarted);
    printf("PASS %u policy combinations and lifecycle: real background, denial, simulation, foreground, stale expiry, repeated transitions, STOP cleanup\n",cases);
}}
