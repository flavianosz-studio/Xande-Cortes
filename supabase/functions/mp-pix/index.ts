// Gera o PIX no Mercado Pago e verifica o pagamento. Nome da função: mp-pix
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const expira = (min: number) => new Date(Date.now() + min * 60000 - 3 * 3600000).toISOString().slice(0, 23) + '-03:00';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const token = (Deno.env.get('MP_ACCESS_TOKEN') ?? '').trim();
    if (!token) return json({ error: 'Secret MP_ACCESS_TOKEN não configurado no Supabase' });
    const mp = (path: string, init: RequestInit = {}) =>
      fetch(`https://api.mercadopago.com${path}`, { ...init, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) } });

    const { order_id, check } = await req.json();
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: o, error } = await sb.from('orders').select('*, campaigns(title)').eq('id', order_id).single();
    if (error || !o) return json({ error: 'Pedido não encontrado: ' + (error?.message ?? order_id) });
    if (o.status === 'paid') return json({ status: 'paid' });

    // ---- verificação do pagamento ----
    if (check) {
      // procura pelo id salvo e, se não houver, pela referência do pedido
      let pay: any = null;
      if (o.mp_payment_id) { const r = await mp(`/v1/payments/${o.mp_payment_id}`); if (r.ok) pay = await r.json(); }
      if (!pay || pay.status !== 'approved') {
        const r = await mp(`/v1/payments/search?external_reference=${encodeURIComponent(o.id)}&sort=date_created&criteria=desc`);
        if (r.ok) { const s = await r.json(); pay = (s.results || []).find((x: any) => x.status === 'approved') ?? (s.results || [])[0] ?? pay; }
      }
      const mpStatus = pay?.status ?? 'not_found';
      if (mpStatus === 'approved' && Number(pay.transaction_amount) >= Number(o.total) - 0.01) {
        const { error: ce } = await sb.rpc('system_confirm_order', { p_order: o.id });
        if (ce) { console.log('confirmar erro', ce.message); return json({ status: 'approved', confirm_error: ce.message }); }
        return json({ status: 'paid' });
      }
      return json({ status: mpStatus });
    }

    // ---- gerar PIX ----
    if (o.status === 'expired') return json({ error: 'Pedido vencido: passou de 30 minutos e as cotas foram liberadas. Faça um novo pedido.' });
    if (o.status !== 'pending') return json({ error: 'Pedido já processado' });
    if (o.pix_code) return json({ qr_code: o.pix_code, qr_code_base64: o.pix_qr });
    const first = String(o.name).trim().split(/\s+/)[0] || 'Cliente';
    const r = await mp('/v1/payments', {
      method: 'POST',
      headers: { 'X-Idempotency-Key': `pix-${o.id}` },
      body: JSON.stringify({
        transaction_amount: Math.round(Number(o.total) * 100) / 100,
        description: `${o.campaigns?.title ?? 'Rifa'} - ${o.qty} cotas`,
        payment_method_id: 'pix',
        external_reference: o.id,
        notification_url: `${Deno.env.get('SUPABASE_URL')}/functions/v1/mp-webhook`,
        date_of_expiration: expira(30),
        payer: { email: `cliente${o.phone}@gmail.com`, first_name: first },
      }),
    });
    const p = await r.json();
    console.log('MP resposta', r.status, JSON.stringify(p));
    const td = p?.point_of_interaction?.transaction_data;
    if (!r.ok || !td?.qr_code) {
      const causa = Array.isArray(p?.cause) && p.cause[0] ? ` (${p.cause[0].code}: ${p.cause[0].description})` : '';
      return json({ error: `Mercado Pago ${r.status}: ${p?.message ?? 'erro'}${causa}` });
    }
    const { error: ue } = await sb.from('orders').update({ mp_payment_id: String(p.id), pix_code: td.qr_code, pix_qr: td.qr_code_base64 }).eq('id', o.id);
    if (ue) console.log('salvar pix erro', ue.message);
    return json({ qr_code: td.qr_code, qr_code_base64: td.qr_code_base64 });
  } catch (e) {
    return json({ error: 'Erro na função: ' + String(e) });
  }
});
