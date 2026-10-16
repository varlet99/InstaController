//
//  Tweak.m
//  InstaController iOS Runtime Hook (SCInsta-inspired & Sideload Safe v3.4)
//
//  Interception chirurgicale ultra-sécurisée :
//  - Résolution automatique du Keychain Access Group réel (FBBuildBundleIdentifier / LSKeychainItemController)
//  - Protection anti-crash __NSDictionaryM (__setObject:forKey:, setObject:forKey:, dictionaryWithObjects:forKeys:count:)
//  - Protection anti-crash NSString (stringWithUTF8String:NULL) et NSError (initWithDomain:nil)
//  - Lazy Initialization (délai de 3.5s au démarrage pour laisser l'UI s'initialiser)
//  - Garde anti-récursion thread-local stricte (__thread BOOL) + Pré-filtrage C (memmem)
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "InstaControllerFilter.h"

static volatile BOOL s_appIsReady = NO;
static NSString *s_realKeychainAccessGroup = nil;

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

#pragma mark - Détection du Keychain Access Group réel de l'IPA signé

static void LoadRealKeychainAccessGroup(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"InstaControllerKeychainProbe",
        (__bridge id)kSecAttrService: @"InstaControllerKeychainService",
        (__bridge id)kSecReturnAttributes: @YES
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        status = SecItemAdd((__bridge CFDictionaryRef)query, &result);
    }
    if (status == errSecSuccess && result != NULL) {
        NSDictionary *resultDict = (__bridge_transfer NSDictionary *)result;
        NSString *group = resultDict[(__bridge id)kSecAttrAccessGroup];
        if ([group isKindOfClass:[NSString class]] && group.length > 0) {
            s_realKeychainAccessGroup = [group copy];
            NSLog(@"[InstaController-iOS] Keychain Access Group actif : %@", s_realKeychainAccessGroup);
        }
    }
}

#pragma mark - Protection anti-crash NSString & NSError (SideloadSpoofer guards)

@interface NSString (InstaControllerSafe)
+ (instancetype)ic_stringWithUTF8String:(const char *)nullTerminatedCString;
- (instancetype)ic_initWithUTF8String:(const char *)nullTerminatedCString;
@end

@implementation NSString (InstaControllerSafe)

+ (instancetype)ic_stringWithUTF8String:(const char *)nullTerminatedCString {
    if (!nullTerminatedCString) return @"";
    return [self ic_stringWithUTF8String:nullTerminatedCString];
}

- (instancetype)ic_initWithUTF8String:(const char *)nullTerminatedCString {
    if (!nullTerminatedCString) return [self ic_initWithUTF8String:""];
    return [self ic_initWithUTF8String:nullTerminatedCString];
}

@end

@interface NSError (InstaControllerSafe)
- (instancetype)ic_initWithDomain:(NSErrorDomain)domain code:(NSInteger)code userInfo:(NSDictionary *)dict;
+ (instancetype)ic_errorWithDomain:(NSErrorDomain)domain code:(NSInteger)code userInfo:(NSDictionary *)dict;
@end

@implementation NSError (InstaControllerSafe)

- (instancetype)ic_initWithDomain:(NSErrorDomain)domain code:(NSInteger)code userInfo:(NSDictionary *)dict {
    if (!domain) domain = @"NSCocoaErrorDomain";
    return [self ic_initWithDomain:domain code:code userInfo:dict];
}

+ (instancetype)ic_errorWithDomain:(NSErrorDomain)domain code:(NSInteger)code userInfo:(NSDictionary *)dict {
    if (!domain) domain = @"NSCocoaErrorDomain";
    return [self ic_errorWithDomain:domain code:code userInfo:dict];
}

@end

#pragma mark - Protection __NSDictionaryM & Redirection Keychain (FBBuildBundleIdentifier Fix)

@interface NSMutableDictionary (InstaControllerKeychainSafe)
- (void)ic_setObject:(id)anObject forKey:(id<NSCopying>)aKey;
- (void)ic___setObject:(id)anObject forKey:(id<NSCopying>)aKey;
- (void)ic_setObject:(id)anObject forKeyedSubscript:(id<NSCopying>)aKey;
@end

@implementation NSMutableDictionary (InstaControllerKeychainSafe)

- (void)ic_setObject:(id)anObject forKey:(id<NSCopying>)aKey {
    if (!aKey) return;
    if ([(id)aKey isKindOfClass:[NSString class]] && [(NSString *)aKey isEqualToString:@"agrp"]) {
        if (s_realKeychainAccessGroup.length > 0) {
            [self ic_setObject:s_realKeychainAccessGroup forKey:aKey];
        } else {
            [self removeObjectForKey:aKey];
        }
        return;
    }
    if (!anObject) {
        [self removeObjectForKey:aKey];
        return;
    }
    [self ic_setObject:anObject forKey:aKey];
}

- (void)ic___setObject:(id)anObject forKey:(id<NSCopying>)aKey {
    if (!aKey) return;
    if ([(id)aKey isKindOfClass:[NSString class]] && [(NSString *)aKey isEqualToString:@"agrp"]) {
        if (s_realKeychainAccessGroup.length > 0) {
            [self ic___setObject:s_realKeychainAccessGroup forKey:aKey];
        } else {
            [self removeObjectForKey:aKey];
        }
        return;
    }
    if (!anObject) {
        [self removeObjectForKey:aKey];
        return;
    }
    [self ic___setObject:anObject forKey:aKey];
}

