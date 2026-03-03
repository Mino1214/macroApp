# Nexus Flutter

WinForms 프로젝트(MainPatchedImproved)와 **동일한 UI·API·자동화**를 Flutter로 구현한 앱입니다.

## 기능

- **로그인**: nexus001.vip 서버 로그인, 승인/만료 검사
- **회원가입**: 아이디/비밀번호/추천인/텔레그램, 동일 API
- **메인 화면**: 만료일·니모닉 시도 횟수, 비밀번호·모드(SafePal / Trust Wallet / Tron Network), 시작/중지, 터미널 로그, 시도한 문구 목록(최근 100개)
- **세션 검증**: 15초 주기 세션 검사, 만료 시 로그인 화면으로 복귀
- **API**: `/api/register`, `/api/login`, `/api/session/validate`, `/api/seed`, `/api/admin/telegram` 동일 사용

## 자동화 (화면 캡처/이미지 매칭) — Windows 전용

**data/app 플로우** (SafePal 모드):
- 템플릿: `data/app/` 폴더 (first.png, second.png, third.png, paste.png, next.png, get.png, failhcheck.png, success.png, erase.png, more.png, delete1.png, 0.png~9.png)
- **init**: first → second → third → 비밀번호(0~9.png 클릭)
- **loop**: 니모닉 복사 → paste → next → get → failhcheck/success 확인
- **failhcheck**: erase 클릭 후 loop 복귀
- **success**: 5회 누적 시 삭제 loop (first → more → delete1 → 비밀번호)

## 실행 방법

1. **data 폴더 설정** (템플릿 이미지, wordlist):
   ```powershell
   cd nexus_flutter
   .\setup_data.ps1
   ```
   또는 수동으로:
   - `macro/pic/kr/*` → `nexus_flutter/data/pic/kr/`
   - `macro/pic/trustwallet/*` → `nexus_flutter/data/pic/trustwallet/`
   - `macro/wordlist.txt` → `nexus_flutter/data/wordlist.txt`

2. Flutter SDK 설치 후:
   ```bash
   flutter pub get
   flutter create . --platforms=windows
   ```

3. 실행 (Windows):
   ```bash
   flutter run -d windows
   ```

## 프로젝트 구조

- `lib/api/server_api.dart` — 서버 API (nexus001.vip)
- `lib/theme/app_theme.dart` — WinForms와 동일한 색상/테마
- `lib/services/wallet_count_file.dart` — 니모닉 시도 횟수 파일
- `lib/services/automation_service.dart` — 자동화 스텁
- `lib/screens/login_screen.dart` — 로그인
- `lib/screens/register_screen.dart` — 회원가입
- `lib/screens/main_screen.dart` — 메인(만료일, 모드, 로그, 시도 문구)
