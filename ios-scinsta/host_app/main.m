//
//  main.m
//  InstaController-iOS Host Application with v3.0 Anti-Obfuscation Engine & DOM Scanner
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "InstaControllerFilter.h"

@interface ViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) WKWebView *webView;
@property (strong, nonatomic) UIVisualEffectView *hudView;
@property (strong, nonatomic) UILabel *hudLabel;
@property (strong, nonatomic) UIView *statusDot;
@property (strong, nonatomic) UIButton *scanButton;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // 1. Purge immédiate des Service Workers et des caches WebKit (conservation des cookies de session)
    NSSet *types = [NSSet setWithObjects:
        WKWebsiteDataTypeServiceWorkerRegistrations,
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache, nil];
    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:types
                                               modifiedSince:[NSDate distantPast]
                                           completionHandler:^{
        NSLog(@"[InstaController-iOS v3.0] Service Workers et caches WebKit purgés avec succès.");
    }];

    // 2. Configuration de la WKWebView
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;

    WKUserContentController *userContentController = [[WKUserContentController alloc] init];
    
    // Handler asynchrone ultra-léger pour le HUD natif
    [userContentController addScriptMessageHandler:self name:@"instaController"];

    // Injection universelle de l'intercepteur v3.0 in-process à DocumentStart
    NSString *jsSource = [InstaControllerFilter sharedInterceptionJavaScript];
    WKUserScript *userScript = [[WKUserScript alloc] initWithSource:jsSource
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:NO];
    [userContentController addUserScript:userScript];
    config.userContentController = userContentController;

    // 3. Initialisation de la WKWebView
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.webView.customUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 280.0.0.18.112";
    [self.view addSubview:self.webView];

    // 4. Construction du Panneau HUD Flottant Natif v3.1 avec Scanner
    [self setupNativeFloatingHUD];

    // 5. Chargement initial standard d'Instagram
    NSURL *url = [NSURL URLWithString:@"https://www.instagram.com/"];
    NSURLRequest *req = [NSURLRequest requestWithURL:url];
    [self.webView loadRequest:req];
}

- (void)setupNativeFloatingHUD {
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    self.hudView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.hudView.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudView.layer.cornerRadius = 20.0;
    self.hudView.layer.masksToBounds = YES;
    self.hudView.layer.borderWidth = 1.0;
    self.hudView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;

    // Point vert d'activité
    self.statusDot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 4.0;
    self.statusDot.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.4 alpha:1.0];

    // Label de statut avec mention explicite v3.1
    self.hudLabel = [[UILabel alloc] init];
    self.hudLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudLabel.textColor = [UIColor whiteColor];
    self.hudLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    self.hudLabel.text = @"v3.1 🛡️ Pubs : 0 | Stories : 0";

    // Séparateur vertical
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];

    // Bouton tactile Scanner DOM
    self.scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.scanButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scanButton setTitle:@"🔍 Scanner" forState:UIControlStateNormal];
    [self.scanButton setTitleColor:[UIColor colorWithRed:0.35 green:0.82 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    self.scanButton.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    [self.scanButton addTarget:self action:@selector(scanButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.hudLabel, separator, self.scanButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;

    [self.hudView.contentView addSubview:stack];
    [self.view addSubview:self.hudView];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusDot.widthAnchor constraintEqualToConstant:8.0],
        [self.statusDot.heightAnchor constraintEqualToConstant:8.0],

        [separator.widthAnchor constraintEqualToConstant:1.0],
        [separator.heightAnchor constraintEqualToConstant:14.0],

        [stack.topAnchor constraintEqualToAnchor:self.hudView.contentView.topAnchor constant:8.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.hudView.contentView.bottomAnchor constant:-8.0],
        [stack.leadingAnchor constraintEqualToAnchor:self.hudView.contentView.leadingAnchor constant:12.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.hudView.contentView.trailingAnchor constant:-12.0],

        [self.hudView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.hudView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10.0],
        [self.hudView.heightAnchor constraintEqualToConstant:40.0]
    ]];

    // Geste de toucher pour retour haptique sur le label
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hudTapped)];
    [self.hudView addGestureRecognizer:tap];
}

- (void)hudTapped {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    NSString *prevText = self.hudLabel.text;
    self.hudLabel.text = @"v3.1 ✅ Filtrage Chirurgical Actif";
    self.statusDot.backgroundColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.5 alpha:1.0];

    [UIView animateWithDuration:0.2 animations:^{
        self.hudView.transform = CGAffineTransformMakeScale(1.05, 1.05);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.2 delay:1.2 options:0 animations:^{
            self.hudView.transform = CGAffineTransformIdentity;
            self.hudLabel.text = prevText;
            self.statusDot.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.4 alpha:1.0];
        } completion:nil];
    }];
}

- (void)scanButtonTapped {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback impactOccurred];

    NSString *js = @"(function() { return (window.__INSTACONTROLLER_SCAN_DOM__ ? window.__INSTACONTROLLER_SCAN_DOM__() : 'Scanner non disponible'); })();";
    [self.webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        NSString *report = @"Aucune donnée disponible.";
        if ([result isKindOfClass:[NSString class]]) {
            report = (NSString *)result;
        } else if (error) {
            report = [NSString stringWithFormat:@"Erreur : %@", error.localizedDescription];
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🔍 Diagnostic DOM (v3.1)"
                                                                       message:report
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)updateHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger ads = [InstaControllerFilter totalAdsBlocked];
        NSInteger stories = [InstaControllerFilter totalStoriesSorted];
        self.hudLabel.text = [NSString stringWithFormat:@"v3.1 🛡️ Pubs : %ld | Stories : %ld", (long)ads, (long)stories];

        [UIView animateWithDuration:0.15 animations:^{
            self.statusDot.transform = CGAffineTransformMakeScale(1.3, 1.3);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.15 animations:^{
                self.statusDot.transform = CGAffineTransformIdentity;
            }];
        }];
    });
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"instaController"] && [message.body isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)message.body;
        NSInteger ads = [dict[@"ads"] integerValue];
        NSInteger stories = [dict[@"stories"] integerValue];
        if (ads > 0) [InstaControllerFilter incrementAdsBlocked:ads];
        if (stories > 0) [InstaControllerFilter incrementStoriesSorted:stories];
        [self updateHUD];
    }
}

#pragma mark - WKNavigationDelegate (Anti-Universal Links & Stable Navigation)

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString;

    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        // WKNavigationActionPolicyAllow + 2 = _WKNavigationActionPolicyAllowWithoutTryingAppLink
        // Empêche iOS d'ouvrir l'application Instagram officielle installée sur l'iPhone !
        decisionHandler((WKNavigationActionPolicy)(WKNavigationActionPolicyAllow + 2));
        return;
    }

    decisionHandler(WKNavigationActionPolicyCancel);
}

#pragma mark - WKUIDelegate

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText
    initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(NSString * _Nullable result))completionHandler
{
    completionHandler(nil);
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
