//
//  InstaControllerFilter.h
//  InstaController iOS Native Engine
//
//  Réplique exacte de :core-filter pour iOS en Objective-C natif (NSJSONSerialization).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface InstaControllerFilter : NSObject

/**
 * Filtre les données NSData brutes provenant de l'endpoint timeline (/api/v1/feed/timeline/ ou GraphQL).
 * Élimine toutes les publications sponsorisées, annonces et suggestions d'utilisateurs.
 */
+ (nullable NSData *)filterTimelineData:(NSData *)jsonData error:(NSError **)error;

/**
 * Filtre un dictionnaire représentant une réponse Timeline (REST ou GraphQL).
 */
+ (NSDictionary *)filterTimelineDictionary:(NSDictionary *)timelineDict;

/**
 * Filtre et réordonne les données NSData brutes de l'endpoint Stories (/api/v1/feed/reels_tray/ ou GraphQL).
 * Élimine les stories sponsorisées et applique l'algorithme PriorityStoryScorer.
 */
+ (nullable NSData *)filterStoriesData:(NSData *)jsonData error:(NSError **)error;

/**
 * Filtre et réordonne un dictionnaire représentant une réponse Stories Tray.
 */
+ (NSDictionary *)filterStoriesDictionary:(NSDictionary *)storiesDict;

/**
 * Détecte si un élément (Post ou Story) contient un marqueur publicitaire ou d'injection algorithmique :
 * is_sponsored, ad_id, injected, netego_type, suggested_users, format publicitaire Pando.
 */
+ (BOOL)isAdOrAlgorithmicInsertion:(NSDictionary *)item;

/**
 * Calcule le score de priorité pour un élément du carrousel de stories (PriorityStoryScorer) :
 * - Favoris / Amis proches (is_bestie = YES) : score >= 1000.0
 * - Non-vus actifs : score ~ 500.0 (avec bonus de fraîcheur)
 * - Déjà vus : score ~ 10.0
 * - Malus pour mots-clés de partenariats/sponsors : -200 à -300
 */
+ (double)scoreStoryTrayItem:(NSDictionary *)storyTrayItem;

@end

NS_ASSUME_NONNULL_END
