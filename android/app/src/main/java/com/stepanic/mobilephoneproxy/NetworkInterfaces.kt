package com.stepanic.mobilephoneproxy

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Helpers for picking the right Android Network to bind outbound sockets to,
 * and for surfacing the current LAN/cellular IPs in the UI.
 *
 * On iOS we relied on NWParameters.requiredInterfaceType = .cellular.
 * The Android equivalent is requesting a TRANSPORT_CELLULAR Network from
 * ConnectivityManager and calling Network.bindSocket() / Network.getByName()
 * on it — that guarantees the socket and its DNS resolution use the cellular
 * data network, regardless of what the system default route is.
 */
object NetworkInterfaces {

    fun connectivityManager(ctx: Context): ConnectivityManager =
        ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    /** First IPv4 address attached to a Network that satisfies [transport]. */
    fun ipForTransport(cm: ConnectivityManager, transport: Int): String? {
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(transport)) continue
            // Skip VPN overlays — we want the underlying interface IP.
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                transport != NetworkCapabilities.TRANSPORT_VPN
            ) continue
            val lp: LinkProperties = cm.getLinkProperties(network) ?: continue
            val v4 = lp.linkAddresses
                .map { it.address }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
            if (v4 != null) return v4.hostAddress
        }
        return null
    }

    /**
     * Fallback used when the LAN ServerSocket binds to 0.0.0.0 — find the first
     * non-loopback IPv4 on any local NetworkInterface so the UI can show a
     * usable "set your laptop proxy to http://this:8888" URL.
     */
    fun anyLocalIPv4(): String? {
        for (iface in NetworkInterface.getNetworkInterfaces()) {
            if (!iface.isUp || iface.isLoopback || iface.isVirtual) continue
            for (addr in iface.inetAddresses) {
                if (addr is Inet4Address && !addr.isLoopbackAddress) {
                    return addr.hostAddress
                }
            }
        }
        return null
    }

    /** First Network in [cm] that has TRANSPORT_CELLULAR, or null. */
    fun firstCellularNetwork(cm: ConnectivityManager): Network? {
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            ) return network
        }
        return null
    }
}
