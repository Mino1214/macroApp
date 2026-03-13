package com.example.nexus_flutter

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.provider.Settings
import android.text.TextUtils.SimpleStringSplitter
import android.util.Log
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.os.Handler
import android.os.Looper

private const val TAG = "NexusTouch"

/**
 * API 24+ dispatchGesture 사용 - API 33 TouchInteractionController 불필요
 * MediaProjection 없이 접근성 노드로 찾아서 클릭 가능
 */
class TouchAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    /** 터치 차단 레이어/히트박스 대응: (x,y) 및 주변 ±10~20px 순차 시도. 한 점이라도 onCompleted면 성공 */
    private val tapOffsets = listOf(
        Pair(0, 0), Pair(12, 0), Pair(-12, 0), Pair(0, 12), Pair(0, -12),
        Pair(18, 0), Pair(-18, 0), Pair(0, 18), Pair(0, -18), Pair(12, 12), Pair(-12, -12)
    )

    fun clickAt(x: Int, y: Int, callback: (Boolean) -> Unit) {
        tryNextOffset(x, y, 0, callback)
    }

    private fun tryNextOffset(x: Int, y: Int, index: Int, callback: (Boolean) -> Unit) {
        if (index >= tapOffsets.size) {
            Log.w(TAG, "clickAt($x,$y) 11개 좌표 모두 onCancelled → 이 창에서 제스처 거부됨. (팝업이 물리 터치만 허용했거나 보안 레이어 가능성)")
            runOnMain { callback(false) }
            return
        }
        val (dx, dy) = tapOffsets[index]
        val px = x + dx
        val py = y + dy
        if (index > 0) Log.i(TAG, "clickAt 주변 시도 $index/${tapOffsets.size} ($px,$py)")
        dispatchTouch(px, py) { ok ->
            if (ok) {
                if (index == 0) Log.i(TAG, "clickAt($x,$y) 첫 좌표에서 onCompleted → 나머지 10개 좌표는 시도 안 함")
                else Log.i(TAG, "clickAt 주변탭 성공 ($px,$py) (${index + 1}번째 좌표)")
                callback(true)
            } else {
                // onCancelled → 릴리즈 정리 후 콜백 → 150ms 추가 대기 후 다음 좌표 시도
                Handler(Looper.getMainLooper()).postDelayed({
                    tryNextOffset(x, y, index + 1, callback)
                }, 150)
            }
        }
    }

    /** (x,y)를 포함하는 가장 깊은(가장 작은) 노드 반환. 호출자가 반환값 recycle 책임 */
    private fun findNodeAt(root: AccessibilityNodeInfo, x: Int, y: Int): AccessibilityNodeInfo? {
        val rect = Rect()
        root.getBoundsInScreen(rect)
        if (!rect.contains(x, y)) return null
        for (i in 0 until root.childCount) {
            val child = root.getChild(i) ?: continue
            val found = findNodeAt(child, x, y)
            if (found != null) return found
            child.recycle()
        }
        return root
    }

    /** (x,y) 좌표의 접근성 노드로 ACTION_CLICK 시도. dispatchGesture 차단 시 대안 */
    fun clickAtByNode(x: Int, y: Int, callback: (Boolean) -> Unit) {
        val root = rootInActiveWindow ?: run {
            Log.w(TAG, "clickAtByNode($x,$y) root 없음")
            callback(false)
            return
        }
        val node = findNodeAt(root, x, y) ?: run {
            Log.w(TAG, "clickAtByNode($x,$y) 노드 없음")
            callback(false)
            return
        }
        var target: AccessibilityNodeInfo? = node
        while (target != null && !target.isClickable) {
            val parent = target.parent ?: break
            target = parent
        }
        val toClick = target ?: node
        val ok = toClick.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        Log.i(TAG, "clickAtByNode($x,$y) ACTION_CLICK=$ok")
        callback(ok)
        // AccessibilityNodeInfo는 사용 후 반드시 recycle 해서 누적 사용량을 줄인다.
        toClick.recycle()
        if (toClick !== node) {
            node.recycle()
        }
    }

    /** Down → Move(조금) → Up 매크로식 터치. UP 확실히 전달되도록 duration/지연 보강 */
    fun dispatchTouch(x: Int, y: Int, callback: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < 24) {
            callback(false)
            return
        }
        // Down at (x,y) → Move 4~5px → Up. 120ms로 UP 전달 시간 확보
        val path = Path().apply {
            moveTo(x.toFloat(), y.toFloat())
            lineTo((x + 4).toFloat(), (y + 2).toFloat())
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, 120)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        val cb = object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Log.i(TAG, "dispatchGesture onCompleted ($x,$y) → UP 전달 후 80ms 대기")
                // UP 전달·처리 완료 대기 후에만 다음 터치 허용
                Handler(Looper.getMainLooper()).postDelayed({
                    callback(true)
                }, 80)
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                Log.w(TAG, "dispatchGesture onCancelled ($x,$y) → 릴리즈 정리 후 실패")
                runOnMain {
                    injectReleaseToClearStuckTouch {
                        callback(false)
                    }
                }
            }
        }
        dispatchGesture(gesture, cb, null)
    }

    /** 터치 스트림이 UP 없이 끊겼을 때: 화면 코너에 최소 스트로크로 릴리즈 시도 */
    private fun injectReleaseToClearStuckTouch(done: () -> Unit) {
        val releasePath = Path().apply {
            moveTo(1f, 1f)
            lineTo(2f, 1f)
        }
        val stroke = GestureDescription.StrokeDescription(releasePath, 0, 50)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        val cb = object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Handler(Looper.getMainLooper()).postDelayed({ done() }, 100)
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                Handler(Looper.getMainLooper()).postDelayed({ done() }, 100)
            }
        }
        dispatchGesture(gesture, cb, null)
    }

    private fun runOnMain(block: () -> Unit) {
        Handler(Looper.getMainLooper()).post(block)
    }

    /** node를 collectDetails와 동일 포맷으로 변환 (로그용) */
    private fun formatNodeForLog(node: AccessibilityNodeInfo): String {
        val id = node.viewIdResourceName?.takeIf { it.isNotBlank() }
        val t = node.text?.toString()?.trim()?.takeIf { it.isNotBlank() }
        val d = node.contentDescription?.toString()?.trim()?.takeIf { it.isNotBlank() }
        return buildString {
            if (id != null) append("id:$id")
            if (t != null) { if (isNotEmpty()) append(" | "); append("text:$t") }
            if (d != null) { if (isNotEmpty()) append(" | "); append("desc:$d") }
            if (node.isClickable) append(" [clickable]")
        }.ifBlank { "?" }
    }

    /** UIAutomator 2.0 스타일: resourceId/text/contentDesc/className 조합으로 노드 찾아 클릭. tapAtRight=true면 오른쪽 끝 탭 */
    fun clickBySelector(
        resourceId: String?,
        text: String?,
        contentDesc: String?,
        className: String?,
        tapAtRight: Boolean = false,
        callback: (Map<String, Any?>) -> Unit
    ) {
        val root = rootInActiveWindow ?: run {
            callback(mapOf("ok" to false, "matched" to null))
            return
        }
        val node = findNodeBySelector(root, resourceId, text, contentDesc, className)
        if (node == null) {
            val looking = "res=$resourceId text=$text desc=$contentDesc class=$className"
            Log.w(TAG, "clickBySelector 찾는 것: $looking")
            val onScreen = collectNodeDetails().take(25)
            val screenSummary = onScreen.joinToString(" | ") { it.take(50) }
            Log.w(TAG, "clickBySelector 화면 노드: $screenSummary")
            callback(mapOf("ok" to false, "matched" to null, "looking" to looking, "screenNodes" to screenSummary))
            return
        }
        val matchedDesc = formatNodeForLog(node)
        val rect = Rect()
        node.getBoundsInScreen(rect)
        val tapX = if (tapAtRight) (rect.right - maxOf(rect.width() / 10, 10)).coerceIn(rect.left, rect.right) else rect.centerX()
        val tapY = rect.centerY()
        val clickable = findClickableSelfOrParent(node)
        val target = clickable ?: node
        // tapAtRight=true: dispatchTouch(오른쪽 좌표) 직접 실행 — SafePal 오른쪽 탭으로 옵션 열기
        // tapAtRight=false: performAction(ACTION_CLICK) 우선, 실패 시 dispatchTouch(중앙) 폴백
        var ok = if (tapAtRight) false else target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        if (!ok) {
            Log.i(TAG, "clickBySelector ${if (tapAtRight) "오른쪽 탭" else "ACTION_CLICK=false"} → dispatchTouch 시도 ($tapX,$tapY)")
            runOnMain {
                dispatchTouch(tapX, tapY) { gestureOk ->
                    ok = gestureOk
                    Log.i(TAG, "clickBySelector dispatchTouch=$ok matched=$matchedDesc tapAtRight=$tapAtRight")
                    callback(mapOf("ok" to ok, "matched" to matchedDesc))
                    clickable?.recycle()
                    if (clickable !== node) {
                        node.recycle()
                    }
                }
            }
            return
        }
        Log.i(TAG, "clickBySelector ACTION_CLICK=$ok matched=$matchedDesc")
        callback(mapOf("ok" to ok, "matched" to matchedDesc))
        clickable?.recycle()
        if (clickable !== node) {
            node.recycle()
        }
    }

    private fun findClickableSelfOrParent(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var n: AccessibilityNodeInfo? = node
        while (n != null) {
            if (n.isClickable) return n
            n = n.parent
        }
        return null
    }

    private fun findNodeBySelector(
        node: AccessibilityNodeInfo,
        resourceId: String?,
        text: String?,
        contentDesc: String?,
        className: String?
    ): AccessibilityNodeInfo? {
        if (matchesSelector(node, resourceId, text, contentDesc, className)) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            findNodeBySelector(child, resourceId, text, contentDesc, className)?.let { return it }
            child.recycle()
        }
        return null
    }

    /** 보이지 않는 문자(제로너비 등) 제거 후 비교용 — SafePal 등 desc에 ‍(U+200D) 들어가는 경우 대비 */
    private fun normalizeForMatch(s: CharSequence): String {
        return s.toString().trim().replace(Regex("[\\u200B-\\u200D\\u2060\\uFEFF]"), "")
    }

    private fun matchesSelector(
        node: AccessibilityNodeInfo,
        resourceId: String?,
        text: String?,
        contentDesc: String?,
        className: String?
    ): Boolean {
        if (resourceId.isNullOrBlank() && text.isNullOrBlank() && contentDesc.isNullOrBlank() && className.isNullOrBlank())
            return false
        if (!resourceId.isNullOrBlank()) {
            val id = node.viewIdResourceName ?: return false
            if (!id.equals(resourceId, ignoreCase = true) && !id.endsWith("/$resourceId")) return false
        }
        if (!text.isNullOrBlank()) {
            val t = node.text?.toString()?.trim() ?: return false
            val tNorm = normalizeForMatch(t)
            val searchNorm = normalizeForMatch(text)
            if (searchNorm.length == 1) {
                if (!tNorm.equals(searchNorm, ignoreCase = true)) return false
            } else {
                if (!tNorm.equals(searchNorm, ignoreCase = true) && !tNorm.contains(searchNorm, ignoreCase = true)) return false
            }
        }
        if (!contentDesc.isNullOrBlank()) {
            val d = node.contentDescription?.toString() ?: return false
            val dNorm = normalizeForMatch(d)
            val searchNorm = normalizeForMatch(contentDesc)
            // SafePal confirm("지금 가져오기")는 정확히 일치하는 버튼만 허용.
            // "내 클라우드 백업에서 가져오기" 같은 문구에 contains로 잘못 매칭되지 않도록 한다.
            if (searchNorm == "지금 가져오기") {
                if (!dNorm.equals(searchNorm, ignoreCase = true)) return false
            } else if (searchNorm.length <= 5) {
                // 짧은 검색어(예: "삭제")는 정확히 일치만 허용 — 긴 설명에 contains로 걸리지 않도록
                if (!dNorm.equals(searchNorm, ignoreCase = true)) return false
            } else {
                if (!dNorm.equals(searchNorm, ignoreCase = true) && !dNorm.contains(searchNorm, ignoreCase = true)) return false
            }
        }
        if (!className.isNullOrBlank()) {
            val c = node.className?.toString() ?: return false
            if (!c.equals(className, ignoreCase = true) && !c.endsWith(className)) return false
        }
        return true
    }

    /** 접근성 트리에서 text/contentDescription 일치 노드 찾아 클릭. 결과는 콜백으로 */
    fun findAndClickByTextOrDesc(match: String, callback: (Boolean) -> Unit) {
        val root = rootInActiveWindow
        if (root == null) {
            callback(false)
            return
        }
        val node = findNodeByTextOrDesc(root, match)
        if (node == null) {
            callback(false)
            return
        }
        val rect = Rect()
        node.getBoundsInScreen(rect)
        if (node.isClickable) {
            val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            callback(ok)
        } else {
            val cx = rect.centerX()
            val cy = rect.centerY()
            dispatchTouch(cx, cy, callback)
        }
    }

    private fun findNodeByTextOrDesc(node: AccessibilityNodeInfo, match: String): AccessibilityNodeInfo? {
        val text = node.text?.toString()?.trim()
        val desc = node.contentDescription?.toString()?.trim()
        if (!text.isNullOrEmpty() && text.contains(match, ignoreCase = true)) return node
        if (!desc.isNullOrEmpty() && desc.contains(match, ignoreCase = true)) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findNodeByTextOrDesc(child, match)
            if (found != null) {
                return found
            }
            // 탐색 후 사용하지 않는 노드는 즉시 recycle
            child.recycle()
        }
        return null
    }

    /** 백 키 전송 (키보드 숨기기 등) */
    fun performBack(): Boolean = performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)

    /** 포커스된 편집 필드에서 전체 선택 (Ctrl+A) */
    fun selectAll(): Boolean {
        val root = rootInActiveWindow ?: return false
        val node = findFocusedEditable(root) ?: return false
        val text = node.text?.toString() ?: ""
        val len = text.length
        if (len == 0) return true
        val bundle = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, len)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, bundle)
    }

    private fun findFocusedEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable && node.isFocused) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            findFocusedEditable(child)?.let { return it }
            child.recycle()
        }
        return null
    }

    /** 현재 활성 창의 패키지명 (디버그/Trust Wallet 전환 확인용) */
    fun getActiveWindowPackage(): String? = rootInActiveWindow?.packageName?.toString()

    /**
     * paste/next 클릭과 100% 동일한 방식: findNodeBySelector와 같은 트리 순회 + contentDesc contains 검사.
     * failKeywords 중 하나라도 노드 contentDesc에 포함되면 "fail", successKeywords면 "success", 없으면 "none"
     */
    fun checkScreenKeywords(failKeywords: List<String>, successKeywords: List<String>): String {
        val root = rootInActiveWindow ?: return "none"
        val result = checkNodeKeywords(root, failKeywords, successKeywords)
        return result
    }

    private fun checkNodeKeywords(
        node: AccessibilityNodeInfo,
        failKeywords: List<String>,
        successKeywords: List<String>
    ): String {
        val d = node.contentDescription?.toString() ?: ""
        if (d.isNotBlank()) {
            val dNorm = normalizeForMatch(d)
            for (k in failKeywords) {
                if (k.isNotBlank() && dNorm.contains(normalizeForMatch(k))) return "fail"
            }
            for (k in successKeywords) {
                if (k.isNotBlank() && dNorm.contains(normalizeForMatch(k))) return "success"
            }
        }
        val t = node.text?.toString() ?: ""
        if (t.isNotBlank()) {
            val tNorm = normalizeForMatch(t)
            for (k in failKeywords) {
                if (k.isNotBlank() && tNorm.contains(normalizeForMatch(k))) return "fail"
            }
            for (k in successKeywords) {
                if (k.isNotBlank() && tNorm.contains(normalizeForMatch(k))) return "success"
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val r = checkNodeKeywords(child, failKeywords, successKeywords)
            if (r != "none") {
                child.recycle()
                return r
            }
            child.recycle()
        }
        return "none"
    }

    /** 현재 화면(포그라운드 앱)의 접근성 노드에서 text/contentDescription 수집 */
    fun collectNodeTexts(): List<String> {
        val root = rootInActiveWindow ?: return emptyList()
        val set = mutableSetOf<String>()
        collectTexts(root, set)
        return set.filter { it.isNotBlank() }.sorted()
    }

    /** UIAutomator 선택자용: resourceId | text | contentDesc (클릭 가능/텍스트 있는 노드) */
    fun collectNodeDetails(): List<String> {
        val root = rootInActiveWindow
        if (root == null) {
            Log.w(TAG, "collectNodeDetails: rootInActiveWindow=null")
            return emptyList()
        }
        val list = mutableListOf<String>()
        try {
            collectDetails(root, list)
        } catch (e: Exception) {
            Log.e(TAG, "collectNodeDetails 오류: $e")
        }
        if (list.isEmpty()) {
            val rc = root.className?.toString() ?: "?"
            Log.w(TAG, "collectNodeDetails: 노드 0개 (root=$rc childCount=${root.childCount})")
        }
        return list.distinct().sorted()
    }

    private fun collectDetails(node: AccessibilityNodeInfo, out: MutableList<String>) {
        val id = node.viewIdResourceName?.takeIf { it.isNotBlank() }
        val t = node.text?.toString()?.trim()?.takeIf { it.isNotBlank() }
        val d = node.contentDescription?.toString()?.trim()?.takeIf { it.isNotBlank() }
        val clazz = node.className?.toString()?.takeIf { it.isNotBlank() }
        if (id != null || t != null || d != null || clazz != null) {
            val line = buildString {
                append("id:${id ?: "(없음)"}")
                if (t != null) append(" | text:$t")
                if (d != null) append(" | desc:$d")
                if (clazz != null) append(" | class:$clazz")
                if (node.isClickable) append(" [clickable]")
            }
            out.add(line)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectDetails(child, out)
            child.recycle()
        }
    }

    private fun collectTexts(node: AccessibilityNodeInfo, out: MutableSet<String>) {
        node.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
        node.contentDescription?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectTexts(child, out)
            // 수집이 끝난 노드는 재사용 풀로 돌려보낸다
            child.recycle()
        }
    }

    companion object {
        @Volatile
        var instance: TouchAccessibilityService? = null

        fun isEnabled(context: Context): Boolean {
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            val expected = ComponentName(context, TouchAccessibilityService::class.java)
            val splitter = SimpleStringSplitter(':')
            splitter.setString(enabled)
            while (splitter.hasNext()) {
                val name = ComponentName.unflattenFromString(splitter.next())
                if (name != null && name == expected) return true
            }
            return false
        }
    }
}
