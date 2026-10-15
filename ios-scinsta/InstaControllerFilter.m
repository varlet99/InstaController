//
//  InstaControllerFilter.m
//  InstaController iOS Native Engine
//
//  Implémentation complète en Objective-C natif de :core-filter
//

#import "InstaControllerFilter.h"

// Ancres de désérialisation GraphQL Meta Instagram
static NSString *const kGraphQLTimelineConnectionKey = @"xdt_api__v1__feed__timeline__connection";
static NSString *const kGraphQLReelsTrayKey = @"xdt_api__v1__feed__reels_tray";

static const double kScoreFavorite = 1000.0;
static const double kScoreActiveFollowing = 500.0;
static const double kScoreSecondary = 250.0;
static const double kScoreNotFollowing = 100.0;
static const double kScoreSeen = 10.0;

@implementation InstaControllerFilter

#pragma mark - Timeline Filtering

+ (nullable NSData *)filterTimelineData:(NSData *)jsonData error:(NSError **)error {
    if (!jsonData || jsonData.length == 0) return jsonData;

    id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData
                                                    options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves
                                                      error:error];
    if (!jsonObject || ![jsonObject isKindOfClass:[NSDictionary class]]) {
        return jsonData;
    }

    NSDictionary *filtered = [self filterTimelineDictionary:(NSDictionary *)jsonObject];
    return [NSJSONSerialization dataWithJSONObject:filtered options:0 error:error];
}

