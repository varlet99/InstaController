package com.instacontroller.core

import org.json.JSONObject

/**
 * Interface permettant de calculer un score de pertinence pour chaque story du reels_tray.
 *
 * Plus le score est élevé, plus la story apparaîtra en tête du plateau de stories.
 * Cette interface sert de pont pour brancher aussi bien des heuristiques locales
 * qu'un agent IA léger (détection de contenu sponsorisé, placements de produits, etc.).
 */
fun interface StoryScorer {
    /**
     * Évalue un élément du tableau `tray` d'Instagram et retourne un score numérique.
     *
     * @param storyTrayItem L'objet JSON brut représentant une story utilisateur dans le tray.
     * @return Score pondéré (valeur plus élevée = affichage plus prioritaire).
     */
    fun score(storyTrayItem: JSONObject): Double
}
