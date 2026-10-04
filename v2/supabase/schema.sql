-- =====================================================================
-- 포인트 통장 v2 — 여러 가족용 스키마
--
-- 원칙
--  * 모든 데이터는 family_id 로 가족별로 나뉜다. 다른 가족 데이터는 RLS 로 차단.
--  * 클라이언트는 테이블을 SELECT 만 한다. 쓰기는 전부 아래 RPC(security definer)로만,
--    RPC 안에서 "부모인가 / 이 아이의 기기인가" 를 검사한다.
--  * 점수 기록(entry)은 지우거나 고치지 않는다. 잘못 넣은 기록은 '취소 기록'을 새로 추가한다.
--  * 부모 = Google 로그인 계정. 아이 기기 = 익명 로그인 + 연결 코드로 아이와 묶인 기기.
--  * 날짜(오늘)는 가족 시간대 기준. 저장은 전부 timestamptz(UTC).
--
-- 적용 순서: 이 파일 한 번 실행 → cron.sql (pg_cron 켠 뒤)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 테이블
-- ---------------------------------------------------------------------
create table public.family (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(btrim(name)) between 1 and 40),
  timezone       text not null default 'Asia/Seoul',
  won_per_point  int  not null default 100 check (won_per_point between 1 and 100000),
  remind_times   text[] not null default array['07:30','12:00','16:00','19:00'],
  remind_last    text,
  show_siblings  boolean not null default false,  -- 아이 폰에서 형제 잔액·오늘 달성률 보이기(경쟁 유도)
  interest_pct   numeric(4,2) not null default 0 check (interest_pct between 0 and 10),  -- 주간 저축 이자율(%) 0=끔
  interest_dow   int not null default 7 check (interest_dow between 1 and 7),           -- 지급 요일(1=월 … 7=일)
  interest_cap   int not null default 50 check (interest_cap between 1 and 100000),     -- 한 번에 최대 이자(점)
  interest_last  text,
  ensured_on     date,                                                                  -- 오늘 루틴을 만든 날짜
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);

-- 부모(관리자). 한 계정은 한 가족에만 속한다.
create table public.family_member (
  family_id  uuid not null references public.family(id) on delete cascade,
  user_id    uuid not null unique references auth.users(id) on delete cascade,
  role       text not null default 'parent' check (role in ('parent')),
  display_name text,
  created_at timestamptz not null default now(),
  primary key (family_id, user_id)
);

create table public.child (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.family(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 20),
  emoji       text not null default '🙂',
  color       text not null default '#4F7CFF',
  sort        int  not null default 0,
  weekly_goal int  not null default 300 check (weekly_goal >= 0),
  archived_at timestamptz,
  created_at  timestamptz not null default now()
);
create index on public.child (family_id);

-- 아이 기기(익명 로그인 계정). mode=child 는 한 아이 전용, shared 는 가족 공용 태블릿.
create table public.device (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.family(id) on delete cascade,
  user_id    uuid not null unique references auth.users(id) on delete cascade,
  mode       text not null check (mode in ('child','shared')),
  child_id   uuid references public.child(id) on delete cascade,
  label      text,
  created_at timestamptz not null default now(),
  last_seen  timestamptz,
  revoked_at timestamptz,
  check ((mode = 'child') = (child_id is not null))
);
create index on public.device (family_id);
create index on public.device (child_id);

-- 아이 기기 연결 코드 / 배우자 초대 코드 (8자리, 짧은 유효기간, 1회용)
create table private.join_code (
  code       text primary key,
  kind       text not null check (kind in ('device','parent')),
  family_id  uuid not null references public.family(id) on delete cascade,
  mode       text check (mode in ('child','shared')),
  child_id   uuid references public.child(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null,
  used_at    timestamptz,
  used_by    uuid
);
create index on private.join_code (family_id);

-- 코드 입력 시도 기록 (무차별 대입 차단)
create table private.join_attempt (
  user_id uuid not null,
  at      timestamptz not null default now(),
  ok      boolean not null
);
create index on private.join_attempt (user_id, at);
create index on private.join_attempt (at);

create table public.category (
  id        uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.family(id) on delete cascade,
  name      text not null check (length(btrim(name)) between 1 and 20),
  weight    numeric(4,2) not null check (weight between 0.1 and 5),
  emoji     text not null default '🏷️',
  hint      text,
  sort      int not null default 0,
  unique (family_id, name)
);

-- 규칙표 (참고용 점수표)
create table public.rule (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.family(id) on delete cascade,
  label      text not null,
  points     int  not null,
  group_name text not null default '기본',
  active     boolean not null default true,
  sort       int not null default 0
);
create index on public.rule (family_id);

create table public.routine (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.family(id) on delete cascade,
  child_id   uuid not null references public.child(id) on delete cascade,
  label      text not null check (length(btrim(label)) between 1 and 60),
  points     int  not null check (points between 0 and 100000),
  slot       text not null default '낮' check (slot in ('아침','낮','저녁')),
  dows       int[] not null default array[1,2,3,4,5,6,7],
  active     boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);
create index on public.routine (family_id);
create index on public.routine (child_id);

-- 점수 기록. append-only: UPDATE/DELETE 금지(트리거). 취소는 kind='cancel' 새 행.
create table public.entry (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.family(id) on delete cascade,
  child_id    uuid not null references public.child(id) on delete cascade,
  occurred_on date not null,
  kind        text not null check (kind in ('earn','spend','adjust','cancel','interest','team')),
  label       text not null,
  raw_points  int  not null,
  weight      numeric(4,2) not null default 1,
  points      int  not null,
  category    text,
  memo        text,
  source      text not null default 'parent',
  cancels_entry_id uuid unique references public.entry(id) on delete cascade,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  check ((kind = 'cancel') = (cancels_entry_id is not null))
);
create index on public.entry (family_id, occurred_on desc);
create index on public.entry (child_id, occurred_on desc);

create table public.todo (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.family(id) on delete cascade,
  child_id   uuid not null references public.child(id) on delete cascade,
  todo_date  date not null,
  label      text not null,
  points     int  not null check (points between 0 and 100000),
  slot       text not null default '낮',
  routine_id uuid references public.routine(id) on delete set null,
  status     text not null default 'open' check (status in ('open','done','approved','rejected')),
  entry_id   uuid references public.entry(id) on delete set null,
  done_at    timestamptz,
  decided_at timestamptz,
  decided_by uuid,
  created_at timestamptz not null default now()
);
create unique index todo_routine_once on public.todo (child_id, todo_date, routine_id) where routine_id is not null;
create index on public.todo (family_id, todo_date desc);
create index on public.todo (child_id, todo_date desc);

create table public.request (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.family(id) on delete cascade,
  child_id   uuid not null references public.child(id) on delete cascade,
  kind       text not null check (kind in ('earn','spend')),
  label      text not null check (length(btrim(label)) between 1 and 60),
  raw_points int  not null check (raw_points between 1 and 1000000),
  category   text,
  memo       text,
  status     text not null default 'pending' check (status in ('pending','approved','rejected','canceled')),
  entry_id   uuid references public.entry(id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);
create index on public.request (family_id, created_at desc);
create index on public.request (child_id);

create table public.goal (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.family(id) on delete cascade,
  child_id    uuid not null references public.child(id) on delete cascade,
  title       text not null,
  price_won   int  not null check (price_won between 1 and 100000000),
  category    text not null default '일반',
  status      text not null default 'active' check (status in ('active','done','canceled')),
  created_at  timestamptz not null default now(),
  achieved_at timestamptz
);
create index on public.goal (family_id);
create index on public.goal (child_id);

create table public.push_sub (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.family(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  role       text not null check (role in ('parent','child')),
  child_id   uuid references public.child(id) on delete cascade,
  ua         text,
  created_at timestamptz not null default now(),
  last_ok    timestamptz
);
create index on public.push_sub (family_id);

-- 형제 공동 목표: 아이들이 자기 점수를 보태서 함께 모은다
create table public.team_goal (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references public.family(id) on delete cascade,
  title         text not null check (length(btrim(title)) between 1 and 60),
  target_points int  not null check (target_points between 1 and 1000000),
  emoji         text not null default '🤝',
  status        text not null default 'active' check (status in ('active','done','canceled')),
  created_at    timestamptz not null default now(),
  achieved_at   timestamptz
);
create index on public.team_goal (family_id);

create table public.team_contribution (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.family(id) on delete cascade,
  goal_id    uuid not null references public.team_goal(id) on delete cascade,
  child_id   uuid not null references public.child(id) on delete cascade,
  entry_id   uuid not null unique references public.entry(id) on delete cascade,
  points     int  not null check (points > 0),
  created_at timestamptz not null default now()
);
create index on public.team_contribution (goal_id);
create index on public.team_contribution (child_id);

-- 배지 (한 번 받으면 남는다). code 예: streak_7, earned_1000, habit:<routine id>
create table public.badge (
  id        uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.family(id) on delete cascade,
  child_id  uuid not null references public.child(id) on delete cascade,
  code      text not null,
  label     text,                 -- 습관 졸업 배지는 루틴 이름
  earned_at timestamptz not null default now(),
  unique (child_id, code)
);
create index on public.badge (family_id);

-- 서버 비밀값 (VAPID 키, 푸시 훅 비밀) — API 로 노출되지 않는 private 스키마
create table private.secret (k text primary key, v text not null);

-- ---------------------------------------------------------------------
-- append-only 보호: entry 는 수정 불가, 직접 삭제 불가(가족 탈퇴 시 cascade 만 허용)
-- ---------------------------------------------------------------------
create or replace function private.entry_block_update() returns trigger
language plpgsql as $$
begin
  raise exception '점수 기록은 수정할 수 없어요. 취소 기록을 추가하세요.';
end $$;
create trigger entry_no_update before update on public.entry
  for each row execute function private.entry_block_update();

-- ---------------------------------------------------------------------
-- 권한 헬퍼 (security definer: RLS 재귀 없이 소속 확인)
-- ---------------------------------------------------------------------
create or replace function private.my_family_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select m.family_id from public.family_member m where m.user_id = (select auth.uid())),
    (select d.family_id from public.device d where d.user_id = (select auth.uid()) and d.revoked_at is null))
$$;

create or replace function private.is_parent() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.family_member m where m.user_id = (select auth.uid()))
$$;

