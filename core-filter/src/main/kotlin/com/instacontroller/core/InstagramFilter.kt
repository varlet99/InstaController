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
        // Traitement de 'feed_items' (structure classique timeline)
        if (root.has("feed_items")) {
            val originalItems = root.getJSONArray("feed_items")
            val cleanedItems = JSONArray()
            for (i in 0 until originalItems.length()) {
                val item = originalItems.optJSONObject(i) ?: continue
                if (!isAdOrAlgorithmicInsertion(item)) {
                    cleanedItems.put(item)
                }
            }
            root.put("feed_items", cleanedItems)
        }

        // Traitement alternatif si les éléments sont sous 'items'
        if (root.has("items")) {
            val originalItems = root.getJSONArray("items")
            val cleanedItems = JSONArray()
            for (i in 0 until originalItems.length()) {
                val item = originalItems.optJSONObject(i) ?: continue
                if (!isAdOrAlgorithmicInsertion(item)) {
                    cleanedItems.put(item)
                }
            }
            root.put("items", cleanedItems)
        }

        return root
    }

    /**
     * Filtre et réordonne le JSON brut de l'endpoint des Stories (/api/v1/feed/reels_tray/).
     *
     * 1. Supprime les publicités et insertions algorithmiques injectées dans le plateau de stories.
     * 2. Réordonne le tableau `tray[]` selon le score fourni par le StoryScorer.
     * 3. Réindexe `ranked_position` pour garantir la cohérence d'affichage côté client.
     *
     * @param rawJson Le corps de réponse JSON brut de reels_tray.
     * @param scorer Scorer optionnel pour surcharger la pondération par défaut.
     * @return Le JSON filtré et trié sous forme de String.
     */
    fun filterStories(rawJson: String, scorer: StoryScorer = defaultStoryScorer): String {
        val root = JSONObject(rawJson)
        val filtered = filterStories(root, scorer)
        return filtered.toString()
    }

    /**
     * Filtre et réordonne un JSONObject de type reels_tray.
     */
    fun filterStories(root: JSONObject, scorer: StoryScorer = defaultStoryScorer): JSONObject {
        if (!root.has("tray")) {
            return root
        }

        val originalTray = root.getJSONArray("tray")
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

        root.put("tray", sortedTray)
        return root
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

        // Marqueurs additionnels courants
        if (obj.has("ad_action") || obj.has("sponsored_tags")) {
            return true
        }

        return false
    }
}
