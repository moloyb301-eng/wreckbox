package local.wreckbox.wreckbox

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom

// AudioServiceActivity (a FlutterActivity) lets playback continue in the background with media controls.
//
// "wreckbox/direct": the phone hosts a Wi-Fi Direct group (an access point named DIRECT-…) that the computer
// joins like any Wi-Fi network, for copying tracks when the two aren't on the same Wi-Fi.
class MainActivity : AudioServiceActivity() {
    private var p2p: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wreckbox/direct").setMethodCallHandler { call, result ->
            when (call.method) {
                "wifiOn" -> result.success((applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).isWifiEnabled)
                "openWifi" -> {
                    startActivity(Intent(if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS))
                    result.success(null)
                }
                "start" -> start(result)
                "stop" -> {
                    stop()
                    result.success(null)
                }
                // A long copy shouldn't stall because the screen went off.
                "keepAwake" -> {
                    if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun manager(): Pair<WifiP2pManager, WifiP2pManager.Channel>? {
        val m = p2p ?: (getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager) ?: return null
        val c = channel ?: m.initialize(this, mainLooper, null)
        p2p = m
        channel = c
        return m to c
    }

    /// Returns {ssid, pass, freq} once the group is up.
    private fun start(result: MethodChannel.Result) {
        val (m, c) = manager() ?: return result.error("unsupported", "This phone has no Wi-Fi Direct", null)
        // A group left over from last time would keep its old passphrase.
        m.removeGroup(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = create(m, c, result, fiveGHz = true)
            override fun onFailure(reason: Int) = create(m, c, result, fiveGHz = true)
        })
    }

    private fun create(m: WifiP2pManager, c: WifiP2pManager.Channel, result: MethodChannel.Result, fiveGHz: Boolean) {
        val listener = object : WifiP2pManager.ActionListener {
            override fun onSuccess() = waitForGroup(m, c, result, 0)
            override fun onFailure(reason: Int) {
                // 5 GHz can be refused (e.g. the phone is on a 2.4 GHz network): let the phone pick the band.
                if (fiveGHz && Build.VERSION.SDK_INT >= 29) return create(m, c, result, fiveGHz = false)
                result.error(
                    when (reason) { WifiP2pManager.P2P_UNSUPPORTED -> "unsupported"; WifiP2pManager.BUSY -> "busy"; else -> "error" },
                    "Couldn't start the direct link (reason $reason)", null,
                )
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                val config = WifiP2pConfig.Builder()
                    .setNetworkName("DIRECT-WB-WreckBox")
                    .setPassphrase(passphrase())
                    .setGroupOperatingBand(if (fiveGHz) WifiP2pConfig.GROUP_OWNER_BAND_5GHZ else WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
                    .build()
                m.createGroup(c, config, listener)
            } else {
                m.createGroup(c, listener)
            }
        } catch (e: SecurityException) {
            result.error("permission", "Allow WreckBox to find nearby Wi-Fi devices", null)
        }
    }

    private fun waitForGroup(m: WifiP2pManager, c: WifiP2pManager.Channel, result: MethodChannel.Result, tries: Int) {
        try {
            m.requestGroupInfo(c) { g: WifiP2pGroup? ->
                if (g != null && g.passphrase != null) {
                    result.success(mapOf(
                        "ssid" to g.networkName,
                        "pass" to g.passphrase,
                        "freq" to (if (Build.VERSION.SDK_INT >= 29) g.frequency else 0),
                    ))
                } else if (tries < 20) {
                    main.postDelayed({ waitForGroup(m, c, result, tries + 1) }, 250)
                } else {
                    result.error("error", "The direct link didn't come up", null)
                }
            }
        } catch (e: SecurityException) {
            result.error("permission", "Allow WreckBox to find nearby Wi-Fi devices", null)
        }
    }

    private fun stop() {
        val (m, c) = manager() ?: return
        m.removeGroup(c, null)
    }

    private fun passphrase(): String {
        val chars = "abcdefghjkmnpqrstuvwxyz23456789"
        val r = SecureRandom()
        return (1..12).map { chars[r.nextInt(chars.length)] }.joinToString("")
    }

    override fun onDestroy() {
        stop()
        super.onDestroy()
    }
}
