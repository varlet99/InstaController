package com.instacontroller.extension

import org.assertj.core.api.Assertions.assertThat
import org.json.JSONObject
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets

class InstaControllerHookTest {

    @BeforeEach
    fun setUp() {
        // Nettoyage des favoris
        InstaControllerHook.getFavorites().forEach {
            InstaControllerHook.removeFavorite(it)
        }
    }

    @Test
    @DisplayName("filterTimeline(String) doit purger les pubs et suggestions")
    fun testFilterTimelineString() {
        val mockJson = loadResource("/mock_timeline.json")
        val filtered = InstaControllerHook.filterTimeline(mockJson)

        assertThat(filtered).isNotNull
        val obj = JSONObject(filtered!!)
        val feedItems = obj.getJSONArray("feed_items")

        assertThat(feedItems.length()).isEqualTo(2)
        assertThat(filtered).doesNotContain("sponsor_998811")
        assertThat(filtered).doesNotContain("ad_casino_44")
    }

    @Test
    @DisplayName("filterTimeline(ByteArray) doit fonctionner de manière identique au niveau binaire")
    fun testFilterTimelineByteArray() {
        val mockJson = loadResource("/mock_timeline.json")
        val inputBytes = mockJson.toByteArray(StandardCharsets.UTF_8)

        val outputBytes = InstaControllerHook.filterTimeline(inputBytes)
        assertThat(outputBytes).isNotNull

        val outputString = String(outputBytes!!, StandardCharsets.UTF_8)
        assertThat(outputString).doesNotContain("sponsor_998811")
        assertThat(JSONObject(outputString).getJSONArray("feed_items").length()).isEqualTo(2)
    }

    @Test
    @DisplayName("filterTimelineStream(InputStream) doit consommer et recréer un flux filtré")
    fun testFilterTimelineInputStream() {
        val mockJson = loadResource("/mock_timeline.json")
        val stream = ByteArrayInputStream(mockJson.toByteArray(StandardCharsets.UTF_8))

        val outputStream = InstaControllerHook.filterTimelineStream(stream)
        assertThat(outputStream).isNotNull

        val outputString = outputStream!!.bufferedReader().use { it.readText() }
        assertThat(outputString).doesNotContain("sponsor_998811")
        assertThat(JSONObject(outputString).getJSONArray("feed_items").length()).isEqualTo(2)
    }

    @Test
    @DisplayName("filterStories(String) doit trier selon les favoris ajoutés dynamiquement")
    fun testFilterStoriesWithDynamicFavorites() {
        val mockStories = loadResource("/mock_reels_tray.json")

        // Ajout d'Alice dans les favoris
        InstaControllerHook.addFavorite("alice_favorite")
        assertThat(InstaControllerHook.getFavorites()).contains("alice_favorite")

        val filtered = InstaControllerHook.filterStories(mockStories)
        assertThat(filtered).isNotNull

        val tray = JSONObject(filtered!!).getJSONArray("tray")
        assertThat(tray.length()).isEqualTo(4) // 6 initiales - 2 pubs = 4
        assertThat(tray.getJSONObject(0).getString("id")).isEqualTo("story_bestie_alice")
        assertThat(tray.getJSONObject(0).getInt("ranked_position")).isEqualTo(0)
    }

    @Test
    @DisplayName("Fail-Safe : Un JSON corrompu ou mal formé ne doit jamais crasher et retourner l'original")
    fun testFailSafeProtection() {
        val corruptJson = "{ this is completely invalid json 123456 !!!"

        val result = InstaControllerHook.filterTimeline(corruptJson)
        // Doit retourner la chaîne originale sans exception
        assertThat(result).isEqualTo(corruptJson)

        val nullResult = InstaControllerHook.filterTimeline(null as String?)
        assertThat(nullResult).isNull()
    }

    private fun loadResource(path: String): String {
        val stream = javaClass.getResourceAsStream(path)
            ?: throw IllegalArgumentException("Fichier ressource introuvable : $path")
        return stream.bufferedReader().use { it.readText() }
    }
}
