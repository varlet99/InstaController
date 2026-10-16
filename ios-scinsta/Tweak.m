//
//  Tweak.m
//  InstaController iOS Runtime Hook (v3.6 - Fix SCIManager cleanCache Sandbox Destruction & Keychain Fallback)
//
//  Interception chirurgicale ultra-légère :
//  - Neutralisation de +[SCIManager cleanCache] qui supprimait les dossiers Library/Caches et tmp/
//    pendant didFinishLaunchingWithOptions: (causant l'écran gris au démarrage sur iOS 18)
//  - Restauration automatique des répertoires Library/Caches et tmp/ s'ils ont été détruits
//  - Vérification de secours de keychainAccessGroup via LSBundleProxy
//  - Pré-initialisation de SCInstaFirstRun et hide_ads dans NSUserDefaults
//  - Lazy Initialization (délai de 3.5s) + Garde anti-récursion (__thread BOOL) + Pré-filtrage C (memmem)
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
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

#pragma mark - Neutralisation de +[SCIManager cleanCache]

static void ic_noop_cleanCache(id self, SEL _cmd) {
    NSLog(@"[InstaController-iOS] +[SCIManager cleanCache] neutralisé (préservation de Library/Caches et tmp).");
}

#pragma mark - NSJSONSerialization Hook (Lazy Init + Garde Anti-Récursion + Memmem)

@interface NSJSONSerialization (InstaControllerHook)
+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error;
@end

@implementation NSJSONSerialization (InstaControllerHook)

+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    // 0. Lazy Initialization : ne rien intercepter pendant le boot UI
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
    NSLog(@"[InstaController-iOS] Dylib chargée (v3.6 - Fix Sandbox Caches & Keychain)");
    NSLog(@"==================================================");

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isNativeInstagram = [bundleId containsString:@"instagram"] || [bundleId containsString:@"burbn"];

    if (isNativeInstagram) {
        // 1. Restauration immédiate des dossiers Library/Caches et tmp/ (si supprimés par SCIManager cleanCache)
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tmpPath = NSTemporaryDirectory();
        if (tmpPath.length > 0 && ![fm fileExistsAtPath:tmpPath]) {
            [fm createDirectoryAtPath:tmpPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSArray *cachePaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        if (cachePaths.count > 0) {
            NSString *cacheDir = cachePaths.firstObject;
            if (cacheDir.length > 0 && ![fm fileExistsAtPath:cacheDir]) {
                [fm createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }

        // 2. Neutralisation runtime de +[SCIManager cleanCache]
        Class sciManagerCls = objc_getClass("SCIManager");
        if (sciManagerCls) {
            Method cleanMethod = class_getClassMethod(sciManagerCls, @selector(cleanCache));
            if (cleanMethod) {
                method_setImplementation(cleanMethod, (IMP)ic_noop_cleanCache);
            }
        }

        // 3. Vérification de secours de keychainAccessGroup dans SCInsta.dylib via LSBundleProxy
        NSString * __strong *scKeychainGroupPtr = (NSString * __strong *)dlsym(RTLD_DEFAULT, "keychainAccessGroup");
        if (scKeychainGroupPtr && (!*scKeychainGroupPtr || [*scKeychainGroupPtr length] == 0)) {
            Class lsClass = objc_getClass("LSBundleProxy");
            if (lsClass && [lsClass respondsToSelector:@selector(bundleProxyForCurrentProcess)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id proxy = [lsClass performSelector:@selector(bundleProxyForCurrentProcess)];
#pragma clang diagnostic pop
                if (proxy) {
                    NSDictionary *ent = [proxy valueForKey:@"entitlements"];
                    if ([ent isKindOfClass:[NSDictionary class]]) {
                        NSString *appId = ent[@"application-identifier"];
                        if ([appId isKindOfClass:[NSString class]] && appId.length > 0) {
                            *scKeychainGroupPtr = [appId copy];
                            NSLog(@"[InstaController-iOS] keychainAccessGroup restauré via LSBundleProxy : %@", *scKeychainGroupPtr);
                        }
                    }
                }
            }
        }

        // 4. Pré-initialise SCInstaFirstRun et les options anti-pub pour empêcher SCInsta d'ouvrir
        //    de manière synchrone la modale CepheiPrefs (HBListController) pendant didFinishLaunchingWithOptions:
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (![defaults objectForKey:@"SCInstaFirstRun"]) {
            [defaults setObject:@"v0.4.0 (dev)" forKey:@"SCInstaFirstRun"];
            [defaults setBool:YES forKey:@"hide_ads"];
            [defaults setBool:YES forKey:@"dw_videos"];
            [defaults setBool:YES forKey:@"save_profile"];
            [defaults setBool:YES forKey:@"remove_screenshot_alert"];
            [defaults setBool:YES forKey:@"show_like_count"];
            [defaults setBool:YES forKey:@"copy_description"];
            [defaults setBool:YES forKey:@"call_confirm"];
            [defaults setBool:YES forKey:@"hide_trending_searches"];
            [defaults setBool:YES forKey:@"no_suggested_chats"];
            [defaults setBool:YES forKey:@"no_suggested_threads"];
            [defaults synchronize];
        } else if ([defaults objectForKey:@"hide_ads"] == nil) {
            [defaults setBool:YES forKey:@"hide_ads"];
        }
    }

    // Swizzle sécurisé de NSJSONSerialization (inactif tant que s_appIsReady == NO)
    Class jsonSerClass = [NSJSONSerialization class];
    SwizzleClassMethod(jsonSerClass,
                       @selector(JSONObjectWithData:options:error:),
                       @selector(ic_JSONObjectWithData:options:error:));

    if (isNativeInstagram) {
        // Activation différée de 3.5 secondes après le lancement
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            s_appIsReady = YES;
            NSLog(@"[InstaController-iOS] Boot UI terminé -> Filtrage JSON actif (s_appIsReady = YES).");
        });
    } else {
        s_appIsReady = YES;
        Class wkClass = objc_getClass("WKWebView");
        if (wkClass) {
            SwizzleInstanceMethod(wkClass,
                                  @selector(initWithFrame:configuration:),
                                  @selector(ic_initWithFrame:configuration:));
        }
    }
}
