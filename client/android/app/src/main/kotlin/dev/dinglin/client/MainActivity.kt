package dev.dinglin.client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NotificationChannels.ensureCreated(this)
        NativeBridgePlugin.attach(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
