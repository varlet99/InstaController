//
//  main.m
//  InstaController-iOS Host Application with v2.0 In-Process Filter & Native Floating HUD
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "InstaControllerFilter.h"

@interface ViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) WKWebView *webView;
@property (strong, nonatomic) UIVisualEffectView *hudView;
@property (strong, nonatomic) UILabel *hudLabel;
@property (strong, nonatomic) UIView *statusDot;
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
        NSLog(@"[InstaController-iOS v2.0] Service Workers et caches WebKit purgés avec succès.");
    }];

    // 2. Configuration de la WKWebView
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;

    WKUserContentController *userContentController = [[WKUserContentController alloc] init];
    
    // Handler asynchrone ultra-léger pour le HUD natif
    [userContentController addScriptMessageHandler:self name:@"instaController"];

    // Injection universelle de l'intercepteur v2.0 in-process à DocumentStart
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

    // 4. Construction du Panneau HUD Flottant Natif v2.0
    [self setupNativeFloatingHUD];

    // 5. Chargement initial forcé sur le flux Abonnements chronologique
    NSURL *url = [NSURL URLWithString:@"https://www.instagram.com/?variant=following"];
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
    self.hudView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

    // Point vert d'activité
    self.statusDot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 4.0;
    self.statusDot.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.4 alpha:1.0];

    // Label de statut avec mention explicite v2.0
    self.hudLabel = [[UILabel alloc] init];
    self.hudLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudLabel.textColor = [UIColor whiteColor];
    self.hudLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.hudLabel.text = @"v2.0 🛡️ Pubs : 0 | Stories : 0";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.hudLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;

    [self.hudView.contentView addSubview:stack];
    [self.view addSubview:self.hudView];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusDot.widthAnchor constraintEqualToConstant:8.0],
        [self.statusDot.heightAnchor constraintEqualToConstant:8.0],

        [stack.topAnchor constraintEqualToAnchor:self.hudView.contentView.topAnchor constant:8.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.hudView.contentView.bottomAnchor constant:-8.0],
        [stack.leadingAnchor constraintEqualToAnchor:self.hudView.contentView.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.hudView.contentView.trailingAnchor constant:-14.0],

        [self.hudView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.hudView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10.0],
        [self.hudView.heightAnchor constraintEqualToConstant:40.0]
    ]];

    // Geste de toucher pour retour haptique
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hudTapped)];
    [self.hudView addGestureRecognizer:tap];
}

- (void)hudTapped {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    NSString *prevText = self.hudLabel.text;
    self.hudLabel.text = @"v2.0 ✅ Actif - 100% In-Process";
    self.statusDot.backgroundColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.5 alpha:1.0];

    [UIView animateWithDuration:0.2 animations:^{
        self.hudView.transform = CGAffineTransformMakeScale(1.06, 1.06);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.2 delay:1.2 options:0 animations:^{
            self.hudView.transform = CGAffineTransformIdentity;
            self.hudLabel.text = prevText;
            self.statusDot.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.4 alpha:1.0];
        } completion:nil];
    }];
}

- (void)updateHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger ads = [InstaControllerFilter totalAdsBlocked];
        NSInteger stories = [InstaControllerFilter totalStoriesSorted];
        self.hudLabel.text = [NSString stringWithFormat:@"v2.0 🛡️ Pubs : %ld | Stories : %ld", (long)ads, (long)stories];

        [UIView animateWithDuration:0.15 animations:^{
            self.statusDot.transform = CGAffineTransformMakeScale(1.3, 1.3);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.15 animations:^{
                self.statusDot.transform = CGAffineTransformIdentity;
            }];
        }];
    });
}

#pragma mark - WKScriptMessageHandler (Réception Asynchrone Ultra-Rapide)

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
