package com.example.medidor_sulco

import android.app.Activity
import android.content.Context
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.view.View
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Session
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** Ponte Flutter <-> ARCore: um único ArDepthView ativo por vez. */
object DepthBridge {
    var active: ArDepthView? = null

    fun isSupported(ctx: Context): Boolean {
        val ok = ArCoreApk.getInstance().checkAvailability(ctx).isSupported
        if (!ok) return false
        // Raw depth exige aparelho na lista de suporte da Depth API
        return try {
            Session(ctx).use { it.isDepthModeSupported(Config.DepthMode.RAW_DEPTH_ONLY) }
        } catch (e: Exception) { false }
    }

    fun onMethodCall(ctx: Context, call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported(ctx))
            "measureAt" -> {
                val v = active ?: return result.error("NO_DEPTH", "View de profundidade não está aberta", null)
                v.requestMeasure(call.argument<Double>("x")!!.toFloat(), call.argument<Double>("y")!!.toFloat(), result)
            }
            else -> result.notImplemented()
        }
    }
}

private fun <T> Session.use(block: (Session) -> T): T = try { block(this) } finally { close() }

class ArDepthViewFactory(private val activity: Activity) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView = ArDepthView(activity)
}

class ArDepthView(private val activity: Activity) : PlatformView, GLSurfaceView.Renderer {
    private val gl = GLSurfaceView(activity)
    private var session: Session? = null
    private val background = CameraBackground()
    private val measurer = DepthMeasurer(framesNeeded = 20)
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var pending: Triple<Float, Float, MethodChannel.Result>? = null
    private var viewW = 1; private var viewH = 1

    init {
        gl.preserveEGLContextOnPause = true
        gl.setEGLContextClientVersion(2)
        gl.setRenderer(this)
        gl.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        // Permissão de câmera e instalação do ARCore devem ter sido tratadas antes (MainActivity)
        session = Session(activity).also { s ->
            val cfg = Config(s).apply {
                depthMode = Config.DepthMode.RAW_DEPTH_ONLY
                focusMode = Config.FocusMode.AUTO
                planeFindingMode = Config.PlaneFindingMode.DISABLED
                lightEstimationMode = Config.LightEstimationMode.DISABLED
            }
            s.configure(cfg)
            s.resume()
        }
        gl.onResume()
        DepthBridge.active = this
    }

    fun requestMeasure(x: Float, y: Float, result: MethodChannel.Result) {
        measurer.reset()
        pending = Triple(x, y, result)
    }

    override fun getView(): View = gl

    override fun dispose() {
        if (DepthBridge.active === this) DepthBridge.active = null
        gl.onPause()
        session?.pause(); session?.close(); session = null
    }

    // ---------------- GL thread ----------------
    override fun onSurfaceCreated(g: GL10?, c: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        background.create()
        session?.setCameraTextureName(background.textureId)
    }

    override fun onSurfaceChanged(g: GL10?, w: Int, h: Int) {
        GLES20.glViewport(0, 0, w, h)
        viewW = w; viewH = h
        session?.setDisplayGeometry(activity.windowManager.defaultDisplay.rotation, w, h)
    }

    override fun onDrawFrame(g: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        val s = session ?: return
        val frame = try { s.update() } catch (e: Exception) { return }
        background.draw(frame)

        val p = pending ?: return
        try {
            val r = measurer.accumulate(frame, p.first, p.second) ?: return
            pending = null
            main.post {
                p.third.success(mapOf(
                    "depthMm" to r.depthMm.toDouble(),
                    "spreadMm" to r.spreadMm.toDouble(),
                    "distanceMm" to r.distanceMm.toDouble(),
                    "frames" to r.frames,
                ))
            }
        } catch (e: DepthMeasurer.MeasureException) {
            pending = null
            main.post { p.third.error(e.code, e.message, null) }
        }
    }
}

/** Desenha a imagem da câmera (textura OES) em tela cheia. Mínimo necessário. */
private class CameraBackground {
    var textureId = 0; private set
    private var program = 0
    private val quad = floatBuffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    private val uvs = floatBuffer(FloatArray(8))

    fun create() {
        val t = IntArray(1); GLES20.glGenTextures(1, t, 0); textureId = t[0]
        val target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES
        GLES20.glBindTexture(target, textureId)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        program = link(
            """attribute vec4 aPos; attribute vec2 aUv; varying vec2 vUv;
               void main(){ gl_Position = aPos; vUv = aUv; }""",
            """#extension GL_OES_EGL_image_external : require
               precision mediump float; varying vec2 vUv; uniform samplerExternalOES uTex;
               void main(){ gl_FragColor = texture2D(uTex, vUv); }"""
        )
    }

    fun draw(frame: Frame) {
        if (frame.hasDisplayGeometryChanged()) {
            quad.position(0); uvs.position(0)
            frame.transformCoordinates2d(Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES, quad,
                Coordinates2d.TEXTURE_NORMALIZED, uvs)
        }
        if (frame.timestamp == 0L) return
        GLES20.glUseProgram(program)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        val aPos = GLES20.glGetAttribLocation(program, "aPos")
        val aUv = GLES20.glGetAttribLocation(program, "aUv")
        quad.position(0); uvs.position(0)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 0, uvs)
        GLES20.glEnableVertexAttribArray(aPos); GLES20.glEnableVertexAttribArray(aUv)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun link(vs: String, fs: String): Int {
        fun sh(type: Int, src: String) = GLES20.glCreateShader(type).also {
            GLES20.glShaderSource(it, src); GLES20.glCompileShader(it)
        }
        return GLES20.glCreateProgram().also {
            GLES20.glAttachShader(it, sh(GLES20.GL_VERTEX_SHADER, vs))
            GLES20.glAttachShader(it, sh(GLES20.GL_FRAGMENT_SHADER, fs))
            GLES20.glLinkProgram(it)
        }
    }

    private fun floatBuffer(a: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(a.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(a); position(0) }
}
