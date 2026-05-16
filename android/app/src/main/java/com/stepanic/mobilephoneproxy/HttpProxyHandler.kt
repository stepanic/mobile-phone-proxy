package com.stepanic.mobilephoneproxy

import android.net.Network
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Per-client HTTP proxy worker. Mirrors HTTPProxyHandler.swift:
 *   - Reads request headers up to CRLF CRLF (limit 64 KiB).
 *   - Supports CONNECT (TLS tunnel) and plain absolute-URI HTTP forwarding.
 *   - Strips hop-by-hop headers per RFC 9110 §7.6.1, dynamically including
 *     any name listed in the inbound Connection header.
 *   - Forces outbound through [cellularNetwork] so DNS + TCP go over LTE.
 *   - Full-duplex byte relay with half-close on EOF.
 */
class HttpProxyHandler(
    private val client: Socket,
    private val cellularNetwork: Network?,
) : Runnable {

    override fun run() {
        ProxyState.connectionOpened()
        try {
            client.tcpNoDelay = true
            client.soTimeout = 0
            val cin = client.getInputStream()
            val cout = client.getOutputStream()

            val parsed = readAndParseRequest(cin)
            if (parsed == null) {
                sendStatus(cout, "400 Bad Request")
                return
            }
            ProxyState.log("${parsed.method} ${parsed.host}:${parsed.port}")

            val upstream = openUpstream(parsed.host, parsed.port)
            if (upstream == null) {
                sendStatus(cout, "502 Bad Gateway")
                return
            }

            try {
                upstream.tcpNoDelay = true
                val uin = upstream.getInputStream()
                val uout = upstream.getOutputStream()

                if (parsed.isConnect) {
                    cout.write(
                        ("HTTP/1.1 200 Connection Established\r\n" +
                            "Proxy-Agent: MobilePhoneProxy\r\n\r\n").toByteArray()
                    )
                    cout.flush()
                } else {
                    val rebuilt = rebuildRequest(parsed).toByteArray()
                    uout.write(rebuilt)
                    if (parsed.leftover.isNotEmpty()) uout.write(parsed.leftover)
                    uout.flush()
                }

                relay(cin, uout, uin, cout, upstream)
            } finally {
                runCatching { upstream.close() }
            }
        } catch (t: Throwable) {
            ProxyState.log("client error: ${t.javaClass.simpleName}: ${t.message ?: ""}")
        } finally {
            runCatching { client.close() }
            ProxyState.connectionClosed()
        }
    }

    private fun openUpstream(host: String, port: Int): Socket? {
        return try {
            val socket = Socket()
            // Bind the socket to the cellular Network *before* connect() so the
            // SYN goes out the LTE interface. If we have no cellular network
            // (simulator, airplane mode), fall back to default routing so we
            // can still validate the protocol path end-to-end.
            cellularNetwork?.bindSocket(socket)
            val addr = if (cellularNetwork != null) {
                // Resolve DNS through the cellular network too — otherwise we'd
                // ask the WiFi resolver and could leak DNS or get split-horizon
                // answers.
                val resolved = cellularNetwork.getAllByName(host).firstOrNull()
                    ?: throw java.net.UnknownHostException(host)
                InetSocketAddress(resolved, port)
            } else {
                InetSocketAddress(host, port)
            }
            socket.connect(addr, CONNECT_TIMEOUT_MS)
            socket
        } catch (t: Throwable) {
            ProxyState.log("upstream failed ($host:$port): ${t.javaClass.simpleName}: ${t.message ?: ""}")
            null
        }
    }

    private fun relay(
        cin: InputStream, uout: OutputStream,
        uin: InputStream, cout: OutputStream,
        upstream: Socket,
    ) {
        val upPump = Thread({
            pump(cin, uout, upRecord = true) {
                runCatching { upstream.shutdownOutput() }
            }
        }, "proxy-up-${client.port}")

        upPump.isDaemon = true
        upPump.start()

        pump(uin, cout, upRecord = false) {
            runCatching { client.shutdownOutput() }
        }
        runCatching { upPump.join(2_000) }
    }

    private inline fun pump(
        src: InputStream,
        dst: OutputStream,
        upRecord: Boolean,
        crossinline onEof: () -> Unit,
    ) {
        val buf = ByteArray(32 * 1024)
        try {
            while (true) {
                val n = src.read(buf)
                if (n < 0) break
                if (n == 0) continue
                dst.write(buf, 0, n)
                dst.flush()
                if (upRecord) ProxyState.recordUp(n) else ProxyState.recordDown(n)
            }
        } catch (_: Throwable) {
            // Either side closed mid-relay — treat as end of stream.
        } finally {
            onEof()
        }
    }

    // -- request parsing ----------------------------------------------------

    private data class Parsed(
        val method: String,
        val target: String,
        val version: String,
        val headers: List<String>,
        val host: String,
        val port: Int,
        val leftover: ByteArray,
    ) {
        val isConnect: Boolean get() = method.equals("CONNECT", ignoreCase = true)
    }

    private fun readAndParseRequest(cin: InputStream): Parsed? {
        val buf = ArrayList<Byte>(2048)
        val chunk = ByteArray(4096)
        var headerEnd = -1
        while (headerEnd < 0) {
            val n = cin.read(chunk)
            if (n < 0) return null
            for (i in 0 until n) buf.add(chunk[i])
            if (buf.size > HEADER_LIMIT) return null
            headerEnd = indexOfCrLfCrLf(buf)
        }
        val headerBytes = ByteArray(headerEnd) { buf[it] }
        val leftover = ByteArray(buf.size - headerEnd - 4) { buf[headerEnd + 4 + it] }
        return parseHeaders(headerBytes, leftover)
    }

    private fun indexOfCrLfCrLf(buf: ArrayList<Byte>): Int {
        if (buf.size < 4) return -1
        for (i in 0..buf.size - 4) {
            if (buf[i] == 0x0D.toByte() && buf[i + 1] == 0x0A.toByte() &&
                buf[i + 2] == 0x0D.toByte() && buf[i + 3] == 0x0A.toByte()
            ) return i
        }
        return -1
    }

    private fun parseHeaders(headerBytes: ByteArray, leftover: ByteArray): Parsed? {
        val text = String(headerBytes, Charsets.ISO_8859_1)
        val lines = text.split("\r\n").toMutableList()
        if (lines.isEmpty()) return null
        val requestLine = lines.removeAt(0)
        val parts = requestLine.split(" ", limit = 3)
        if (parts.size != 3) return null
        val method = parts[0]
        val target = parts[1]
        val version = parts[2]

        val hopByHop = mutableSetOf(
            "proxy-connection", "proxy-authorization", "connection", "keep-alive",
            "transfer-encoding", "te", "trailer", "upgrade",
        )
        val raw = ArrayList<Pair<String, String>>()
        for (line in lines) {
            if (line.isEmpty()) continue
            val colon = line.indexOf(':')
            if (colon < 0) continue
            val name = line.substring(0, colon).trim()
            val value = line.substring(colon + 1).trim()
            raw.add(name to value)
            if (name.equals("connection", ignoreCase = true)) {
                value.split(",").forEach { hopByHop.add(it.trim().lowercase()) }
            }
        }

        var host = ""
        var port = 80
        val sanitized = ArrayList<String>()
        for ((name, value) in raw) {
            val lower = name.lowercase()
            if (lower in hopByHop) continue
            if (lower == "host") {
                val (h, p) = splitHostPort(value, defaultPort = port)
                host = h; port = p
            }
            sanitized.add("$name: $value")
        }

        if (method.equals("CONNECT", ignoreCase = true)) {
            val (h, p) = splitHostPort(target, defaultPort = 443)
            host = h; port = p
        } else {
            val (uHost, uPort) = hostPortFromAbsoluteUri(target)
            if (uHost != null) {
                if (host.isEmpty()) host = uHost
                if (uPort != null) port = uPort
            }
        }

        if (host.isEmpty()) return null
        return Parsed(method, target, version, sanitized, host, port, leftover)
    }

    private fun splitHostPort(s: String, defaultPort: Int): Pair<String, Int> {
        if (s.startsWith("[")) {
            val end = s.indexOf(']')
            if (end > 0) {
                val h = s.substring(1, end)
                val rest = s.substring(end + 1)
                if (rest.startsWith(":")) {
                    val p = rest.substring(1).toIntOrNull()
                    if (p != null) return h to p
                }
                return h to defaultPort
            }
        }
        val colon = s.lastIndexOf(':')
        if (colon >= 0) {
            val p = s.substring(colon + 1).toIntOrNull()
            if (p != null) return s.substring(0, colon) to p
        }
        return s to defaultPort
    }

    private fun hostPortFromAbsoluteUri(target: String): Pair<String?, Int?> {
        // target may be http://host:port/path or /path. We only need host/port
        // when method != CONNECT and the URI is absolute (RFC 9112 §3.2.2).
        val scheme = when {
            target.startsWith("http://", ignoreCase = true) -> "http"
            target.startsWith("https://", ignoreCase = true) -> "https"
            else -> return null to null
        }
        val rest = target.substring(scheme.length + 3) // skip "://"
        val slash = rest.indexOf('/').let { if (it < 0) rest.length else it }
        val authority = rest.substring(0, slash)
        val (h, p) = splitHostPort(authority, defaultPort = if (scheme == "https") 443 else 80)
        return h to p
    }

    private fun rebuildRequest(req: Parsed): String {
        // Convert absolute URI to origin-form path.
        val path = run {
            val t = req.target
            if (t.startsWith("http://", true) || t.startsWith("https://", true)) {
                val rest = t.substringAfter("://")
                val slash = rest.indexOf('/')
                if (slash < 0) "/" else rest.substring(slash)
            } else t
        }
        val sb = StringBuilder()
        sb.append(req.method).append(' ').append(path).append(' ').append(req.version).append("\r\n")
        var hasHost = false
        for (h in req.headers) {
            if (h.lowercase().startsWith("host:")) hasHost = true
            sb.append(h).append("\r\n")
        }
        if (!hasHost) {
            val hostHeader = if (req.port == 80) req.host else "${req.host}:${req.port}"
            sb.append("Host: ").append(hostHeader).append("\r\n")
        }
        sb.append("Connection: close\r\n\r\n")
        return sb.toString()
    }

    private fun sendStatus(out: OutputStream, status: String) {
        try {
            val body = "HTTP/1.1 $status\r\n" +
                "Proxy-Agent: MobilePhoneProxy\r\n" +
                "Connection: close\r\n" +
                "Content-Length: 0\r\n\r\n"
            out.write(body.toByteArray())
            out.flush()
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val HEADER_LIMIT = 64 * 1024
        private const val CONNECT_TIMEOUT_MS = 15_000
    }
}
