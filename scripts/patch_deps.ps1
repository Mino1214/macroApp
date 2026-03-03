# AGP 8+ namespace & JVM 호환성 패치 - flutter pub get 후 실행
$cache = "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev"

# app_launcher: namespace + compileOptions/kotlinOptions
$appLauncher = "$cache\app_launcher-1.0.1\android\build.gradle"
if (Test-Path $appLauncher) {
    $c = Get-Content $appLauncher -Raw
    $changed = $false
    if ($c -notmatch "namespace 'me.akoraingdkb.app_launcher'") {
        $c = $c -replace "android \{[ \r\n]*", "android {`n    namespace 'me.akoraingdkb.app_launcher'`n    "
        $changed = $true
    }
    if ($c -notmatch "compileOptions") {
        $c = $c -replace "namespace 'me.akoraingdkb.app_launcher'([ \r\n]+)compileSdkVersion", "namespace 'me.akoraingdkb.app_launcher'`$1compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }`n    kotlinOptions { jvmTarget = `"17`" }`$1compileSdkVersion"
        $changed = $true
    }
    if ($changed) { Set-Content $appLauncher $c -NoNewline; Write-Host "Patched app_launcher build.gradle" }
}

# app_launcher: Registrar import 제거 (구버전 API)
$appLauncherKt = "$cache\app_launcher-1.0.1\android\src\main\kotlin\me\akoraingdkb\app_launcher\AppLauncherPlugin.kt"
if ((Test-Path $appLauncherKt) -and ((Get-Content $appLauncherKt -Raw) -match "PluginRegistry.Registrar")) {
    (Get-Content $appLauncherKt -Raw) -replace "import io.flutter.plugin.common.PluginRegistry.Registrar\r?\n\r?\n", "`n" | Set-Content $appLauncherKt -NoNewline
    Write-Host "Patched app_launcher AppLauncherPlugin.kt"
}

# media_projection_creator: namespace
$mpc = "$cache\media_projection_creator-1.0.0\android\build.gradle"
if ((Test-Path $mpc) -and ((Get-Content $mpc -Raw) -notmatch "namespace ")) {
    (Get-Content $mpc -Raw) -replace "android \{[ \r\n]*", "android {`n    namespace 'im.zego.media_projection_creator'`n    " | Set-Content $mpc -NoNewline
    Write-Host "Patched media_projection_creator"
}

# media_projection_creator: registerReceiver RECEIVER_NOT_EXPORTED (API 33+, 상수 대신 숫자 사용)
$mpcActivity = "$cache\media_projection_creator-1.0.0\android\src\main\java\im\zego\media_projection_creator\internal\RequestMediaProjectionPermissionActivity.java"
if ((Test-Path $mpcActivity) -and ((Get-Content $mpcActivity -Raw) -notmatch "registerReceiver.*filter, 4\)")) {
    $c = Get-Content $mpcActivity -Raw
    $c = $c -replace "registerReceiver\(RequestMediaProjectionPermissionManager\.getInstance\(\), filter\);", "if (Build.VERSION.SDK_INT >= 33) { registerReceiver(RequestMediaProjectionPermissionManager.getInstance(), filter, 4); } else { registerReceiver(RequestMediaProjectionPermissionManager.getInstance(), filter); }"
    Set-Content $mpcActivity $c -NoNewline
    Write-Host "Patched RequestMediaProjectionPermissionActivity (RECEIVER_NOT_EXPORTED)"
}

# media_projection_creator: MediaProjectionService onStartCommand Intent null 크래시 방지
$mpcService = "$cache\media_projection_creator-1.0.0\android\src\main\java\im\zego\media_projection_creator\internal\MediaProjectionService.java"
if ((Test-Path $mpcService) -and ((Get-Content $mpcService -Raw) -notmatch "if \(intent == null\)")) {
    $c = Get-Content $mpcService -Raw
    $c = $c -replace "public int onStartCommand\(Intent intent, int flags, int startId\) \{\r?\n\r?\n        int resultCode", "public int onStartCommand(Intent intent, int flags, int startId) {`n        if (intent == null) { stopSelf(); return START_NOT_STICKY; }`n`n        int resultCode"
    Set-Content $mpcService $c -NoNewline
    Write-Host "Patched MediaProjectionService (Intent null check)"
}

