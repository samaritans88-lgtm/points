// 새 Supabase 프로젝트 값으로 채운다 (Project Settings → API).
// publishable(anon) 키는 공개돼도 되는 키다. 데이터 보호는 서버의 RLS/RPC 가 한다.
window.KP_CONFIG = {
  SUPABASE_URL: "",
  SUPABASE_KEY: "",
  // 켜둔 로그인 방법만 버튼이 보인다. Supabase 에서 해당 Provider 를 켠 뒤 추가.
  PROVIDERS: [],   // 가입 없이 시작이 기본. 소셜 로그인을 켜면 ["kakao"] / ["google"]
};
