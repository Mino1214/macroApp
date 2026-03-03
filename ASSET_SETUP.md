# Android 이미지 인식 - data/app 플로우 설정

## 1. 템플릿 이미지 (빌드 시 포함) — 필수

**MainPatchedImproved/data/app/** 의 PNG들을 **nexus_flutter/assets/data/app/** 로 복사하세요.
빌드 시 APK에 포함됩니다. **first.png가 없으면 릴리즈 APK에서 first 인식이 동작하지 않습니다.**

필요 이미지: first, second, third, 0~9, paste, next, get, failhcheck, success, erase, more, delete1.png, errorword.png

## 2. 로고 (스플래시·앱 아이콘)

**MainPatchedImproved/data/logo.png** 를 **nexus_flutter/assets/data/app/logo.png** 로 복사한 뒤:

```bash
dart run flutter_native_splash:create
dart run flutter_launcher_icons
```

## 3. wordlist.txt

앱의 문서 폴더 `.../documents/data/wordlist.txt` 에 12단어 니모닉을 한 줄씩 넣습니다.
(메인 화면 "템플릿:" 경로의 상위 data 폴더)

## 4. 권한

- **화면 캡처**: "화면 캡처 권한" 버튼 → 시스템 팝업에서 허용
- **접근성**: "접근성 권한" 버튼 → 설정에서 Nexus 활성화
