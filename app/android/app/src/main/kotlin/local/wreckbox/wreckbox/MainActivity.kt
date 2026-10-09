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
import android.media.audiofx.Visualizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import java.security.SecureRandom

// AudioServiceActivity (a FlutterActivity) lets playback continue in the background with media controls.
//
// "wreckbox/direct": the phone hosts a Wi-Fi Direct group (an access point named DIRECT-…) that the computer
// joins like any Wi-Fi network, for copying tracks when the two aren't on the same Wi-Fi.
class MainActivity : AudioServiceActivity() {
    private var p2p: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private val main = Handler(Looper.getMainLooper())

    private var visualizer: Visualizer? = null
    private var fftSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Spectrum of what this phone plays, for the full-screen visualiser.
        EventChannel(messenger, "wreckbox/visualizer/fft").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) { fftSink = sink }
            override fun onCancel(args: Any?) { fftSink = null }
        })
        MethodChannel(messenger, "wreckbox/visualizer").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> try {
                    startVisualizer(call.arguments as Int)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("visualizer", e.message, null)
                }
                "stop" -> { stopVisualizer(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wreckbox/direct").setMethodCallHandler { call, result ->
            when (call.method) {
                "wifiOn" -> result.success((applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).isWifiEnabled)
                "openWifi" -> {
                    startActivity(Intent(if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS))
                    result.success(null)
                }
                // "Galaxy S23 Ultra" (what the phone calls itself), for the list of devices on the computer.
                "deviceName" -> result.success(
                    Settings.Global.getString(contentResolver, "device_name") ?: "${Build.MANUFACTURER} ${Build.MODEL}",
                )
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

    private fun startVisualizer(session: Int) {
        stopVisualizer()
        val v = Visualizer(session)
        v.captureSize = Visualizer.getCaptureSizeRange()[1]
        val bands = 32
        v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
            override fun onWaveFormDataCapture(vis: Visualizer, data: ByteArray, rate: Int) {}
            override fun onFftDataCapture(vis: Visualizer, fft: ByteArray, rate: Int) {
                val n = fft.size / 2
                val binHz = vis.samplingRate / 1000.0 / 2 / n      // samplingRate is in mHz
                val out = DoubleArray(bands)
                for (b in 0 until bands) {
                    val lo = 40 * 400.0.pow(b / bands.toDouble())
                    val hi = 40 * 400.0.pow((b + 1) / bands.toDouble())
                    val i0 = max(1, (lo / binHz).toInt())
                    val i1 = max(i0 + 1, minOf(n, (hi / binHz).toInt()))
                    var peak = 0.0
                    for (i in i0 until i1) peak = max(peak, hypot(fft[2 * i].toDouble(), fft[2 * i + 1].toDouble()))
                    val db = 20 * log10(max(peak, 1e-3) / 128.0)
                    out[b] = ((db + 48) / 48).coerceIn(0.0, 1.0)
                }
                fftSink?.success(out.toList())
            }
        }, Visualizer.getMaxCaptureRate(), false, true)
        v.enabled = true
        visualizer = v
    }

    private fun stopVisualizer() {
        visualizer?.run { enabled = false; release() }
        visualizer = null
    }

    override fun onDestroy() {
        stopVisualizer()
        stop()
        super.onDestroy()
    }
}
