// 포인트통장 v2 웹 푸시 발송 함수
// DB(private.notify)가 x-kp-hook 비밀값과 함께 호출한다. (JWT 검증 대신 자체 비밀값 검증 → verify_jwt=false 로 배포)
// 필요한 함수 시크릿: KP_HOOK, VAPID_PUBLIC, VAPID_PRIVATE, VAPID_SUBJECT(예: mailto:you@example.com)
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const HOOK = Deno.env.get("KP_HOOK") || "";
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") || "mailto:admin@example.com",
  Deno.env.get("VAPID_PUBLIC")!,
  Deno.env.get("VAPID_PRIVATE")!,
);

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  try {
    if (!HOOK || req.headers.get("x-kp-hook") !== HOOK) return json({ ok: false, error: "forbidden" }, 403);
    const m = await req.json();
    let q = sb.from("push_sub").select("id,endpoint,p256dh,auth");
    if (m.target === "parent") q = q.eq("family_id", m.family_id).eq("role", "parent");
    else if (m.target === "child") q = q.eq("family_id", m.family_id).eq("role", "child").eq("child_id", m.child_id);
    else if (m.target === "endpoint") q = q.eq("endpoint", m.endpoint);
    else return json({ ok: false, error: "bad target" }, 400);
    const { data: subs, error } = await q;
    if (error) throw error;
    const payload = JSON.stringify({ title: m.title, body: m.body, tag: m.tag || undefined, url: m.url || "./" });
    let sent = 0;
    const gone: string[] = [];
    await Promise.all((subs || []).map(async (s: any) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          payload,
          { TTL: 86400, urgency: "high" },
        );
        sent++;
        await sb.from("push_sub").update({ last_ok: new Date().toISOString() }).eq("id", s.id);
      } catch (e: any) {
        const code = e?.statusCode;
        if (code === 404 || code === 410) gone.push(s.id);
        else console.error("push fail", code, e?.body || String(e));
      }
    }));
    if (gone.length) await sb.from("push_sub").delete().in("id", gone);
    return json({ ok: true, sent, removed: gone.length, total: subs?.length || 0 });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String(e) }, 500);
  }
});