-- 이 사용자가 볼 수 있는 아이들 (부모·공용기기 = 가족 전체, 아이 기기 = 그 아이)
create or replace function private.my_child_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select c.id from public.child c
   where c.family_id = private.my_family_id()
     and (private.is_parent()
          or exists (select 1 from public.device d
                      where d.user_id = (select auth.uid()) and d.revoked_at is null
                        and (d.mode = 'shared' or d.child_id = c.id)))
$$;

-- 화면에 '보이기만' 하는 아이들: 내 아이들 + (형제 보기 켜짐이면) 가족 아이 전체.
-- 조작 권한(require_child_access)은 여전히 my_child_ids 로만 판단한다.
create or replace function private.my_visible_child_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select id from private.my_child_ids() as t(id)
  union
  select c.id from public.child c join public.family f on f.id = c.family_id
   where c.family_id = private.my_family_id() and f.show_siblings
$$;

create or replace function private.family_today(p_family uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone f.timezone)::date from public.family f where f.id = p_family
$$;

grant usage on schema private to authenticated;
grant execute on function private.my_family_id(), private.is_parent(), private.my_child_ids(), private.my_visible_child_ids() to authenticated;

-- ---------------------------------------------------------------------
-- RLS: 읽기만 허용. 쓰기 정책은 없다(전부 RPC).
-- ---------------------------------------------------------------------
alter table public.family        enable row level security;
alter table public.family_member enable row level security;
alter table public.child         enable row level security;
alter table public.device        enable row level security;
alter table public.category      enable row level security;
alter table public.rule          enable row level security;
alter table public.routine       enable row level security;
alter table public.entry         enable row level security;
alter table public.todo          enable row level security;
alter table public.request       enable row level security;
alter table public.goal          enable row level security;
alter table public.push_sub      enable row level security;
alter table public.team_goal     enable row level security;
alter table public.team_contribution enable row level security;
alter table public.badge         enable row level security;

create policy family_read on public.family for select to authenticated
  using (id = (select private.my_family_id()));
create policy member_read on public.family_member for select to authenticated
  using (family_id = (select private.my_family_id()) and (select private.is_parent()));
-- 아이 이름 목록은 가족 모두가 본다(형제 카드 표시)
create policy child_read on public.child for select to authenticated
  using (family_id = (select private.my_family_id()));
create policy device_read on public.device for select to authenticated
  using (family_id = (select private.my_family_id())
         and ((select private.is_parent()) or user_id = (select auth.uid())));
create policy category_read on public.category for select to authenticated
  using (family_id = (select private.my_family_id()));
create policy rule_read on public.rule for select to authenticated
  using (family_id = (select private.my_family_id()));
create policy routine_read on public.routine for select to authenticated
  using (family_id = (select private.my_family_id()) and child_id in (select private.my_child_ids()));
create policy entry_read on public.entry for select to authenticated
  using (family_id = (select private.my_family_id()) and child_id in (select private.my_child_ids()));
-- 할 일은 형제 보기 켜짐이면 형제 것도 보인다(달성률 비교용). 체크는 여전히 자기 것만.
create policy todo_read on public.todo for select to authenticated
  using (family_id = (select private.my_family_id()) and child_id in (select private.my_visible_child_ids()));
create policy request_read on public.request for select to authenticated
  using (family_id = (select private.my_family_id()) and child_id in (select private.my_child_ids()));
create policy goal_read on public.goal for select to authenticated
  using (family_id = (select private.my_family_id()) and child_id in (select private.my_child_ids()));
-- 공동 목표는 협동이므로 가족 모두가 본다
create policy team_goal_read on public.team_goal for select to authenticated
  using (family_id = (select private.my_family_id()));
create policy team_contrib_read on public.team_contribution for select to authenticated
  using (family_id = (select private.my_family_id()));
-- 배지는 '보이는 아이'(형제 보기 설정 반영) 것만
create policy badge_read on public.badge for select to authenticated
  using (family_id = (select private.my_family_id()) and child_id in (select private.my_visible_child_ids()));
create policy push_read on public.push_sub for select to authenticated
  using (user_id = (select auth.uid()));

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant select on all tables in schema public to authenticated;

-- 잔액: 보이는 아이들(형제 보기 설정 반영)의 잔액만. 상세 기록은 entry_read 로 자기 것만.
create or replace function public.balances() returns table(child_id uuid, balance int, week_earned int, week_spent int)
language sql stable security definer set search_path = '' as $$
  select c.id,
         coalesce(sum(e.points), 0)::int,
         coalesce(sum(e.points) filter (where e.points > 0 and e.kind <> 'cancel'
                    and e.occurred_on >= private.family_today(c.family_id) - 6), 0)::int,
         coalesce(sum(-e.points) filter (where e.points < 0 and e.kind <> 'cancel'
                    and e.occurred_on >= private.family_today(c.family_id) - 6), 0)::int
    from public.child c left join public.entry e on e.child_id = c.id
   where c.id in (select private.my_visible_child_ids())
   group by c.id
$$;

-- =====================================================================
-- RPC
-- =====================================================================

-- 공통: 부모인지 확인하고 가족 id 반환
create or replace function private.require_parent() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  select m.family_id into v from public.family_member m where m.user_id = (select auth.uid());
  if v is null then raise exception 'not_parent' using errcode = '42501'; end if;
  return v;
end $$;

-- 공통: 이 아이를 다룰 수 있는 사용자(부모 또는 그 아이의 기기)인지 확인
create or replace function private.require_child_access(p_child uuid) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  select c.family_id into v from public.child c
   where c.id = p_child and c.archived_at is null and c.id in (select private.my_child_ids());
  if v is null then raise exception 'no_access' using errcode = '42501'; end if;
  return v;
end $$;

