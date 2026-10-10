-- schema.sql 다음에 실행. pg_cron / pg_net 확장이 필요하다.
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- 매분: 가족별 정기 알림 (각 가족 시간대 기준)
select cron.schedule('kp-remind', '* * * * *', $$select private.remind_tick()$$);

-- 매일 새벽: 오래된 코드·시도 기록 정리
select cron.schedule('kp-cleanup', '17 18 * * *', $$
  delete from private.join_code where expires_at < now() - interval '7 days';
  delete from private.join_attempt where at < now() - interval '1 day';
$$);
