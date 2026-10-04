-- =====================================================================
-- v1(기존 한 가족용 kp_* 테이블) → v2 이전
--
-- 1) v1 프로젝트에서 export 쿼리(아래 맨 끝 주석)를 실행해 JSON 하나를 얻는다.
-- 2) v2 에서 부모가 가입해 가족을 만든다(아이 이름은 v1 과 같게).
-- 3) v2 에서: select private.import_v1('<family_id>', '<JSON>'::jsonb);
--    아이는 이름으로 짝지어진다. 새 가족에 점수 기록이 이미 있으면 거부(두 번 이전 방지).
--    가족의 루틴·할 일·카테고리·규칙은 v1 것으로 교체된다.
-- =====================================================================
create or replace function private.import_v1(p_family uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c jsonb; r jsonb; v_new uuid; v_n_entry int := 0; v_n_todo int := 0; k text;
begin
  -- 비어 있는 목록(jsonb_agg 결과 null)은 빈 배열로
  foreach k in array array['children','entries','todos','routines','requests','goals','categories','rules'] loop
    if jsonb_typeof(d->k) is distinct from 'array' then d := jsonb_set(d, array[k], '[]'); end if;
  end loop;
  if exists (select 1 from public.entry where family_id = p_family) then
    raise exception '이 가족에는 이미 점수 기록이 있어요 (이전은 한 번만)';
  end if;

  create temp table m_child(old text primary key, new uuid) on commit drop;
  create temp table m_entry(old text primary key, new uuid) on commit drop;
  create temp table m_routine(old text primary key, new uuid) on commit drop;

  for c in select * from jsonb_array_elements(d->'children') loop
    select id into v_new from public.child where family_id = p_family and name = c->>'name' and archived_at is null;
    if v_new is null then raise exception '새 가족에 % 아이가 없어요', c->>'name'; end if;
    update public.child set emoji = coalesce(c->>'emoji', emoji), color = coalesce(c->>'color', color),
           weekly_goal = coalesce((d->'config'->'weekly_goal'->>(c->>'id'))::int, weekly_goal)
     where id = v_new;
    insert into m_child values (c->>'id', v_new);
  end loop;

  -- 설정
  update public.family set
    won_per_point = coalesce((d->'config'->>'won_per_point')::int, won_per_point),
    remind_times  = coalesce((select array_agg(t order by t) from jsonb_array_elements_text(d->'config'->'remind_times') t), remind_times)
   where id = p_family;

  -- 카테고리·규칙 교체
  delete from public.category where family_id = p_family;
  insert into public.category(family_id, name, weight, emoji, hint, sort)
  select p_family, x->>'name', (x->>'weight')::numeric, coalesce(x->>'emoji','🏷️'), x->>'hint', coalesce((x->>'sort')::int, 0)
    from jsonb_array_elements(d->'categories') x;
  delete from public.rule where family_id = p_family;
  insert into public.rule(family_id, label, points, group_name, active, sort)
  select p_family, x->>'label', (x->>'points')::int, coalesce(x->>'group_name','기본'), coalesce((x->>'active')::boolean, true), coalesce((x->>'sort')::int, 0)
    from jsonb_array_elements(d->'rules') x;

  -- 루틴 교체 (예시 루틴·오늘 할 일 제거)
  delete from public.todo where family_id = p_family;
  delete from public.routine where family_id = p_family;
  for r in select * from jsonb_array_elements(d->'routines') loop
    insert into public.routine(family_id, child_id, label, points, slot, dows, active, sort, created_at)
    values (p_family, (select new from m_child where old = r->>'child_id'), r->>'label', (r->>'points')::int,
            coalesce(r->>'slot','낮'), (select array_agg(x::int) from jsonb_array_elements_text(r->'dows') x),
            coalesce((r->>'active')::boolean, true), coalesce((r->>'sort')::int, 0), coalesce((r->>'created_at')::timestamptz, now()))
    returning id into v_new;
    insert into m_routine values (r->>'id', v_new);
  end loop;

  -- 점수 기록 (원래 날짜·시각 유지)
  for r in select * from jsonb_array_elements(d->'entries') order by (value->>'id')::bigint loop
    insert into public.entry(family_id, child_id, occurred_on, kind, label, raw_points, weight, points, category, memo, source, created_at)
    values (p_family, (select new from m_child where old = r->>'child_id'), (r->>'occurred_on')::date,
            case when r->>'kind' in ('earn','spend','adjust') then r->>'kind' else 'adjust' end,
            coalesce(r->>'label',''), coalesce((r->>'raw_points')::int, 0), coalesce((r->>'weight')::numeric, 1),
            (r->>'points')::int, r->>'category', r->>'memo', coalesce(r->>'source','v1'), coalesce((r->>'created_at')::timestamptz, now()))
    returning id into v_new;
    insert into m_entry values (r->>'id', v_new);
    v_n_entry := v_n_entry + 1;
  end loop;

  for r in select * from jsonb_array_elements(d->'todos') loop
    insert into public.todo(family_id, child_id, todo_date, label, points, slot, routine_id, status, entry_id, done_at, decided_at, created_at)
    values (p_family, (select new from m_child where old = r->>'child_id'), (r->>'todo_date')::date, r->>'label', (r->>'points')::int,
            coalesce(r->>'slot','낮'), (select new from m_routine where old = r->>'routine_id'), r->>'status',
            (select new from m_entry where old = r->>'entry_id'), (r->>'done_at')::timestamptz, (r->>'decided_at')::timestamptz,
            coalesce((r->>'created_at')::timestamptz, now()))
    on conflict do nothing;
    v_n_todo := v_n_todo + 1;
  end loop;

  insert into public.request(family_id, child_id, kind, label, raw_points, category, memo, status, entry_id, created_at, decided_at)
  select p_family, (select new from m_child where old = x->>'child_id'), x->>'kind', x->>'label', greatest(1, abs((x->>'raw_points')::int)),
         x->>'category', x->>'memo', x->>'status', (select new from m_entry where old = x->>'entry_id'),
         coalesce((x->>'created_at')::timestamptz, now()), (x->>'decided_at')::timestamptz
    from jsonb_array_elements(d->'requests') x;

  insert into public.goal(family_id, child_id, title, price_won, category, status, created_at, achieved_at)
  select p_family, (select new from m_child where old = x->>'child_id'), x->>'title', (x->>'price_won')::int,
         coalesce(x->>'category','일반'), x->>'status', coalesce((x->>'created_at')::timestamptz, now()), (x->>'achieved_at')::timestamptz
    from jsonb_array_elements(d->'goals') x;

  -- 이전 기록으로 이미 받을 자격이 있는 배지 지급
  perform private.award_badges(id) from public.child where family_id = p_family;

  return jsonb_build_object('ok', true, 'entries', v_n_entry, 'todos', v_n_todo,
    'badges', (select count(*) from public.badge where family_id = p_family),
    'balances', (select jsonb_object_agg(c.name, (select coalesce(sum(points),0) from public.entry e where e.child_id = c.id))
                   from public.child c where c.family_id = p_family));
end $$;
revoke execute on function private.import_v1(uuid, jsonb) from public, anon, authenticated;

/* v1 프로젝트에서 실행할 export 쿼리:
select jsonb_build_object(
  'children',   (select jsonb_agg(to_jsonb(c)) from kp_child c),
  'entries',    (select jsonb_agg(to_jsonb(e)) from kp_entry e),
  'todos',      (select jsonb_agg(to_jsonb(t)) from kp_todo t),
  'routines',   (select jsonb_agg(to_jsonb(r)) from kp_routine r),
  'requests',   (select jsonb_agg(to_jsonb(q)) from kp_request q),
  'goals',      (select jsonb_agg(to_jsonb(g)) from kp_goal g),
  'categories', (select jsonb_agg(to_jsonb(k)) from kp_category k),
  'rules',      (select jsonb_agg(to_jsonb(r)) from kp_rule r),
  'config',     (select jsonb_object_agg(k, v) from kp_config),
  'balances',   (select jsonb_object_agg(name, balance) from kp_balance)
);
*/
