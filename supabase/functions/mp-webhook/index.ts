// Recebe avisos do Mercado Pago e confirma o pedido quando o PIX é aprovado.
// Nome da função: mp-webhook — publicar com "Verify JWT" DESLIGADO
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    let body: any = {};
    try { body = await req.json(); } catch { /* MP às vezes manda só query string */ }
    const type = body?.type ?? body?.topic ?? url.searchParams.get('type') ?? url.searchParams.get('topic');
    const id = body?.data?.id ?? url.searchParams.get('data.id') ?? url.searchParams.get('id');
    console.log('webhook recebido', type, id);
    if (!id || (type && !String(type).includes('payment'))) return new Response('ignored', { status: 200 });

    const r = await fetch(`https://api.mercadopago.com/v1/payments/${id}`, { headers: { Authorization: `Bearer ${(Deno.env.get('MP_ACCESS_TOKEN') ?? '').trim()}` } });
    const p = await r.json();
    console.log('pagamento', id, r.status, p.status, p.external_reference);
    if (!r.ok) return new Response('mp error', { status: 200 });

    if (p.status === 'approved' && p.external_reference) {
      const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
      const { data: o } = await sb.from('orders').select('id,total,status').eq('id', p.external_reference).single();
      if (o && o.status === 'pending' && Number(p.transaction_amount) >= Number(o.total) - 0.01) {
        const { error } = await sb.rpc('system_confirm_order', { p_order: o.id });
        console.log('confirmado', o.id, error ? 'ERRO ' + error.message : 'ok');
      }
    }
    return new Response('ok', { status: 200 });
  } catch (e) {
    console.log('erro', String(e));
    return new Response('ok', { status: 200 });
  }
});
