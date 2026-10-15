//
//  test_ios_filter.m
//  Unit tests for InstaControllerFilter iOS engine
//

#import <Foundation/Foundation.h>
#import "InstaControllerFilter.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"==================================================");
        NSLog(@"[Test] Démarrage des tests unitaires InstaController iOS");
        NSLog(@"==================================================");

        // 1. Test Timeline Filtering
        NSString *timelinePath = @"core-filter/src/test/resources/mock_timeline.json";
        NSData *timelineData = [NSData dataWithContentsOfFile:timelinePath];
        NSCAssert(timelineData != nil, @"Impossible de charger mock_timeline.json");

        NSError *error = nil;
        NSData *filteredTimelineData = [InstaControllerFilter filterTimelineData:timelineData error:&error];
        NSCAssert(error == nil, @"Erreur lors du filtrage Timeline : %@", error);

        NSDictionary *timelineResult = [NSJSONSerialization JSONObjectWithData:filteredTimelineData options:0 error:&error];
        NSArray *feedItems = timelineResult[@"feed_items"];

        NSLog(@"[Test Timeline] Nombre d'items initiaux : 6 -> Filtrés restants : %lu", (unsigned long)feedItems.count);
        NSCAssert(feedItems.count == 2, @"Attendu 2 items légitimes dans la timeline, obtenu : %lu", (unsigned long)feedItems.count);

        for (NSDictionary *item in feedItems) {
            NSDictionary *mediaOrAd = item[@"media_or_ad"];
            NSCAssert(mediaOrAd != nil, @"Chaque item doit être un media_or_ad valide");
            NSString *postId = mediaOrAd[@"id"];
            NSCAssert([postId isEqualToString:@"post_legit_1"] || [postId isEqualToString:@"post_legit_2"],
                      @"Item non autorisé dans le flux : %@", postId);
            NSCAssert(item[@"is_sponsored"] == nil && mediaOrAd[@"is_sponsored"] == nil,
                      @"Le tag is_sponsored ne doit pas exister");
            NSCAssert(item[@"suggested_users"] == nil, @"Les suggestions d'utilisateurs doivent être purgées");
            NSCAssert(item[@"netego_type"] == nil, @"Les blocs netego doivent être purgés");
        }
        NSLog(@"[Test Timeline] ✅ SUCCÈS : 100%% des annonces et suggestions éliminées !");

        // 2. Test Stories Tray Filtering & Ranking
        NSString *storiesPath = @"core-filter/src/test/resources/mock_reels_tray.json";
        NSData *storiesData = [NSData dataWithContentsOfFile:storiesPath];
        NSCAssert(storiesData != nil, @"Impossible de charger mock_reels_tray.json");

        NSData *filteredStoriesData = [InstaControllerFilter filterStoriesData:storiesData error:&error];
        NSCAssert(error == nil, @"Erreur lors du filtrage Stories : %@", error);

        NSDictionary *storiesResult = [NSJSONSerialization JSONObjectWithData:filteredStoriesData options:0 error:&error];
        NSArray *tray = storiesResult[@"tray"];

        NSLog(@"[Test Stories] Nombre de stories initiales : 5 -> Filtrées restantes : %lu", (unsigned long)tray.count);
        NSCAssert(tray.count == 4, @"Attendu 4 stories après élimination de la pub, obtenu : %lu", (unsigned long)tray.count);

        // Vérification que story_ad_sponsor n'est plus dans le tray
        for (NSDictionary *story in tray) {
            NSCAssert(![story[@"id"] isEqualToString:@"story_ad_sponsor"], @"La story sponsorisée doit être supprimée");
            NSCAssert(story[@"is_sponsored"] == nil, @"Aucune story ne doit avoir is_sponsored");
        }

        // Vérification de l'ordre :
        // 1. story_bestie_alice (is_bestie = true) -> Position 0
        NSDictionary *firstStory = tray[0];
        NSCAssert([firstStory[@"id"] isEqualToString:@"story_bestie_alice"],
                  @"La story #0 doit être story_bestie_alice, obtenu : %@", firstStory[@"id"]);
        NSCAssert([firstStory[@"ranked_position"] integerValue] == 0, @"ranked_position doit être 0");

        // 2. Stories actives non vues (story_active_bob, story_product_placement)
        // 3. Story déjà vue en dernier (story_seen_david)
        NSDictionary *lastStory = [tray lastObject];
        NSCAssert([lastStory[@"id"] isEqualToString:@"story_seen_david"],
                  @"La story déjà vue doit être en dernière position, obtenu : %@", lastStory[@"id"]);

        // Vérification stricte des index ranked_position séquentiels (0, 1, 2, 3)
        for (NSUInteger i = 0; i < tray.count; i++) {
            NSDictionary *story = tray[i];
            NSCAssert([story[@"ranked_position"] integerValue] == (NSInteger)i,
                      @"ranked_position incorrect à l'index %lu (obtenu %ld)", (unsigned long)i, (long)[story[@"ranked_position"] integerValue]);
        }

        NSLog(@"[Test Stories] ✅ SUCCÈS : Stories triées (Favoris > Non-vues > Vues) et ranked_position réindexé !");

        NSLog(@"==================================================");
        NSLog(@"[Test] TOUS LES TESTS UNITAIRES iOS ONT RÉUSSI (100%%) !");
        NSLog(@"==================================================");
    }
    return 0;
}