+ (NSDictionary *)filterTimelineDictionary:(NSDictionary *)timelineDict {
    if (!timelineDict || ![timelineDict isKindOfClass:[NSDictionary class]]) return timelineDict;

    NSMutableDictionary *root = [timelineDict mutableCopy];

    // Nettoyage des clés standard REST
    [self cleanArrayIfPresentInDictionary:root key:@"feed_items"];
    [self cleanArrayIfPresentInDictionary:root key:@"items"];

    // Neutralisation des drapeaux racine publicitaires
    NSArray<NSString *> *adRootKeys = @[
        @"ad_action", @"ad_header_style", @"ig_ads_peak_hour_throttling_config",
        @"is_promoted", @"has_promoted_media", @"feed_recs_user_interests_enabled"
    ];
    for (NSString *k in adRootKeys) {
        if (root[k]) {
            [root removeObjectForKey:k];
        }
    }

    // Support GraphQL: { "data": { "...": { "edges": [ ... ] } } }
    id dataObj = root[@"data"];
    if ([dataObj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutableData = [dataObj mutableCopy];
        
        // Cible spécifique Timeline Connection GraphQL
        if ([mutableData[kGraphQLTimelineConnectionKey] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *conn = [mutableData[kGraphQLTimelineConnectionKey] mutableCopy];
            [self cleanArrayIfPresentInDictionary:conn key:@"edges"];
            mutableData[kGraphQLTimelineConnectionKey] = conn;
        }

        for (NSString *key in [dataObj allKeys]) {
            id subObj = dataObj[key];
            if ([subObj isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *mutableSubObj = [subObj mutableCopy];
                [self cleanArrayIfPresentInDictionary:mutableSubObj key:@"feed_items"];
                [self cleanArrayIfPresentInDictionary:mutableSubObj key:@"items"];

                id edges = mutableSubObj[@"edges"];
                if ([edges isKindOfClass:[NSArray class]]) {
                    NSMutableArray *cleanedEdges = [NSMutableArray array];
                    for (id edge in (NSArray *)edges) {
                        if (![edge isKindOfClass:[NSDictionary class]]) continue;
                        id node = edge[@"node"] ?: edge;
                        if ([node isKindOfClass:[NSDictionary class]] && ![self isAdOrAlgorithmicInsertion:node]) {
                            [cleanedEdges addObject:edge];
                        }
                    }
                    mutableSubObj[@"edges"] = cleanedEdges;
                }
                mutableData[key] = mutableSubObj;
            }
        }
        root[@"data"] = mutableData;
    }

    return root;
}

+ (void)cleanArrayIfPresentInDictionary:(NSMutableDictionary *)parent key:(NSString *)key {
    id arr = parent[key];
    if ([arr isKindOfClass:[NSArray class]]) {
        NSMutableArray *cleaned = [NSMutableArray array];
        for (id item in (NSArray *)arr) {
            if ([item isKindOfClass:[NSDictionary class]] && ![self isAdOrAlgorithmicInsertion:item]) {
                [cleaned addObject:item];
            }
        }
        NSInteger removed = ((NSArray *)arr).count - cleaned.count;
        if (removed > 0) {
            [self incrementAdsBlocked:removed];
        }
        parent[key] = cleaned;
    }
}

#pragma mark - Stories Tray Filtering & Sorting

+ (nullable NSData *)filterStoriesData:(NSData *)jsonData error:(NSError **)error {
    if (!jsonData || jsonData.length == 0) return jsonData;

    id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData
                                                    options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves
                                                      error:error];
    if (!jsonObject || ![jsonObject isKindOfClass:[NSDictionary class]]) {
        return jsonData;
    }

    NSDictionary *filtered = [self filterStoriesDictionary:(NSDictionary *)jsonObject];
    return [NSJSONSerialization dataWithJSONObject:filtered options:0 error:error];
}

+ (NSDictionary *)filterStoriesDictionary:(NSDictionary *)storiesDict {
    if (!storiesDict || ![storiesDict isKindOfClass:[NSDictionary class]]) return storiesDict;

    NSMutableDictionary *root = [storiesDict mutableCopy];

    if ([root[@"tray"] isKindOfClass:[NSArray class]]) {
        root[@"tray"] = [self filterAndSortTray:(NSArray *)root[@"tray"]];
        return root;
    }

    // Support GraphQL Stories: { "data": { "xdt_api__v1__feed__reels_tray": { "tray": [ ... ] } } }
    id dataObj = root[@"data"];
    if ([dataObj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutableData = [dataObj mutableCopy];
        
        // Cible spécifique Reels Tray GraphQL
        if ([mutableData[kGraphQLReelsTrayKey] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *reelTray = [mutableData[kGraphQLReelsTrayKey] mutableCopy];
            if ([reelTray[@"tray"] isKindOfClass:[NSArray class]]) {
                reelTray[@"tray"] = [self filterAndSortTray:(NSArray *)reelTray[@"tray"]];
                mutableData[kGraphQLReelsTrayKey] = reelTray;
            }
        }

        for (NSString *key in [dataObj allKeys]) {
            id subObj = dataObj[key];
            if ([subObj isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *mutableSubObj = [subObj mutableCopy];
                if ([mutableSubObj[@"tray"] isKindOfClass:[NSArray class]]) {
                    mutableSubObj[@"tray"] = [self filterAndSortTray:(NSArray *)mutableSubObj[@"tray"]];
                    mutableData[key] = mutableSubObj;
                }
            }
        }
        root[@"data"] = mutableData;
    }

    return root;
}

+ (NSArray *)filterAndSortTray:(NSArray *)originalTray {
    NSMutableArray<NSDictionary *> *validStories = [NSMutableArray array];

    for (id rawItem in originalTray) {
        if (![rawItem isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *item = (NSDictionary *)rawItem;

        // 1. Élimination des annonces dans les stories
        if ([self isAdOrAlgorithmicInsertion:item]) {
            continue;
        }

        [validStories addObject:item];
    }

    NSInteger removedAds = originalTray.count - validStories.count;
    if (removedAds > 0) {
        [self incrementAdsBlocked:removedAds];
    }
    if (validStories.count > 0) {
        [self incrementStoriesSorted:validStories.count];
    }

    // 2. Tri par score PriorityStoryScorer décroissant
    [validStories sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        double score1 = [self scoreStoryTrayItem:obj1];
        double score2 = [self scoreStoryTrayItem:obj2];
        if (score1 > score2) return NSOrderedAscending;
        if (score1 < score2) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // 3. Réindexation stricte de ranked_position (0, 1, 2...)
    NSMutableArray *reindexedTray = [NSMutableArray arrayWithCapacity:validStories.count];
    for (NSUInteger idx = 0; idx < validStories.count; idx++) {
        NSMutableDictionary *story = [validStories[idx] mutableCopy];
        story[@"ranked_position"] = @(idx);
        [reindexedTray addObject:story];
    }

    return reindexedTray;
}

#pragma mark - Ad / Suggestion Detection

+ (BOOL)isAdOrAlgorithmicInsertion:(NSDictionary *)item {
    if (!item || ![item isKindOfClass:[NSDictionary class]]) return NO;

    if ([self hasAdMarkers:item]) {
        return YES;
    }

    // Vérification dans sous-objets media_or_ad, story, media
    for (NSString *subKey in @[@"media_or_ad", @"story", @"media", @"explore_item"]) {
        id sub = item[subKey];
        if ([sub isKindOfClass:[NSDictionary class]] && [self hasAdMarkers:sub]) {
            return YES;
        }
    }

    return NO;
}

+ (BOOL)hasAdMarkers:(NSDictionary *)dict {
    // is_sponsored
    id isSponsored = dict[@"is_sponsored"];
    if (isSponsored) {
        if ([isSponsored respondsToSelector:@selector(boolValue)] && [isSponsored boolValue]) {
            return YES;
        }
        if ([isSponsored respondsToSelector:@selector(integerValue)] && [isSponsored integerValue] == 1) {
            return YES;
        }
    }

    // ad_id
    id adId = dict[@"ad_id"];
    if (adId && ![adId isKindOfClass:[NSNull class]]) {
        NSString *str = [NSString stringWithFormat:@"%@", adId];
        if (str.length > 0 && ![str isEqualToString:@"0"]) {
            return YES;
        }
    }

    // injected
    if (dict[@"injected"]) {
        return YES;
    }

    // netego_type
    if (dict[@"netego_type"]) {
        return YES;
    }

    // suggested_users
    if (dict[@"suggested_users"]) {
        return YES;
    }

    // format publicitaire ou partenariat
    if (dict[@"ad_action"] || dict[@"link_text"] || dict[@"is_paid_partnership"]) {
        id paid = dict[@"is_paid_partnership"];
        if (paid && [paid respondsToSelector:@selector(boolValue)] && [paid boolValue]) {
            return YES;
        }
        if (dict[@"ad_action"]) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - Priority Story Scorer

+ (double)scoreStoryTrayItem:(NSDictionary *)storyTrayItem {
    NSDictionary *userObj = storyTrayItem[@"user"];
    NSDictionary *friendshipStatus = [userObj isKindOfClass:[NSDictionary class]] ? userObj[@"friendship_status"] : nil;

    BOOL isBestie = NO;
    if ([friendshipStatus isKindOfClass:[NSDictionary class]]) {
        id bestieVal = friendshipStatus[@"is_bestie"];
        if ([bestieVal respondsToSelector:@selector(boolValue)]) {
            isBestie = [bestieVal boolValue];
        }
    }

    BOOL isFollowing = YES;
    if ([friendshipStatus isKindOfClass:[NSDictionary class]]) {
        id followingVal = friendshipStatus[@"following"];
        if ([followingVal respondsToSelector:@selector(boolValue)]) {
            isFollowing = [followingVal boolValue];
        }
    }

    long long seen = [storyTrayItem[@"seen"] respondsToSelector:@selector(longLongValue)] ? [storyTrayItem[@"seen"] longLongValue] : 0;
    long long latestReelMedia = [storyTrayItem[@"latest_reel_media"] respondsToSelector:@selector(longLongValue)] ? [storyTrayItem[@"latest_reel_media"] longLongValue] : 0;
    BOOL isAlreadySeen = (seen > 0 && seen >= latestReelMedia);

    double baseScore = kScoreActiveFollowing;
    if (isAlreadySeen) {
        baseScore = kScoreSeen;
    } else if (isBestie) {
        baseScore = kScoreFavorite;
    } else if (!isFollowing) {
        baseScore = kScoreNotFollowing;
    }

    // Bonus de fraîcheur
    if (latestReelMedia > 0 && !isAlreadySeen) {
        double recencyBonus = (double)(latestReelMedia % 100000) / 1000.0;
        baseScore += recencyBonus;
    }

    // Malus pour mots-clés de partenariats/placements
    baseScore += [self inspectStoryItemsForAdIndicators:storyTrayItem];

    return baseScore;
}

+ (double)inspectStoryItemsForAdIndicators:(NSDictionary *)storyTrayItem {
    id items = storyTrayItem[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return 0.0;

    static NSDictionary<NSString *, NSNumber *> *adKeywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adKeywords = @{
            @"sponsorise": @(-300.0),
            @"partenariat": @(-300.0),
            @"collaboration": @(-300.0),
            @"codepromo": @(-300.0),
            @"promo": @(-200.0),
            @"remise": @(-200.0),
            @"ad": @(-200.0)
        };
    });

    double malus = 0.0;
    for (id item in (NSArray *)items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        id caption = item[@"caption"];
        NSString *text = @"";
        if ([caption isKindOfClass:[NSDictionary class]]) {
            text = caption[@"text"] ?: @"";
        }
        if (text.length == 0) continue;

        NSString *lower = [text lowercaseString];
        for (NSString *kw in adKeywords) {
            if ([lower containsString:kw]) {
                malus += [adKeywords[kw] doubleValue];
            }
        }
    }

    return malus;
}

#pragma mark - String Processing Bridge

+ (NSString *)processTimelineJsonString:(NSString *)jsonString {
    if (!jsonString || jsonString.length < 5) return jsonString;
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return jsonString;

    NSError *error = nil;
    NSData *filteredData = [self filterTimelineData:data error:&error];
    if (filteredData && !error) {
        NSString *result = [[NSString alloc] initWithData:filteredData encoding:NSUTF8StringEncoding];
        if (result && result.length > 5) {
            return result;
        }
    }
    return jsonString;
}

+ (NSString *)processStoriesJsonString:(NSString *)jsonString {
    if (!jsonString || jsonString.length < 5) return jsonString;
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return jsonString;

    NSError *error = nil;
    NSData *filteredData = [self filterStoriesData:data error:&error];
    if (filteredData && !error) {
        NSString *result = [[NSString alloc] initWithData:filteredData encoding:NSUTF8StringEncoding];
        if (result && result.length > 5) {
            return result;
        }
    }
    return jsonString;
}

#pragma mark - Live Metrics

static NSInteger s_totalAdsBlocked = 0;
static NSInteger s_totalStoriesSorted = 0;

+ (NSInteger)totalAdsBlocked {
    @synchronized(self) {
        return s_totalAdsBlocked;
    }
}

+ (NSInteger)totalStoriesSorted {
    @synchronized(self) {
        return s_totalStoriesSorted;
    }
}

+ (void)incrementAdsBlocked:(NSInteger)delta {
    if (delta <= 0) return;
    @synchronized(self) {
        s_totalAdsBlocked += delta;
    }
}

+ (void)incrementStoriesSorted:(NSInteger)delta {
    if (delta <= 0) return;
    @synchronized(self) {
        s_totalStoriesSorted += delta;
    }
}

#pragma mark - JavaScript Interceptor Asset

+ (NSString *)sharedInterceptionJavaScript {
    static NSString *s_script = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_script = @""
        "(function() {\n"
        "    if (window.__INSTACONTROLLER_V31_ACTIVE__) return;\n"
        "    window.__INSTACONTROLLER_V31_ACTIVE__ = true;\n"
        "    console.log('[InstaController-iOS v3.1] Safe Non-Destructive Engine Active');\n"
        "\n"
        "    // 1. Destruction et neutralisation du Service Worker\n"
        "    if ('serviceWorker' in navigator) {\n"
        "        try {\n"
        "            navigator.serviceWorker.getRegistrations().then(function(regs) {\n"
        "                for (var i = 0; i < regs.length; i++) regs[i].unregister();\n"
        "            });\n"
        "            navigator.serviceWorker.register = function() {\n"
        "                return Promise.resolve({\n"
        "                    installing: null, waiting: null, active: null,\n"
        "                    addEventListener: function() {}, removeEventListener: function() {}\n"
        "                });\n"
        "            };\n"
        "        } catch(e) {}\n"
        "    }\n"
        "\n"
        "    // 2. Notification asynchrone légère au HUD natif\n"
        "    function reportNative(ads, stories) {\n"
        "        if (ads <= 0 && stories <= 0) return;\n"
        "        try {\n"
        "            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.instaController) {\n"
        "                window.webkit.messageHandlers.instaController.postMessage({ ads: ads, stories: stories });\n"
        "            }\n"
        "        } catch(e) {}\n"
        "    }\n"
        "\n"
        "    // 3. Normalisation de texte anti-obfuscation (supprime accents, espaces et caractères invisibles)\n"
        "    function normalizeText(str) {\n"
        "        if (!str || typeof str !== 'string') return '';\n"
        "        try {\n"
        "            return str.normalize('NFD').replace(/[\\u0300-\\u036f]/g, '')\n"
        "                      .replace(/[\\s\\u200B-\\u200D\\uFEFF\\u00AD\\u00A0.,;:_\\/\\\\|\\-]/g, '').toLowerCase();\n"
        "        } catch(e) {\n"
        "            return str.replace(/[\\s\\u200B-\\u200D\\uFEFF\\u00AD\\u00A0.,;:_\\/\\\\|\\-]/g, '').toLowerCase();\n"
        "        }\n"
        "    }\n"
        "\n"
        "    var adCompactKeywords = [\n"
        "        'commandite', 'sponsorise', 'sponsored', 'publicite',\n"
        "        'suggerepourvous', 'suggestedforyou', 'recommandepourvous',\n"
        "        'paidpartnership', 'partenariatremunere'\n"
        "    ];\n"
        "\n"
        "    var ctaKeywords = [\n"
        "        'ensavoirplus', 'learnmore', 'acheter', 'shopnow', 'installer', 'installnow',\n"
        "        'telecharger', 'sinscrire', 'signup', 'applynow'\n"
        "    ];\n"
        "\n"
        "    function hasAdKeyword(text) {\n"
        "        var compact = normalizeText(text);\n"
        "        if (!compact || compact.length < 3) return false;\n"
        "        for (var i = 0; i < adCompactKeywords.length; i++) {\n"
        "            if (compact.indexOf(adCompactKeywords[i]) !== -1) return true;\n"
        "        }\n"
        "        return false;\n"
        "    }\n"
        "\n"
        "    function hasCtaKeyword(text) {\n"
        "        var compact = normalizeText(text);\n"
        "        if (!compact || compact.length < 4) return false;\n"
        "        for (var i = 0; i < ctaKeywords.length; i++) {\n"
        "            if (compact.indexOf(ctaKeywords[i]) !== -1) return true;\n"
        "        }\n"
        "        return false;\n"
        "    }\n"
        "\n"
        "    // 4. Détecteur universel de conteneur de publication (supporte div, section et article dans <main>)\n"
        "    function findPostContainer(el) {\n"
        "        if (!el) return null;\n"
        "        var article = el.closest('article');\n"
        "        if (article) return article;\n"
        "\n"
        "        var curr = el;\n"
        "        while (curr && curr !== document.body && curr !== document.documentElement) {\n"
        "            var parent = curr.parentElement;\n"
        "            if (!parent) break;\n"
        "            if (parent.tagName === 'MAIN' || parent.getAttribute('role') === 'main' || parent.getAttribute('role') === 'feed') {\n"
        "                return curr;\n"
        "            }\n"
        "            if (curr.querySelector && curr.querySelector('svg[aria-label*=\"J’aime\"], svg[aria-label*=\"Like\"], svg[aria-label*=\"J\\'aime\"]')) {\n"
        "                if (curr.tagName !== 'MAIN' && (!curr.getAttribute('role') || curr.getAttribute('role') !== 'main')) {\n"
        "                    if (parent.querySelectorAll('svg[aria-label*=\"J’aime\"], svg[aria-label*=\"Like\"], svg[aria-label*=\"J\\'aime\"]').length > 1) {\n"
        "                        return curr;\n"
        "                    }\n"
        "                }\n"
        "            }\n"
        "            curr = parent;\n"
        "        }\n"
        "        return null;\n"
        "    }\n"
        "\n"
        "    function hideContainer(container) {\n"
        "        if (!container || container.dataset.icHidden === '1') return false;\n"
        "        container.dataset.icHidden = '1';\n"
        "        container.style.setProperty('display', 'none', 'important');\n"
        "        container.style.setProperty('height', '0px', 'important');\n"
        "        container.style.setProperty('overflow', 'hidden', 'important');\n"
        "        container.style.setProperty('opacity', '0', 'important');\n"
        "        container.style.setProperty('pointer-events', 'none', 'important');\n"
        "        reportNative(1, 0);\n"
        "        return true;\n"
        "    }\n"
        "\n"
        "    // 5. Styles CSS de masquage\n"
        "    var style = document.createElement('style');\n"
        "    style.textContent = ''\n"
        "        + '[data-testid=\"app-upsell-modal\"], .app-upsell,'\n"
        "        + 'div[role=\"dialog\"]:has(a[href*=\"itunes.apple.com\"]),'\n"
        "        + 'a[href^=\"intent:\"], a[href^=\"instagram:\"] {'\n"
        "        + '    display: none !important;'\n"
        "        + '}';\n"
        "    (document.head || document.documentElement).appendChild(style);\n"
        "\n"
        "    // 6. Filtrage Chirurgical Non-Destructif (CSS Visibility - Jamais de remove())\n"
        "    function scanAndHideAds() {\n"
        "        // A. Liens publicitaires directs\n"
        "        var adLinks = document.querySelectorAll('a[href*=\"/ads/\"], a[href*=\"/about/ads\"], a[href*=\"facebook.com/ads\"]');\n"
        "        for (var k = 0; k < adLinks.length; k++) {\n"
        "            var postByLink = findPostContainer(adLinks[k]);\n"
        "            if (postByLink) hideContainer(postByLink);\n"
        "        }\n"
        "\n"
        "        // B. Éléments textuels suspects dans le flux\n"
        "        var textNodes = document.querySelectorAll('span, header, p, div[role=\"button\"], a[role=\"link\"]');\n"
        "        for (var m = 0; m < textNodes.length; m++) {\n"
        "            var cEl = textNodes[m];\n"
        "            var cTxt = cEl.textContent;\n"
        "            if (cTxt && cTxt.length >= 4 && cTxt.length <= 40) {\n"
        "                if (hasAdKeyword(cTxt)) {\n"
        "                    var postByTxt = findPostContainer(cEl);\n"
        "                    if (postByTxt) hideContainer(postByTxt);\n"
        "                }\n"
        "            }\n"
        "        }\n"
        "\n"
        "        // C. Nettoyage de tous les conteneurs de posts (articles ou blocs avec interactions)\n"
        "        var allPosts = [];\n"
        "        var articles = document.querySelectorAll('article');\n"
        "        for (var i = 0; i < articles.length; i++) allPosts.push(articles[i]);\n"
        "        var likeSvgs = document.querySelectorAll('svg[aria-label*=\"J’aime\"], svg[aria-label*=\"Like\"], svg[aria-label*=\"J\\'aime\"]');\n"
        "        for (var j = 0; j < likeSvgs.length; j++) {\n"
        "            var pCont = findPostContainer(likeSvgs[j]);\n"
        "            if (pCont && allPosts.indexOf(pCont) === -1) allPosts.push(pCont);\n"
        "        }\n"
        "\n"
        "        for (var pIdx = 0; pIdx < allPosts.length; pIdx++) {\n"
        "            var art = allPosts[pIdx];\n"
        "            if (art.dataset.icHidden === '1') continue;\n"
        "\n"
        "            var isAd = false;\n"
        "            if (art.querySelector('a[href*=\"/ads/\"], a[href*=\"/about/ads\"], a[href*=\"facebook.com/ads\"]')) {\n"
        "                isAd = true;\n"
        "            }\n"
        "\n"
        "            if (!isAd) {\n"
        "                var spans = art.querySelectorAll('span, div, header, p');\n"
        "                for (var s = 0; s < spans.length; s++) {\n"
        "                    var txt = spans[s].innerText || spans[s].textContent || '';\n"
        "                    if (txt.length > 0 && txt.length < 50 && hasAdKeyword(txt)) {\n"
        "                        isAd = true;\n"
        "                        break;\n"
        "                    }\n"
        "                }\n"
        "            }\n"
        "\n"
        "            if (!isAd) {\n"
        "                var buttons = art.querySelectorAll('button, div[role=\"button\"], a[role=\"link\"]');\n"
        "                for (var b = 0; b < buttons.length; b++) {\n"
        "                    var btnTxt = buttons[b].innerText || buttons[b].textContent || '';\n"
        "                    if (hasCtaKeyword(btnTxt)) {\n"
        "                        if (art.querySelector('a[href*=\"/ads/\"]') || hasAdKeyword(art.innerText || art.textContent || '')) {\n"
        "                            isAd = true;\n"
        "                            break;\n"
        "                        }\n"
        "                    }\n"
        "                }\n"
        "            }\n"
        "\n"
        "            if (isAd) {\n"
        "                hideContainer(art);\n"
        "            }\n"
        "        }\n"
        "\n"
        "        // D. Saut automatique des Stories publicitaires\n"
        "        var storySections = document.querySelectorAll('section, div[role=\"dialog\"], div[role=\"presentation\"]');\n"
        "        for (var st = 0; st < storySections.length; st++) {\n"
        "            var sec = storySections[st];\n"
        "            if (sec.querySelector('video, img, div[role=\"progressbar\"]')) {\n"
        "                var secText = (sec.innerText || sec.textContent || '');\n"
        "                var isAdStory = hasAdKeyword(secText) || !!sec.querySelector('a[href*=\"/about/ads\"], a[href*=\"/ads/\"], [data-testid=\"story_ad_cta\"]');\n"
        "                if (isAdStory && !sec.__ic_skipped) {\n"
        "                    sec.__ic_skipped = true;\n"
        "                    console.log('[InstaController] Story sponsorisée détectée -> Saut immédiat');\n"
        "                    reportNative(1, 0);\n"
        "                    var next = document.querySelector('button[aria-label=\"Suivant\"], button[aria-label=\"Next\"], [aria-label=\"Suivant\"], [aria-label=\"Next\"]');\n"
        "                    if (next) {\n"
        "                        next.click();\n"
        "                    } else {\n"
        "                        var rightX = Math.floor(window.innerWidth * 0.85);\n"
        "                        var centerY = Math.floor(window.innerHeight * 0.5);\n"
        "                        var ev = new MouseEvent('click', { bubbles: true, cancelable: true, clientX: rightX, clientY: centerY });\n"
        "                        var el = document.elementFromPoint(rightX, centerY);\n"
        "                        if (el) el.dispatchEvent(ev);\n"
        "                    }\n"
        "                }\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "\n"
        "    var observer = new MutationObserver(function() {\n"
        "        scanAndHideAds();\n"
        "    });\n"
        "    observer.observe(document.documentElement, { childList: true, subtree: true });\n"
        "    setInterval(scanAndHideAds, 250);\n"
        "\n"
        "    // 7. Outil de diagnostic DOM pour le bouton HUD natif\n"
        "    window.__INSTACONTROLLER_SCAN_DOM__ = function() {\n"
        "        var lines = [];\n"
        "        lines.push('URL : ' + window.location.href);\n"
        "        var articles = document.querySelectorAll('article');\n"
        "        var likeSvgs = document.querySelectorAll('svg[aria-label*=\"J’aime\"], svg[aria-label*=\"Like\"], svg[aria-label*=\"J\\'aime\"]');\n"
        "        var candidatePosts = [];\n"
        "        for (var i = 0; i < articles.length; i++) candidatePosts.push(articles[i]);\n"
        "        for (var j = 0; j < likeSvgs.length; j++) {\n"
        "            var pCont = findPostContainer(likeSvgs[j]);\n"
        "            if (pCont && candidatePosts.indexOf(pCont) === -1) candidatePosts.push(pCont);\n"
        "        }\n"
        "        var hiddenCount = 0;\n"
        "        for (var h = 0; h < candidatePosts.length; h++) {\n"
        "            if (candidatePosts[h].dataset.icHidden === '1') hiddenCount++;\n"
        "        }\n"
        "        lines.push('Posts détectés : ' + candidatePosts.length + ' (Articles HTML : ' + articles.length + ')');\n"
        "        lines.push('Annonces masquées : ' + hiddenCount);\n"
        "        for (var idx = 0; idx < Math.min(candidatePosts.length, 3); idx++) {\n"
        "            var p = candidatePosts[idx];\n"
        "            var isH = p.dataset.icHidden === '1' ? 'OUI' : 'NON';\n"
        "            var header = p.querySelector('header') || p.firstElementChild;\n"
        "            var headerTxt = header ? normalizeText(header.innerText || header.textContent || '') : '';\n"
        "            var hasAdL = !!p.querySelector('a[href*=\"/ads/\"], a[href*=\"/about/ads\"]');\n"
        "            var tag = p.tagName.toLowerCase();\n"
        "            lines.push('--- Post #' + (idx + 1) + ' [' + tag + '] ---');\n"
        "            lines.push('Masqué : ' + isH);\n"
        "            lines.push('Header épuré : ' + headerTxt.substring(0, 35));\n"
        "            lines.push('Lien pub : ' + (hasAdL ? 'OUI' : 'NON'));\n"
        "        }\n"
        "        return lines.join('\\n');\n"
        "    };\n"
        "})();\n";
    });
    return s_script;
}

@end
