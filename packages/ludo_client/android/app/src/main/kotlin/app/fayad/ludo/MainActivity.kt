package app.fayad.ludo

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The platform side of the one feedback channel, `app.fayad.ludo/feedback`
 * (work/ludo/orders/C-225-feedback.md, doctrine section 3). Every cue a
 * screen decided to play through `lib/src/feedback.dart` arrives here as
 * `haptic` or `sound` with one argument, `id`, and either vibrates a fixed
 * waveform or plays a short clip loaded once at startup. Nothing here
 * decides which cue fires for which game event; this class only knows how
 * to make one named cue felt on a real device, and how to stay quiet when
 * the system says to: the haptic system switch, an unvibrating device, and
 * a ringer that is not in normal mode are all read here, not in Dart.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "app.fayad.ludo/feedback"
    private var soundPool: SoundPool? = null
    private val soundIds = HashMap<String, Int>()

    // C-225's starting shapes: ms segments (an initial delay, then
    // alternating vibrate/rest), tuned by feel later, kept distinct. This
    // same array is also what the pre-O vibrate(long[], Int) fallback plays
    // directly, so one table serves both paths.
    private val hapticTimings: Map<String, LongArray> = mapOf(
        "your_turn" to longArrayOf(0, 18),
        "can_move" to longArrayOf(0, 20, 60, 20),
        "no_move" to longArrayOf(0, 220),
        "step" to longArrayOf(0, 8),
        "captured_other" to longArrayOf(0, 30, 40, 30),
        "captured_me" to longArrayOf(0, 180, 60, 50),
        "home" to longArrayOf(0, 30, 50, 40, 50, 60),
        "win" to longArrayOf(0, 60, 60, 80, 60, 120, 60, 260),
        "game_over" to longArrayOf(0, 90),
        "invalid_tap" to longArrayOf(0, 10),
    )

    // Same ids, 0..255 amplitude per segment of hapticTimings, used only
    // when the device reports amplitude control.
    private val hapticAmplitudes: Map<String, IntArray> = mapOf(
        "your_turn" to intArrayOf(0, 90),
        "can_move" to intArrayOf(0, 120, 0, 120),
        "no_move" to intArrayOf(0, 200),
        "step" to intArrayOf(0, 60),
        "captured_other" to intArrayOf(0, 255, 0, 255),
        "captured_me" to intArrayOf(0, 200, 0, 140),
        "home" to intArrayOf(0, 90, 0, 160, 0, 240),
        "win" to intArrayOf(0, 80, 0, 130, 0, 190, 0, 255),
        "game_over" to intArrayOf(0, 70),
        "invalid_tap" to intArrayOf(0, 50),
    )

    // Every id except invalid_tap (doctrine section 3's table: none) has a
    // clip; tool/gen_feedback_sounds.py writes it to res/raw as fb_<id>.wav,
    // and aapt2 generates the matching R.raw entry read here.
    private val soundResources: Map<String, Int> = mapOf(
        "your_turn" to R.raw.fb_your_turn,
        "can_move" to R.raw.fb_can_move,
        "no_move" to R.raw.fb_no_move,
        "step" to R.raw.fb_step,
        "captured_other" to R.raw.fb_captured_other,
        "captured_me" to R.raw.fb_captured_me,
        "home" to R.raw.fb_home,
        "win" to R.raw.fb_win,
        "game_over" to R.raw.fb_game_over,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val pool = SoundPool.Builder()
            .setMaxStreams(4)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .build()
            )
            .build()
        soundPool = pool
        for ((id, resId) in soundResources) {
            soundIds[id] = pool.load(this, resId, 1)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val id = call.argument<String>("id")
                when (call.method) {
                    "haptic" -> {
                        if (id != null) {
                            playHaptic(id)
                        }
                        result.success(null)
                    }
                    "sound" -> {
                        if (id != null) {
                            playSound(id)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        soundPool?.release()
        soundPool = null
        super.onDestroy()
    }

    private fun playHaptic(id: String) {
        val timings = hapticTimings[id] ?: return
        val systemHapticsOn = Settings.System.getInt(
            contentResolver,
            Settings.System.HAPTIC_FEEDBACK_ENABLED,
            1,
        ) != 0
        if (!systemHapticsOn) {
            return
        }
        val vibrator = systemVibrator() ?: return
        if (!vibrator.hasVibrator()) {
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val amplitudes = hapticAmplitudes[id]
            val effect = if (amplitudes != null && vibrator.hasAmplitudeControl()) {
                VibrationEffect.createWaveform(timings, amplitudes, -1)
            } else {
                VibrationEffect.createWaveform(timings, -1)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val attributes = VibrationAttributes.Builder()
                    .setUsage(VibrationAttributes.USAGE_TOUCH)
                    .build()
                vibrator.vibrate(effect, attributes)
            } else {
                vibrator.vibrate(effect)
            }
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(timings, -1)
        }
    }

    private fun systemVibrator(): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private fun playSound(id: String) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (audioManager.ringerMode != AudioManager.RINGER_MODE_NORMAL) {
            return
        }
        val soundId = soundIds[id] ?: return
        soundPool?.play(soundId, 1f, 1f, 1, 0, 1f)
    }
}