create or replace function private.gen_code() returns text
language sql volatile as $$
  -- 헷갈리는 글자(0 O 1 I L) 제외 31자 × 8자리 ≈ 8.5e11 경우의 수
  select string_agg(substr('23456789ABCDEFGHJKMNPQRSTUVWXYZ', 1 + floor(random() * 31)::int, 1), '')
    from generate_series(1, 8)
$$;

-- 내 상태: 앱 시작 시 호출 → 부모 / 아이 기기 / 미가입 구분
create or replace function public.whoami() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); m record; d record;
begin
  if v_uid is null then return jsonb_build_object('state','anon'); end if;
  select * into m from public.family_member where user_id = v_uid;
  if found then
    return jsonb_build_object('state','parent','family_id',m.family_id);
  end if;
  select * into d from public.device where user_id = v_uid;
  if found then
    if d.revoked_at is not null then return jsonb_build_object('state','revoked'); end if;
    return jsonb_build_object('state','device','family_id',d.family_id,'mode',d.mode,'child_id',d.child_id,'device_id',d.id);
  end if;
  return jsonb_build_object('state','new',
    'anonymous', coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false));
end $$;

-- 가족 만들기 (Google 로그인 부모, 아직 가족 없음)
create or replace function public.create_family(
  p_name text, p_children jsonb, p_timezone text default 'Asia/Seoul',
  p_display_name text default null, p_examples boolean default false, p_show_siblings boolean default false,
  p_interest_pct numeric default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_fam uuid; c jsonb; v_child uuid; i int := 0;
begin
  if v_uid is null or coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) then
    raise exception 'login_required' using errcode = '42501';
  end if;
  if exists (select 1 from public.family_member where user_id = v_uid)
     or exists (select 1 from public.device where user_id = v_uid) then
    raise exception 'already_in_family';
  end if;
  if jsonb_typeof(p_children) <> 'array' or jsonb_array_length(p_children) not between 1 and 10 then
    raise exception '아이는 1명 이상 10명 이하로 넣어주세요';
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    p_timezone := 'Asia/Seoul';
  end if;

  insert into public.family(name, timezone, created_by, show_siblings, interest_pct)
  values (btrim(p_name), p_timezone, v_uid, coalesce(p_show_siblings,false), least(10, greatest(0, coalesce(p_interest_pct,0))))
  returning id into v_fam;
  insert into public.family_member(family_id, user_id, display_name) values (v_fam, v_uid, p_display_name);

  for c in select * from jsonb_array_elements(p_children) loop
    i := i + 1;
    insert into public.child(family_id, name, emoji, color, sort)
    values (v_fam, btrim(c->>'name'), coalesce(nullif(c->>'emoji',''),'🙂'),
            coalesce(nullif(c->>'color',''),'#4F7CFF'), i)
    returning id into v_child;
    if p_examples then
      insert into public.routine(family_id, child_id, label, points, slot, sort) values
        (v_fam, v_child, '이불 정리', 5, '아침', 1),
        (v_fam, v_child, '숙제하기', 20, '낮', 2),
        (v_fam, v_child, '책 20분 읽기', 15, '저녁', 3),
        (v_fam, v_child, '내일 가방 챙기기', 5, '저녁', 4);
    end if;
  end loop;

  insert into public.category(family_id, name, weight, emoji, hint, sort) values
    (v_fam, '책·학습',   0.5, '📚', '책, 학습지, 교구 — 반값으로 살 수 있어요', 1),
    (v_fam, '경험·체험', 0.7, '🎟️', '전시, 공연, 체험, 여행 — 남는 건 추억', 2),
    (v_fam, '운동·취미', 0.8, '⚽', '운동용품, 악기, 만들기 재료', 3),
    (v_fam, '일반',      1.0, '🛍️', '보통 물건 — 정가 그대로', 4),
    (v_fam, '군것질',    1.2, '🍭', '과자, 음료, 아이스크림', 5),
    (v_fam, '게임',      1.3, '🎮', '게임 본편·팩. 아이템·가챠는 충동구매', 6),
    (v_fam, '충동구매',  1.5, '🎰', '뽑기, 가챠, 굿즈 — 50% 더 비싸요', 7);

  insert into public.rule(family_id, label, points, group_name, sort) values
    (v_fam, '심부름 하기', 10, '기본', 1),
    (v_fam, '동생/형제 도와주기', 10, '기본', 2),
    (v_fam, '거짓말', -20, '약속', 3);

  return jsonb_build_object('ok', true, 'family_id', v_fam);
end $$;