# media_projection_screenshot: 캡처 이미지 실제 크기 사용 + crop 범위 제한 (y+height <= bitmap.height 크래시 방지)
# 수동 적용: pub cache의 MediaProjectionScreenshotPlugin.kt 에서 takeCapture/startCapture 의 width/height 를 image.width, image.height 로 하고 crop 인자를 coerceIn 으로 클램프
$mpsPlugin = "$cache\media_projection_screenshot-0.0.6\android\src\main\kotlin\com\liasica\media_projection_screenshot\MediaProjectionScreenshotPlugin.kt"
if ((Test-Path $mpsPlugin) -and ((Get-Content $mpsPlugin -Raw) -notmatch "coerceIn\(0, \(bitmap\.width - 1\)")) {
    $c = Get-Content $mpsPlugin -Raw
    # takeCapture: bitmap 생성 시 image 실제 크기 사용
    $c = $c -replace "val image = imageReader\.acquireLatestImage\(\) \?\: return@postDelayed\s+\n\s+val planes = image\.planes", "val image = imageReader.acquireLatestImage() ?: return@postDelayed`n`n      val imgWidth = image.width`n      val imgHeight = image.height`n      val planes = image.planes"
    $c = $c -replace "val rowPadding = rowStride - pixelStride \* width\s+\n\s+val padding = rowPadding / pixelStride\s+\n\s+var bitmap = Bitmap\.createBitmap\(width \+ padding, height, Bitmap\.Config\.ARGB_8888\)\s+\n\s+bitmap\.copyPixelsFromBuffer\(buffer\)\s+\n\s+image\.close\(\)\s+\n\s+mVirtualDisplay", "val rowPadding = rowStride - pixelStride * imgWidth`n      val padding = rowPadding / pixelStride`n`n      var bitmap = Bitmap.createBitmap(imgWidth + padding, imgHeight, Bitmap.Config.ARGB_8888)`n      bitmap.copyPixelsFromBuffer(buffer)`n`n      image.close()`n`n      mVirtualDisplay"
    # takeCapture: crop 인자 클램프
    $c = $c -replace "region\?\.let \{\s+\n\s+val x = it\[\""x\""\] as Int \+ padding / 2\s+\n\s+val y = it\[\""y\""\] as Int\s+\n\s+val w = it\[\""width\""\] as Int\s+\n\s+val h = it\[\""height\""\] as Int\s+\n\s+\n\s+bitmap = bitmap\.crop\(x, y, w, h\)\s+\n\s+\}", "region?.let {`n        val x0 = (it[`"x`"] as? Number)?.toInt() ?: 0`n        val y0 = (it[`"y`"] as? Number)?.toInt() ?: 0`n        val w0 = (it[`"width`"] as? Number)?.toInt() ?: bitmap.width`n        val h0 = (it[`"height`"] as? Number)?.toInt() ?: bitmap.height`n        val x = (x0 + padding / 2).coerceIn(0, (bitmap.width - 1).coerceAtLeast(0))`n        val y = y0.coerceIn(0, (bitmap.height - 1).coerceAtLeast(0))`n        val w = w0.coerceIn(1, bitmap.width - x)`n        val h = h0.coerceIn(1, bitmap.height - y)`n        if (w > 0 && h > 0) {`n          bitmap = bitmap.crop(x, y, w, h)`n        }`n      }"
    # startCapture: image 실제 크기 사용
    $c = $c -replace "mImageReader!!\.setOnImageAvailableListener\(\{ reader ->\s+\n\s+val image = reader\.acquireLatestImage\(\)\s+\n\s+val start = System\.currentTimeMillis\(\)\s+\n\s+\n\s+val planes = image\.planes", "mImageReader!!.setOnImageAvailableListener({ reader ->`n      val image = reader.acquireLatestImage()`n      val start = System.currentTimeMillis()`n`n      val imgWidth = image.width`n      val imgHeight = image.height`n      val planes = image.planes"
    $c = $c -replace "val rowPadding = rowStride - pixelStride \* width\s+\n\s+val padding = rowPadding / pixelStride\s+\n\s+var bitmap = Bitmap\.createBitmap\(width \+ padding, height, Bitmap\.Config\.ARGB_8888\)\s+\n\s+bitmap\.copyPixelsFromBuffer\(buffer\)\s+\n\s+image\.close\(\)\s+\n\s+\n\s+// 控制速率", "val rowPadding = rowStride - pixelStride * imgWidth`n      val padding = rowPadding / pixelStride`n`n      var bitmap = Bitmap.createBitmap(imgWidth + padding, imgHeight, Bitmap.Config.ARGB_8888)`n      bitmap.copyPixelsFromBuffer(buffer)`n`n      image.close()`n`n`n      // 控制速率"
    # startCapture: crop 클램프
    $c = $c -replace "region\?\.let \{ params ->\s+\n\s+val x = params\[\""x\""\] as Int\?\s+\n\s+val y = params\[\""y\""\] as Int\?\s+\n\s+val w = params\[\""width\""\] as Int\?\s+\n\s+val h = params\[\""height\""\] as Int\?\s+\n\s+if \(x != null && y != null && w != null && h != null\) \{\s+\n\s+bitmap = bitmap\.crop\(x \+ padding / 2, y, w, h\)\s+\n\s+\}\s+\n\s+\}", "region?.let { params ->`n          val x0 = (params[`"x`"] as? Number)?.toInt() ?: 0`n          val y0 = (params[`"y`"] as? Number)?.toInt() ?: 0`n          val w0 = (params[`"width`"] as? Number)?.toInt() ?: bitmap.width`n          val h0 = (params[`"height`"] as? Number)?.toInt() ?: bitmap.height`n          val x = (x0 + padding / 2).coerceIn(0, (bitmap.width - 1).coerceAtLeast(0))`n          val y = y0.coerceIn(0, (bitmap.height - 1).coerceAtLeast(0))`n          val w = w0.coerceIn(1, bitmap.width - x)`n          val h = h0.coerceIn(1, bitmap.height - y)`n          if (w > 0 && h > 0) {`n            bitmap = bitmap.crop(x, y, w, h)`n          }`n        }"
    Set-Content $mpsPlugin $c -NoNewline
    Write-Host "Patched MediaProjectionScreenshotPlugin (crop bounds)"
}

