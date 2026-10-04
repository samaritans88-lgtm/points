-- 권한 테스트. 로컬 Postgres(+Supabase 흉내)에서 실행. 실패 시 예외로 중단된다.
\set ON_ERROR_STOP on
set client_min_messages = warning;

-- 사용자들: A(부모, 가족1) B(부모, 가족2) C(부모 초대받을 사람) D(아이1 폰, 익명) E(익명 공격자)
insert into auth.users(id,email,is_anonymous) values
 ('00000000-0000-0000-0000-00000000000a','a@x.com',false),
 ('00000000-0000-0000-0000-00000000000b','b@x.com',false),
 ('00000000-0000-0000-0000-00000000000c','c@x.com',false),
 ('00000000-0000-0000-0000-00000000000d',null,true),
 ('00000000-0000-0000-0000-00000000000e',null,true);

create or replace function pg_temp.as_user(u text, anon boolean) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u, false);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',u,'is_anonymous',anon)::text, false);
end $$;
create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(cond,false) then raise exception 'FAIL: %', msg; end if; raise notice 'ok - %', msg; end $$;
set client_min_messages = notice;

create temp table ids(k text primary key, v text);
grant all on ids to authenticated;

-- 1. 가족 만들기
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', false);
select pg_temp.ok((whoami()->>'state')='new', 'A 처음엔 미가입');
select pg_temp.ok((create_family('A네', '[{"name":"로니","emoji":"🦊"},{"name":"로하","emoji":"🐰"}]', 'Asia/Seoul', '엄마', true)->>'ok')::boolean, 'A 가족 생성');
select pg_temp.ok((whoami()->>'state')='parent', 'A 는 부모');
insert into ids select 'k1', id from child where name='로니';
insert into ids select 'k2', id from child where name='로하';
select pg_temp.ok((select count(*) from category)=7, '기본 카테고리 7개');
select pg_temp.ok((ensure_today()->>'ok')::boolean, '오늘 할 일 생성');
select pg_temp.ok((select count(*) from todo)>0, '예시 루틴으로 할 일 생김');

-- 같은 계정으로 가족 두 번 만들기 불가
do $$ begin perform create_family('또', '[{"name":"x"}]'); raise exception 'FAIL: 중복 가족 생성됨';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 가족 중복 생성 차단'; end $$;

select pg_temp.as_user('00000000-0000-0000-0000-00000000000b', false);
select create_family('B네', '[{"name":"민수"}]');
select pg_temp.ok((select count(*) from child)=1, 'B 는 자기 아이 1명만 보임');
select pg_temp.ok((select count(*) from todo)=0 and (select count(*) from category)=7, 'B 는 A 데이터 안 보임');

-- B 가 A 아이에게 점수 주기 시도 → 차단
do $$ begin perform add_entry(jsonb_build_object('child_id',(select v from ids where k='k1'),'raw_points',100));
  raise exception 'FAIL: 다른 가족 아이에게 점수 줌';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 다른 가족 아이 점수 차단'; end $$;

-- 테이블 직접 쓰기 차단
do $$ begin insert into entry(family_id,child_id,occurred_on,kind,label,raw_points,points)
  select family_id,id,current_date,'earn','해킹',1,1 from child limit 1; raise exception 'FAIL: 직접 insert 됨';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 테이블 직접 쓰기 차단'; end $$;

-- 2. 점수 기록 / 취소
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', false);
insert into ids select 'e1', add_entry(jsonb_build_object('child_id',(select v from ids where k='k1'),'raw_points',100,'label','심부름'))->>'id';
select add_entry(jsonb_build_object('child_id',(select v from ids where k='k1'),'kind','spend','raw_points',100,'category','게임','label','스위치'));
select pg_temp.ok((select balance from balances() where child_id=(select v from ids where k='k1')::uuid)=-30, '100 - 130(게임 1.3배) = -30');
do $$ begin update entry set points=999; raise exception 'FAIL: 기록 수정됨';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 기록 직접 수정 차단'; end $$;
reset role;
do $$ begin update entry set points=999; raise exception 'FAIL: 관리자도 기록 수정됨';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 서버 관리자 권한으로도 기록 수정 차단(트리거)'; end $$;
set role authenticated;
select pg_temp.ok((cancel_entry((select v from ids where k='e1')::uuid,'실수')->>'ok')::boolean, '기록 취소');
select pg_temp.ok((select balance from balances() where child_id=(select v from ids where k='k1')::uuid)=-130, '취소 후 잔액 -130');
select pg_temp.ok((select count(*) from entry where id=(select v from ids where k='e1')::uuid)=1, '원본 기록은 남아 있음');
select pg_temp.ok(not (cancel_entry((select v from ids where k='e1')::uuid)->>'ok')::boolean, '두 번 취소 불가');

