package com.instacontroller.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Moteur principal de filtrage et de réordonnancement pour les réponses de l'API Instagram.
 * Conçu pour fonctionner aussi bien en JVM pure qu'embarqué via Smali / ReVanced.
 */
class InstagramFilter(
    private val defaultStoryScorer: StoryScorer = PriorityStoryScorer()
) {

    /**
     * Filtre le JSON brut de l'endpoint timeline (/api/v1/feed/timeline/).
     * Supprime toutes les publicités sponsorisées, suggestions de comptes et blocs netego.
     *
     * @param rawJson Le corps de réponse JSON brut.
     * @return Le JSON filtré sous forme de String.
     */
    fun filterTimeline(rawJson: String): String {
        val root = JSONObject(rawJson)
        val filtered = filterTimeline(root)
        return filtered.toString()
    }

    /**
     * Filtre un JSONObject représentant une réponse timeline.
     */
    fun filterTimeline(root: JSONObject): JSONObject {
        cleanArrayIfPresent(root, "feed_items")
        cleanArrayIfPresent(root, "items")

        // Support GraphQL : { "data": { "...": { "edges": [ ... ] } } }
        val dataObj = root.optJSONObject("data")
        if (dataObj != null) {
            val keys = dataObj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val subObj = dataObj.optJSONObject(key) ?: continue
                cleanArrayIfPresent(subObj, "feed_items")
                cleanArrayIfPresent(subObj, "items")

                if (subObj.has("edges")) {
                    val originalEdges = subObj.getJSONArray("edges")
                    val cleanedEdges = JSONArray()
                    for (i in 0 until originalEdges.length()) {
                        val edge = originalEdges.optJSONObject(i) ?: continue
                        val node = edge.optJSONObject("node") ?: edge
                        if (!isAdOrAlgorithmicInsertion(node)) {
                            cleanedEdges.put(edge)
                        }
                    }
                    subObj.put("edges", cleanedEdges)
                }
            }
        }

        return root
    }

    private fun cleanArrayIfPresent(parent: JSONObject, key: String) {
        if (parent.has(key)) {
            val original = parent.optJSONArray(key) ?: return
            val cleaned = JSONArray()
            for (i in 0 until original.length()) {
                val item = original.optJSONObject(i) ?: continue
                if (!isAdOrAlgorithmicInsertion(item)) {
                    cleaned.put(item)
                }
            }
            parent.put(key, cleaned)
        }
    }

    /**
     * Filtre et réordonne le JSON brut de l'endpoint des Stories (/api/v1/feed/reels_tray/).
     */
    fun filterStories(rawJson: String, scorer: StoryScorer = defaultStoryScorer): String {
        val root = JSONObject(rawJson)
        val filtered = filterStories(root, scorer)
        return filtered.toString()
    }

    /**
     * Filtre et réordonne un JSONObject de type reels_tray ou GraphQL Stories.
     */
    fun filterStories(root: JSONObject, scorer: StoryScorer = defaultStoryScorer): JSONObject {
        if (root.has("tray")) {
            val originalTray = root.getJSONArray("tray")
            root.put("tray", filterAndSortTray(originalTray, scorer))
            return root
        }

        // Support GraphQL Stories : { "data": { "xdt_api__v1__feed__reels_tray": { "tray": [ ... ] } } }
        val dataObj = root.optJSONObject("data")
        if (dataObj != null) {
            val keys = dataObj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val subObj = dataObj.optJSONObject(key) ?: continue
                if (subObj.has("tray")) {
                    val originalTray = subObj.getJSONArray("tray")
                    subObj.put("tray", filterAndSortTray(originalTray, scorer))
                }
            }
        }

        return root
    }

    private fun filterAndSortTray(originalTray: JSONArray, scorer: StoryScorer): JSONArray {
        val validStories = mutableListOf<Pair<JSONObject, Double>>()

        for (i in 0 until originalTray.length()) {
            val item = originalTray.optJSONObject(i) ?: continue

            // 1. Détection et élimination des pubs / injections dans le tray
            if (isAdOrAlgorithmicInsertion(item)) {
                continue
            }

            // 2. Calcul du score de tri
            val score = scorer.score(item)
            validStories.add(Pair(item, score))
        }

        // Tri par score décroissant (les scores les plus hauts en premier)
        validStories.sortByDescending { it.second }

        // 3. Reconstruction du tableau 'tray' avec mise à jour de 'ranked_position'
        val sortedTray = JSONArray()
        validStories.forEachIndexed { index, (storyObj, _) ->
            storyObj.put("ranked_position", index)
            sortedTray.put(storyObj)
        }

        return sortedTray
    }

    /**
     * Vérifie si un objet JSON contient un marqueur publicitaire ou d'injection algorithmique :
     * - is_sponsored (booléen ou 1)
     * - ad_id
     * - injected
     * - netego_type (ex: ad4ad, suggested_clips, stories_netego)
     * - suggested_users
     */
    fun isAdOrAlgorithmicInsertion(obj: JSONObject): Boolean {
        // Vérification directe sur l'objet racine de l'item
        if (hasAdMarkers(obj)) {
            return true
        }

        // Vérification dans l'objet imbriqué 'media_or_ad' (courant dans la timeline)
        val mediaOrAd = obj.optJSONObject("media_or_ad")
        if (mediaOrAd != null && hasAdMarkers(mediaOrAd)) {
            return true
        }

        // Vérification dans l'objet imbriqué 'story'
        val story = obj.optJSONObject("story")
        if (story != null && hasAdMarkers(story)) {
            return true
        }

        return false
    }

    private fun hasAdMarkers(obj: JSONObject): Boolean {
        // Clé 'is_sponsored' (peut être un booléen ou un entier 1)
        if (obj.has("is_sponsored")) {
            val isSponsored = obj.optBoolean("is_sponsored", false) || obj.optInt("is_sponsored", 0) == 1
            if (isSponsored) return true
        }

        // Clé 'ad_id'
        if (obj.has("ad_id") && !obj.isNull("ad_id")) {
            val adId = obj.optString("ad_id", "")
            if (adId.isNotBlank()) return true
        }

        // Clé 'injected'
        if (obj.has("injected")) {
            return true
        }

        // Clé 'netego_type' (Network Ego: posts sponsorisés, suggestions algorithmiques poussées)
        if (obj.has("netego_type")) {
            return true
        }

        // Clé 'suggested_users'
        if (obj.has("suggested_users")) {
            return true
        }

        return false
    }

    companion object {
        const val ENDPOINT_REELS_TRAY = "reels_tray"
        const val ENDPOINT_TIMELINE = "timeline"
        const val KEY_IS_SPONSORED = "is_sponsored"
        const val KEY_RANKED_POSITION = "ranked_position"
        const val KEY_FEED_ITEMS = "feed_items"
        const val KEY_NETEGO_TYPE = "netego_type"
    }
}
