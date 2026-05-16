package com.stepanic.mobilephoneproxy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Foreground service that hosts the HTTP CONNECT proxy listener on the LAN.
 * Each accepted client socket is dispatched to a worker thread that bridges
 * traffic out through the cellular Network, mirroring iOS ProxyServer.
 *
 * Why a foreground service:
 *   - Plain background work gets aggressively suspended (esp. on OEM ROMs).
 *   - With foregroundServiceType=dataSync + an ongoing notification, the OS
 *     keeps the process alive and the ServerSocket open for clients on WiFi.
 */
class ProxyService : Service() {

    private val executor = Executors.newCachedThreadPool { r ->
        Thread(r, "proxy-worker").apply { isDaemon = true }
    }
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    @Volatile private var running = false

    private lateinit var cm: ConnectivityManager
    private val cellularNetwork = AtomicReference<Network?>(null)
    private var cellularCallback: ConnectivityManager.NetworkCallback? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        cm = NetworkInterfaces.connectivityManager(this)
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopProxy()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val port = intent?.getIntExtra(EXTRA_PORT, ProxyState.DEFAULT_PORT)
                    ?: ProxyState.DEFAULT_PORT
                startForeground(NOTIF_ID, buildNotification(port), foregroundServiceType())
                startProxy(port)
            }
        }
        return START_STICKY
    }

    private fun foregroundServiceType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else 0

    override fun onDestroy() {
        stopProxy()
        super.onDestroy()
    }

    private fun startProxy(port: Int) {
        if (running) return
        ProxyState.setPort(port)
        ProxyState.resetCounters()

        // Hold a partial wake lock so the CPU stays responsive while the device
        // is idle but the screen may be off. The user is expected to plug the
        // phone in — this is a "phone as appliance" use case.
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG::wake")
            .apply { setReferenceCounted(false); acquire() }

        registerCellularCallback()

        try {
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(java.net.InetSocketAddress(InetAddress.getByName("0.0.0.0"), port))
            serverSocket = ss
            running = true
            ProxyState.setRunning(true)
            ProxyState.log("Listening on port $port")
            refreshIps()

            acceptThread = Thread({ acceptLoop(ss) }, "proxy-accept").also {
                it.isDaemon = true
                it.start()
            }
        } catch (t: Throwable) {
            ProxyState.log("Start error: ${t.message}")
            stopProxy()
            stopSelf()
        }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running && !ss.isClosed) {
            try {
                val client = ss.accept()
                executor.execute(HttpProxyHandler(client, cellularNetwork.get()))
            } catch (t: Throwable) {
                if (running) ProxyState.log("accept error: ${t.message}")
            }
        }
    }

    private fun stopProxy() {
        if (!running && serverSocket == null) return
        running = false
        ProxyState.setRunning(false)
        runCatching { serverSocket?.close() }
        serverSocket = null
        acceptThread = null
        unregisterCellularCallback()
        runCatching { wakeLock?.release() }
        wakeLock = null
        ProxyState.log("Stopped")
    }

    private fun registerCellularCallback() {
        if (cellularCallback != null) return
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cellularNetwork.set(network)
                ProxyState.log("Cellular network available")
                refreshIps()
            }
            override fun onLost(network: Network) {
                if (cellularNetwork.compareAndSet(network, null)) {
                    ProxyState.log("Cellular network lost")
                    refreshIps()
                }
            }
        }
        cellularCallback = cb
        // requestNetwork keeps the cellular radio up even if WiFi is the default
        // route, which is exactly what we want for a residential proxy.
        cm.requestNetwork(req, cb)
        // Seed immediately in case cellular is already up.
        cellularNetwork.set(NetworkInterfaces.firstCellularNetwork(cm))
    }

    private fun unregisterCellularCallback() {
        cellularCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        cellularCallback = null
        cellularNetwork.set(null)
    }

    private fun refreshIps() {
        val wifi = NetworkInterfaces.ipForTransport(cm, NetworkCapabilities.TRANSPORT_WIFI)
            ?: NetworkInterfaces.anyLocalIPv4() ?: "—"
        val cell = NetworkInterfaces.ipForTransport(cm, NetworkCapabilities.TRANSPORT_CELLULAR) ?: "—"
        ProxyState.setWifiIp(wifi)
        ProxyState.setCellularIp(cell)
    }

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val ch = NotificationChannel(
                CHANNEL_ID, "Proxy", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Mobile Phone Proxy running notification" }
            nm.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(port: Int): Notification {
        val launch = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopIntent = Intent(this, ProxyService::class.java).setAction(ACTION_STOP)
        val stopPi = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("Mobile Phone Proxy")
            .setContentText("Listening on port $port — tunneling via cellular")
            .setOngoing(true)
            .setContentIntent(pi)
            .addAction(0, "Stop", stopPi)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        private const val TAG = "MobilePhoneProxy"
        private const val CHANNEL_ID = "proxy"
        private const val NOTIF_ID = 1
        const val ACTION_STOP = "com.stepanic.mobilephoneproxy.STOP"
        const val EXTRA_PORT = "port"

        fun start(ctx: Context, port: Int) {
            val i = Intent(ctx, ProxyService::class.java).putExtra(EXTRA_PORT, port)
            ctx.startForegroundService(i)
        }

        fun stop(ctx: Context) {
            val i = Intent(ctx, ProxyService::class.java).setAction(ACTION_STOP)
            ctx.startService(i)
        }
    }
}
