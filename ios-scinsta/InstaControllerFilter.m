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
        "    if (window.__INSTACONTROLLER_ACTIVE__) return;\n"
        "    window.__INSTACONTROLLER_ACTIVE__ = true;\n"
        "    console.log('[InstaController-iOS] Universal WebKit Filter & Interceptor Active');\n"
        "\n"
        "    // 0. Synchronous Native Bridge\n"
        "    function nativeFilterTimeline(jsonStr) {\n"
        "        if (!jsonStr || jsonStr.length < 10) return jsonStr;\n"
        "        try {\n"
        "            const res = window.prompt('__INSTACONTROLLER_FILTER_TIMELINE__', jsonStr);\n"
        "            if (res && res.length > 5 && res !== jsonStr) {\n"
        "                return res;\n"
        "            }\n"
        "        } catch(e) {\n"
        "            console.error('[InstaController] Error in nativeFilterTimeline:', e);\n"
        "        }\n"
        "        return jsonStr;\n"
        "    }\n"
        "\n"
        "    function nativeFilterStories(jsonStr) {\n"
        "        if (!jsonStr || jsonStr.length < 10) return jsonStr;\n"
        "        try {\n"
        "            const res = window.prompt('__INSTACONTROLLER_FILTER_STORIES__', jsonStr);\n"
        "            if (res && res.length > 5 && res !== jsonStr) {\n"
        "                return res;\n"
        "            }\n"
        "        } catch(e) {\n"
        "            console.error('[InstaController] Error in nativeFilterStories:', e);\n"
        "        }\n"
        "        return jsonStr;\n"
        "    }\n"
        "\n"
        "    function reportMetrics(adsDelta, storiesDelta) {\n"
        "        try {\n"
        "            window.prompt('__INSTACONTROLLER_REPORT_METRICS__', JSON.stringify({adsDelta: adsDelta, storiesDelta: storiesDelta}));\n"
        "        } catch(e) {}\n"
        "    }\n"
        "\n"
        "    // 1. Forcer le flux Abonnements chronologique (variant=following) sans pubs algorithmiques\n"
        "    function enforceFollowingFeed() {\n"
        "        try {\n"
        "            const loc = window.location;\n"
        "            if ((loc.pathname === '/' || loc.pathname === '') && !loc.search.includes('variant=following')) {\n"
        "                const target = '/?variant=following' + (loc.hash || '');\n"
        "                console.log('[InstaController] Redirection vers le flux Abonnements :', target);\n"
        "                window.location.replace(target);\n"
        "            }\n"
        "        } catch(e) {}\n"
        "    }\n"
        "    enforceFollowingFeed();\n"
        "\n"
        "    document.addEventListener('click', function(e) {\n"
        "        const a = e.target.closest ? e.target.closest('a') : null;\n"
        "        if (a && a.href) {\n"
        "            try {\n"
        "                const u = new URL(a.href, window.location.href);\n"
        "                if ((u.pathname === '/' || u.pathname === '') && (!u.search || !u.search.includes('variant=following'))) {\n"
        "                    u.searchParams.set('variant', 'following');\n"
        "                    a.href = u.toString();\n"
        "                }\n"
        "            } catch(e) {}\n"
        "        }\n"
        "    }, true);\n"
        "\n"
        "    // 2. Styles CSS de secours et neutralisation des bannières d'installation app\n"
        "    function injectEmergencyStyles() {\n"
        "        if (document.getElementById('instacontroller-ios-styles')) return;\n"
        "        const style = document.createElement('style');\n"
        "        style.id = 'instacontroller-ios-styles';\n"
        "        style.textContent = `\n"
        "            [data-testid=\"app-upsell-modal\"],\n"
        "            .app-upsell,\n"
        "            div[role=\"dialog\"]:has(a[href*=\"itunes.apple.com\"]),\n"
        "            a[href^=\"intent:\"],\n"
        "            a[href^=\"instagram:\"],\n"
        "            article:has(a[href*=\"/about/ads\"]),\n"
        "            article:has(span:contains(\"Sponsored\")),\n"
        "            article:has(span:contains(\"Sponsorisé\")),\n"
        "            article:has(span:contains(\"Commandité\")),\n"
        "            article:has(span:contains(\"Publicité\")) {\n"
        "                display: none !important;\n"
        "            }\n"
        "        `;\n"
        "        (document.head || document.documentElement).appendChild(style);\n"
        "    }\n"
        "    injectEmergencyStyles();\n"
        "    if (document.readyState === 'loading') {\n"
        "        document.addEventListener('DOMContentLoaded', injectEmergencyStyles);\n"
        "    }\n"
        "\n"
        "    // 3. Interception SSR HTML et monkey-patch JSON.parse pour Relay/ServerJS\n"
        "    const originalJSONParse = JSON.parse;\n"
        "    JSON.parse = function(text, reviver) {\n"
        "        if (typeof text === 'string' && text.length > 50) {\n"
        "            if (text.includes('\"feed_items\"') || text.includes('\"is_sponsored\"') || text.includes('\"xdt_api__v1__feed__timeline__connection\"')) {\n"
        "                text = nativeFilterTimeline(text);\n"
        "            } else if (text.includes('\"reels_tray\"') || text.includes('\"xdt_api__v1__feed__reels_tray\"') || (text.includes('\"tray\":') && !text.includes('\"feed_items\"'))) {\n"
        "                text = nativeFilterStories(text);\n"
        "            }\n"
        "        }\n"
        "        return originalJSONParse.call(this, text, reviver);\n"
        "    };\n"
        "\n"
        "    // 4. Interception réseau Fetch API\n"
        "    if (window.fetch) {\n"
        "        const origFetch = window.fetch;\n"
        "        window.fetch = async function(...args) {\n"
        "            const req = args[0];\n"
        "            const url = typeof req === 'string' ? req : (req && req.url ? req.url : '');\n"
        "            const response = await origFetch.apply(this, args);\n"
        "            if (response && response.ok) {\n"
        "                try {\n"
        "                    const clone = response.clone();\n"
        "                    const text = await clone.text();\n"
        "                    if (text && text.length > 20) {\n"
        "                        const isTimeline = url.includes('timeline') || url.includes('feed') || url.includes('graphql') ||\n"
        "                                           text.includes('\"feed_items\"') || text.includes('\"is_sponsored\"') || text.includes('\"xdt_api__v1__feed__timeline__connection\"');\n"
        "                        const isStories = url.includes('reels_tray') || url.includes('stories') ||\n"
        "                                          text.includes('\"reels_tray\"') || text.includes('\"xdt_api__v1__feed__reels_tray\"') || (text.includes('\"tray\":') && !text.includes('\"feed_items\"'));\n"
        "                        let cleaned = text;\n"
        "                        if (isStories) {\n"
        "                            cleaned = nativeFilterStories(text);\n"
        "                        } else if (isTimeline) {\n"
        "                            cleaned = nativeFilterTimeline(text);\n"
        "                        }\n"
        "                        if (cleaned !== text) {\n"
        "                            const newHeaders = new Headers(response.headers);\n"
        "                            newHeaders.delete('content-length');\n"
        "                            const newResp = new Response(cleaned, {\n"
        "                                status: response.status,\n"
        "                                statusText: response.statusText,\n"
        "                                headers: newHeaders\n"
        "                            });\n"
        "                            newResp.json = async () => JSON.parse(cleaned);\n"
        "                            newResp.text = async () => cleaned;\n"
        "                            return newResp;\n"
        "                        }\n"
        "                    }\n"
        "                } catch(err) {\n"
        "                    console.error('[InstaController] Erreur Fetch:', err);\n"
        "                }\n"
        "            }\n"
        "            return response;\n"
        "        };\n"
        "    }\n"
        "\n"
        "    // 5. Interception réseau XMLHttpRequest\n"
        "    const origXHROpen = XMLHttpRequest.prototype.open;\n"
        "    const origXHRSend = XMLHttpRequest.prototype.send;\n"
        "    XMLHttpRequest.prototype.open = function(method, url) {\n"
        "        this.__ic_url = typeof url === 'string' ? url : (url ? url.toString() : '');\n"
        "        return origXHROpen.apply(this, arguments);\n"
        "    };\n"
        "    XMLHttpRequest.prototype.send = function() {\n"
        "        const xhr = this;\n"
        "        const url = xhr.__ic_url || '';\n"
        "        xhr.addEventListener('readystatechange', function() {\n"
        "            if (xhr.readyState === 4 && xhr.status === 200) {\n"
        "                try {\n"
        "                    const rawText = xhr.responseText;\n"
        "                    if (rawText && rawText.length > 20) {\n"
        "                        const isTimeline = url.includes('timeline') || url.includes('feed') || url.includes('graphql') ||\n"
        "                                           rawText.includes('\"feed_items\"') || rawText.includes('\"is_sponsored\"');\n"
        "                        const isStories = url.includes('reels_tray') || url.includes('stories') ||\n"
        "                                          rawText.includes('\"reels_tray\"') || (rawText.includes('\"tray\":') && !rawText.includes('\"feed_items\"'));\n"
        "                        let cleaned = rawText;\n"
        "                        if (isStories) {\n"
        "                            cleaned = nativeFilterStories(rawText);\n"
        "                        } else if (isTimeline) {\n"
        "                            cleaned = nativeFilterTimeline(rawText);\n"
        "                        }\n"
        "                        if (cleaned !== rawText) {\n"
        "                            Object.defineProperty(xhr, 'responseText', { get: () => cleaned, configurable: true });\n"
        "                            Object.defineProperty(xhr, 'response', {\n"
        "                                get: () => {\n"
        "                                    if (xhr.responseType === '' || xhr.responseType === 'text') return cleaned;\n"
        "                                    if (xhr.responseType === 'json') {\n"
        "                                        try { return JSON.parse(cleaned); } catch(e) { return cleaned; }\n"
        "                                    }\n"
        "                                    return cleaned;\n"
        "                                },\n"
        "                                configurable: true\n"
        "                            });\n"
        "                        }\n"
        "                    }\n"
        "                } catch(e) {}\n"
        "            }\n"
        "        }, false);\n"
        "        return origXHRSend.apply(this, arguments);\n"
        "    };\n"
        "\n"
        "    // 6. Chirurgie DOM en temps réel via MutationObserver\n"
        "    const adRegex = /(sponsoris[ée]|sponsored|commandit[ée]|publicit[ée]|suggested for you|sugg[ée]r[ée] pour vous|suggestions? pour vous|recommand[ée] pour vous)/i;\n"
        "    function purgeNode(node) {\n"
        "        if (!node || node.nodeType !== 1) return;\n"
        "        const tag = node.tagName.toLowerCase();\n"
        "        const article = tag === 'article' ? node : (node.closest ? node.closest('article') : null);\n"
        "        if (article && !article.__ic_purged) {\n"
        "            const hasAdLink = article.querySelector('a[href*=\"/about/ads\"]');\n"
        "            const hasAdText = adRegex.test(article.innerText || article.textContent || '');\n"
        "            if (hasAdLink || hasAdText) {\n"
        "                article.__ic_purged = true;\n"
        "                article.remove();\n"
        "                reportMetrics(1, 0);\n"
        "                return;\n"
        "            }\n"
        "        }\n"
        "        if (tag === 'div' && (node.getAttribute('data-testid') === 'app-upsell-modal' || (node.className && typeof node.className === 'string' && node.className.includes('app-upsell')))) {\n"
        "            node.remove();\n"
        "        }\n"
        "    }\n"
        "    const observer = new MutationObserver(function(mutations) {\n"
        "        for (let i = 0; i < mutations.length; i++) {\n"
        "            const m = mutations[i];\n"
        "            for (let j = 0; j < m.addedNodes.length; j++) {\n"
        "                purgeNode(m.addedNodes[j]);\n"
        "            }\n"
        "        }\n"
        "    });\n"
        "    observer.observe(document.documentElement, { childList: true, subtree: true });\n"
        "})();\n";
    });
    return s_script;
}

@end
