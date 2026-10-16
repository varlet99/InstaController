//
//  Tweak.m
//  InstaController iOS Runtime Hook (SCInsta-inspired & IGSideloadFix)
//
//  Interception chirurgicale ultra-sécurisée :
//  - Protection anti-récursion thread-local strict (__thread BOOL)
//  - Pré-filtrage C pur ultra-rapide (memmem) pour démarrage instantané
//  - Correction AppGroup containerURLForSecurityApplicationGroupIdentifier (IGSideloadFix)
//  - Protection contre les crashs NSString stringWithUTF8String:NULL (SideloadSpoofer)
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "InstaControllerFilter.h"

#pragma mark - Method Swizzling Helpers

static void SwizzleClassMethod(Class cls, SEL origSel, SEL newSel) {
    Method origMethod = class_getClassMethod(cls, origSel);
    Method newMethod = class_getClassMethod(cls, newSel);
    if (!origMethod || !newMethod) return;

    Class metaClass = object_getClass((id)cls);
    if (class_addMethod(metaClass, origSel, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(metaClass, newSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL newSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (!origMethod || !newMethod) return;

    if (class_addMethod(cls, origSel, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(cls, newSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

#pragma mark - Protection anti-crash NSString (SideloadSpoofer null cString guard)

@interface NSString (InstaControllerSafe)
+ (instancetype)ic_stringWithUTF8String:(const char *)nullTerminatedCString;
@end

@implementation NSString (InstaControllerSafe)

+ (instancetype)ic_stringWithUTF8String:(const char *)nullTerminatedCString {
    if (!nullTerminatedCString) {
        return @"";
    }
    return [self ic_stringWithUTF8String:nullTerminatedCString];
}

@end

#pragma mark - IGSideloadFix (Contournement des App Groups sur iOS Sideloadé)

@interface NSFileManager (IGSideloadFix)
- (NSURL *)ic_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (IGSideloadFix)

- (NSURL *)ic_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSURL *url = [self ic_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    if (!url) {
        NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *groupFolder = [NSString stringWithFormat:@"AppGroup_%@", groupIdentifier ?: @"default"];
        NSString *groupPath = [docPath stringByAppendingPathComponent:groupFolder];
        [[NSFileManager defaultManager] createDirectoryAtPath:groupPath withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:groupPath];
    }
    return url;
}

@end

#pragma mark - NSJSONSerialization Hook (Filtrage Chirurgical avec Garde Anti-Récursion)

@interface NSJSONSerialization (InstaControllerHook)
+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error;
@end

@implementation NSJSONSerialization (InstaControllerHook)

+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    // 1. Verrou thread-local strict pour interdire toute récursion
    static __thread BOOL _ic_isInsideHook = NO;
    if (_ic_isInsideHook) {
        return [self ic_JSONObjectWithData:data options:opt error:error];
    }

    // 2. Pré-filtrage ultra-rapide en C (Zéro allocation, ignore tous les micro-JSON internes)
    if (!data || data.length < 300) {
        return [self ic_JSONObjectWithData:data options:opt error:error];
    }

    const void *bytes = data.bytes;
    size_t len = (size_t)data.length;

    if (!memmem(bytes, len, "reels_tray", 10) &&
        !memmem(bytes, len, "feed_items", 10) &&
        !memmem(bytes, len, "is_sponsored", 12) &&
        !memmem(bytes, len, "xdt_api__v1__feed", 17)) {
        return [self ic_JSONObjectWithData:data options:opt error:error];
    }

    // 3. Exécution avec verrouillage anti-récursion
    _ic_isInsideHook = YES;
    id result = nil;

    @try {
        result = [self ic_JSONObjectWithData:data options:opt error:error];

        if (result && [result isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)result;

            // A. Détection Stories Tray (/api/v1/feed/reels_tray/)
            if (dict[@"tray"] != nil) {
                NSLog(@"[InstaController-iOS] Interception et tri Reels Tray natif");
                return [InstaControllerFilter filterStoriesDictionary:dict];
            }

            // B. Détection Timeline Feed (/api/v1/feed/timeline/)
            if (dict[@"feed_items"] != nil || (dict[@"items"] != nil && (dict[@"auto_load_more_enabled"] || dict[@"pagination_source"]))) {
                NSLog(@"[InstaController-iOS] Interception et purge Feed Timeline natif");
                return [InstaControllerFilter filterTimelineDictionary:dict];
            }

            // C. Détection GraphQL (Tray ou Feed)
            id dataObj = dict[@"data"];
            if ([dataObj isKindOfClass:[NSDictionary class]]) {
                for (NSString *key in [dataObj allKeys]) {
                    id sub = dataObj[key];
                    if ([sub isKindOfClass:[NSDictionary class]]) {
                        if (sub[@"tray"] != nil) {
                            return [InstaControllerFilter filterStoriesDictionary:dict];
                        }
                        if (sub[@"feed_items"] != nil || sub[@"edges"] != nil) {
                            return [InstaControllerFilter filterTimelineDictionary:dict];
                        }
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[InstaController-iOS] Exception interceptée en sécurité : %@", exception);
    } @finally {
        _ic_isInsideHook = NO;
    }

    return result;
}

@end

#pragma mark - WKWebView Auto-Injection Hook (Uniquement pour le mode Hôte)

@interface WKWebView (InstaControllerHook)
- (instancetype)ic_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration;
@end

@implementation WKWebView (InstaControllerHook)

- (instancetype)ic_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    if (configuration) {
        if (!configuration.userContentController) {
            configuration.userContentController = [[WKUserContentController alloc] init];
        }
        NSString *jsSource = [InstaControllerFilter sharedInterceptionJavaScript];
        WKUserScript *userScript = [[WKUserScript alloc] initWithSource:jsSource
                                                          injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                       forMainFrameOnly:NO];
        [configuration.userContentController addUserScript:userScript];
    }
    return [self ic_initWithFrame:frame configuration:configuration];
}

@end

#pragma mark - Constructor Initializer

__attribute__((constructor))
static void initInstaController(void) {
    NSLog(@"==================================================");
    NSLog(@"[InstaController-iOS] Dylib chargée (v3.2 - Crash Guard)");
    NSLog(@"==================================================");

    // 1. Protection NSString stringWithUTF8String:NULL contre crashs SideloadSpoofer
    Class nsStringClass = [NSString class];
    SwizzleClassMethod(nsStringClass, @selector(stringWithUTF8String:), @selector(ic_stringWithUTF8String:));

    // 2. Correction App Groups pour Instagram sideloadé (IGSideloadFix)
    Class fileManagerClass = [NSFileManager class];
    SwizzleInstanceMethod(fileManagerClass,
                          @selector(containerURLForSecurityApplicationGroupIdentifier:),
                          @selector(ic_containerURLForSecurityApplicationGroupIdentifier:));

    // 3. Swizzle sécurisé de NSJSONSerialization avec garde thread-local & pré-filtrage C
    Class jsonSerClass = [NSJSONSerialization class];
    SwizzleClassMethod(jsonSerClass,
                       @selector(JSONObjectWithData:options:error:),
                       @selector(ic_JSONObjectWithData:options:error:));

    // 4. Distinction de l'application hôte
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isNativeInstagram = [bundleId containsString:@"instagram"] || [bundleId containsString:@"burbn"];

    if (!isNativeInstagram) {
        Class wkClass = objc_getClass("WKWebView");
        if (wkClass) {
            SwizzleInstanceMethod(wkClass,
                                  @selector(initWithFrame:configuration:),
                                  @selector(ic_initWithFrame:configuration:));
            NSLog(@"[InstaController-iOS] Mode Hôte WKWebView initialisé.");
        }
    } else {
        NSLog(@"[InstaController-iOS] Mode Natif Instagram activé (Pas d'interférence avec WebKit ni SCInsta).");
    }
}
