# UIAutomator 2.0 스타일 선택자 사용법

이미지 매칭 대신(또는 우선) **노드 기반 클릭**을 쓰면, first 이후처럼 터치가 차단되는 화면에서도 동작할 수 있습니다.

## 필요한 데이터

각 스텝(first, second, phrase1, wordinput 등)마다 **다음 중 하나 이상**이 필요합니다.

| 항목 | 설명 | 예시 |
|------|------|------|
| **resourceId** | 뷰의 id (전체 또는 끝부분) | `explore_tab` 또는 `com.wallet.crypto.trustapp:id/explore_tab` |
| **text** | 뷰에 보이는 텍스트 (완전 일치 또는 포함) | `탐색`, `Next` |
| **contentDesc** | contentDescription | `Recovery phrase` |
| **className** | 위젯 클래스명 | `android.widget.Button` |

## 데이터 수집 방법

### 1) 앱 내 버튼으로 수집 (권장)

1. Trust Wallet을 원하는 화면까지 열어 둠.
2. Nexus 앱에서 **「노드 상세(선택자)」** 버튼 탭.
3. 다이얼로그에 `id:... | text:... | desc:... [clickable]` 목록이 나옴.
4. 클릭할 대상 행의 `id` 또는 `text` 값을 복사해 `automation_runner.dart`의 `uiautomatorSelectors`에 넣음.

### 2) adb로 UI 덤프

```bash
adb shell uiautomator dump /sdcard/ui.xml
adb pull /sdcard/ui.xml
```

`ui.xml`에서 `resource-id`, `text`, `content-desc`를 보고 필요한 값만 골라 사용.

## 설정 위치

`lib/services/automation_runner.dart`:

```dart
static final Map<String, Map<String, String?>> uiautomatorSelectors = {
  'first':  {'text': '탐색'},           // 텍스트로 찾기
  'second': {'resourceId': 'explore_tab'},  // id 끝부분
  'phrase1': {'contentDesc': 'Recovery phrase'},
  // 필요할 때만 추가. 없으면 기존처럼 이미지 매칭만 사용.
};
```

- **키**: 스텝 이름 (`first`, `second`, `phrase1`, `wordinput` 등).
- **값**: `resourceId`, `text`, `contentDesc`, `className` 중 하나 이상 지정.

## 동작 순서

1. 해당 스텝에서 `uiautomatorSelectors`에 항목이 있으면 **선택자 클릭을 먼저** 시도.
2. 성공하면 화면 변경 대기 후 다음 스텝으로 진행.
3. 실패하면 기존처럼 **이미지 매칭 + 제스처/노드 클릭**으로 진행.

이렇게 하면 first 이후 터치가 막힌 구간은 선택자로, 나머지는 기존 이미지 방식으로 처리할 수 있습니다.
