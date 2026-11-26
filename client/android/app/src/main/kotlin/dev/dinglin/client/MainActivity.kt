package dev.dinglin.client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NotificationChannels.ensureCreated(this)
        NativeBridgePlugin.attach(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        NativeBridgePlugin.detachActivity(this)
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        NativeBridgePlugin.onRequestPermissionsResult(requestCode, grantResults)
    }
}
