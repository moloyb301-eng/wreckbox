package local.wreckbox.player

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.os.Message
import android.webkit.WebChromeClient
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature

/** The only time a service's web page is on screen: signing in. Cookies are app-wide, so the hidden pages are signed in too. */
class LoginActivity : Activity() {
    private lateinit var service: Service
    private lateinit var root: FrameLayout
    private val popups = mutableListOf<WebView>()

    /**
     * One sign-in page. Google refuses sign-in from anything that looks like an embedded WebView
     * ("disallowed_useragent"): a "; wv" marker in the user agent and the X-Requested-With header carrying the app's
     * name. Spotify's "Continue with Google" goes through exactly that check, so Spotify's sign-in presents itself as
     * plain mobile Chrome. (YouTube's own Google login page accepts the WebView's normal identity.)
     */
    @SuppressLint("SetJavaScriptEnabled")
    private fun newPage(): WebView = WebView(this).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        if (service == Service.SPOTIFY) {
            settings.userAgentString = chromeMobileAgent()
            if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
                WebSettingsCompat.setRequestedWithHeaderOriginAllowList(settings, emptySet())
            }
        }
        // "Continue with Google" opens a popup window and talks back to this page: allow it.
        settings.setSupportMultipleWindows(true)
        settings.javaScriptCanOpenWindowsAutomatically = true
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
        webViewClient = object : WebViewClient() {
            // Signed in: done — close before the service's own player page loads here.
            override fun onPageFinished(view: WebView, url: String) = finishIfSignedIn()
        }
        webChromeClient = object : WebChromeClient() {
            override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                val popup = newPage()
                popups += popup
                root.addView(popup, FrameLayout.LayoutParams(-1, -1))
                (resultMsg.obj as WebView.WebViewTransport).webView = popup
                resultMsg.sendToTarget()
                return true
            }

            override fun onCloseWindow(window: WebView) {
                closePopup(window)
                finishIfSignedIn()
            }
        }
    }

    private fun closePopup(w: WebView) {
        if (popups.remove(w)) { root.removeView(w); w.destroy() }
    }

    private fun finishIfSignedIn() {
        if (signedIn(service)) {
            CookieManager.getInstance().flush()
            setResult(RESULT_OK)
            finish()
        }
    }

    override fun onBackPressed() {
        // Back closes the Google popup first, then the sign-in screen.
        popups.lastOrNull()?.let { closePopup(it) } ?: super.onBackPressed()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        service = Service.valueOf(intent.getStringExtra("service") ?: "YOUTUBE")
        val web = newPage().apply { loadUrl(service.login) }
        val done = Button(this).apply {
            text = "Done"
            setOnClickListener {
                CookieManager.getInstance().flush()
                setResult(RESULT_OK)
                finish()
            }
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            addView(done)
            addView(web, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        root = FrameLayout(this).apply { addView(column, FrameLayout.LayoutParams(-1, -1)) }
        setContentView(root)
    }

    override fun onDestroy() {
        popups.toList().forEach { closePopup(it) }
        super.onDestroy()
    }

    companion object {
        /** Plain mobile Chrome on this WebView's engine version (no "; wv" marker). */
        fun chromeMobileAgent(): String {
            val chrome = runCatching { WebView.getCurrentWebViewPackage()?.versionName?.substringBefore('.') }.getOrNull() ?: "140"
            return "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chrome.0.0.0 Mobile Safari/537.36"
        }

        /**
         * Signs out of one service: expires its cookies (Android has no "delete this site's cookies"), on every domain
         * its sign-in uses, then reloads nothing — the hidden page picks the change up on its next song.
         */
        fun signOut(s: Service) {
            val cm = CookieManager.getInstance()
            val sites = when (s) {
                Service.YOUTUBE -> listOf("youtube.com", "music.youtube.com", "www.youtube.com", "google.com", "accounts.google.com", "www.google.com")
                Service.SPOTIFY -> listOf("spotify.com", "open.spotify.com", "accounts.spotify.com", "www.spotify.com")
            }
            for (site in sites) {
                val url = "https://$site"
                val names = cm.getCookie(url)?.split(";")?.map { it.substringBefore('=').trim() }?.filter { it.isNotEmpty() } ?: continue
                for (n in names) {
                    val secure = "; Secure"
                    cm.setCookie(url, "$n=; Max-Age=0; Path=/$secure")
                    if (!n.startsWith("__Host-")) {
                        cm.setCookie(url, "$n=; Max-Age=0; Path=/; Domain=$site$secure")
                        cm.setCookie(url, "$n=; Max-Age=0; Path=/; Domain=.${site.split('.').takeLast(2).joinToString(".")}$secure")
                    }
                }
            }
            cm.flush()
        }

        /** Signed in = the service's session cookie is there. */
        fun signedIn(s: Service): Boolean {
            val c = CookieManager.getInstance().getCookie(s.origin) ?: return false
            return when (s) {
                Service.YOUTUBE -> c.contains("SAPISID=") || c.contains("__Secure-3PAPISID=")
                Service.SPOTIFY -> c.contains("sp_dc=")
            }
        }
    }
}
