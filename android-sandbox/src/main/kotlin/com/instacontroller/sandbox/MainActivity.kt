package com.instacontroller.sandbox

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.graphics.Bitmap
import android.os.Bundle
import android.view.View
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.ImageButton
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.card.MaterialCardView
import com.google.android.material.floatingactionbutton.ExtendedFloatingActionButton

class MainActivity : AppCompatActivity(), InstaBridge.StatsListener {

    private lateinit var webView: WebView
    private lateinit var fabToggleHud: ExtendedFloatingActionButton
    private lateinit var hudCard: MaterialCardView
    private lateinit var btnCloseHud: ImageButton
    private lateinit var tvAdsCount: TextView
    private lateinit var tvStoriesCount: TextView
    private lateinit var tvStatusDesc: TextView
    private lateinit var tvFavoritesList: TextView
    private lateinit var etNewFavorite: EditText
    private lateinit var btnAddFavorite: Button
    private lateinit var btnSimulate: Button
    private lateinit var btnReload: Button

    private lateinit var instaBridge: InstaBridge
    private var interceptorJsCode: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        instaBridge = InstaBridge(this)
        interceptorJsCode = loadAssetAsString("interceptor.js")

        initViews()
        setupWebView()
        setupListeners()

        // Chargement d'Instagram Following
        webView.loadUrl("https://www.instagram.com/?variant=following")
    }

    private fun initViews() {
        webView = findViewById(R.id.webView)
        fabToggleHud = findViewById(R.id.fabToggleHud)
        hudCard = findViewById(R.id.hudCard)
        btnCloseHud = findViewById(R.id.btnCloseHud)
        tvAdsCount = findViewById(R.id.tvAdsCount)
        tvStoriesCount = findViewById(R.id.tvStoriesCount)
        tvStatusDesc = findViewById(R.id.tvStatusDesc)
        tvFavoritesList = findViewById(R.id.tvFavoritesList)
        etNewFavorite = findViewById(R.id.etNewFavorite)
        btnAddFavorite = findViewById(R.id.btnAddFavorite)
        btnSimulate = findViewById(R.id.btnSimulate)
        btnReload = findViewById(R.id.btnReload)

        updateFavoritesDisplay(instaBridge.getFavorites())
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.allowFileAccess = true
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true

        // User-Agent Chrome mobile Android moderne
        settings.userAgentString = "Mozilla/5.0 (Linux; Android 13; SM-A136W Build/TP1A.220624.014; wv) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/128.0.6613.127 Mobile Safari/537.36"

        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        cookieManager.setAcceptThirdPartyCookies(webView, true)

        // Enregistrement du pont natif
        webView.addJavascriptInterface(instaBridge, "InstaBridge")

        webView.webChromeClient = WebChromeClient()
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                super.onPageStarted(view, url, favicon)
                injectInterceptor()
            }

            override fun onLoadResource(view: WebView?, url: String?) {
                super.onLoadResource(view, url)
                injectInterceptor()
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                injectInterceptor()
            }
        }
    }

    private fun injectInterceptor() {
        if (interceptorJsCode.isNotBlank()) {
            webView.evaluateJavascript(interceptorJsCode, null)
        }
    }

    private fun setupListeners() {
        fabToggleHud.setOnClickListener {
            hudCard.visibility = View.VISIBLE
            fabToggleHud.visibility = View.GONE
        }

        btnCloseHud.setOnClickListener {
            hudCard.visibility = View.GONE
            fabToggleHud.visibility = View.VISIBLE
        }

        btnAddFavorite.setOnClickListener {
            val user = etNewFavorite.text.toString().trim()
            if (user.isNotBlank()) {
                instaBridge.addFavorite(user)
                etNewFavorite.text.clear()
            }
        }

        btnReload.setOnClickListener {
            webView.reload()
            tvStatusDesc.text = "Rechargement de la page..."
        }

        btnSimulate.setOnClickListener {
            runLocalSimulation()
        }
    }

    private fun runLocalSimulation() {
        try {
            val mockTimeline = loadAssetAsString("mock_timeline.json")
            val mockStories = loadAssetAsString("mock_reels_tray.json")

            val timelineFiltered = instaBridge.processTimelineJson(mockTimeline)
            val storiesFiltered = instaBridge.processStoriesJson(mockStories)

            val summary = buildString {
                append("Simulation locale réussie !\n\n")
                append("• Timeline : Pubs & suggestions supprimées du JSON simulé.\n")
                append("• Stories : Réordonnées selon Favoris (${instaBridge.getFavorites().joinToString { "@$it" }}).\n\n")
                append("Total Pubs bloquées : ${instaBridge.getAdsBlocked()}\n")
                append("Total Stories triées : ${instaBridge.getStoriesSorted()}")
            }

            AlertDialog.Builder(this)
                .setTitle("🧪 Test Moteur Local")
                .setMessage(summary)
                .setPositiveButton("OK", null)
                .show()

        } catch (e: Exception) {
            AlertDialog.Builder(this)
                .setTitle("Erreur de simulation")
                .setMessage(e.message)
                .setPositiveButton("OK", null)
                .show()
        }
    }

    override fun onStatsUpdated(adsBlocked: Int, storiesSorted: Int, lastActionDesc: String) {
        tvAdsCount.text = "🚫 Pubs: $adsBlocked"
        tvStoriesCount.text = "🔄 Stories: $storiesSorted"
        tvStatusDesc.text = "Dernière action : $lastActionDesc"
    }

    override fun onFavoritesChanged(favorites: Set<String>) {
        updateFavoritesDisplay(favorites)
    }

    private fun updateFavoritesDisplay(favorites: Set<String>) {
        if (favorites.isEmpty()) {
            tvFavoritesList.text = "(Aucun favori configuré)"
        } else {
            tvFavoritesList.text = favorites.joinToString(", ") { "@$it" }
        }
    }

    private fun loadAssetAsString(fileName: String): String {
        return assets.open(fileName).bufferedReader().use { it.readText() }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (hudCard.visibility == View.VISIBLE) {
            hudCard.visibility = View.GONE
            fabToggleHud.visibility = View.VISIBLE
        } else if (webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
    }
}
