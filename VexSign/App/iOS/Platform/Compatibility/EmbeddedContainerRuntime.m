#import "EmbeddedContainerRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>

/// The entry points this build calls on the host, in one place so the probe and
/// the availability gate cannot disagree about the contract.
static NSArray<NSString *> *VEXRequiredHostSelectors(void) {
    return @[
        @"vexSignCombinedHostAvailable",
        @"launchToGuestAppWithURL:",
        @"vexSignStageIPA:",
        @"vexSignGuestInfo:",
    ];
}

/// Whether this process was packaged as part of a combined host at all.
static BOOL VEXDeclaresHostMetadata(void) {
    NSDictionary *metadata = NSBundle.mainBundle.infoDictionary;
    return [metadata[@"VexSignEmbeddedGuest"] boolValue] || [metadata[@"VexSignPrimaryHost"] boolValue];
}

static Class VEXHostClass(void) {
    return NSClassFromString(@"LCSharedUtils");
}

/// Whether the runtime class came from an executable image rather than an injected library.
///
/// `NSClassFromString` searches every loaded image, and a jailbroken or TrollStore install -
/// both supported routes for this app - lets a dylib claim the host class name. Such a class
/// would then be asked to stage an IPA, or to launch a guest, which is exactly the handle an
/// injector wants. A host is always a bundle executable: never a `.dylib`, never a framework
/// binary. This does not prove the class belongs to the intended host; the ABI has no
/// challenge that could, but it removes the trivially reachable path.
static BOOL VEXHostImageIsExecutable(Class runtime) {
    if (runtime == Nil) return NO;
    const char *image = class_getImageName(runtime);
    if (image == NULL) return NO;
    NSString *path = [NSString stringWithUTF8String:image];
    if (path.length == 0) return NO;
    if ([path containsString:@".framework/"]) return NO;
    return ![path.pathExtension.lowercased() isEqualToString:@"dylib"];
}

NSArray<NSString *> *VEXEmbeddedRuntimeMissingSelectors(void) {
    if (!VEXDeclaresHostMetadata()) return VEXRequiredHostSelectors();
    Class runtime = VEXHostClass();
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in VEXRequiredHostSelectors()) {
        if (!runtime || ![runtime respondsToSelector:NSSelectorFromString(name)]) {
            [missing addObject:name];
        }
    }
    return missing;
}

static Class VEXHostRuntime(void) {
    if (!VEXDeclaresHostMetadata()) return Nil;
    Class runtime = VEXHostClass();
    SEL available = NSSelectorFromString(@"vexSignCombinedHostAvailable");
    if (!VEXHostImageIsExecutable(runtime) || ![runtime respondsToSelector:available]) return Nil;
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
    if (![source isKindOfClass:NSURL.class] || !source.isFileURL) return NO;
    // This is reached from the import task's thread, which has no run loop: without a pool the
    // selector strings, the URL and whatever the host allocates in the call stay alive until
    // the thread's GCD pool drains.
    @autoreleasepool {
        Class runtime = VEXHostRuntime();
        SEL stage = NSSelectorFromString(@"vexSignStageIPA:");
        if (!runtime || ![runtime respondsToSelector:stage]) return NO;
        BOOL (*invoke)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))(void *)objc_msgSend;
        return invoke(runtime, stage, source);
    }
}

NSDictionary<NSString *, NSString *> *VEXEmbeddedRuntimeGuestInfo(NSString *identifier) {
    if (identifier.length == 0) return nil;
    // Same reason as staging: this is asked from whatever thread is refreshing the note, and
    // the host answers with autoreleased objects.
    @autoreleasepool {
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
        return [result copy];
    }
}
