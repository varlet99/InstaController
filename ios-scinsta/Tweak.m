//
//  Tweak.m
//  InstaController iOS Runtime Hook (SCInsta-inspired)
//
//  Intercepte NSJSONSerialization et les classes du runtime Instagram iOS.
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "InstaControllerFilter.h"

#pragma mark - Method Swizzling Helper

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

#pragma mark - NSJSONSerialization Hook

@interface NSJSONSerialization (InstaControllerHook)
+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error;
@end

@implementation NSJSONSerialization (InstaControllerHook)

+ (id)ic_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = [self ic_JSONObjectWithData:data options:opt error:error];

    if (!result || ![result isKindOfClass:[NSDictionary class]]) {
        return result;
    }

    @try {
        NSDictionary *dict = (NSDictionary *)result;

        // 1. Détection de réponse Stories Tray (/api/v1/feed/reels_tray/)
        if (dict[@"tray"] != nil) {
            NSLog(@"[InstaController-iOS] Interception de 'reels_tray' via NSJSONSerialization");
            return [InstaControllerFilter filterStoriesDictionary:dict];
        }

        // 2. Détection de réponse Timeline Feed (/api/v1/feed/timeline/)
        if (dict[@"feed_items"] != nil || (dict[@"items"] != nil && (dict[@"auto_load_more_enabled"] || dict[@"pagination_source"]))) {
            NSLog(@"[InstaController-iOS] Interception de 'feed/timeline' via NSJSONSerialization");
            return [InstaControllerFilter filterTimelineDictionary:dict];
        }

        // 3. Détection de réponse GraphQL (Stories ou Feed)
        id dataObj = dict[@"data"];
        if ([dataObj isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in [dataObj allKeys]) {
                id sub = dataObj[key];
                if ([sub isKindOfClass:[NSDictionary class]]) {
                    if (sub[@"tray"] != nil) {
                        NSLog(@"[InstaController-iOS] Interception de 'tray' GraphQL");
                        return [InstaControllerFilter filterStoriesDictionary:dict];
                    }
                    if (sub[@"feed_items"] != nil || sub[@"edges"] != nil) {
                        NSLog(@"[InstaController-iOS] Interception de 'feed' GraphQL");
                        return [InstaControllerFilter filterTimelineDictionary:dict];
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[InstaController-iOS] Exception dans le hook JSON : %@", exception);
    }

    return result;
}

@end

#pragma mark - Native SCInsta Runtime Hooks (Classes Objective-C)

static BOOL FalseReturnBool(id self, SEL _cmd) {
    return NO;
}

static id NilReturnId(id self, SEL _cmd) {
    return nil;
}

static void HookSCInstaNativeClasses(void) {
    // 1. Hook sur IGFeedItem
    Class igFeedItem = objc_getClass("IGFeedItem");
    if (igFeedItem) {
        NSLog(@"[InstaController-iOS] Classe IGFeedItem détectée dans le runtime. Injection des hooks...");
        class_replaceMethod(igFeedItem, sel_registerName("isSponsored"), (IMP)FalseReturnBool, "c@:");
        class_replaceMethod(igFeedItem, sel_registerName("isSponsoredItem"), (IMP)FalseReturnBool, "c@:");
        class_replaceMethod(igFeedItem, sel_registerName("sponsoredPostInfo"), (IMP)NilReturnId, "@@:");
        class_replaceMethod(igFeedItem, sel_registerName("hasInjectedStoryTrayItems"), (IMP)FalseReturnBool, "c@:");
    }

    // 2. Hook sur IGPostItem
    Class igPostItem = objc_getClass("IGPostItem");
    if (igPostItem) {
        class_replaceMethod(igPostItem, sel_registerName("isSponsored"), (IMP)FalseReturnBool, "c@:");
    }

    // 3. Hook sur IGStoryTrayDataSource
    Class igStoryTrayDataSource = objc_getClass("IGStoryTrayDataSource");
    if (igStoryTrayDataSource) {
        NSLog(@"[InstaController-iOS] Classe IGStoryTrayDataSource détectée dans le runtime.");
    }
}

#pragma mark - WKWebView Auto-Injection Hook

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
        NSLog(@"[InstaController-iOS] Script de filtrage universel injecté dans la WKWebView.");
    }
    return [self ic_initWithFrame:frame configuration:configuration];
}

@end

#pragma mark - Constructor Initializer

__attribute__((constructor))
static void initInstaController(void) {
    NSLog(@"==================================================");
    NSLog(@"[InstaController-iOS] Dylib chargée et active dans Instagram !");
    NSLog(@"[InstaController-iOS] Architecture : ARM64");
    NSLog(@"==================================================");

    // Swizzle de NSJSONSerialization
    Class jsonSerClass = [NSJSONSerialization class];
    SEL origSel = @selector(JSONObjectWithData:options:error:);
    SEL newSel = @selector(ic_JSONObjectWithData:options:error:);
    SwizzleClassMethod(jsonSerClass, origSel, newSel);

    // Swizzle de WKWebView pour injection universelle
    Class wkClass = objc_getClass("WKWebView");
    if (wkClass) {
        SEL wkOrigSel = @selector(initWithFrame:configuration:);
        SEL wkNewSel = @selector(ic_initWithFrame:configuration:);
        SwizzleInstanceMethod(wkClass, wkOrigSel, wkNewSel);
        NSLog(@"[InstaController-iOS] Hook de WKWebView initialisé.");
    }

    // Hooks sur classes natives Instagram si présentes au chargement
    HookSCInstaNativeClasses();
}