-- 3. 아이 기기 연결
insert into ids select 'code1', create_join_code('device',(select v from ids where k='k1')::uuid,'child')->>'code';
-- Google 계정(부모 C)으로 아이 코드 입력 → 거부
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c', false);
select pg_temp.ok(not (redeem_join_code((select v from ids where k='code1'))->>'ok')::boolean, '아이 코드는 Google 계정으로 못 씀');
-- 공격자 E: 틀린 코드 5번 → 잠김 (맞는 코드를 넣어도)
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e', true);
select redeem_join_code('AAAA-AAA' || g) from generate_series(1,5) g;
select pg_temp.ok((redeem_join_code((select v from ids where k='code1'))->>'error') like '잠시 후%', '5번 틀리면 잠김');
-- 아이 폰 D
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d', true);
select pg_temp.ok((redeem_join_code(lower((select v from ids where k='code1')),'로니 폰')->>'ok')::boolean, '아이 폰 연결 (소문자 입력도 OK)');
select pg_temp.ok((whoami()->>'state')='device', 'D 는 아이 기기');
select pg_temp.ok(not (redeem_join_code((select v from ids where k='code1'))->>'ok')::boolean, '코드 재사용 불가');
select pg_temp.ok((select count(*) from child)=2, '아이 기기도 형제 이름 목록은 봄');
select pg_temp.ok((select count(*) from balances())=1, '형제 보기 꺼짐: 잔액은 자기 것만');
select pg_temp.ok((select count(distinct child_id) from todo)=1, '형제 보기 꺼짐: 할 일은 자기 것만');
select pg_temp.ok((select count(distinct child_id) from entry)=1, '기록은 자기 것만');
select pg_temp.ok((check_todo((select id from todo where child_id=(select v from ids where k='k1')::uuid limit 1))->>'ok')::boolean, '자기 할 일 체크');
do $$ begin perform add_entry(jsonb_build_object('child_id',(select v from ids where k='k1'),'raw_points',1000));
  raise exception 'FAIL: 아이가 스스로 점수 줌';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 아이 기기는 점수 못 줌'; end $$;
do $$ begin perform decide_todo((select id from todo where status='done' limit 1), true);
  raise exception 'FAIL: 아이가 스스로 승인';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 아이 기기는 승인 못 함'; end $$;
select pg_temp.ok((create_request((select v from ids where k='k1')::uuid,'spend','과자',30,'군것질')->>'ok')::boolean, '아이 신청');
do $$ begin perform create_request((select v from ids where k='k2')::uuid,'earn','몰래',100);
  raise exception 'FAIL: 형제 이름으로 신청';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 형제 이름으로 신청 불가'; end $$;

-- 4. 형제 보기 켜기
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', false);
select update_family('{"show_siblings":true}');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d', true);
select pg_temp.ok((select count(*) from balances())=2, '형제 보기 켜짐: 형제 잔액 보임');
select pg_temp.ok((select count(distinct child_id) from todo)=2, '형제 보기 켜짐: 형제 할 일 보임');
select pg_temp.ok((select count(distinct child_id) from entry)=1, '형제 보기 켜짐이어도 기록 상세는 자기 것만');
do $$ begin perform check_todo((select t.id from todo t where t.child_id=(select v from ids where k='k2')::uuid limit 1));
  raise exception 'FAIL: 형제 할 일 체크';
exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'ok - 형제 할 일은 체크 불가'; end $$;

-- 5. 부모 승인
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', false);
select pg_temp.ok((decide_todo((select id from todo where status='done' limit 1), true)->>'ok')::boolean, '부모 승인');
select pg_temp.ok((decide_request((select id from request where status='pending' limit 1), true)->>'ok')::boolean, '신청 승인');

-- 6. 기기 해제
select revoke_device((select id from device limit 1));
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d', true);
select pg_temp.ok((whoami()->>'state')='revoked', '해제된 기기');
select pg_temp.ok((select count(*) from entry)=0 and (select count(*) from child)=0, '해제된 기기는 아무것도 못 봄');

-- 7. 배우자 초대
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', false);
insert into ids select 'pcode', create_join_code('parent')->>'code';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e', true);
select pg_temp.ok(not (redeem_join_code((select v from ids where k='pcode'))->>'ok')::boolean, '익명 기기는 부모 초대 못 씀');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c', false);
select pg_temp.ok((redeem_join_code((select v from ids where k='pcode'),null,'아빠')->>'ok')::boolean, '배우자 합류');
select pg_temp.ok((select count(*) from entry)>0, '배우자도 기록 봄');

-- 8. 정기 알림 (시각 맞추기)
reset role;
insert into private.secret values ('push_hook','h'),('push_url','http://x/kp-push');
insert into public.push_sub(family_id,user_id,endpoint,p256dh,auth,role)
  select f.id,'00000000-0000-0000-0000-00000000000a','ep1','k','a','parent' from family f where name='A네';
update family set remind_times = array[to_char(now() at time zone 'Asia/Seoul','HH24:MI')];
select pg_temp.ok(private.remind_tick()=2, '알림 시각 → 2가족 모두 처리');
select pg_temp.ok(private.remind_tick()=0, '같은 분에 두 번 안 보냄');
select pg_temp.ok((select count(*) from net.calls where body->>'tag'='remind-parent')=1, '부모 알림 1건 호출');

-- 9. 탈퇴
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c', false);
select pg_temp.ok((leave_family(null)->>'deleted')='member', '부모 2명일 땐 나만 빠짐');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', false);
select pg_temp.ok(not (leave_family('틀린이름')->>'ok')::boolean, '가족 이름 틀리면 삭제 안 됨');
select pg_temp.ok((leave_family('A네')->>'deleted')='family', '가족 전체 삭제');
reset role;
select pg_temp.ok((select count(*) from entry e join child c on c.id=e.child_id where c.name in ('로니','로하'))=0, 'A네 기록 전부 삭제');
select pg_temp.ok((select count(*) from family where name='B네')=1, 'B네는 그대로');
select pg_temp.ok(not exists(select 1 from auth.users where id='00000000-0000-0000-0000-00000000000d'), '아이 기기 익명 계정도 삭제');
\echo ALL_TESTS_PASSED