# media_projection_screenshot: takeCapture에서 acquireLatestImage() null 시 result.error 호출 (무한 대기 방지) + 대기 400ms
if (Test-Path $mpsPlugin) {
    $c = Get-Content $mpsPlugin -Raw
    if ($c -notmatch "acquireLatestImage returned null") {
        $c = $c -replace "val image = imageReader\.acquireLatestImage\(\) \?\: return@postDelayed", "val image = imageReader.acquireLatestImage()`n      if (image == null) {`n        result.error(LOG_TAG, `"acquireLatestImage returned null (retry or allow more time)`", null)`n        return@postDelayed`n      }"
        $c = $c -replace "\}, 100\)\s+\n\s+\}\s+\n\s+private fun Bitmap\.crop", "}, 400)`n  }`n`n  private fun Bitmap.crop"
        Set-Content $mpsPlugin $c -NoNewline
        Write-Host "Patched MediaProjectionScreenshotPlugin (takeCapture null + 400ms)"
    }
}

# media_projection_screenshot: encodeYV12 ArrayIndexOutOfBounds 방지 (홀수 해상도 시 U/V 영역 초과)
if (Test-Path $mpsPlugin) {
    $c = Get-Content $mpsPlugin -Raw
    if ($c -notmatch "uIndex < yuv420sp\.size") {
        $c = $c -replace "yuv420sp\[yIndex\+\+\] = y\.toByte\(\)\s+\n\s+if \(j % 2 == 0 && index % 2 == 0\) \{\s+\n\s+yuv420sp\[uIndex\+\+\] = v\.toByte\(\)\s+\n\s+yuv420sp\[vIndex\+\+\] = u\.toByte\(\)\s+\n\s+\}", "yuv420sp[yIndex++] = y.toByte()`n        if (j % 2 == 0 && index % 2 == 0) {`n          if (uIndex < yuv420sp.size) yuv420sp[uIndex++] = v.toByte()`n          if (vIndex < yuv420sp.size) yuv420sp[vIndex++] = u.toByte()`n        }"
        Set-Content $mpsPlugin $c -NoNewline
        Write-Host "Patched MediaProjectionScreenshotPlugin (encodeYV12 bounds)"
    }
}
