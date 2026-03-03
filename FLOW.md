# Nexus (SafePal) — 시작 버튼 누르면 뭐가 어떻게 도는지

## 1. 시작 버튼 누르면 하는 일 (순서대로)

| 순서 | 하는 일 | 사용하는 것 |
|------|---------|-------------|
| 1 | 접근성 권한 있는지 확인 | **AccessibilityService** (우리 앱의 Nexus 접근성) → `hasTouchPermission` (MethodChannel) |
| 2 | **캡처 모드일 때만** 화면캡처 권한 요청 | **MediaProjection** → `media_projection_screenshot` 패키지 `requestPermission()` |
| 3 | **캡처 모드일 때만** 4초 대기 후 캡처 1회 (세션 확보) | **MediaProjection** → `takeCapture()` (우리 앱 화면 캡처) |
| 4 | SafePal 앱 실행/포그라운드로 가져오기 | **Intent** → `getLaunchIntentForPackage("io.safepal.wallet")` + `FLAG_ACTIVITY_REORDER_TO_FRONT` (MethodChannel `bringSafePalToFront`) |
| 5 | 2초 대기 | - |
| 6 | **init**: first → second → third → 비밀번호 입력 | 아래 "클릭 방식" 참고 |
| 7 | **니모닉 루프**: wordlist에서 문구 읽기 → 클립보드 복사 → paste → next → get → 결과 확인 (fail/success) | 클립보드(**Clipboard**), 클릭 방식, **이미지 매칭**(캡처 모드일 때) |
| 8 | success 5번 나오면 **삭제 루프**: first → more → delete1 → 비밀번호 | 같은 클릭 방식 |

---

## 2. 사용하는 기술/권한 정리

| 구분 | 사용하는 것 | 용도 |
|------|-------------|------|
| **접근성 (Accessibility)** | Android **AccessibilityService** (우리 `TouchAccessibilityService`) | ① 터치 보내기: **dispatchGesture** (API 24+) ② 접근성만 모드: **getRootInActiveWindow**로 노드 찾아서 클릭 |
| **화면 캡처 (캡처 모드)** | Android **MediaProjection** (`media_projection_screenshot` 패키지) | 지금 보이는 화면(SafePal)을 **캡처**해서 이미지로 쓰기 |
| **앱 실행** | **Intent** (`MainActivity` → MethodChannel) | `io.safepal.wallet` (SafePal) 실행/포그라운드로 가져오기 |
| **이미지 매칭 (캡처 모드)** | `image` 패키지 + `TemplateMatcher` (우리 코드) | 캡처한 화면에서 first.png, paste.png 등 **템플릿 위치** 찾기 |
| **터치** | 접근성 **dispatchGesture** (좌표 x,y에 탭) | 찾은 위치 또는 접근성 노드 위치에 **한 번 탭** |
| **클립보드** | Flutter **Clipboard** | 니모닉 문구 복사 → SafePal 붙여넣기용 |

---

## 3. 두 가지 모드 (체크박스 "접근성만 사용")

### 3-1. **접근성만 사용** 체크 해제 (기본 = 캡처 모드)

- **화면 캡처**: MediaProjection으로 **지금 화면 캡처** → 픽셀 이미지 얻음  
- **버튼 찾기**: 캡처 이미지에서 **템플릿 이미지**(first.png, paste.png 등) **매칭** → (x, y) 좌표 계산  
- **클릭**: 그 (x, y)에 접근성 **dispatchGesture**로 터치  
- **사용**: MediaProjection, 이미지 매칭, Accessibility(터치만)

### 3-2. **접근성만 사용** 체크 (캡처 없음)

- **화면 캡처**: 사용 안 함 (MediaProjection 없음)  
- **버튼 찾기**: 접근성 **getRootInActiveWindow**로 현재 화면 노드 트리 가져와서, **텍스트/설명**이 맞는 노드 찾기 (`accessibilityTextMap` 문자열 사용)  
- **클릭**: 노드가 클릭 가능하면 **performAction(ACTION_CLICK)**, 아니면 노드 영역 중앙에 **dispatchGesture**  
- **사용**: Accessibility(노드 찾기 + 터치만)

---

## 4. 시작 시 실제 호출 흐름 (캡처 모드 기준)

```
시작 클릭
  → hasTouchPermission()        [MethodChannel → TouchAccessibilityService]
  → requestScreenPermission()   [media_projection_screenshot]
  → 4초 대기
  → testCapture()               [takeCapture() → MediaProjection]
  → bringSafePalToFront()       [MethodChannel → Intent]
  → 2초 대기
  → _runInit()
      → clickImage('first')     [캡처 → first.png 매칭 → dispatchGesture]
      → clickImage('second')
      → clickImage('third')
      → clickImage('0'~'9')      [비밀번호]
  → 니모닉 루프
      → setClipboard(phrase)
      → clickImage('paste')
      → clickImage('next')
      → clickImage('get')
      → findImage('failhcheck') / findImage('success')
      → clickImage('erase') or clickImage('success')
  → (success 5회 시) _runDeleteLoop()
      → clickImage('first'), clickImage('more'), clickImage('delete1'), 비밀번호
```

---

## 5. 한 줄 요약

- **시작** 누르면:  
  **접근성 확인** → **(캡처 모드면) MediaProjection 권한 요청·캡처 1회** → **Intent로 SafePal 실행** →  
  **캡처 모드**: 화면 캡처 + 이미지 매칭 + **dispatchGesture** 터치  
  **접근성만 모드**: 노드 텍스트로 찾아서 **performAction/ dispatchGesture** 터치  
  로 SafePal 화면을 자동 조작합니다.
