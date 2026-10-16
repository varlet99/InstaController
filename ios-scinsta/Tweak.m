//
//  Tweak.m
//  InstaController iOS Runtime Hook (SCInsta-inspired & Sideload Safe)
//
//  Interception chirurgicale ultra-sécurisée :
//  - Lazy Initialization (délai de 3.5s au démarrage pour laisser l'UI et le Keychain s'initialiser)
//  - Protection anti-récursion thread-local stricte (__thread BOOL)
//  - Pré-filtrage C pur ultra-rapide (memmem < 0.01ms)
//  - Protection contre les crashs NSString stringWithUTF8String:NULL (SideloadSpoofer)
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "InstaControllerFilter.h"

static volatile BOOL s_appIsReady = NO;

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

#pragma mark - NSJSONSerialization Hook (Lazy Init + Garde Anti-Récursion + Memmem)

@interface NSJSONSerialization (InstaControllerHook)
+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error;
@end

@implementation NSJSONSerialization (InstaControllerHook)

+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    // 0. Lazy Initialization : ne rien intercepter pendant les premières secondes du boot UI
    if (!s_appIsReady) {
        return [self ic_JSONObjectWithData:data options:opt error:error];
    }

    // 1. Verrou thread-local strict pour interdire toute récursion
    static __thread BOOL _ic_isInsideHook = NO;
    if (_ic_isInsideHook) {
        return [self ic_JSONObjectWithData:data options:opt error:error];
    }

    // 2. Pré-filtrage ultra-rapide en C (< 0.01ms, zéro allocation, cibles explicites uniquement)
    if (!data || data.length < 300) {
        return [self ic_JSONObjectWithData:data options:opt error:error];
    }

    const void *bytes = data.bytes;
    size_t len = (size_t)data.length;

    if (!memmem(bytes, len, "reels_tray", 10) &&
        !memmem(bytes, len, "feed_items", 10)) {
        return [self ic_JSONObjectWithData:data options:opt error:error];
    }

    // 3. Exécution avec verrouillage anti-récursion
    _ic_isInsideHook = YES;
    id result = [self ic_JSONObjectWithData:data options:opt error:error];

    if (!result || ![result isKindOfClass:[NSDictionary class]]) {
        _ic_isInsideHook = NO;
        return result;
    }

    @try {
        NSDictionary *dict = (NSDictionary *)result;

        // A. Détection Stories Tray (/api/v1/feed/reels_tray/)
        if (dict[@"tray"] != nil) {
            id filtered = [InstaControllerFilter filterStoriesDictionary:dict];
            _ic_isInsideHook = NO;
            return filtered ?: result;
        }

        // B. Détection Timeline Feed (/api/v1/feed/timeline/)
        if (dict[@"feed_items"] != nil) {
            id filtered = [InstaControllerFilter filterTimelineDictionary:dict];
            _ic_isInsideHook = NO;
            return filtered ?: result;
        }
    } @catch (NSException *exception) {
        // En cas d'erreur, retourne immédiatement l'objet original sans bloquer
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
    NSLog(@"[InstaController-iOS] Dylib chargée (v3.3 - Lazy Boot & Keychain Safe)");
    NSLog(@"==================================================");

    // 1. Protection NSString stringWithUTF8String:NULL contre crashs SideloadSpoofer
    Class nsStringClass = [NSString class];
    SwizzleClassMethod(nsStringClass, @selector(stringWithUTF8String:), @selector(ic_stringWithUTF8String:));

    // 2. Swizzle sécurisé de NSJSONSerialization (inactif tant que s_appIsReady == NO)
    Class jsonSerClass = [NSJSONSerialization class];
    SwizzleClassMethod(jsonSerClass,
                       @selector(JSONObjectWithData:options:error:),
                       @selector(ic_JSONObjectWithData:options:error:));

    // 3. Activation différée de 3.5 secondes après le lancement pour laisser l'UI d'Instagram démarrer librement
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        s_appIsReady = YES;
        NSLog(@"[InstaController-iOS] Boot UI terminé -> Filtrage JSON actif (s_appIsReady = YES).");
    });

    // 4. Distinction de l'application hôte
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isNativeInstagram = [bundleId containsString:@"instagram"] || [bundleId containsString:@"burbn"];

    if (!isNativeInstagram) {
        s_appIsReady = YES;
        Class wkClass = objc_getClass("WKWebView");
        if (wkClass) {
            SwizzleInstanceMethod(wkClass,
                                  @selector(initWithFrame:configuration:),
                                  @selector(ic_initWithFrame:configuration:));
        }
    }
}
