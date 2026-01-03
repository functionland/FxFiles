package land.fx.files

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val STORAGE_CHANNEL = "land.fx.files/storage"
    private val PIP_CHANNEL = "land.fx.files/pip"
    private var pipEventSink: EventChannel.EventSink? = null
    private var isInPipMode = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Storage channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openManageStorageSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            intent.data = Uri.parse("package:$packageName")
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("ERROR", "Could not open settings: ${e2.message}", null)
                            }
                        }
                    } else {
                        result.error("UNSUPPORTED", "Android 11+ required", null)
                    }
                }
                "hasManageStoragePermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(Environment.isExternalStorageManager())
                    } else {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // PiP channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val aspectRatioWidth = call.argument<Int>("width") ?: 16
                            val aspectRatioHeight = call.argument<Int>("height") ?: 9
                            val rational = Rational(aspectRatioWidth, aspectRatioHeight)

                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(rational)
                                .build()

                            enterPictureInPictureMode(params)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PIP_ERROR", "Failed to enter PiP: ${e.message}", null)
                        }
                    } else {
                        result.error("UNSUPPORTED", "PiP requires Android 8.0+", null)
                    }
                }
                "isPipSupported" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                }
                "isInPipMode" -> {
                    result.success(isInPipMode)
                }
                "setAutoPip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            val enabled = call.argument<Boolean>("enabled") ?: false
                            val aspectRatioWidth = call.argument<Int>("width") ?: 16
                            val aspectRatioHeight = call.argument<Int>("height") ?: 9
                            val rational = Rational(aspectRatioWidth, aspectRatioHeight)

                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(rational)
                                .setAutoEnterEnabled(enabled)
                                .build()

                            setPictureInPictureParams(params)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PIP_ERROR", "Failed to set auto PiP: ${e.message}", null)
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // PiP event channel for state changes
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "$PIP_CHANNEL/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    pipEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    pipEventSink = null
                }
            }
        )
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode = isInPictureInPictureMode
        pipEventSink?.success(mapOf(
            "isInPipMode" to isInPictureInPictureMode
        ))
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Auto-enter PiP when user presses home during video playback
        // This is handled by setAutoPip in Flutter when video is playing
    }
}
