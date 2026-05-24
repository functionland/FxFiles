package land.fx.files.dev

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Process-wide upload ownership registry.
 *
 * Replaces the broken cross-isolate `UploadQueueLock` (Dart-side
 * `RandomAccessFile.lock`). POSIX `fcntl` advisory locks are PER-PROCESS
 * on Linux/Android — two Dart isolates inside the same OS process do not
 * see each other's locks. Confirmed by Dart's own docs:
 * "several isolates in the same process can obtain an exclusive lock on
 *  the same file." (api.dart.dev/dart-io/RandomAccessFile/lock.html)
 *
 * Hosting the mutex in Kotlin (one JVM, one static object) is the only
 * way to get a true process-wide mutual exclusion that honours Dart
 * isolate boundaries.
 *
 * **Ownership identity is a per-isolate UUID, NOT a role string.**
 * Earlier draft used `"main"` / `"background"` strings as the owner id,
 * which let two `UploadQueueLock` instances inside the SAME isolate
 * appear identical to the registry. The Kotlin side would happily let
 * both "acquire" (same owner = re-entrant), but a single `release` from
 * one of them would clear the owner while the other still believed it
 * held the lock. Per-isolate UUIDs make every instance distinguishable.
 *
 * **Re-entrancy by ref count.** A token that already owns the lock can
 * acquire again — hold count increments. Each acquire must be matched
 * by exactly one release; ownership clears when the count returns to 0.
 * Needed because both the outer lock in `sync_background_entrypoint`
 * and `SyncService._queueLock` (inside the same BG isolate) currently
 * acquire the same lock.
 *
 * **No lifecycle force-release.** Earlier draft tied `release("main")`
 * to `MainActivity.onDestroy()`, but rotation/config-change destroys
 * the Activity while the FlutterEngine (and therefore the main isolate)
 * survives — so the force-release could clear ownership during an
 * active upload, allowing the BG isolate to race. The lock is released
 * only by Dart-side `try/finally` blocks. If the whole process dies,
 * the static state dies with it; no leak.
 */
object UploadOwnershipRegistry {
    const val CHANNEL = "land.fx.files/upload_ownership"

    private val mu = Any()

    @Volatile
    private var owner: String? = null

    @Volatile
    private var holdCount: Int = 0

    /**
     * The current background-isolate's lock token, recorded so
     * SyncForegroundService.onDestroy can force-release if the BG
     * isolate dies without releasing (e.g. engine destroyed while
     * mid-upload). Null when no BG isolate is active.
     *
     * Only the BG-isolate path uses this; main isolate releases via
     * its own try/finally (Activity destroy != isolate destroy, so we
     * can't safely tie main's release to a lifecycle event).
     */
    @Volatile
    private var backgroundToken: String? = null

    fun registerBackgroundToken(token: String) {
        synchronized(mu) { backgroundToken = token }
    }

    /**
     * Best-effort safety net: if the BG isolate's recorded token is
     * the current lock owner, force-clear ownership. Called from
     * SyncForegroundService.onDestroy because the FlutterEngine is
     * destroyed there (and with it, the BG isolate's Dart code —
     * any pending `try/finally` releases will not execute).
     */
    fun forceReleaseBackgroundToken() {
        synchronized(mu) {
            val token = backgroundToken ?: return
            if (owner == token) {
                owner = null
                holdCount = 0
            }
            backgroundToken = null
        }
    }

    /**
     * Try to claim ownership. Returns true if [token] now holds the
     * lock — either as a fresh claim (owner was null) or as re-entrant
     * acquire (owner was already [token]; hold count incremented).
     * Non-blocking.
     */
    fun tryAcquire(token: String): Boolean {
        synchronized(mu) {
            val cur = owner
            if (cur == null) {
                owner = token
                holdCount = 1
                return true
            }
            if (cur == token) {
                holdCount += 1
                return true
            }
            return false
        }
    }

    /**
     * Release ownership if currently held by [token]. Decrements the
     * hold count; ownership clears when the count returns to 0.
     * Returns true on actual release-or-decrement, false if [token]
     * doesn't currently own.
     */
    fun release(token: String): Boolean {
        synchronized(mu) {
            if (owner != token) return false
            holdCount -= 1
            if (holdCount <= 0) {
                owner = null
                holdCount = 0
            }
            return true
        }
    }

    /** Read-only view of the current owner id (null if unowned). */
    fun currentOwner(): String? = synchronized(mu) { owner }

    /**
     * Install the method-channel handler on [messenger]. Call from
     * each FlutterEngine that needs to participate (MainActivity's
     * engine + SyncForegroundService's engine + any future
     * WorkManager-spawned engines). Idempotent — installing twice on
     * the same messenger just replaces the handler.
     */
    fun installChannelHandler(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "tryAcquire" -> {
                    val token = call.argument<String>("token")
                    if (token.isNullOrEmpty()) {
                        result.error(
                            "BAD_ARG",
                            "tryAcquire requires non-empty 'token'",
                            null,
                        )
                    } else {
                        result.success(tryAcquire(token))
                    }
                }
                "release" -> {
                    val token = call.argument<String>("token")
                    if (token.isNullOrEmpty()) {
                        result.error(
                            "BAD_ARG",
                            "release requires non-empty 'token'",
                            null,
                        )
                    } else {
                        result.success(release(token))
                    }
                }
                "registerBackgroundToken" -> {
                    val token = call.argument<String>("token")
                    if (token.isNullOrEmpty()) {
                        result.error(
                            "BAD_ARG",
                            "registerBackgroundToken requires non-empty 'token'",
                            null,
                        )
                    } else {
                        registerBackgroundToken(token)
                        result.success(true)
                    }
                }
                "currentOwner" -> result.success(currentOwner())
                else -> result.notImplemented()
            }
        }
    }
}
