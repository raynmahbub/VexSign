#import "EmbeddedContainerRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>

static Class VEXHostRuntime(void) {
    if (![NSBundle.mainBundle.infoDictionary[@"VexSignEmbeddedGuest"] boolValue]) return Nil;
    Class runtime = NSClassFromString(@"LCSharedUtils");
    SEL available = NSSelectorFromString(@"vexSignCombinedHostAvailable");
    if (!runtime || ![runtime respondsToSelector:available]) return Nil;
    BOOL (*invoke)(id, SEL) = (BOOL (*)(id, SEL))(void *)objc_msgSend;
    return invoke(runtime, available) ? runtime : Nil;
}

BOOL VEXEmbeddedRuntimeAvailable(void) {
    return VEXHostRuntime() != Nil;
}

BOOL VEXEmbeddedRuntimeOpen(BOOL sideStore) {
    // UIKit/session relaunch must be initiated on the main thread.
    if (!NSThread.isMainThread) return NO;
    Class runtime = VEXHostRuntime();
    SEL launch = NSSelectorFromString(@"launchToGuestAppWithURL:");
    if (!runtime || ![runtime respondsToSelector:launch]) return NO;
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"livecontainer";
    components.host = @"livecontainer-launch";
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"bundle-name"
                                                        value:sideStore ? @"builtinSideStore" : @"ui"]];
    BOOL (*invoke)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))(void *)objc_msgSend;
    // This is a direct call into this process's loaded LCSharedUtils class.
    // There is no UIApplication.openURL/canOpenURL external-app fallback.
    return invoke(runtime, launch, components.URL);
}

BOOL VEXEmbeddedRuntimeStageIPA(NSURL *source) {
    Class runtime = VEXHostRuntime();
    SEL stage = NSSelectorFromString(@"vexSignStageIPA:");
    if (!runtime || ![runtime respondsToSelector:stage]) return NO;
    BOOL (*invoke)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))(void *)objc_msgSend;
    return invoke(runtime, stage, source);
}

NSDictionary<NSString *, NSString *> *VEXEmbeddedRuntimeGuestInfo(NSString *identifier) {
    Class runtime = VEXHostRuntime();
    SEL query = NSSelectorFromString(@"vexSignGuestInfo:");
    if (!runtime || ![runtime respondsToSelector:query]) return nil;
    id (*invoke)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))(void *)objc_msgSend;
    id answer = invoke(runtime, query, identifier);
    if (![answer isKindOfClass:NSDictionary.class]) return nil;
    // Pass through only the small, typed public inventory fields.
    NSString *state = answer[@"state"];
    if (![state isKindOfClass:NSString.class]) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:state forKey:@"state"];
    id version = answer[@"version"];
    if ([version isKindOfClass:NSString.class]) result[@"version"] = version;
    return result;
}
