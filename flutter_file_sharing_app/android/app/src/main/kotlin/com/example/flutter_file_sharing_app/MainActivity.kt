package com.example.flutter_file_sharing_app

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private var multicastLock: WifiManager.MulticastLock? = null
	private val channelName = "lan.discovery/platform"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"acquireMulticast" -> {
					try {
						val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
						if (multicastLock?.isHeld == true) {
							result.success(true)
							return@setMethodCallHandler
						}
						multicastLock = wifi.createMulticastLock("fs_multicast")
						multicastLock?.setReferenceCounted(false)
						multicastLock?.acquire()
						result.success(true)
					} catch (e: Exception) {
						result.error("ERR", e.message, null)
					}
				}
				"releaseMulticast" -> {
					try {
						if (multicastLock?.isHeld == true) {
							multicastLock?.release()
						}
						result.success(true)
					} catch (e: Exception) {
						result.error("ERR", e.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}
}
