package com.instacontroller.sandbox

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import com.instacontroller.core.InstagramFilter
import com.instacontroller.core.PriorityStoryScorer
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicInteger

/**
 * Pont natif JavaScript <-> Android pour intercepter et modifier les flux Instagram.
 *
 * Annoté avec @JavascriptInterface pour être accessible depuis le script interceptor.js
 * injecté dans la WebView.
 */
class InstaBridge(
    private val onStatsListener: StatsListener? = null
) {

    interface StatsListener {
        fun onStatsUpdated(adsBlocked: Int, storiesSorted: Int, lastActionDesc: String)
        fun onFavoritesChanged(favorites: Set<String>)
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val favoriteUsernames = CopyOnWriteArraySet<String>(setOf("charlie", "tech_news"))
    private val totalAdsBlocked = AtomicInteger(0)
    private val totalStoriesSorted = AtomicInteger(0)

    @Volatile
    private var filter = createFilterInstance()

    private fun createFilterInstance(): InstagramFilter {
        val scorer = PriorityStoryScorer(
            favoriteUsernames = favoriteUsernames
        )
        return InstagramFilter(defaultStoryScorer = scorer)
    }

    /**
     * Traite de manière synchrone le JSON brut de la timeline (/api/v1/feed/timeline/).
     */
    @JavascriptInterface
    fun processTimelineJson(rawJson: String): String {
        try {
            val root = JSONObject(rawJson)
            val countBefore = countTimelineItems(root)

            val filtered = filter.filterTimeline(root)
            val countAfter = countTimelineItems(filtered)

            val blocked = maxOf(0, countBefore - countAfter)
            val total = totalAdsBlocked.addAndGet(blocked)

            val desc = if (blocked > 0) "Bloqué $blocked pub(s)/suggestion(s) dans la Timeline" else "Timeline analysée (propre)"
            Log.d(TAG, "[InstaBridge] Timeline: $countBefore -> $countAfter items (blocked $blocked, total $total)")

            notifyListener(total, totalStoriesSorted.get(), desc)
            return filtered.toString()
        } catch (e: Exception) {
            Log.e(TAG, "[InstaBridge] Error processing timeline JSON", e)
            return rawJson
        }
    }

    /**
     * Traite de manière synchrone le JSON brut du reels_tray (/api/v1/feed/reels_tray/).
     */
    @JavascriptInterface
    fun processStoriesJson(rawJson: String): String {
        try {
            val root = JSONObject(rawJson)
            val trayBefore = root.optJSONArray("tray")?.length() ?: 0

            val filtered = filter.filterStories(root)
            val trayAfter = filtered.optJSONArray("tray")?.length() ?: 0

            val adsInTray = maxOf(0, trayBefore - trayAfter)
            val totalAds = totalAdsBlocked.addAndGet(adsInTray)
            val totalSorted = totalStoriesSorted.addAndGet(trayAfter)

            val desc = "Stories: $trayAfter réordonnées (selon Favoris), $adsInTray pub(s) purgée(s)"
            Log.d(TAG, "[InstaBridge] Stories: $trayBefore -> $trayAfter items (blocked ads: $adsInTray)")

            notifyListener(totalAds, totalSorted, desc)
            return filtered.toString()
        } catch (e: Exception) {
            Log.e(TAG, "[InstaBridge] Error processing stories JSON", e)
            return rawJson
        }
    }

    fun addFavorite(username: String) {
        val clean = username.trim().removePrefix("@").lowercase()
        if (clean.isNotBlank()) {
            favoriteUsernames.add(clean)
            filter = createFilterInstance()
            mainHandler.post {
                onStatsListener?.onFavoritesChanged(favoriteUsernames)
            }
        }
    }

    fun removeFavorite(username: String) {
        val clean = username.trim().removePrefix("@").lowercase()
        if (clean.isNotBlank()) {
            favoriteUsernames.remove(clean)
            filter = createFilterInstance()
            mainHandler.post {
                onStatsListener?.onFavoritesChanged(favoriteUsernames)
            }
        }
    }

    fun getFavorites(): Set<String> = favoriteUsernames.toSet()

    fun getAdsBlocked(): Int = totalAdsBlocked.get()

    fun getStoriesSorted(): Int = totalStoriesSorted.get()

    fun resetStats() {
        totalAdsBlocked.set(0)
        totalStoriesSorted.set(0)
        notifyListener(0, 0, "Compteurs réinitialisés")
    }

    private fun countTimelineItems(root: JSONObject): Int {
        var count = 0
        if (root.has("feed_items")) {
            count += root.optJSONArray("feed_items")?.length() ?: 0
        }
        if (root.has("items")) {
            count += root.optJSONArray("items")?.length() ?: 0
        }
        return count
    }

    private fun notifyListener(ads: Int, stories: Int, desc: String) {
        mainHandler.post {
            onStatsListener?.onStatsUpdated(ads, stories, desc)
        }
    }

    companion object {
        private const val TAG = "InstaController"
    }
}