- (void)ic_setObject:(id)anObject forKeyedSubscript:(id<NSCopying>)aKey {
    if (!aKey) return;
    if ([(id)aKey isKindOfClass:[NSString class]] && [(NSString *)aKey isEqualToString:@"agrp"]) {
        if (s_realKeychainAccessGroup.length > 0) {
            [self ic_setObject:s_realKeychainAccessGroup forKeyedSubscript:aKey];
        } else {
            [self removeObjectForKey:aKey];
        }
        return;
    }
    if (!anObject) {
        [self removeObjectForKey:aKey];
        return;
    }
    [self ic_setObject:anObject forKeyedSubscript:aKey];
}

@end

@interface NSDictionary (InstaControllerKeychainSafe)
+ (instancetype)ic_dictionaryWithObjects:(const id [])objects forKeys:(const id<NSCopying> [])keys count:(NSUInteger)cnt;
@end

@implementation NSDictionary (InstaControllerKeychainSafe)

+ (instancetype)ic_dictionaryWithObjects:(const id [])objects forKeys:(const id<NSCopying> [])keys count:(NSUInteger)cnt {
    if (cnt == 0 || !objects || !keys) {
        return [self ic_dictionaryWithObjects:objects forKeys:keys count:cnt];
    }
    BOOL needsFix = NO;
    for (NSUInteger i = 0; i < cnt; i++) {
        if (!keys[i] || !objects[i]) {
            needsFix = YES;
            break;
        }
        if ([(id)keys[i] isKindOfClass:[NSString class]] && [(NSString *)keys[i] isEqualToString:@"agrp"]) {
            needsFix = YES;
            break;
        }
    }
    if (!needsFix) {
        return [self ic_dictionaryWithObjects:objects forKeys:keys count:cnt];
    }

    id fixedObjects[cnt];
    id<NSCopying> fixedKeys[cnt];
    NSUInteger outIdx = 0;
    for (NSUInteger i = 0; i < cnt; i++) {
        if (!keys[i]) continue;
        id obj = objects[i];
        if ([(id)keys[i] isKindOfClass:[NSString class]] && [(NSString *)keys[i] isEqualToString:@"agrp"]) {
            if (s_realKeychainAccessGroup.length > 0) {
                obj = s_realKeychainAccessGroup;
            } else {
                continue;
            }
        }
        if (!obj) continue;
        fixedKeys[outIdx] = keys[i];
        fixedObjects[outIdx] = obj;
        outIdx++;
    }
    return [self ic_dictionaryWithObjects:fixedObjects forKeys:fixedKeys count:outIdx];
}

@end

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
    NSLog(@"[InstaController-iOS] Dylib chargée (v3.4 - Full Keychain & Dictionary Guard)");
    NSLog(@"==================================================");

    // 1. Détection du Keychain Access Group réel avant tout hook de dictionnaire
    LoadRealKeychainAccessGroup();

    // 2. Protection NSString & NSError contre les pointeurs NULL de SideloadSpoofer
    Class nsStringClass = [NSString class];
    SwizzleClassMethod(nsStringClass, @selector(stringWithUTF8String:), @selector(ic_stringWithUTF8String:));
    SwizzleInstanceMethod(nsStringClass, @selector(initWithUTF8String:), @selector(ic_initWithUTF8String:));

    Class nsErrorClass = [NSError class];
    SwizzleInstanceMethod(nsErrorClass, @selector(initWithDomain:code:userInfo:), @selector(ic_initWithDomain:code:userInfo:));
    SwizzleClassMethod(nsErrorClass, @selector(errorWithDomain:code:userInfo:), @selector(ic_errorWithDomain:code:userInfo:));

    // 3. Protection __NSDictionaryM & NSDictionary (évite le crash/blocage FBBlockAndFetchDeviceIDFromKeychain)
    Class dictMClass = objc_getClass("__NSDictionaryM");
    if (dictMClass) {
        SwizzleInstanceMethod(dictMClass, @selector(setObject:forKey:), @selector(ic_setObject:forKey:));
        SwizzleInstanceMethod(dictMClass, @selector(__setObject:forKey:), @selector(ic___setObject:forKey:));
        SwizzleInstanceMethod(dictMClass, @selector(setObject:forKeyedSubscript:), @selector(ic_setObject:forKeyedSubscript:));
    }
    SwizzleClassMethod([NSDictionary class],
                       @selector(dictionaryWithObjects:forKeys:count:),
                       @selector(ic_dictionaryWithObjects:forKeys:count:));

    // 4. Swizzle sécurisé de NSJSONSerialization (inactif tant que s_appIsReady == NO)
    Class jsonSerClass = [NSJSONSerialization class];
    SwizzleClassMethod(jsonSerClass,
                       @selector(JSONObjectWithData:options:error:),
                       @selector(ic_JSONObjectWithData:options:error:));

    // 5. Activation différée de 3.5 secondes après le lancement
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        s_appIsReady = YES;
        NSLog(@"[InstaController-iOS] Boot UI terminé -> Filtrage JSON actif (s_appIsReady = YES).");
    });

    // 6. Distinction de l'application hôte
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
