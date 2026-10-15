package com.instacontroller.core

import org.json.JSONObject

/**
 * Implémentation de référence ordonnant les Stories selon la règle :
 * 1. Favoris (Besties / Close Friends ou liste blanche d'utilisateurs prioritaires) : score >= 1000.0
 * 2. Abonnements actifs non vus : score ~ 500.0 (pondéré par l'heure de publication la plus récente)
 * 3. Stories déjà vues ou comptes secondaires : score <= 100.0
 *
 * Supporte également la détection de mots-clés de partenariats/placements non déclarés
 * dans les légendes pour pénaliser les stories suspectes.
 */
class PriorityStoryScorer(
    private val favoriteUsernames: Set<String> = emptySet(),
    private val secondaryUsernames: Set<String> = emptySet(),
    private val adKeywordsMalus: Map<String, Double> = mapOf(
        "sponsorise" to -300.0,
        "partenariat" to -300.0,
        "collaboration" to -300.0,
        "codepromo" to -300.0,
        "promo" to -200.0,
        "remise" to -200.0,
        "ad" to -200.0
    )
) : StoryScorer {

    override fun score(storyTrayItem: JSONObject): Double {
        val userObj = storyTrayItem.optJSONObject("user")
        val username = userObj?.optString("username", "") ?: ""
        val friendshipStatus = userObj?.optJSONObject("friendship_status")

        val isBestie = friendshipStatus?.optBoolean("is_bestie", false) == true ||
                favoriteUsernames.contains(username)
        val isFollowing = friendshipStatus?.optBoolean("following", true) ?: true
        val isSecondary = secondaryUsernames.contains(username)

        val seen = storyTrayItem.optLong("seen", 0L)
        val latestReelMedia = storyTrayItem.optLong("latest_reel_media", 0L)
        val isAlreadySeen = seen > 0L && seen >= latestReelMedia

        var baseScore = when {
            isAlreadySeen -> SCORE_SEEN
            isBestie -> SCORE_FAVORITE
            !isFollowing -> SCORE_NOT_FOLLOWING
            isSecondary -> SCORE_SECONDARY
            else -> SCORE_ACTIVE_FOLLOWING
        }

        // Bonus fraîcheur (les plus récentes en premier au sein d'une même catégorie)
        if (latestReelMedia > 0L && !isAlreadySeen) {
            val recencyBonus = (latestReelMedia % 100000).toDouble() / 1000.0
            baseScore += recencyBonus
        }

        // Malus détection placement de produit / spam dans les captions des items
        baseScore += inspectStoryItemsForAdIndicators(storyTrayItem)

        return baseScore
    }

    private fun inspectStoryItemsForAdIndicators(storyTrayItem: JSONObject): Double {
        var malus = 0.0
        val items = storyTrayItem.optJSONArray("items") ?: return 0.0

        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val captionObj = item.optJSONObject("caption")
            val text = captionObj?.optString("text", "") ?: ""

            for ((keyword, penalty) in adKeywordsMalus) {
                val pattern = Regex("""(?i)\b${Regex.escape(keyword)}\b""")
                if (pattern.containsMatchIn(text)) {
                    malus += penalty
                }
            }
        }
        return malus
    }

    companion object {
        const val SCORE_FAVORITE = 1000.0
        const val SCORE_ACTIVE_FOLLOWING = 500.0
        const val SCORE_SECONDARY = 250.0
        const val SCORE_NOT_FOLLOWING = 100.0
        const val SCORE_SEEN = 10.0
    }
}
