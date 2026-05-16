package com.stepanic.mobilephoneproxy

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.stepanic.mobilephoneproxy.ui.ProxyScreen
import com.stepanic.mobilephoneproxy.ui.ProxyTheme

class MainActivity : ComponentActivity() {

    private val askNotifications = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { /* result not strictly required — the proxy still runs without it */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the screen on while the proxy app is in the foreground (iOS
        // disabled the idle timer; this is the Android analogue without
        // demanding a full wake lock from the UI process).
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        requestNotificationPermissionIfNeeded()

        setContent {
            ProxyTheme {
                ProxyScreen(
                    onStart = { port -> ProxyService.start(this, port) },
                    onStop = { ProxyService.stop(this) },
                )
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
