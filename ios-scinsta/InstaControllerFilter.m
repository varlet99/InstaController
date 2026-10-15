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
        "    if (window.__INSTACONTROLLER_V3_ACTIVE__) return;\n"
        "    window.__INSTACONTROLLER_V3_ACTIVE__ = true;\n"
        "    console.log('[InstaController-iOS v3.0] Anti-Obfuscation Engine Active');\n"
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
        "    // 3. Normalisation de texte anti-obfuscation (supprime espaces, soft-hyphens et caractères invisibles)\n"
        "    function normalizeText(str) {\n"
        "        if (!str || typeof str !== 'string') return '';\n"
        "        return str.replace(/[\\s\\u200B-\\u200D\\uFEFF\\u00AD\\u00A0.,;:_\\/\\\\|\\-]/g, '').toLowerCase();\n"
        "    }\n"
        "\n"
        "    var adCompactKeywords = [\n"
        "        'commandite', 'commandité', 'sponsorise', 'sponsorisé', 'sponsored',\n"
        "        'publicite', 'publicité', 'suggerepourvous', 'suggérépourvous', 'suggestedforyou',\n"
        "        'recommandepourvous', 'recommandépourvous', 'paidpartnership', 'partenariatremunere',\n"
        "        'partenariatrémunéré', 'commanditépar', 'sponsorisépar'\n"
        "    ];\n"
        "\n"
        "    var ctaKeywords = [\n"
        "        'ensavoirplus', 'learnmore', 'acheter', 'shopnow', 'installer', 'installnow',\n"
        "        'telecharger', 'télécharger', 'sinscrire', 's\\'inscrire', 'signup', 'applynow'\n"
        "    ];\n"
        "\n"
        "    function isCompactAdText(compact) {\n"
        "        if (!compact || compact.length < 3) return false;\n"
        "        for (var i = 0; i < adCompactKeywords.length; i++) {\n"
        "            if (compact.indexOf(adCompactKeywords[i]) !== -1) return true;\n"
        "        }\n"
        "        return false;\n"
        "    }\n"
        "\n"
        "    function isCompactCta(compact) {\n"
        "        if (!compact || compact.length < 4) return false;\n"
        "        for (var i = 0; i < ctaKeywords.length; i++) {\n"
        "            if (compact.indexOf(ctaKeywords[i]) !== -1) return true;\n"
        "        }\n"
        "        return false;\n"
        "    }\n"
        "\n"
        "    // 4. Détection d'annonces JSON et d'injections algorithmiques\n"
        "    function isAdObject(obj) {\n"
        "        if (!obj || typeof obj !== 'object') return false;\n"
        "        if (obj.is_sponsored === true || obj.is_sponsored === 1) return true;\n"
        "        if (obj.ad_id != null || obj.ad_action != null || obj.injected != null) return true;\n"
        "        if (obj.netego_type != null || obj.suggested_users != null) return true;\n"
        "        if (obj.sponsored_label != null || obj.is_ad === true) return true;\n"
        "        if (obj.__typename === 'XDTGraphAd' || obj.__typename === 'GraphAd') return true;\n"
        "        if (obj.ad_header_style != null || obj.hide_flow_type != null) return true;\n"
        "        if (obj.link_text != null && (obj.tracking_token != null || obj.ad_action != null)) return true;\n"
        "        if (obj.node && isAdObject(obj.node)) return true;\n"
        "        if (obj.media_or_ad && isAdObject(obj.media_or_ad)) return true;\n"
        "        return false;\n"
        "    }\n"
        "\n"
        "    // 5. Scoring et tri du plateau de stories (reels_tray)\n"
        "    function scoreStoryItem(item) {\n"
        "        if (!item || typeof item !== 'object') return 0;\n"
        "        var user = item.user || {};\n"
        "        if (item.is_bestie || user.is_bestie || item.show_besties_badge) return 1000.0;\n"
        "        var seen = (item.seen || 0);\n"
        "        var latest = (item.latest_reel_media || 1);\n"
        "        if (seen >= latest) return 10.0;\n"
        "        return 500.0;\n"
        "    }\n"
        "\n"
        "    function processTray(tray) {\n"
        "        if (!Array.isArray(tray)) return tray;\n"
        "        var initLen = tray.length;\n"
        "        var valid = [];\n"
        "        for (var i = 0; i < tray.length; i++) {\n"
        "            var item = tray[i];\n"
        "            if (item && !isAdObject(item)) {\n"
        "                if (Array.isArray(item.items)) {\n"
        "                    item.items = item.items.filter(function(it) { return !isAdObject(it); });\n"
        "                }\n"
        "                valid.push(item);\n"
        "            }\n"
        "        }\n"
        "        var adsRemoved = initLen - valid.length;\n"
        "        valid.sort(function(a, b) {\n"
        "            return scoreStoryItem(b) - scoreStoryItem(a);\n"
        "        });\n"
        "        for (var j = 0; j < valid.length; j++) {\n"
        "            if (valid[j] && typeof valid[j] === 'object') {\n"
        "                valid[j].ranked_position = j;\n"
        "            }\n"
        "        }\n"
        "        if (adsRemoved > 0 || valid.length > 0) {\n"
        "            reportNative(adsRemoved, valid.length);\n"
        "        }\n"
        "        return valid;\n"
        "    }\n"
        "\n"
        "    // 6. Nettoyage récursif in-process ultra-rapide\n"
        "    function cleanJsonObject(root) {\n"
        "        if (!root || typeof root !== 'object') return root;\n"
        "        if (Array.isArray(root)) {\n"
        "            var out = [];\n"
        "            var removed = 0;\n"
        "            for (var i = 0; i < root.length; i++) {\n"
        "                var elem = root[i];\n"
        "                if (isAdObject(elem)) {\n"
        "                    removed++;\n"
        "                } else {\n"
        "                    out.push(cleanJsonObject(elem));\n"
        "                }\n"
        "            }\n"
        "            if (removed > 0) reportNative(removed, 0);\n"
        "            return out;\n"
        "        }\n"
        "\n"
        "        if (Array.isArray(root.tray)) {\n"
        "            root.tray = processTray(root.tray);\n"
        "        }\n"
        "        if (Array.isArray(root.feed_items)) root.feed_items = cleanJsonObject(root.feed_items);\n"
        "        if (Array.isArray(root.items)) root.items = cleanJsonObject(root.items);\n"
        "        if (Array.isArray(root.edges)) root.edges = cleanJsonObject(root.edges);\n"
        "        if (Array.isArray(root.medias)) root.medias = cleanJsonObject(root.medias);\n"
        "\n"
        "        delete root.ad_action;\n"
        "        delete root.ad_header_style;\n"
        "        delete root.ig_ads_peak_hour_throttling_config;\n"
        "        delete root.is_promoted;\n"
        "        delete root.has_promoted_media;\n"
        "        delete root.feed_recs_user_interests_enabled;\n"
        "\n"
        "        var keys = Object.keys(root);\n"
        "        for (var k = 0; k < keys.length; k++) {\n"
        "            var key = keys[k];\n"
        "            if (key !== 'tray' && key !== 'feed_items' && key !== 'items' && key !== 'edges' && key !== 'medias') {\n"
        "                var val = root[key];\n"
        "                if (val && typeof val === 'object') {\n"
        "                    root[key] = cleanJsonObject(val);\n"
        "                }\n"
        "            }\n"
        "        }\n"
        "        return root;\n"
        "    }\n"
        "\n"
        "    // 7. Sanitisation des balises <script type='application/json'> AVANT exécution\n"
        "    function sanitizeScriptTag(sc) {\n"
        "        if (!sc || sc.__ic_sanitized) return;\n"
        "        var type = sc.getAttribute('type') || '';\n"
        "        if (type.indexOf('json') === -1 && !sc.hasAttribute('data-sjs')) return;\n"
        "        var txt = sc.textContent || '';\n"
        "        if (txt.length > 30 && (txt.includes('is_sponsored') || txt.includes('ad_id') || txt.includes('reels_tray') || txt.includes('netego_type'))) {\n"
        "            sc.__ic_sanitized = true;\n"
        "            try {\n"
        "                txt = txt.replace(/\"is_sponsored\"\\s*:\\s*true/g, '\"is_sponsored\":false');\n"
        "                txt = txt.replace(/\"is_ad\"\\s*:\\s*true/g, '\"is_ad\":false');\n"
        "                txt = txt.replace(/\"netego_type\"\\s*:\\s*\"[^\"]+\"/g, '\"netego_type\":null');\n"
        "                var parsed = JSON.parse(txt);\n"
        "                var cleaned = cleanJsonObject(parsed);\n"
        "                sc.textContent = JSON.stringify(cleaned);\n"
        "            } catch(e) {\n"
        "                sc.textContent = txt;\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "\n"
        "    // 8. Surcharges universelles JSON.parse & Response.prototype.json\n"
        "    var origJSONParse = JSON.parse;\n"
        "    JSON.parse = function(text, reviver) {\n"
        "        var val = origJSONParse.call(this, text, reviver);\n"
        "        if (val && typeof val === 'object') {\n"
        "            try { return cleanJsonObject(val); } catch(e) {}\n"
        "        }\n"
        "        return val;\n"
        "    };\n"
        "\n"
        "    if (window.Response && Response.prototype.json) {\n"
        "        var origRespJson = Response.prototype.json;\n"
        "        Response.prototype.json = async function() {\n"
        "            var data = await origRespJson.apply(this, arguments);\n"
        "            if (data && typeof data === 'object') {\n"
        "                try { return cleanJsonObject(data); } catch(e) {}\n"
        "            }\n"
        "            return data;\n"
        "        };\n"
        "    }\n"
        "\n"
        "    // 9. Surcharge de history.pushState & replaceState pour forcer variant=following\n"
        "    function patchFollowingUrl(url) {\n"
        "        if (!url) return url;\n"
        "        try {\n"
        "            var u = new URL(url, window.location.href);\n"
        "            if ((u.pathname === '/' || u.pathname === '') && (!u.search || !u.search.includes('variant=following'))) {\n"
        "                u.searchParams.set('variant', 'following');\n"
        "                return u.pathname + u.search + u.hash;\n"
        "            }\n"
        "        } catch(e) {}\n"
        "        return url;\n"
        "    }\n"
        "\n"
        "    var origPush = history.pushState;\n"
        "    history.pushState = function(state, title, url) {\n"
        "        return origPush.call(this, state, title, patchFollowingUrl(url));\n"
        "    };\n"
        "\n"
        "    var origReplace = history.replaceState;\n"
        "    history.replaceState = function(state, title, url) {\n"
        "        return origReplace.call(this, state, title, patchFollowingUrl(url));\n"
        "    };\n"
        "\n"
        "    if ((window.location.pathname === '/' || window.location.pathname === '') && !window.location.search.includes('variant=following')) {\n"
        "        window.location.replace('/?variant=following' + (window.location.hash || ''));\n"
        "    }\n"
        "\n"
        "    document.addEventListener('click', function(e) {\n"
        "        var a = e.target.closest ? e.target.closest('a') : null;\n"
        "        if (a && a.href) {\n"
        "            try {\n"
        "                var u = new URL(a.href, window.location.href);\n"
        "                if ((u.pathname === '/' || u.pathname === '') && (!u.search || !u.search.includes('variant=following'))) {\n"
        "                    u.searchParams.set('variant', 'following');\n"
        "                    a.href = u.toString();\n"
        "                }\n"
        "            } catch(e) {}\n"
        "        }\n"
        "    }, true);\n"
        "\n"
        "    // 10. Styles CSS d'urgence\n"
        "    var style = document.createElement('style');\n"
        "    style.textContent = ''\n"
        "        + '[data-testid=\"app-upsell-modal\"], .app-upsell,'\n"
        "        + 'div[role=\"dialog\"]:has(a[href*=\"itunes.apple.com\"]),'\n"
        "        + 'a[href^=\"intent:\"], a[href^=\"instagram:\"],'\n"
        "        + 'article:has(a[href*=\"/about/ads\"]),'\n"
        "        + 'article:has(a[href*=\"/ads/\"]) {'\n"
        "        + '    display: none !important;'\n"
        "        + '}';\n"
        "    (document.head || document.documentElement).appendChild(style);\n"
        "\n"
        "    // 11. Chirurgie DOM Agressive (Anti-Spans Éclatés & Saut Stories)\n"
        "    function checkAndPurgeDOM() {\n"
        "        // 1. Sanitisateur de scripts\n"
        "        var scripts = document.querySelectorAll('script[type=\"application/json\"], script[data-sjs]');\n"
        "        for (var sIdx = 0; sIdx < scripts.length; sIdx++) {\n"
        "            sanitizeScriptTag(scripts[sIdx]);\n"
        "        }\n"
        "\n"
        "        // 2. Nettoyage du fil d'actualité\n"
        "        var articles = document.querySelectorAll('article, div[style*=\"flex-direction: column\"]');\n"
        "        for (var i = 0; i < articles.length; i++) {\n"
        "            var art = articles[i];\n"
        "            if (art.__ic_purged) continue;\n"
        "\n"
        "            // Vérification liens publicitaires explicites\n"
        "            var hasAdLink = !!art.querySelector('a[href*=\"/about/ads\"], a[href*=\"/ads/\"], a[href*=\"facebook.com/ads\"]');\n"
        "\n"
        "            // Vérification header épuré (anti-spans éclatés)\n"
        "            var header = art.querySelector('header') || art.firstElementChild;\n"
        "            var headCompact = header ? normalizeText(header.innerText || header.textContent || '') : '';\n"
        "            var isHeaderAd = isCompactAdText(headCompact);\n"
        "\n"
        "            // Vérification boutons d'action d'achat/téléchargement\n"
        "            var buttons = art.querySelectorAll('button, div[role=\"button\"], a[role=\"link\"]');\n"
        "            var hasAdButton = false;\n"
        "            for (var b = 0; b < buttons.length; b++) {\n"
        "                var bCompact = normalizeText(buttons[b].innerText || buttons[b].textContent || '');\n"
        "                if (isCompactCta(bCompact)) {\n"
        "                    hasAdButton = true;\n"
        "                    break;\n"
        "                }\n"
        "            }\n"
        "\n"
        "            // Texte complet compacté au cas où l'en-tête n'est pas balisé <header>\n"
        "            var fullCompact = normalizeText((art.innerText || art.textContent || '').substring(0, 400));\n"
        "            var isFullAd = isCompactAdText(fullCompact);\n"
        "\n"
        "            if (hasAdLink || isHeaderAd || (hasAdButton && isFullAd) || isFullAd) {\n"
        "                art.__ic_purged = true;\n"
        "                art.style.display = 'none';\n"
        "                art.remove();\n"
        "                reportNative(1, 0);\n"
        "            }\n"
        "        }\n"
        "\n"
        "        // 3. Saut automatique des Stories publicitaires\n"
        "        var storySections = document.querySelectorAll('section, div[role=\"dialog\"], div[role=\"presentation\"]');\n"
        "        for (var s = 0; s < storySections.length; s++) {\n"
        "            var sec = storySections[s];\n"
        "            if (sec.querySelector('video, img, div[role=\"progressbar\"]')) {\n"
        "                var secCompact = normalizeText((sec.innerText || sec.textContent || '').substring(0, 300));\n"
        "                var isAdStory = isCompactAdText(secCompact) || !!sec.querySelector('a[href*=\"/about/ads\"], a[href*=\"/ads/\"], [data-testid=\"story_ad_cta\"]');\n"
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
        "    var observer = new MutationObserver(function(mutations) {\n"
        "        for (var m = 0; m < mutations.length; m++) {\n"
        "            var added = mutations[m].addedNodes;\n"
        "            for (var a = 0; a < added.length; a++) {\n"
        "                var node = added[a];\n"
        "                if (node.nodeType === 1 && node.tagName === 'SCRIPT') {\n"
        "                    sanitizeScriptTag(node);\n"
        "                }\n"
        "            }\n"
        "        }\n"
        "        checkAndPurgeDOM();\n"
        "    });\n"
        "    observer.observe(document.documentElement, { childList: true, subtree: true });\n"
        "    setInterval(checkAndPurgeDOM, 200);\n"
        "\n"
        "    // 12. Outil de diagnostic DOM pour le bouton HUD natif\n"
        "    window.__INSTACONTROLLER_SCAN_DOM__ = function() {\n"
        "        var lines = [];\n"
        "        lines.push('URL : ' + window.location.href);\n"
        "        var arts = document.querySelectorAll('article');\n"
        "        lines.push('Articles détectés : ' + arts.length);\n"
        "        for (var idx = 0; idx < Math.min(arts.length, 3); idx++) {\n"
        "            var a = arts[idx];\n"
        "            var h = a.querySelector('header') || a.firstElementChild;\n"
        "            var hTxt = h ? normalizeText(h.innerText || '') : '';\n"
        "            var adL = !!a.querySelector('a[href*=\"/ads/\"], a[href*=\"/about/ads\"]');\n"
        "            var cta = a.querySelector('button, [role=\"button\"]');\n"
        "            var ctaTxt = cta ? (cta.innerText || '').trim() : 'aucun';\n"
        "            lines.push('--- Article #' + (idx + 1) + ' ---');\n"
        "            lines.push('Header épuré : ' + hTxt.substring(0, 50));\n"
        "            lines.push('Lien pub : ' + (adL ? 'OUI' : 'NON'));\n"
        "            lines.push('CTA : ' + ctaTxt);\n"
        "        }\n"
        "        var stories = document.querySelectorAll('section, div[role=\"dialog\"]');\n"
        "        lines.push('Conteneurs Stories : ' + stories.length);\n"
        "        return lines.join('\\n');\n"
        "    };\n"
        "})();\n";
    });
    return s_script;
}

@end
