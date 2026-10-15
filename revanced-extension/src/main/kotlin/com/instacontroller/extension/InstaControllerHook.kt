package com.instacontroller.extension

import com.instacontroller.core.InstagramFilter
import com.instacontroller.core.PriorityStoryScorer
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicInteger

/**
 * Pont statique ReVanced pour Instagram.
 *
 * Cette classe est la cible directe des hooks Smali injectés par le patch ReVanced.
 * Toutes les méthodes sont statiques (@JvmStatic), synchrones et strictement protégées
 * contre tout crash (fail-safe) pour garantir que l'application Instagram ne plante jamais.
 */
object InstaControllerHook {

    private const val TAG = "InstaControllerHook"

    private val favoriteUsernames = CopyOnWriteArraySet<String>()
    private val totalTimelineAdsRemoved = AtomicInteger(0)
    private val totalStoriesProcessed = AtomicInteger(0)

    @Volatile
    private var filter = createFilterInstance()

    private fun createFilterInstance(): InstagramFilter {
        val scorer = PriorityStoryScorer(
            favoriteUsernames = favoriteUsernames
        )
        return InstagramFilter(defaultStoryScorer = scorer)
    }

    /**
     * Point d'injection Smali pour la Timeline :
     *
     * Smali:
     *   invoke-static {v0}, Lcom/instacontroller/extension/InstaControllerHook;->filterTimeline(Ljava/lang/String;)Ljava/lang/String;
     *   move-result-object v0
     */
    @JvmStatic
    fun filterTimeline(rawJson: String?): String? {
        if (rawJson.isNullOrBlank()) return rawJson

        return try {
            val result = filter.filterTimeline(rawJson)
            totalTimelineAdsRemoved.incrementAndGet()
            result
        } catch (t: Throwable) {
            logError("filterTimeline failed, returning untouched raw payload", t)
            rawJson // Fail-safe : retourne la charge originale
        }
    }

    /**
     * Surcharge pour flux binaire ByteArray (réponse brute réseau).
     */
    @JvmStatic
    fun filterTimeline(rawBytes: ByteArray?): ByteArray? {
        if (rawBytes == null || rawBytes.isEmpty()) return rawBytes

        return try {
            val rawString = String(rawBytes, StandardCharsets.UTF_8)
            val filteredString = filterTimeline(rawString) ?: return rawBytes
            filteredString.toByteArray(StandardCharsets.UTF_8)
        } catch (t: Throwable) {
            logError("filterTimeline(bytes) failed", t)
            rawBytes
        }
    }

    /**
     * Surcharge pour flux réseau InputStream.
     */
    @JvmStatic
    fun filterTimelineStream(inputStream: InputStream?): InputStream? {
        if (inputStream == null) return null

        return try {
            val bytes = inputStream.readBytes()
            val filteredBytes = filterTimeline(bytes) ?: bytes
            ByteArrayInputStream(filteredBytes)
        } catch (t: Throwable) {
            logError("filterTimelineStream failed", t)
            inputStream
        }
    }

    /**
     * Point d'injection Smali pour les Stories (reels_tray) :
     *
     * Smali:
     *   invoke-static {v0}, Lcom/instacontroller/extension/InstaControllerHook;->filterStories(Ljava/lang/String;)Ljava/lang/String;
     *   move-result-object v0
     */
    @JvmStatic
    fun filterStories(rawJson: String?): String? {
        if (rawJson.isNullOrBlank()) return rawJson

        return try {
            val result = filter.filterStories(rawJson)
            totalStoriesProcessed.incrementAndGet()
            result
        } catch (t: Throwable) {
            logError("filterStories failed, returning untouched raw payload", t)
            rawJson // Fail-safe
        }
    }

    /**
     * Surcharge pour flux binaire ByteArray des Stories.
     */
    @JvmStatic
    fun filterStories(rawBytes: ByteArray?): ByteArray? {
        if (rawBytes == null || rawBytes.isEmpty()) return rawBytes

        return try {
            val rawString = String(rawBytes, StandardCharsets.UTF_8)
            val filteredString = filterStories(rawString) ?: return rawBytes
            filteredString.toByteArray(StandardCharsets.UTF_8)
        } catch (t: Throwable) {
            logError("filterStories(bytes) failed", t)
            rawBytes
        }
    }

    /**
     * Surcharge pour flux InputStream des Stories.
     */
    @JvmStatic
    fun filterStoriesStream(inputStream: InputStream?): InputStream? {
        if (inputStream == null) return null

        return try {
            val bytes = inputStream.readBytes()
            val filteredBytes = filterStories(bytes) ?: bytes
            ByteArrayInputStream(filteredBytes)
        } catch (t: Throwable) {
            logError("filterStoriesStream failed", t)
            inputStream
        }
    }

    // Gestion des Favoris
    @JvmStatic
    fun addFavorite(username: String) {
        val clean = username.trim().removePrefix("@").lowercase()
        if (clean.isNotBlank()) {
            favoriteUsernames.add(clean)
            filter = createFilterInstance()
        }
    }

    @JvmStatic
    fun removeFavorite(username: String) {
        val clean = username.trim().removePrefix("@").lowercase()
        if (clean.isNotBlank()) {
            favoriteUsernames.remove(clean)
            filter = createFilterInstance()
        }
    }

    @JvmStatic
    fun getFavorites(): Set<String> = favoriteUsernames.toSet()

    @JvmStatic
    fun getStats(): String {
        return "Timeline calls filtered: ${totalTimelineAdsRemoved.get()}, Stories processed: ${totalStoriesProcessed.get()}"
    }

    private fun logError(message: String, t: Throwable) {
        // En environnement Android, System.err est automatiquement redirigé vers logcat (tag System.err)
        System.err.println("[$TAG] $message: ${t.javaClass.simpleName} - ${t.message}")
    }
}