-- 가족 설정 변경 (부모)
create or replace function public.update_family(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_times text[];
begin
  if p ? 'remind_times' then
    select coalesce(array_agg(distinct t order by t), '{}') into v_times
      from jsonb_array_elements_text(p->'remind_times') t where t ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$';
  end if;
  if p ? 'timezone' and not exists (select 1 from pg_timezone_names where name = p->>'timezone') then
    raise exception '알 수 없는 시간대';
  end if;
  update public.family set
    name          = coalesce(nullif(btrim(p->>'name'),''), name),
    won_per_point = coalesce((p->>'won_per_point')::int, won_per_point),
    timezone      = coalesce(p->>'timezone', timezone),
    remind_times  = coalesce(v_times, remind_times),
    show_siblings = coalesce((p->>'show_siblings')::boolean, show_siblings),
    interest_pct  = coalesce((p->>'interest_pct')::numeric, interest_pct),
    interest_dow  = coalesce((p->>'interest_dow')::int, interest_dow),
    interest_cap  = coalesce((p->>'interest_cap')::int, interest_cap)
   where id = v_fam;
  return jsonb_build_object('ok', true);
end $$;

-- 아이 추가/수정 (부모)
create or replace function public.upsert_child(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_id uuid;
begin
  if p ? 'id' then
    update public.child set
      name  = coalesce(nullif(btrim(p->>'name'),''), name),
      emoji = coalesce(nullif(p->>'emoji',''), emoji),
      color = coalesce(nullif(p->>'color',''), color),
      weekly_goal = coalesce((p->>'weekly_goal')::int, weekly_goal)
     where id = (p->>'id')::uuid and family_id = v_fam
    returning id into v_id;
    if v_id is null then raise exception 'no_access' using errcode = '42501'; end if;
  else
    if (select count(*) from public.child where family_id = v_fam and archived_at is null) >= 10 then
      raise exception '아이는 10명까지예요';
    end if;
    insert into public.child(family_id, name, emoji, color, sort)
    values (v_fam, btrim(p->>'name'), coalesce(nullif(p->>'emoji',''),'🙂'), coalesce(nullif(p->>'color',''),'#4F7CFF'),
            coalesce((select max(sort) from public.child where family_id = v_fam), 0) + 1)
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 아이 숨기기 (기록은 남김, 그 아이 기기 연결 해제)
create or replace function public.archive_child(p_child uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  update public.child set archived_at = now() where id = p_child and family_id = v_fam and archived_at is null;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  update public.device set revoked_at = now() where child_id = p_child and revoked_at is null;
  update public.routine set active = false where child_id = p_child;
  return jsonb_build_object('ok', true);
end $$;

-- 연결 코드 만들기 (부모). kind=device: 아이 기기 / kind=parent: 배우자 초대
create or replace function public.create_join_code(p_kind text, p_child uuid default null, p_mode text default 'child')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_code text; v_exp timestamptz;
begin
  if p_kind = 'device' then
    if p_mode = 'child' and not exists (select 1 from public.child where id = p_child and family_id = v_fam and archived_at is null) then
      raise exception 'no_access' using errcode = '42501';
    end if;
    if p_mode not in ('child','shared') then raise exception 'bad_mode'; end if;
    v_exp := now() + interval '10 minutes';
  elsif p_kind = 'parent' then
    p_child := null; p_mode := null;
    v_exp := now() + interval '24 hours';
  else
    raise exception 'bad_kind';
  end if;
  -- 이 가족의 쓰지 않은 같은 종류 코드는 무효화 (코드는 늘 하나만 살아 있게)
  delete from private.join_code where family_id = v_fam and kind = p_kind and used_at is null;
  loop
    v_code := private.gen_code();
    begin
      insert into private.join_code(code, kind, family_id, mode, child_id, created_by, expires_at)
      values (v_code, p_kind, v_fam, case when p_kind = 'device' then p_mode end,
              case when p_mode = 'child' then p_child end, (select auth.uid()), v_exp);
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'code', v_code, 'expires_at', v_exp);
end $$;

-- 코드 사용. 아이 기기(익명 로그인)는 device 코드, Google 로그인 부모는 parent 코드.
create or replace function public.redeem_join_code(p_code text, p_label text default null, p_display_name text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_anon boolean; c record; v_code text; v_dev uuid;
begin
  if v_uid is null then raise exception 'login_required' using errcode = '42501'; end if;
  v_anon := coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false);

  -- 무차별 대입 차단: 사용자당 10분에 실패 5회, 서비스 전체 1분에 실패 60회
  if (select count(*) from private.join_attempt where user_id = v_uid and not ok and at > now() - interval '10 minutes') >= 5
     or (select count(*) from private.join_attempt where not ok and at > now() - interval '1 minute') >= 60 then
    return jsonb_build_object('ok', false, 'error', '잠시 후 다시 시도해 주세요 (입력 실패가 많아요)');
  end if;
  delete from private.join_attempt where at < now() - interval '1 day';

  v_code := upper(regexp_replace(coalesce(p_code,''), '[^0-9A-Za-z]', '', 'g'));
  select * into c from private.join_code
   where code = v_code and used_at is null and expires_at > now()
   for update;
  if not found then
    insert into private.join_attempt(user_id, ok) values (v_uid, false);
    return jsonb_build_object('ok', false, 'error', '코드가 맞지 않거나 시간이 지났어요');
  end if;

  if exists (select 1 from public.family_member where user_id = v_uid) then
    return jsonb_build_object('ok', false, 'error', '이미 가족에 속한 계정이에요');
  end if;

  if c.kind = 'device' then
    if not v_anon then
      return jsonb_build_object('ok', false, 'error', '아이 기기 코드는 아이 폰에서 입력해 주세요');
    end if;
    -- 이 기기가 예전에 연결돼 있었다면 새 연결로 교체
    delete from public.device where user_id = v_uid;
    insert into public.device(family_id, user_id, mode, child_id, label, last_seen)
    values (c.family_id, v_uid, c.mode, c.child_id, left(p_label, 60), now())
    returning id into v_dev;
  else
    if v_anon then
      return jsonb_build_object('ok', false, 'error', '부모 초대 코드는 Google 로그인 후 입력해 주세요');
    end if;
    delete from public.device where user_id = v_uid;
    insert into public.family_member(family_id, user_id, display_name) values (c.family_id, v_uid, p_display_name);
  end if;

  update private.join_code set used_at = now(), used_by = v_uid where code = c.code;
  insert into private.join_attempt(user_id, ok) values (v_uid, true);
  return jsonb_build_object('ok', true, 'kind', c.kind, 'family_id', c.family_id, 'mode', c.mode, 'child_id', c.child_id);
end $$;

create or replace function public.revoke_device(p_device uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  update public.device set revoked_at = now() where id = p_device and family_id = v_fam and revoked_at is null;
  delete from public.push_sub where user_id = (select user_id from public.device where id = p_device and family_id = v_fam);
  return jsonb_build_object('ok', true);
end $$;

-- 다른 부모 내보내기 (자기 자신은 불가 — 탈퇴는 leave_family)
create or replace function public.remove_parent(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  if p_user = (select auth.uid()) then raise exception '자기 자신은 내보낼 수 없어요'; end if;
  delete from public.family_member where family_id = v_fam and user_id = p_user;
  delete from public.push_sub where family_id = v_fam and user_id = p_user;
  return jsonb_build_object('ok', true);
end $$;

-- 기기 접속 시각 갱신 (부모가 '마지막 사용' 확인용)
create or replace function public.touch_device() returns void
language sql security definer set search_path = '' as $$
  update public.device set last_seen = now()
   where user_id = (select auth.uid()) and revoked_at is null
     and (last_seen is null or last_seen < now() - interval '5 minutes')
$$;

-- 오늘 루틴 → 할 일 생성 (가족 시간대 기준). 앱 시작·정기 알림 때 호출.
create or replace function private.ensure_today_for(p_family uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare v_d date := private.family_today(p_family); v_n int;
begin
  insert into public.todo(family_id, child_id, todo_date, label, points, slot, routine_id)
  select r.family_id, r.child_id, v_d, r.label, r.points, r.slot, r.id
    from public.routine r join public.child c on c.id = r.child_id and c.archived_at is null
   where r.family_id = p_family and r.active and extract(isodow from v_d)::int = any(r.dows)
  on conflict (child_id, todo_date, routine_id) where routine_id is not null do nothing;
  get diagnostics v_n = row_count;
  update public.family set ensured_on = v_d where id = p_family and ensured_on is distinct from v_d;
  return v_n;
end $$;

create or replace function public.ensure_today() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.my_family_id();
begin
  if v_fam is null then raise exception 'no_family' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true, 'created', private.ensure_today_for(v_fam), 'date', private.family_today(v_fam));
end $$;

-- ---------- 아이 쪽 (아이 기기 또는 부모) ----------
create or replace function public.check_todo(p_todo uuid, p_done boolean default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t record;
begin
  select * into t from public.todo where id = p_todo;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  perform private.require_child_access(t.child_id);
  if p_done then
    update public.todo set status = 'done', done_at = now() where id = p_todo and status in ('open','rejected');
  else
    update public.todo set status = 'open', done_at = null where id = p_todo and status = 'done';
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.create_request(p_child uuid, p_kind text, p_label text, p_raw_points int,
  p_category text default null, p_memo text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_child_access(p_child); v_id uuid;
begin
  -- 장난 방지: 대기 중 신청은 아이당 20개까지
  if (select count(*) from public.request where child_id = p_child and status = 'pending') >= 20 then
    return jsonb_build_object('ok', false, 'error', '기다리는 신청이 너무 많아요');
  end if;
  insert into public.request(family_id, child_id, kind, label, raw_points, category, memo, created_by)
  values (v_fam, p_child, p_kind, btrim(p_label), abs(p_raw_points), p_category, left(p_memo, 200), (select auth.uid()))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.cancel_request(p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  select * into r from public.request where id = p_request;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  perform private.require_child_access(r.child_id);
  update public.request set status = 'canceled', decided_at = now() where id = p_request and status = 'pending';
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 부모 전용 ----------
create or replace function private.weight_of(p_family uuid, p_category text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select weight from public.category where family_id = p_family and name = p_category), 1.0)
$$;

-- 점수 주기 / 사용 / 조정
create or replace function public.add_entry(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_child uuid := (p->>'child_id')::uuid;
        v_kind text := coalesce(p->>'kind','earn'); v_raw int := abs((p->>'raw_points')::int);
        v_w numeric := 1; v_pts int; v_id uuid;
begin
  if not exists (select 1 from public.child where id = v_child and family_id = v_fam) then
    raise exception 'no_access' using errcode = '42501';
  end if;
  if v_kind not in ('earn','spend','adjust') then raise exception 'bad_kind'; end if;
  if v_kind = 'spend' then
    v_w := coalesce((p->>'weight')::numeric, private.weight_of(v_fam, p->>'category'));
    v_pts := -round(v_raw * v_w);
  elsif v_kind = 'adjust' and (p->>'raw_points')::int < 0 then
    v_pts := -v_raw;
  else
    v_pts := v_raw;
  end if;
  insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, memo, source, created_by)
  values (v_fam, v_child, coalesce((p->>'occurred_on')::date, private.family_today(v_fam)), v_kind,
          coalesce(nullif(btrim(p->>'label'),''), '점수'), v_raw, v_w, v_pts, p->>'category', left(p->>'memo', 200),
          coalesce(p->>'source','parent'), (select auth.uid()))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'points', v_pts);
end $$;

-- 기록 취소 = 반대 점수의 취소 기록 추가 (원본은 그대로 남음)
create or replace function public.cancel_entry(p_entry uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); e record; v_id uuid;
begin
  select * into e from public.entry where id = p_entry and family_id = v_fam;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  if e.kind = 'cancel' then return jsonb_build_object('ok', false, 'error', '취소 기록은 다시 취소할 수 없어요'); end if;
  if exists (select 1 from public.entry where cancels_entry_id = p_entry) then
    return jsonb_build_object('ok', false, 'error', '이미 취소된 기록이에요');
  end if;
  insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, memo, source, cancels_entry_id, created_by)
  values (v_fam, e.child_id, private.family_today(v_fam), 'cancel', '취소: ' || e.label, e.raw_points, e.weight, -e.points,
          e.category, left(p_reason, 200), 'cancel', e.id, (select auth.uid()))
  returning id into v_id;
  -- 이 기록으로 승인된 할 일은 다시 '확인 중'으로
  update public.todo set status = 'done', entry_id = null, decided_at = null where entry_id = p_entry;
  update public.request set status = 'pending', entry_id = null, decided_at = null where entry_id = p_entry;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.add_todo(p_child uuid, p_label text, p_points int, p_date date default null, p_slot text default '낮')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_id uuid;
begin
  if not exists (select 1 from public.child where id = p_child and family_id = v_fam) then
    raise exception 'no_access' using errcode = '42501';
  end if;
  insert into public.todo(family_id, child_id, todo_date, label, points, slot)
  values (v_fam, p_child, coalesce(p_date, private.family_today(v_fam)), btrim(p_label), p_points,
          case when p_slot in ('아침','낮','저녁') then p_slot else '낮' end)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 할 일 삭제는 점수와 연결 안 된 것만 (승인된 건 기록이 있으므로 cancel_entry 로)
create or replace function public.delete_todo(p_todo uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  delete from public.todo where id = p_todo and family_id = v_fam and status <> 'approved';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.decide_todo(p_todo uuid, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); t record; v_entry uuid;
begin
  select * into t from public.todo where id = p_todo and family_id = v_fam for update;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  if t.status = 'approved' then return jsonb_build_object('ok', true, 'already', true); end if;
  if p_approve then
    insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, source, created_by)
    values (v_fam, t.child_id, t.todo_date, 'earn', t.label, t.points, 1, t.points, '할 일', 'todo', (select auth.uid()))
    returning id into v_entry;
    update public.todo set status = 'approved', entry_id = v_entry, decided_at = now(), decided_by = (select auth.uid()) where id = p_todo;
  else
    update public.todo set status = 'rejected', decided_at = now(), decided_by = (select auth.uid()) where id = p_todo;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.carry_todo(p_todo uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); t record;
begin
  select * into t from public.todo where id = p_todo and family_id = v_fam;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  insert into public.todo(family_id, child_id, todo_date, label, points, slot)
  values (v_fam, t.child_id, private.family_today(v_fam), t.label, t.points, t.slot);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.decide_request(p_request uuid, p_approve boolean, p_raw_points int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); r record; v_raw int; v_w numeric := 1; v_pts int; v_entry uuid;
begin
  select * into r from public.request where id = p_request and family_id = v_fam for update;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  if r.status <> 'pending' then return jsonb_build_object('ok', false, 'error', '이미 처리된 신청이에요'); end if;
  if p_approve then
    v_raw := abs(coalesce(p_raw_points, r.raw_points));
    if r.kind = 'spend' then
      v_w := private.weight_of(v_fam, r.category); v_pts := -round(v_raw * v_w);
    else
      v_pts := v_raw;
    end if;
    insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, memo, source, created_by)
    values (v_fam, r.child_id, private.family_today(v_fam), r.kind, r.label, v_raw, v_w, v_pts, r.category, r.memo, 'request', (select auth.uid()))
    returning id into v_entry;
    update public.request set status = 'approved', entry_id = v_entry, decided_at = now(), decided_by = (select auth.uid()) where id = p_request;
  else
    update public.request set status = 'rejected', decided_at = now(), decided_by = (select auth.uid()) where id = p_request;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.upsert_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  insert into public.category(family_id, name, weight, emoji, hint, sort)
  values (v_fam, btrim(p->>'name'), (p->>'weight')::numeric, coalesce(nullif(p->>'emoji',''),'🏷️'), nullif(p->>'hint',''),
          coalesce((p->>'sort')::int, (select coalesce(max(sort),0)+1 from public.category where family_id = v_fam)))
  on conflict (family_id, name) do update set weight = excluded.weight, emoji = excluded.emoji, hint = excluded.hint;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.delete_category(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  delete from public.category where family_id = v_fam and name = p_name;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.upsert_rule(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_id uuid;
begin
  if p ? 'id' then
    update public.rule set label = btrim(p->>'label'), points = (p->>'points')::int,
           group_name = coalesce(nullif(p->>'group_name',''),'기본'), active = coalesce((p->>'active')::boolean, true)
     where id = (p->>'id')::uuid and family_id = v_fam returning id into v_id;
  else
    insert into public.rule(family_id, label, points, group_name, sort)
    values (v_fam, btrim(p->>'label'), (p->>'points')::int, coalesce(nullif(p->>'group_name',''),'기본'),
            (select coalesce(max(sort),0)+1 from public.rule where family_id = v_fam))
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', v_id is not null, 'id', v_id);
end $$;

create or replace function public.delete_rule(p_rule uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  delete from public.rule where id = p_rule and family_id = v_fam;
  return jsonb_build_object('ok', true);
end $$;

-- 루틴 추가 (여러 아이에게 한 번에)
create or replace function public.add_routine(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_child uuid; v_dows int[]; v_n int := 0;
begin
  select coalesce(array_agg(distinct d::int order by d::int), '{}') into v_dows
    from jsonb_array_elements_text(coalesce(p->'dows','[1,2,3,4,5,6,7]')) d where d::int between 1 and 7;
  if cardinality(v_dows) = 0 then raise exception '요일을 하나 이상 고르세요'; end if;
  for v_child in select (x)::uuid from jsonb_array_elements_text(p->'child_ids') x loop
    if not exists (select 1 from public.child where id = v_child and family_id = v_fam and archived_at is null) then
      raise exception 'no_access' using errcode = '42501';
    end if;
    insert into public.routine(family_id, child_id, label, points, slot, dows, sort)
    values (v_fam, v_child, btrim(p->>'label'), (p->>'points')::int,
            case when p->>'slot' in ('아침','낮','저녁') then p->>'slot' else '낮' end, v_dows,
            (select coalesce(max(sort),0)+1 from public.routine where child_id = v_child));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'created', v_n);
end $$;

create or replace function public.toggle_routine(p_routine uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  update public.routine set active = not active where id = p_routine and family_id = v_fam;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.delete_routine(p_routine uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  delete from public.routine where id = p_routine and family_id = v_fam;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.upsert_goal(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_id uuid; v_status text := coalesce(p->>'status','active');
begin
  if p ? 'id' then
    update public.goal set title = btrim(p->>'title'), price_won = (p->>'price_won')::int,
           category = coalesce(nullif(p->>'category',''),'일반'), status = v_status,
           achieved_at = case when v_status = 'done' then now() end
     where id = (p->>'id')::uuid and family_id = v_fam returning id into v_id;
  else
    if not exists (select 1 from public.child where id = (p->>'child_id')::uuid and family_id = v_fam) then
      raise exception 'no_access' using errcode = '42501';
    end if;
    insert into public.goal(family_id, child_id, title, price_won, category)
    values (v_fam, (p->>'child_id')::uuid, btrim(p->>'title'), (p->>'price_won')::int, coalesce(nullif(p->>'category',''),'일반'))
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', v_id is not null, 'id', v_id);
end $$;

create or replace function public.delete_goal(p_goal uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  update public.goal set status = 'canceled' where id = p_goal and family_id = v_fam;
  return jsonb_build_object('ok', true);
end $$;

-- 탈퇴: 부모가 1명이면 가족 전체 삭제(기록·아이 기기 계정 포함), 여러 명이면 나만 빠짐
create or replace function public.leave_family(p_confirm text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_name text; v_parents int;
begin
  select name into v_name from public.family where id = v_fam;
  select count(*) into v_parents from public.family_member where family_id = v_fam;
  if v_parents > 1 then
    delete from public.family_member where user_id = (select auth.uid());
    delete from public.push_sub where user_id = (select auth.uid());
    return jsonb_build_object('ok', true, 'deleted', 'member');
  end if;
  if p_confirm is distinct from v_name then
    return jsonb_build_object('ok', false, 'error', '가족 이름을 정확히 입력해 주세요');
  end if;
  -- 아이 기기용 익명 계정도 정리
  begin
    delete from auth.users u using public.device d
     where d.family_id = v_fam and d.user_id = u.id and coalesce(u.is_anonymous, false);
  exception when others then null;
  end;
  delete from public.family where id = v_fam;
  return jsonb_build_object('ok', true, 'deleted', 'family');
end $$;

-- ---------- 푸시 ----------
create or replace function public.push_subscribe(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_fam uuid := private.my_family_id(); v_role text; v_child uuid;
begin
  if v_fam is null then raise exception 'no_family' using errcode = '42501'; end if;
  if private.is_parent() and coalesce(p->>'role','parent') = 'parent' then
    v_role := 'parent'; v_child := null;
  else
    v_role := 'child'; v_child := (p->>'child_id')::uuid;
    perform private.require_child_access(v_child);
  end if;
  insert into public.push_sub(family_id, user_id, endpoint, p256dh, auth, role, child_id, ua)
  values (v_fam, v_uid, p->>'endpoint', p->>'p256dh', p->>'auth', v_role, v_child, left(p->>'ua', 200))
  on conflict (endpoint) do update set family_id = excluded.family_id, user_id = excluded.user_id,
    p256dh = excluded.p256dh, auth = excluded.auth, role = excluded.role, child_id = excluded.child_id, ua = excluded.ua;
  return jsonb_build_object('ok', true, 'role', v_role);
end $$;

create or replace function public.push_unsubscribe(p_endpoint text) returns jsonb
language sql security definer set search_path = '' as $$
  delete from public.push_sub where endpoint = p_endpoint and user_id = (select auth.uid());
  select jsonb_build_object('ok', true);
$$;

create or replace function public.push_vapid() returns text
language sql stable security definer set search_path = '' as $$
  select v from private.secret where k = 'vapid_public'
$$;

-- 서버 → 푸시 발송 함수(kp-push) 호출. 실패해도 본 작업은 막지 않음.
create or replace function private.notify(p_msg jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_hook text; v_url text;
begin
  select v into v_hook from private.secret where k = 'push_hook';
  select v into v_url  from private.secret where k = 'push_url';
  if v_hook is null or v_url is null then return; end if;
  perform net.http_post(url := v_url, body := p_msg,
    headers := jsonb_build_object('Content-Type','application/json','x-kp-hook', v_hook),
    timeout_milliseconds := 8000);
exception when others then
  raise warning 'notify failed: %', sqlerrm;
end $$;

create or replace function public.push_test(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.push_sub where endpoint = p_endpoint and user_id = (select auth.uid())) then
    return jsonb_build_object('ok', false, 'error', '등록되지 않은 기기');
  end if;
  perform private.notify(jsonb_build_object('target','endpoint','endpoint',p_endpoint,
    'title','🔔 알림 테스트','body','포인트통장 알림이 잘 연결됐어요!','tag','test'));
  return jsonb_build_object('ok', true);
end $$;

-- 이벤트 알림 트리거
create or replace function private.push_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_name text; v_bal int;
begin
  select name into v_name from public.child where id = new.child_id;
  v_name := coalesce(v_name, '아이');
  if tg_table_name = 'request' then
    if tg_op = 'INSERT' and new.status = 'pending' then
      perform private.notify(jsonb_build_object('target','parent','family_id',new.family_id,
        'title','📝 ' || v_name || ' 신청',
        'body', new.label || ' · ' || case when new.kind = 'spend' then '사용 ' else '적립 ' end || new.raw_points || '점 — 승인해 주세요',
        'tag','req-' || new.id));
    elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'rejected' then
      perform private.notify(jsonb_build_object('target','child','family_id',new.family_id,'child_id',new.child_id,
        'title','🙅 신청이 반려됐어요','body',new.label,'tag','req-' || new.id));
    end if;
  elsif tg_table_name = 'todo' then
    if old.status in ('open','rejected') and new.status = 'done' then
      perform private.notify(jsonb_build_object('target','parent','family_id',new.family_id,
        'title','✅ ' || v_name || ' 할 일 완료','body', new.label || ' (+' || new.points || '점) 승인 대기','tag','todo-' || new.id));
    elsif old.status = 'done' and new.status = 'rejected' then
      perform private.notify(jsonb_build_object('target','child','family_id',new.family_id,'child_id',new.child_id,
        'title','🔁 다시 확인해 보자','body', new.label || ' — 승인되지 않았어요','tag','todo-' || new.id));
    end if;
  elsif tg_table_name = 'entry' then
    select coalesce(sum(points),0) into v_bal from public.entry where child_id = new.child_id;
    perform private.notify(jsonb_build_object('target','child','family_id',new.family_id,'child_id',new.child_id,
      'title', case when new.kind = 'cancel' then '↩️ 기록이 취소됐어요 (' || new.points || '점)'
                    when new.kind = 'interest' then '🌳 저축 이자 +' || new.points || '점'
                    when new.kind = 'team' then '🤝 공동 목표에 ' || (-new.points) || '점 보탰어요'
                    when new.points >= 0 then '🎉 +' || new.points || '점 받았어요'
                    else '💸 ' || new.points || '점 사용' end,
      'body', new.label || ' · 잔액 ' || v_bal || '점', 'tag','entry-' || new.id));
  end if;
  return new;
end $$;

create trigger push_request after insert or update on public.request for each row execute function private.push_trg();
create trigger push_todo    after update on public.todo for each row execute function private.push_trg();
create trigger push_entry   after insert on public.entry for each row execute function private.push_trg();

-- 정기 알림 내용 (가족 하나)
create or replace function private.remind_payload(p_family uuid, p_label text) returns jsonb
language sql stable security definer set search_path = '' as $$
with d as (select private.family_today(p_family) as today),
k as (
  select c.id, c.name, c.emoji, c.sort,
    coalesce((select sum(e.points) from public.entry e where e.child_id = c.id), 0)::int as balance,
    coalesce((select sum(e.points) from public.entry e, d where e.child_id = c.id and e.occurred_on = d.today and e.points > 0 and e.kind <> 'cancel'), 0)::int as earned,
    coalesce((select sum(t.points) from public.todo t, d where t.child_id = c.id and t.todo_date = d.today), 0)::int as total,
    coalesce((select sum(t.points) from public.todo t, d where t.child_id = c.id and t.todo_date = d.today and t.status = 'approved'), 0)::int as got
  from public.child c where c.family_id = p_family and c.archived_at is null
),
m as (
  select *, case when total = 0 then '오늘 할 일 없음'
                 when total - got <= 0 then '오늘 할 일 전부 완료 🎉'
                 else '남은 점수 ' || (total - got) || '점 (' || round((total - got)::numeric / total * 100)::int || '%)' end as left_txt
  from k
)
select jsonb_build_object(
  'kids', coalesce(jsonb_agg(jsonb_build_object('child_id', id,
            'title', '⏰ ' || emoji || ' ' || name || ' 포인트 (' || p_label || ')',
            'body', '오늘 받은 점수 +' || earned || '점 · 현재 ' || balance || '점' || chr(10) || left_txt) order by sort), '[]'),
  'parent', jsonb_build_object('title', '⏰ 포인트 현황 (' || p_label || ')',
            'body', string_agg(emoji || ' ' || name || ': 오늘 +' || earned || ' · 현재 ' || balance || '점 · ' || left_txt, chr(10) order by sort)))
from m
$$;

-- 매분 cron 이 호출: 각 가족 시간대로 '지금'이 알림 시각이면 발송(하루·시각당 1회)
create or replace function private.remind_tick() returns int
language plpgsql security definer set search_path = '' as $$
declare f record; v_hm text; v_key text; v_p jsonb; x jsonb; v_n int := 0;
begin
  for f in select * from public.family loop
    -- 앱을 아무도 안 열어도 매일 루틴이 올라오게 (연속 기록이 엉뚱하게 끊기지 않도록)
    if f.ensured_on is distinct from private.family_today(f.id) then
      perform private.ensure_today_for(f.id);
    end if;
    perform private.pay_interest(f.id);
    v_hm := to_char(now() at time zone f.timezone, 'HH24:MI');
    continue when not (v_hm = any(f.remind_times));
    v_key := to_char(now() at time zone f.timezone, 'YYYY-MM-DD') || ' ' || v_hm;
    continue when f.remind_last is not distinct from v_key;
    update public.family set remind_last = v_key where id = f.id;
    perform private.ensure_today_for(f.id);
    v_p := private.remind_payload(f.id, v_hm);
    for x in select * from jsonb_array_elements(v_p->'kids') loop
      if exists (select 1 from public.push_sub where role = 'child' and child_id = (x->>'child_id')::uuid) then
        perform private.notify(jsonb_build_object('target','child','family_id',f.id,'child_id',(x->>'child_id')::uuid,
          'title',x->>'title','body',x->>'body','tag','remind-' || (x->>'child_id')));
      end if;
    end loop;
    if exists (select 1 from public.push_sub where role = 'parent' and family_id = f.id) then
      perform private.notify(jsonb_build_object('target','parent','family_id',f.id,
        'title',v_p->'parent'->>'title','body',v_p->'parent'->>'body','tag','remind-parent'));
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- =====================================================================
-- 저축 이자 · 공동 목표 · 배지
-- =====================================================================

-- 주간 저축 이자: 지급 요일 저녁 7시(가족 시간대) 이후 첫 tick 에 한 번.
-- 잔액이 양수인 아이에게 floor(잔액 × 이자율), 최대 interest_cap 점.
create or replace function private.pay_interest(p_family uuid, p_force boolean default false) returns int
language plpgsql security definer set search_path = '' as $$
declare f record; v_local timestamp; v_key text; c record; v_bal int; v_pts int; v_n int := 0;
begin
  select * into f from public.family where id = p_family;
  if f.interest_pct <= 0 then return 0; end if;
  v_local := now() at time zone f.timezone;
  if not p_force and (extract(isodow from v_local)::int <> f.interest_dow or v_local::time < time '19:00') then return 0; end if;
  v_key := to_char(v_local, 'YYYY-MM-DD');
  if f.interest_last is not distinct from v_key then return 0; end if;
  update public.family set interest_last = v_key where id = p_family;
  for c in select id from public.child where family_id = p_family and archived_at is null loop
    select coalesce(sum(points),0) into v_bal from public.entry where child_id = c.id;
    v_pts := least(f.interest_cap, floor(v_bal * f.interest_pct / 100))::int;
    if v_pts >= 1 then
      insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, source)
      values (p_family, c.id, v_local::date, 'interest', '저축 이자 ' || f.interest_pct::float || '%', v_bal, 1, v_pts, '이자', 'interest');
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- 연속 기록: 할 일이 있는 날 전부 승인된 날이 며칠 이어졌나 (오늘은 다 끝났을 때만 포함)
create or replace function private.child_streak(p_child uuid) returns int
language plpgsql stable security definer set search_path = '' as $$
declare v_today date; d date; v_ok boolean; v_n int := 0;
begin
  select private.family_today(family_id) into v_today from public.child where id = p_child;
  select bool_and(status = 'approved') into v_ok from public.todo where child_id = p_child and todo_date = v_today;
  if v_ok then v_n := 1; end if;
  d := v_today - 1;
  loop
    select bool_and(status = 'approved') into v_ok from public.todo where child_id = p_child and todo_date = d;
    exit when v_ok is not true;
    v_n := v_n + 1; d := d - 1;
    exit when v_n > 1000;
  end loop;
  return v_n;
end $$;

-- 습관 연속: 이 루틴의 최근 할 일이 몇 번 연속 승인됐나 (오늘 미완료는 건너뜀)
create or replace function private.routine_streak(p_routine uuid) returns int
language sql stable security definer set search_path = '' as $$
  with t as (
    select t.todo_date, t.status = 'approved' as ok,
           row_number() over (order by t.todo_date desc) as rn
      from public.todo t
     where t.routine_id = p_routine
       and not (t.todo_date = private.family_today(t.family_id) and t.status <> 'approved')
  )
  select coalesce(min(rn) - 1, (select count(*) from t))::int from t where not ok
$$;

-- 배지 지급 (새로 받은 배지마다 알림). 이미 받은 배지는 무시.
create or replace function private.award_badges(p_child uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_fam uuid; v_name text; v_streak int; v_earned int; v_bal int; v_new int := 0; b record; r record;
  v_codes text[] := '{}';
begin
  select family_id, name into v_fam, v_name from public.child where id = p_child;
  if v_fam is null then return 0; end if;
  v_streak := private.child_streak(p_child);
  select coalesce(sum(e.points),0) into v_earned from public.entry e
   where e.child_id = p_child and e.kind in ('earn','adjust') and e.points > 0
     and not exists (select 1 from public.entry x where x.cancels_entry_id = e.id);
  select coalesce(sum(points),0) into v_bal from public.entry where child_id = p_child;

  if exists (select 1 from public.todo where child_id = p_child and status = 'approved') then v_codes := v_codes || text 'first_todo'; end if;
  if v_streak >= 3   then v_codes := v_codes || text 'streak_3'; end if;
  if v_streak >= 7   then v_codes := v_codes || text 'streak_7'; end if;
  if v_streak >= 14  then v_codes := v_codes || text 'streak_14'; end if;
  if v_streak >= 30  then v_codes := v_codes || text 'streak_30'; end if;
  if v_streak >= 100 then v_codes := v_codes || text 'streak_100'; end if;
  if v_earned >= 100  then v_codes := v_codes || text 'earned_100'; end if;
  if v_earned >= 500  then v_codes := v_codes || text 'earned_500'; end if;
  if v_earned >= 1000 then v_codes := v_codes || text 'earned_1000'; end if;
  if v_earned >= 5000 then v_codes := v_codes || text 'earned_5000'; end if;
  if v_bal >= 300  then v_codes := v_codes || text 'save_300'; end if;
  if v_bal >= 1000 then v_codes := v_codes || text 'save_1000'; end if;
  if exists (select 1 from public.request where child_id = p_child and status = 'approved' and kind = 'earn') then v_codes := v_codes || text 'self_request'; end if;
  if exists (select 1 from public.goal where child_id = p_child and status = 'done') then v_codes := v_codes || text 'goal_done'; end if;
  if exists (select 1 from public.entry e where e.child_id = p_child and e.kind = 'spend' and e.weight < 1
               and not exists (select 1 from public.entry x where x.cancels_entry_id = e.id)) then v_codes := v_codes || text 'smart_buy'; end if;
  if exists (select 1 from public.entry where child_id = p_child and kind = 'interest') then v_codes := v_codes || text 'interest_first'; end if;
  if exists (select 1 from public.team_contribution c join public.team_goal g on g.id = c.goal_id
              where c.child_id = p_child and g.status = 'done') then v_codes := v_codes || text 'team_done'; end if;

  for b in
    insert into public.badge(family_id, child_id, code)
    select v_fam, p_child, x from unnest(v_codes) x
    on conflict (child_id, code) do nothing
    returning code
  loop
    v_new := v_new + 1;
    perform private.notify(jsonb_build_object('target','child','family_id',v_fam,'child_id',p_child,
      'title','🏅 새 배지를 받았어요!','body', private.badge_name(b.code, null),'tag','badge-' || p_child || '-' || b.code));
    perform private.notify(jsonb_build_object('target','parent','family_id',v_fam,
      'title','🏅 ' || v_name || ' 새 배지','body', private.badge_name(b.code, null),'tag','badge-' || p_child || '-' || b.code));
  end loop;

  -- 습관 졸업: 같은 루틴 30번 연속 승인
  for r in select id, label from public.routine where child_id = p_child and active loop
    if private.routine_streak(r.id) >= 30 then
      insert into public.badge(family_id, child_id, code, label) values (v_fam, p_child, 'habit:' || r.id, r.label)
      on conflict (child_id, code) do nothing;
      if found then
        v_new := v_new + 1;
        perform private.notify(jsonb_build_object('target','child','family_id',v_fam,'child_id',p_child,
          'title','🎓 습관 졸업!','body', r.label || ' 30번 연속 성공 — 이제 진짜 내 습관이에요','tag','habit-' || r.id));
        perform private.notify(jsonb_build_object('target','parent','family_id',v_fam,
          'title','🎓 ' || v_name || ' 습관 졸업','body', r.label || ' 30번 연속. 점수를 줄이거나 끄는 걸 검토해 보세요','tag','habit-' || r.id));
      end if;
    end if;
  end loop;
  return v_new;
end $$;

create or replace function private.badge_name(p_code text, p_label text) returns text
language sql immutable as $$
  select case p_code
    when 'first_todo'     then '🌱 첫 걸음 — 처음으로 할 일 성공'
    when 'streak_3'       then '🔥 3일 연속'
    when 'streak_7'       then '🔥 일주일 연속'
    when 'streak_14'      then '🔥 2주 연속'
    when 'streak_30'      then '🏆 한 달 연속'
    when 'streak_100'     then '👑 100일 연속'
    when 'earned_100'     then '🪙 누적 100점'
    when 'earned_500'     then '💰 누적 500점'
    when 'earned_1000'    then '💎 누적 1,000점'
    when 'earned_5000'    then '🚀 누적 5,000점'
    when 'save_300'       then '🐷 300점 모으기'
    when 'save_1000'      then '🏦 1,000점 모으기'
    when 'self_request'   then '✋ 스스로 신청해서 인정받기'
    when 'goal_done'      then '🎯 목표 달성'
    when 'smart_buy'      then '📚 똑똑한 소비 (할인 카테고리로 구매)'
    when 'interest_first' then '🌳 첫 이자 받기'
    when 'team_done'      then '🤝 형제와 함께 목표 달성'
    else coalesce('🎓 습관 졸업: ' || p_label, p_code) end
$$;

-- 배지 검사 트리거: 점수 기록, 할 일 승인, 목표 달성, 공동 목표 달성 때
create or replace function private.badge_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c uuid;
begin
  if tg_table_name = 'team_goal' then
    for c in select distinct child_id from public.team_contribution where goal_id = new.id loop
      perform private.award_badges(c);
    end loop;
  else
    perform private.award_badges(new.child_id);
  end if;
  return null;
exception when others then
  raise warning 'award_badges failed: %', sqlerrm;  -- 배지 실패가 본 작업을 막지 않게
  return null;
end $$;
create trigger badge_entry after insert on public.entry for each row execute function private.badge_trg();
create trigger badge_todo  after update of status on public.todo for each row when (new.status = 'approved' and old.status <> 'approved') execute function private.badge_trg();
create trigger badge_goal  after update of status on public.goal for each row when (new.status = 'done' and old.status <> 'done') execute function private.badge_trg();
create trigger badge_team  after update of status on public.team_goal for each row when (new.status = 'done' and old.status <> 'done') execute function private.badge_trg();

-- 아이 화면용: 연속 기록 · 습관 진행
create or replace function public.child_progress(p_child uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_child not in (select private.my_visible_child_ids()) then raise exception 'no_access' using errcode = '42501'; end if;
  return jsonb_build_object('streak', private.child_streak(p_child),
    'habits', (select coalesce(jsonb_agg(jsonb_build_object('routine_id', r.id, 'label', r.label,
                 'streak', private.routine_streak(r.id)) order by r.sort), '[]')
                 from public.routine r where r.child_id = p_child and r.active));
end $$;

-- ---------- 공동 목표 ----------
create or replace function public.create_team_goal(p_title text, p_target int, p_emoji text default '🤝') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); v_id uuid;
begin
  insert into public.team_goal(family_id, title, target_points, emoji)
  values (v_fam, btrim(p_title), p_target, coalesce(nullif(p_emoji,''),'🤝')) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function private.team_progress(p_goal uuid) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(c.points),0)::int from public.team_contribution c
   where c.goal_id = p_goal and not exists (select 1 from public.entry x where x.cancels_entry_id = c.entry_id)
$$;

-- 아이(또는 부모)가 자기 점수를 공동 목표에 보탠다
create or replace function public.contribute_team(p_goal uuid, p_child uuid, p_points int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_child_access(p_child); g record; v_bal int; v_left int; v_pts int; v_entry uuid;
begin
  select * into g from public.team_goal where id = p_goal and family_id = v_fam for update;
  if not found or g.status <> 'active' then return jsonb_build_object('ok', false, 'error', '진행 중인 공동 목표가 아니에요'); end if;
  select coalesce(sum(points),0) into v_bal from public.entry where child_id = p_child;
  v_left := g.target_points - private.team_progress(p_goal);
  v_pts := least(coalesce(p_points,0), v_left);
  if v_pts < 1 then return jsonb_build_object('ok', false, 'error', '보탤 점수를 넣어주세요'); end if;
  if v_pts > v_bal then return jsonb_build_object('ok', false, 'error', '잔액이 모자라요 (지금 ' || v_bal || '점)'); end if;
  insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, source, created_by)
  values (v_fam, p_child, private.family_today(v_fam), 'team', g.emoji || ' ' || g.title, v_pts, 1, -v_pts, '공동목표', 'team', (select auth.uid()))
  returning id into v_entry;
  insert into public.team_contribution(family_id, goal_id, child_id, entry_id, points) values (v_fam, p_goal, p_child, v_entry, v_pts);
  if private.team_progress(p_goal) >= g.target_points then
    update public.team_goal set status = 'done', achieved_at = now() where id = p_goal;
    perform private.notify(jsonb_build_object('target','parent','family_id',v_fam,
      'title','🤝 공동 목표 달성!','body', g.title || ' — 아이들이 ' || g.target_points || '점을 함께 모았어요','tag','team-' || p_goal));
  end if;
  return jsonb_build_object('ok', true, 'points', v_pts);
end $$;

-- 공동 목표 취소: 보탠 점수는 취소 기록으로 각자에게 돌려준다
create or replace function public.cancel_team_goal(p_goal uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent(); c record; v_n int := 0;
begin
  update public.team_goal set status = 'canceled' where id = p_goal and family_id = v_fam and status = 'active';
  if not found then return jsonb_build_object('ok', false, 'error', '진행 중인 공동 목표가 아니에요'); end if;
  for c in select e.* from public.team_contribution tc join public.entry e on e.id = tc.entry_id
            where tc.goal_id = p_goal and not exists (select 1 from public.entry x where x.cancels_entry_id = e.id) loop
    insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, memo, source, cancels_entry_id, created_by)
    values (v_fam, c.child_id, private.family_today(v_fam), 'cancel', '돌려받음: ' || c.label, c.raw_points, 1, -c.points,
            '공동목표', '공동 목표 취소', 'cancel', c.id, (select auth.uid()));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'refunded', v_n);
end $$;

-- 루틴 수정 (습관 졸업 후 점수 줄이기 등)
create or replace function public.update_routine(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fam uuid := private.require_parent();
begin
  update public.routine set
    label  = coalesce(nullif(btrim(p->>'label'),''), label),
    points = coalesce((p->>'points')::int, points),
    slot   = case when p->>'slot' in ('아침','낮','저녁') then p->>'slot' else slot end
   where id = (p->>'id')::uuid and family_id = v_fam;
  if not found then raise exception 'no_access' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- 데이터 확인용 요약 (이전 검증 등)
create or replace function public.family_summary() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('kids', jsonb_agg(jsonb_build_object('name', c.name,
           'balance', (select coalesce(sum(points),0) from public.entry e where e.child_id = c.id),
           'entries', (select count(*) from public.entry e where e.child_id = c.id)) order by c.sort))
    from public.child c where c.family_id = private.require_parent()
$$;

-- ---------------------------------------------------------------------
-- 함수 실행 권한: 기본 PUBLIC 실행권 제거 → 로그인 사용자만
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.my_family_id(), private.is_parent(), private.my_child_ids(), private.my_visible_child_ids() to authenticated;
