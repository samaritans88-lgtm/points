# 포인트 통장 v2 — 서버 준비 순서

앱 주소(예정): `https://samaritans88-lgtm.github.io/points/v2/`

## 사람이 해야 하는 것 (계정·화면 설정)

### 1. 새 Supabase 계정과 프로젝트
1. 팩토릿지와 **다른 이메일**로 https://supabase.com 가입
2. New project → 이름 `kid-points`, 지역 **Northeast Asia (Seoul)**, Free 플랜
3. 데이터베이스 비밀번호는 안전한 곳에 보관

### 2. Google 로그인 켜기
1. https://console.cloud.google.com → 새 프로젝트 → **API 및 서비스 → OAuth 동의 화면** (외부, 앱 이름 "포인트 통장")
2. **사용자 인증 정보 → OAuth 클라이언트 ID** (웹 애플리케이션)
   - 승인된 리디렉션 URI: `https://<새 프로젝트 ref>.supabase.co/auth/v1/callback`
3. 만들어진 클라이언트 ID / 보안 비밀을 Supabase → **Authentication → Sign In / Providers → Google** 에 입력 후 켜기

### 3. 익명 로그인(아이 기기용) 켜기
Supabase → **Authentication → Sign In / Providers → Allow anonymous sign-ins** 켜기

### 4. 주소 등록
Supabase → **Authentication → URL Configuration**
- Site URL: `https://samaritans88-lgtm.github.io/points/v2/`
- Redirect URLs: 같은 주소 추가

## Claude 가 하는 것 (새 프로젝트에 접근 권한이 생기면)
1. `supabase/schema.sql` 실행
2. pg_cron·pg_net 켜고 `supabase/cron.sql` 실행
3. VAPID 키 생성 → `private.secret`(vapid_public, push_hook, push_url) 과 함수 시크릿(KP_HOOK, VAPID_*) 저장
4. `supabase/functions/kp-push` 배포 (verify_jwt = false, 자체 비밀값 검사)
5. `config.js` 에 프로젝트 주소·publishable 키 입력
6. 기존 가족 데이터 이전: 가입·가족 생성(로니·로하) 후 `migrate_v1.sql` 의 `private.import_v1` 실행 → 잔액 비교

## 테스트
- `supabase/tests/rls_test.sql` — 권한 테스트 52개 (다른 가족 차단, 아이 기기 권한, 코드 대입 차단, 기록 취소, 탈퇴 등)
