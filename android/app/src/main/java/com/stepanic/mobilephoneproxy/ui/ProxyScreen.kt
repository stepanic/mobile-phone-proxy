package com.stepanic.mobilephoneproxy.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.stepanic.mobilephoneproxy.ProxyState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProxyScreen(
    onStart: (Int) -> Unit,
    onStop: () -> Unit,
) {
    val isRunning by ProxyState.isRunning.collectAsState()
    val port by ProxyState.port.collectAsState()
    val wifiIp by ProxyState.wifiIp.collectAsState()
    val cellularIp by ProxyState.cellularIp.collectAsState()
    val active by ProxyState.activeConnections.collectAsState()
    val up by ProxyState.bytesUp.collectAsState()
    val down by ProxyState.bytesDown.collectAsState()
    val log by ProxyState.log.collectAsState()

    var portText by remember { mutableStateOf(port.toString()) }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Mobile Phone Proxy") }) }
    ) { pad ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(pad)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            StatusCard(isRunning, active, wifiIp, cellularIp, up, down)
            ProxyControlCard(
                isRunning = isRunning,
                portText = portText,
                onPortChange = { portText = it.filter { c -> c.isDigit() }.take(5) },
                onStart = {
                    val p = portText.toIntOrNull()?.takeIf { it in 1..65535 } ?: ProxyState.DEFAULT_PORT
                    onStart(p)
                },
                onStop = onStop,
            )
            if (isRunning) {
                UsageCard(wifiIp, port)
            }
            LogCard(log)
        }
    }
}

@Composable
private fun StatusCard(
    isRunning: Boolean, active: Int, wifiIp: String, cellularIp: String,
    up: Long, down: Long,
) {
    Card(elevation = CardDefaults.cardElevation(2.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("Status")
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(10.dp)
                        .background(if (isRunning) Color(0xFF34C759) else Color.Gray, CircleShape)
                )
                Spacer(Modifier.size(8.dp))
                Text(
                    if (isRunning) "Running" else "Stopped",
                    style = MaterialTheme.typography.titleMedium,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "$active active",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            LabeledRow("WiFi IP", wifiIp)
            LabeledRow("Cellular IP", cellularIp)
            LabeledRow("Bytes ↑", formatBytes(up))
            LabeledRow("Bytes ↓", formatBytes(down))
        }
    }
}

@Composable
private fun ProxyControlCard(
    isRunning: Boolean,
    portText: String,
    onPortChange: (String) -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
) {
    Card(elevation = CardDefaults.cardElevation(2.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SectionTitle("Proxy")
            OutlinedTextField(
                value = portText,
                onValueChange = onPortChange,
                label = { Text("Port") },
                enabled = !isRunning,
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )
            if (isRunning) {
                Button(
                    onClick = onStop,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                        contentColor = MaterialTheme.colorScheme.onErrorContainer,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Default.Stop, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text("Stop proxy")
                }
            } else {
                Button(onClick = onStart, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.PlayArrow, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text("Start proxy")
                }
            }
        }
    }
}

@Composable
private fun UsageCard(wifiIp: String, port: Int) {
    val url = "http://$wifiIp:$port"
    Card(elevation = CardDefaults.cardElevation(2.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("Use from Mac")
            Text(url, fontFamily = FontFamily.Monospace)
            Text(
                "export https_proxy=$url\nexport http_proxy=$url",
                fontFamily = FontFamily.Monospace,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun LogCard(log: List<String>) {
    Card(
        elevation = CardDefaults.cardElevation(2.dp),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        Column(Modifier.padding(16.dp)) {
            SectionTitle("Log")
            Spacer(Modifier.height(8.dp))
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 8.dp),
            ) {
                val tail = if (log.size > 80) log.subList(log.size - 80, log.size) else log
                items(tail.asReversed()) { line ->
                    Text(
                        line,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun LabeledRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(value, fontFamily = FontFamily.Monospace)
    }
}

private fun formatBytes(b: Long): String {
    if (b < 1024) return "$b B"
    val units = listOf("KiB", "MiB", "GiB", "TiB")
    var v = b.toDouble() / 1024.0
    var i = 0
    while (v >= 1024.0 && i < units.size - 1) { v /= 1024.0; i++ }
    return String.format("%.2f %s", v, units[i])
}
