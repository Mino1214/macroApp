package com.example.nexus_flutter

import android.graphics.BitmapFactory
import android.util.Log
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.imgproc.Imgproc

/**
 * OpenCV 기반 템플릿 매칭 (빠른 속도).
 * screenBytes, templateBytes: PNG/JPEG 바이트 배열.
 * 반환: 중심 (x, y), confidence 또는 null.
 */
object OpenCvMatcher {
    private const val TAG = "OpenCvMatcher"
    private var initialized = false

    fun ensureInit(): Boolean {
        if (initialized) return true
        initialized = OpenCVLoader.initDebug()
        if (initialized) Log.i(TAG, "OpenCV loaded") else Log.w(TAG, "OpenCV load failed")
        return initialized
    }

    /**
     * @param screenBytes PNG/JPEG 화면 캡처 바이트
     * @param templateBytes PNG/JPEG 템플릿 바이트
     * @param threshold 0.0~1.0 (TM_CCOEFF_NORMED, 1=완전일치)
     * @return mapOf("x" to centerX, "y" to centerY, "confidence" to value) or null
     */
    fun matchTemplate(
        screenBytes: ByteArray,
        templateBytes: ByteArray,
        threshold: Double = 0.75
    ): Map<String, Any>? {
        if (!ensureInit()) return null
        var screenMat: Mat? = null
        var templateMat: Mat? = null
        var resultMat: Mat? = null
        try {
            val screenBmp = BitmapFactory.decodeByteArray(screenBytes, 0, screenBytes.size)
                ?: return null
            val templateBmp = BitmapFactory.decodeByteArray(templateBytes, 0, templateBytes.size)
                ?: return null

            screenMat = Mat()
            templateMat = Mat()
            Utils.bitmapToMat(screenBmp, screenMat)
            Utils.bitmapToMat(templateBmp, templateMat)
            if (screenMat.rows() < templateMat.rows() || screenMat.cols() < templateMat.cols()) return null

            val resultCols = screenMat.cols() - templateMat.cols() + 1
            val resultRows = screenMat.rows() - templateMat.rows() + 1
            resultMat = Mat(resultRows, resultCols, CvType.CV_32FC1)
            Imgproc.matchTemplate(screenMat, templateMat, resultMat, Imgproc.TM_CCOEFF_NORMED)

            val mmr = Core.minMaxLoc(resultMat)
            val maxVal = mmr.maxVal
            if (maxVal < threshold) {
                return mapOf("found" to false, "bestConfidence" to maxVal)
            }

            val maxLoc = mmr.maxLoc
            val tw = templateMat.cols()
            val th = templateMat.rows()
            val centerX = (maxLoc.x + tw / 2.0).toInt()
            val centerY = (maxLoc.y + th / 2.0).toInt()

            return mapOf(
                "found" to true,
                "x" to centerX,
                "y" to centerY,
                "confidence" to maxVal
            )
        } catch (e: Exception) {
            Log.e(TAG, "matchTemplate error", e)
            return null
        } finally {
            screenMat?.release()
            templateMat?.release()
            resultMat?.release()
        }
    }
}
