package com.instacontroller.core

import org.assertj.core.api.Assertions.assertThat
import org.json.JSONObject
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

class InstagramFilterTest {

    private val filter = InstagramFilter()

    @Test
    @DisplayName("La Timeline doit être purgée de toutes les pubs, suggestions et blocs netego")
    fun testTimelinePurgedOfAdsAndSuggestions() {
        val rawTimeline = loadResource("/mock_timeline.json")
        val rawJsonObj = JSONObject(rawTimeline)
        assertThat(rawJsonObj.getJSONArray("feed_items").length()).isEqualTo(6)

        val filteredJsonString = filter.filterTimeline(rawTimeline)
        val filteredObj = JSONObject(filteredJsonString)
        val feedItems = filteredObj.getJSONArray("feed_items")

        // Il ne doit rester que les 2 posts légitimes
        assertThat(feedItems.length()).isEqualTo(2)

        val firstItem = feedItems.getJSONObject(0).getJSONObject("media_or_ad")
        val secondItem = feedItems.getJSONObject(1).getJSONObject("media_or_ad")

        assertThat(firstItem.getString("id")).isEqualTo("post_legit_1")
        assertThat(firstItem.getJSONObject("caption").getString("text")).contains("Belle journée en montagne")

        assertThat(secondItem.getString("id")).isEqualTo("post_legit_2")
        assertThat(secondItem.getJSONObject("caption").getString("text")).contains("recette de pâtes")

        // Vérification absolue : aucun résidu publicitaire dans tout le JSON
        assertThat(filteredJsonString).doesNotContain("sponsor_998811")
        assertThat(filteredJsonString).doesNotContain("ad_casino_44")
        assertThat(filteredJsonString).doesNotContain("ad4ad")
        assertThat(filteredJsonString).doesNotContain("suggested_users")
        assertThat(filteredJsonString).doesNotContain("injected")
    }

    @Test
    @DisplayName("Les Stories doivent être purgées des pubs et réordonnées : Favoris > Actifs > Vus")
    fun testStoriesPurgedAndReorderedByPriority() {
        val rawStories = loadResource("/mock_reels_tray.json")
        val initialObj = JSONObject(rawStories)
        assertThat(initialObj.getJSONArray("tray").length()).isEqualTo(6)

        val customScorer = PriorityStoryScorer(
            favoriteUsernames = setOf("alice_favorite"),
            secondaryUsernames = setOf("zoe_secondary")
        )

        val filteredStoriesString = filter.filterStories(rawStories, customScorer)
        val filteredObj = JSONObject(filteredStoriesString)
        val tray = filteredObj.getJSONArray("tray")

        // 6 items d'origine - 1 pub sponsor - 1 netego = 4 stories restantes
        assertThat(tray.length()).isEqualTo(4)

        // 1. Première position : Alice (Favori / Bestie)
        val pos0 = tray.getJSONObject(0)
        assertThat(pos0.getString("id")).isEqualTo("story_bestie_alice")
        assertThat(pos0.getInt("ranked_position")).isEqualTo(0)
        assertThat(pos0.getJSONObject("user").getString("username")).isEqualTo("alice_favorite")

        // 2. Deuxième position : Bob (Abonnement actif non vu)
        val pos1 = tray.getJSONObject(1)
        assertThat(pos1.getString("id")).isEqualTo("story_active_bob")
        assertThat(pos1.getInt("ranked_position")).isEqualTo(1)
        assertThat(pos1.getJSONObject("user").getString("username")).isEqualTo("bob_active")

        // 3. Troisième position : Zoe (Compte secondaire)
        val pos2 = tray.getJSONObject(2)
        assertThat(pos2.getString("id")).isEqualTo("story_secondary_zoe")
        assertThat(pos2.getInt("ranked_position")).isEqualTo(2)
        assertThat(pos2.getJSONObject("user").getString("username")).isEqualTo("zoe_secondary")

        // 4. Quatrième position : David (Story déjà vue, envoyée en fin de tray)
        val pos3 = tray.getJSONObject(3)
        assertThat(pos3.getString("id")).isEqualTo("story_seen_david")
        assertThat(pos3.getInt("ranked_position")).isEqualTo(3)
        assertThat(pos3.getJSONObject("user").getString("username")).isEqualTo("david_seen")

        // Aucune pub présente
        assertThat(filteredStoriesString).doesNotContain("story_ad_sponsor")
        assertThat(filteredStoriesString).doesNotContain("netego_tray_item")
    }

    @Test
    @DisplayName("StoryScorer interface : un modèle ou agent IA peut pénaliser un placement dissimulé")
    fun testAiStoryScorerPenalizesProductPlacement() {
        val rawStories = loadResource("/mock_reels_tray.json")

        // Ajoutons dynamiquement un placement produit dans la story de Bob
        val modifiedRawObj = JSONObject(rawStories)
        val tray = modifiedRawObj.getJSONArray("tray")
        for (i in 0 until tray.length()) {
            val item = tray.getJSONObject(i)
            if (item.optString("id") == "story_active_bob") {
                val itemsArr = item.getJSONArray("items")
                itemsArr.getJSONObject(0).getJSONObject("caption")
                    .put("text", "Regardez cette gourde incroyable avec le codepromo FITNESS20 !")
            }
        }

        // Le PriorityStoryScorer applique un malus sur 'codepromo'
        val scorer = PriorityStoryScorer(
            favoriteUsernames = setOf("alice_favorite"),
            secondaryUsernames = emptySet()
        )

        val filtered = filter.filterStories(modifiedRawObj.toString(), scorer)
        val resultTray = JSONObject(filtered).getJSONArray("tray")

        // Alice reste 1ère (Favori)
        assertThat(resultTray.getJSONObject(0).getString("id")).isEqualTo("story_bestie_alice")

        // Zoe passe devant Bob car Bob a été pénalisé par le malus de détection de placement
        assertThat(resultTray.getJSONObject(1).getString("id")).isEqualTo("story_secondary_zoe")
        assertThat(resultTray.getJSONObject(2).getString("id")).isEqualTo("story_active_bob")
    }

    private fun loadResource(path: String): String {
        val stream = javaClass.getResourceAsStream(path)
            ?: throw IllegalArgumentException("Fichier ressource introuvable : $path")
        return stream.bufferedReader().use { it.readText() }
    }
}
