package com.stepanic.mobilephoneproxy

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/**
 * Process-wide observable state shared between the foreground proxy service and
 * the Compose UI. Mirrors the @Published fields on iOS ProxyServer.
 */
object ProxyState {
    private val _isRunning = MutableStateFlow(false)
    val isRunning: StateFlow<Boolean> = _isRunning.asStateFlow()

    private val _port = MutableStateFlow(DEFAULT_PORT)
    val port: StateFlow<Int> = _port.asStateFlow()

    private val _wifiIp = MutableStateFlow("—")
    val wifiIp: StateFlow<String> = _wifiIp.asStateFlow()

    private val _cellularIp = MutableStateFlow("—")
    val cellularIp: StateFlow<String> = _cellularIp.asStateFlow()

    private val _activeConnections = MutableStateFlow(0)
    val activeConnections: StateFlow<Int> = _activeConnections.asStateFlow()

    private val _bytesUp = MutableStateFlow(0L)
    val bytesUp: StateFlow<Long> = _bytesUp.asStateFlow()

    private val _bytesDown = MutableStateFlow(0L)
    val bytesDown: StateFlow<Long> = _bytesDown.asStateFlow()

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()

    private val upCounter = AtomicLong(0)
    private val downCounter = AtomicLong(0)

    fun setRunning(running: Boolean) { _isRunning.value = running }
    fun setPort(p: Int) { _port.value = p }
    fun setWifiIp(s: String) { _wifiIp.value = s }
    fun setCellularIp(s: String) { _cellularIp.value = s }

    fun connectionOpened() { _activeConnections.update { it + 1 } }
    fun connectionClosed() { _activeConnections.update { if (it > 0) it - 1 else 0 } }

    fun recordUp(n: Int) { _bytesUp.value = upCounter.addAndGet(n.toLong()) }
    fun recordDown(n: Int) { _bytesDown.value = downCounter.addAndGet(n.toLong()) }

    fun resetCounters() {
        upCounter.set(0); downCounter.set(0)
        _bytesUp.value = 0; _bytesDown.value = 0
        _activeConnections.value = 0
    }

    fun log(line: String) {
        val ts = TS.format(Date())
        _log.update { prev ->
            val next = prev + "$ts  $line"
            if (next.size > 300) next.subList(next.size - 300, next.size) else next
        }
    }

    private val TS = SimpleDateFormat("HH:mm:ss", Locale.US)

    const val DEFAULT_PORT = 8888
}
