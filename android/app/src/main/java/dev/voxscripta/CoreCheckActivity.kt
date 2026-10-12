package dev.voxscripta

import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.voxscripta.core.NativeTime

/**
 * The first screen, and deliberately not a product screen.
 *
 * Everything about the native core has been verified on macOS by compiling it.
 * Nothing has verified that it *runs*: that the JNI symbols resolve on a real
 * runtime, that int64 values survive the boundary intact on a 32-bit ABI, and
 * above all that a C++ exception becomes a Java throwable instead of calling
 * std::terminate and taking the process with it.
 *
 * So the first app is a harness. Every expected value below comes from the
 * Swift tests in Tests/VoxScriptaCoreTests, which are the specification during
 * the migration — if a row here disagrees, the port has drifted from the
 * implementation the macOS app ships.
 *
 * This screen is thrown away once the React Native shell exists.
 */
class CoreCheckActivity : AppCompatActivity() {

    private data class Check(val name: String, val passed: Boolean, val detail: String)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val checks = runChecks()
        val failed = checks.count { !it.passed }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 64, 48, 64)
        }

        column.addView(TextView(this).apply {
            text = if (failed == 0) {
                "libvoxscripta runs\n${checks.size} checks, all matching Swift"
            } else {
                "$failed of ${checks.size} checks disagree with Swift"
            }
            textSize = 20f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (failed == 0) PASS else FAIL)
            gravity = Gravity.START
            setPadding(0, 0, 0, 40)
        })

        for (check in checks) {
            column.addView(TextView(this).apply {
                text = "${if (check.passed) "✓" else "✗"}  ${check.name}\n     ${check.detail}"
                textSize = 13f
                typeface = Typeface.MONOSPACE
                setTextColor(if (check.passed) PASS else FAIL)
                setPadding(0, 0, 0, 24)
            })
        }

        setContentView(ScrollView(this).apply { addView(column) })
    }

    private fun runChecks(): List<Check> {
        val checks = mutableListOf<Check>()

        fun expect(name: String, expected: Any, actual: () -> Any) {
            val result = runCatching(actual)
            checks += result.fold(
                onSuccess = { value ->
                    Check(name, value == expected, "got $value, expected $expected")
                },
                onFailure = { error ->
                    Check(name, false, "threw ${error.javaClass.simpleName}: ${error.message}")
                },
            )
        }

        fun expectThrows(name: String, expected: Class<out Throwable>, body: () -> Any) {
            val result = runCatching(body)
            checks += result.fold(
                onSuccess = { value -> Check(name, false, "returned $value instead of throwing") },
                onFailure = { error ->
                    Check(
                        name,
                        expected.isInstance(error),
                        "threw ${error.javaClass.simpleName}, expected ${expected.simpleName}",
                    )
                },
            )
        }

        // ── Values the Swift tests pin exactly ──────────────────────────────
        expect("format(0)", "0:00.000") { NativeTime.format(0L) }
        expect("format(65.25 s)", "1:05.250") { NativeTime.format(65_250_000_000L) }
        expect("format(3725.5 s)", "1:02:05.500") { NativeTime.format(3_725_500_000_000L) }
        expect("format(-1.5 s)", "-0:01.500") { NativeTime.format(-1_500_000_000L) }

        expect("1 s at 16 kHz", 16_000L) { NativeTime.samplesAt(1_000_000_000L, 16_000) }
        // Six hours, the longest recording the app targets. On a 32-bit ABI this
        // is the value that would break if int64 did not survive the boundary.
        expect("6 h at 48 kHz", 1_036_800_000L) {
            NativeTime.samplesAt(21_600_000_000_000L, 48_000)
        }

        expect("1.5 s to nanoseconds", 1_500_000_000L) {
            NativeTime.nanosecondsFromSeconds(1.5)
        }
        expect("nanoseconds to 1.5 s", 1.5) {
            NativeTime.secondsFromNanoseconds(1_500_000_000L)
        }

        // Asymmetric speech padding: trailing is larger than leading because
        // word-final decay outlasts word-initial onset.
        val padded = runCatching {
            NativeTime.paddedRange(
                startNanoseconds = 10_000_000_000L,
                endNanoseconds = 20_000_000_000L,
                leadNanoseconds = 200_000_000L,
                trailNanoseconds = 350_000_000L,
                limitEndNanoseconds = 60_000_000_000L,
            ).toList()
        }
        checks += padded.fold(
            onSuccess = { value ->
                val expected = listOf(9_800_000_000L, 20_350_000_000L)
                Check("padded range round-trips", value == expected, "got $value")
            },
            onFailure = { error ->
                Check("padded range round-trips", false, "threw ${error.javaClass.simpleName}")
            },
        )

        // ── The reason this harness exists ──────────────────────────────────
        // Each of these throws in C++. If the JNI translation is wrong the
        // process dies here rather than showing a red row.
        expectThrows("overflow becomes ArithmeticException", ArithmeticException::class.java) {
            NativeTime.samplesAt(4_611_686_018_427_387L, 48_000)
        }
        expectThrows("zero rate becomes IllegalArgument", IllegalArgumentException::class.java) {
            NativeTime.samplesAt(1_000_000_000L, 0)
        }
        expectThrows("NaN becomes IllegalArgument", IllegalArgumentException::class.java) {
            NativeTime.nanosecondsFromSeconds(Double.NaN)
        }

        return checks
    }

    private companion object {
        val PASS = Color.parseColor("#2F6048")
        val FAIL = Color.parseColor("#8D3535")
    }
}
