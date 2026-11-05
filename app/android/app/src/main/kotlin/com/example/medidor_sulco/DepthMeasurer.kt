package com.example.medidor_sulco

import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.exceptions.NotYetAvailableException
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Abordagem B - mede a profundidade do sulco no ponto tocado usando a
 * ARCore Raw Depth API (ToF quando o aparelho tem, depth-from-motion senão).
 *
 * Algoritmo por quadro:
 *  1. Converte o toque (coordenadas normalizadas da view) para pixel da
 *     imagem de profundidade com frame.transformCoordinates2d.
 *  2. Desprojeta para 3D (mm) os pixels de um ANEL externo (blocos) e de um
 *     DISCO central (fundo do sulco), descartando confiança < MIN_CONF.
 *  3. Ajusta um plano z = ax + by + c ao anel, de forma robusta, mantendo só o
 *     nível mais próximo da câmera (o topo dos blocos; sulcos vizinhos saem).
 *  4. Profundidade do quadro = mediana da distância (ao longo da normal)
 *     dos pontos do disco até esse plano.
 * Depois de [framesNeeded] quadros válidos: mediana e dispersão (IQR).
 */
class DepthMeasurer(private val framesNeeded: Int = 20) {

    data class Result(val depthMm: Float, val spreadMm: Float, val distanceMm: Float, val frames: Int)

    class MeasureException(val code: String, msg: String) : Exception(msg)

    companion object {
        const val MIN_CONF = 200          // 0..255 (≈ 78 %)
        const val INNER_RADIUS_MM = 2.0f  // disco do fundo do sulco
        const val RING_IN_MM = 7.0f       // anel dos blocos
        const val RING_OUT_MM = 14.0f
        const val MAX_MM_PER_PX = 2.5f    // mais que isso: longe demais
        const val PLANE_TOL_MM = 2.5f
    }

    private val estimates = ArrayList<Float>()
    private val distances = ArrayList<Float>()
    private var lowConfFrames = 0

    fun reset() {
        estimates.clear(); distances.clear(); lowConfFrames = 0
    }

