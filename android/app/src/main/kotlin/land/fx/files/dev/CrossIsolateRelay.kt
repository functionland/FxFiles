package land.fx.files.dev

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/**
 * Cross-isolate event relay.
 *
 * Dart isolates don't share heap, so an in-memory signal sent from
 * `MainActivity`'s isolate (e.g. "user cancelled task X from
 * Settings") never reaches the `SyncForegroundService`'s BG isolate.
 * Hive writes propagate (both isolates read the same on-disk box),
 * but anything held in a per-isolate Map / Set / Future is invisible
 * to the other side. The most painful instance: per-isolate
 * `CancelHandle` (from fula-api#18) in the BG isolate's
 * `_activeCancelHandles` can only be triggered by code running in
 * the BG isolate — main's `cancelTask` calls
 * `triggerCancel(handle)` on its own empty map and the upload keeps
 * going.
 *
 * This relay sits in Kotlin and forwards selected method calls
 * between the two engines:
 *
 *  - MainActivity's engine registers via [installMainHandler] —
 *    main-isolate code calls into the channel; the handler routes
 *    onward.
 *  - SyncForegroundService registers its engine's messenger via
 *    [registerBgMessenger] when the service spawns the BG engine,
 *    and clears it via `registerBgMessenger(null)` in onDestroy.
 *
 *  - On the BG isolate side, `sync_background_entrypoint.dart`
 *    calls `setMethodCallHandler` on the same channel name to
 *    receive the relayed calls.
 *
 * Methods routed:
 *
 *  - `cancelTaskInBgIsolate(localPath: String)` — main → BG
 */
object CrossIsolateRelay {
    const val CHANNEL = "land.fx.files/sync_cross_isolate"

    @Volatile
    private var bgMessenger: BinaryMessenger? = null

    /**
     * Set the BG isolate's messenger so [installMainHandler] knows
     * where to relay calls. Pass null on service teardown.
     */
    fun registerBgMessenger(messenger: BinaryMessenger?) {
        bgMessenger = messenger
    }

    /**
     * Install the handler on the main isolate's engine. Receives
     * calls from main-isolate Dart code and forwards them to the
     * BG engine if one is currently registered.
     */
    fun installMainHandler(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(MethodCallHandler { call, result ->
            when (call.method) {
                "cancelTaskInBgIsolate" -> {
                    val localPath = call.argument<String>("localPath")
                    if (localPath.isNullOrEmpty()) {
                        result.error("BAD_ARG", "cancelTaskInBgIsolate requires non-empty 'localPath'", null)
                        return@MethodCallHandler
                    }
                    val target = bgMessenger
                    if (target == null) {
                        // No BG isolate alive — main's local cancel +
                        // Hive writes are sufficient (BG will see the
                        // missing task on its next startup). Return
                        // false so the caller can log it.
                        result.success(false)
                    } else {
                        // The messenger may have been invalidated mid-
                        // dispatch (SyncForegroundService.onDestroy clears
                        // it, but a destroy could race with an in-flight
                        // relay call). Catch any throw from invokeMethod
                        // against a stale messenger and fail closed so
                        // the channel handler itself doesn't crash. The
                        // Hive deletes that main's cancelTask already
                        // performed remain the durable record of intent.
                        try {
                            MethodChannel(target, CHANNEL).invokeMethod(
                                "cancelTaskInBgIsolate",
                                mapOf("localPath" to localPath),
                            )
                            result.success(true)
                        } catch (t: Throwable) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        })
    }
}
