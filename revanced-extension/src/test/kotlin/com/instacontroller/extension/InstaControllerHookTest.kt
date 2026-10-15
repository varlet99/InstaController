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

    enum class MockFeedItemType { MEDIA, AD, SUGGESTED_USERS, CLIPS_NETEGO }

    class MockOrganicItem {
        @JvmField val type = MockFeedItemType.MEDIA
    }
    class MockAdItem {
        @JvmField val type = MockFeedItemType.AD
    }
    class MockSuggestedUsersItem {
        @JvmField val type = MockFeedItemType.SUGGESTED_USERS
    }
    class MockClipsItem {
        @JvmField val type = MockFeedItemType.CLIPS_NETEGO
    }

    class MockUser(val username: String)
    class MockStory(val user: MockUser) {
        fun Dqt() = user
    }
    class MockSuggestedStory {
        fun getSuggestedUsers() = "suggested"
    }

    class MockMedia(val isSponsored: Boolean, val iaaSingleAd: Any? = null) {
        fun A1U() = iaaSingleAd
    }

    class MockItemWithMethods(
        private val media: MockMedia?,
        private val isA0JAd: Boolean = false
    ) {
        fun A0A(): MockMedia? = media
        fun A0J(): Boolean = isA0JAd
    }

    class MockTimelineResponse {
        @JvmField var A09: Any? = "suggested_users_block"
        @JvmField var A08: Any? = "survey_block"
        @JvmField var A0U: List<Any?>? = null
        @JvmField var A0W: List<Any?>? = null
    }

    @Test
    @DisplayName("filterFeedItems() doit éliminer les objets publicitaires et suggestions")
    fun testFilterFeedItems() {
        val sponsoredMedia = MockMedia(isSponsored = true)
        val iaaAdMedia = MockMedia(isSponsored = false, iaaSingleAd = "IAA_INFO")
        val cleanMedia = MockMedia(isSponsored = false)

        val items = listOf(
            MockOrganicItem(),
            MockAdItem(),
            MockOrganicItem(),
            MockSuggestedUsersItem(),
            MockClipsItem(),
            MockItemWithMethods(sponsoredMedia),
            MockItemWithMethods(iaaAdMedia),
            MockItemWithMethods(cleanMedia, isA0JAd = true),
            MockItemWithMethods(cleanMedia, isA0JAd = false)
        )

        val filtered = InstaControllerHook.filterFeedItems(items)
        assertThat(filtered).isNotNull
        // Seuls MockOrganicItem (x2) et MockItemWithMethods(cleanMedia, isA0JAd=false) doivent survivre = 3
        assertThat(filtered).hasSize(3)
        assertThat(filtered!![0]).isInstanceOf(MockOrganicItem::class.java)
        assertThat(filtered[1]).isInstanceOf(MockOrganicItem::class.java)
        assertThat(filtered[2]).isInstanceOf(MockItemWithMethods::class.java)
    }

    @Test
    @DisplayName("cleanTimelineResponse() doit neutraliser A09/A08 et filtrer A0U/A0W")
    fun testCleanTimelineResponse() {
        val resp = MockTimelineResponse()
        resp.A0U = listOf(MockOrganicItem(), MockAdItem())
        resp.A0W = listOf(MockClipsItem(), MockOrganicItem())

        val cleaned = InstaControllerHook.cleanTimelineResponse(resp) as MockTimelineResponse
        assertThat(cleaned.A09).isNull()
        assertThat(cleaned.A08).isNull()
        assertThat(cleaned.A0U).hasSize(1)
        assertThat(cleaned.A0W).hasSize(1)
    }

    class MockReelResponseItem(
        @JvmField val A0E: Any? = null, // IntentAwareAdsInfo
        @JvmField val A0d: Any? = null  // Ad4adDict
    )

    class MockReelsMediaResponse {
        @JvmField var A03: Any? = "intent_aware_ads"
        @JvmField var A0G: MutableMap<String, Any?> = HashMap()
    }

    @Test
    @DisplayName("cleanReelsMediaResponse() doit éliminer les reels publicitaires injectés")
    fun testCleanReelsMediaResponse() {
        val resp = MockReelsMediaResponse()
        resp.A0G["user_friend_1"] = MockStory(MockUser("friend_1"))
        resp.A0G["injected_ad_1"] = MockReelResponseItem(A0E = "intent_ad")
        resp.A0G["injected_ad_2"] = MockReelResponseItem(A0d = "ad4ad")

        val cleaned = InstaControllerHook.cleanReelsMediaResponse(resp) as MockReelsMediaResponse
        assertThat(cleaned.A03).isNull()
        assertThat(cleaned.A0G).hasSize(1)
        assertThat(cleaned.A0G).containsKey("user_friend_1")
    }

    @Test
    @DisplayName("filterStoriesTray() doit placer les favoris en tête et éliminer les suggestions")
    fun testFilterStoriesTray() {
        InstaControllerHook.addFavorite("alice_favorite")

        val stories = listOf(
            MockStory(MockUser("bob_regular")),
            MockSuggestedStory(),
            MockStory(MockUser("alice_favorite")),
            MockStory(MockUser("charlie_regular"))
        )

        val filtered = InstaControllerHook.filterStoriesTray(stories)
        assertThat(filtered).isNotNull
        assertThat(filtered).hasSize(3) // 4 minus 1 suggestion = 3
        val firstStory = filtered!![0] as MockStory
        assertThat(firstStory.user.username).isEqualTo("alice_favorite")
    }

    private fun loadResource(path: String): String {
        val stream = javaClass.getResourceAsStream(path)
            ?: throw IllegalArgumentException("Fichier ressource introuvable : $path")
        return stream.bufferedReader().use { it.readText() }
    }
}