    /** Chamar dentro de onDrawFrame (o Frame só vale ali). Retorna o resultado quando completo. */
    fun accumulate(frame: Frame, viewX: Float, viewY: Float): Result? {
        val depthImg = try { frame.acquireRawDepthImage16Bits() } catch (e: NotYetAvailableException) { return null }
        val confImg = try { frame.acquireRawDepthConfidenceImage() } catch (e: NotYetAvailableException) {
            depthImg.close(); return null
        }
        depthImg.use { d ->
            confImg.use { c ->
                val w = d.width; val h = d.height
                val dp = d.planes[0]; val cp = c.planes[0]
                val db = dp.buffer.order(ByteOrder.LITTLE_ENDIAN)
                val cb = cp.buffer

                // 1) toque -> pixel da imagem de profundidade (alinhada à textura da câmera)
                val out = FloatArray(2)
                frame.transformCoordinates2d(
                    Coordinates2d.VIEW_NORMALIZED, floatArrayOf(viewX, viewY),
                    Coordinates2d.TEXTURE_NORMALIZED, out
                )
                val cu = out[0] * w; val cv = out[1] * h

                // intrínsecos da textura, escalados para a resolução da profundidade
                val intr = frame.camera.textureIntrinsics
                val dims = intr.imageDimensions
                val fx = intr.focalLength[0] * w / dims[0]
                val fy = intr.focalLength[1] * h / dims[1]
                val px = intr.principalPoint[0] * w / dims[0]
                val py = intr.principalPoint[1] * h / dims[1]

                fun depthAt(u: Int, v: Int): Int =
                    db.getShort(v * dp.rowStride + u * dp.pixelStride).toInt() and 0xFFFF
                fun confAt(u: Int, v: Int): Int =
                    cb.get(v * cp.rowStride + u * cp.pixelStride).toInt() and 0xFF

                // distância no centro define a escala mm/px
                val zc = depthAt(cu.toInt().coerceIn(0, w - 1), cv.toInt().coerceIn(0, h - 1))
                if (zc == 0) return null
                val mmPerPx = zc / fx
                if (mmPerPx > MAX_MM_PER_PX) throw MeasureException("TOO_FAR", "Aproxime o celular (${zc} mm)")

                // 2) amostra anel e disco em 3D
                val rOut = (RING_OUT_MM / mmPerPx).roundToInt()
                val ring = ArrayList<FloatArray>(); val core = ArrayList<FloatArray>()
                var total = 0; var rejeitados = 0
                for (v in max(0, (cv - rOut).toInt())..min(h - 1, (cv + rOut).toInt())) {
                    for (u in max(0, (cu - rOut).toInt())..min(w - 1, (cu + rOut).toInt())) {
                        val rMm = sqrt((u - cu) * (u - cu) + (v - cv) * (v - cv)) * mmPerPx
                        val alvo = when {
                            rMm <= INNER_RADIUS_MM -> core
                            rMm in RING_IN_MM..RING_OUT_MM -> ring
                            else -> continue
                        }
                        total++
                        val z = depthAt(u, v)
                        if (z == 0 || confAt(u, v) < MIN_CONF) { rejeitados++; continue }
                        val zf = z.toFloat()
                        alvo.add(floatArrayOf((u - px) * zf / fx, (v - py) * zf / fy, zf))
                    }
                }
                if (ring.size < 12 || core.isEmpty()) {
                    if (total > 0 && rejeitados > total / 2 && ++lowConfFrames > framesNeeded)
                        throw MeasureException("LOW_CONFIDENCE", "Sensor com baixa confiança")
                    return null
                }

                // 3) plano dos blocos (robusto, lado mais próximo)
                var plane = fitPlane(ring) ?: return null
                repeat(4) {
                    val keep = ring.filter { (it[2] - (plane[0] * it[0] + plane[1] * it[1] + plane[2])) < PLANE_TOL_MM }
                    if (keep.size >= 12) plane = fitPlane(keep) ?: plane
                }
                val norm = sqrt(plane[0] * plane[0] + plane[1] * plane[1] + 1f)

                // 4) profundidade deste quadro
                val prof = core.map { (it[2] - (plane[0] * it[0] + plane[1] * it[1] + plane[2])) / norm }.sorted()
                estimates.add(prof[prof.size / 2])
                distances.add(zc.toFloat())
            }
        }

        if (estimates.size < framesNeeded) return null
        val s = estimates.sorted()
        val iqr = s[(s.size * 3) / 4] - s[s.size / 4]
        val r = Result(max(0f, s[s.size / 2]), abs(iqr), distances.sorted()[distances.size / 2], s.size)
        reset()
        return r
    }

    /** Mínimos quadrados z = a x + b y + c (equações normais 3x3, regra de Cramer). */
    private fun fitPlane(p: List<FloatArray>): FloatArray? {
        var sxx = 0.0; var sxy = 0.0; var syy = 0.0; var sx = 0.0; var sy = 0.0
        var sxz = 0.0; var syz = 0.0; var sz = 0.0; val n = p.size.toDouble()
        for (q in p) {
            val x = q[0].toDouble(); val y = q[1].toDouble(); val z = q[2].toDouble()
            sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y
            sxz += x * z; syz += y * z; sz += z
        }
        val det = sxx * (syy * n - sy * sy) - sxy * (sxy * n - sy * sx) + sx * (sxy * sy - syy * sx)
        if (abs(det) < 1e-9) return null
        val a = (sxz * (syy * n - sy * sy) - sxy * (syz * n - sy * sz) + sx * (syz * sy - syy * sz)) / det
        val b = (sxx * (syz * n - sz * sy) - sxz * (sxy * n - sy * sx) + sx * (sxy * sz - syz * sx)) / det
        val c = (sxx * (syy * sz - sy * syz) - sxy * (sxy * sz - syz * sx) + sxz * (sxy * sy - syy * sx)) / det
        return floatArrayOf(a.toFloat(), b.toFloat(), c.toFloat())
    }
}
