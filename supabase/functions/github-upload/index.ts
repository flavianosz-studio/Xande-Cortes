// Envia fotos da campanha para o repositório do GitHub (pasta /fotos).
// Secrets necessários (Edge Functions > Secrets):
//   GITHUB_TOKEN  = token fine-grained com permissão "Contents: Read and write" só neste repositório
//   GITHUB_REPO   = usuario/repositorio   (ex: alexandre/xandecortes)
//   GITHUB_BRANCH = main
//   SITE_URL      = https://xandecortes.com.br
// Deploy: supabase functions deploy github-upload
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    // só admin logado pode enviar
    const auth = req.headers.get('Authorization') ?? '';
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
    const { data: isAdmin } = await sb.rpc('is_admin');
    if (isAdmin !== true) return json({ error: 'Sem permissão' }, 403);

    const { campaign_id, content_base64 } = await req.json();
    if (!campaign_id || !content_base64) return json({ error: 'Dados incompletos' }, 400);
    if (content_base64.length > 8_000_000) return json({ error: 'Foto muito grande' }, 413);

    const name = `${Date.now()}-${Math.random().toString(36).slice(2, 7)}.jpg`;
    const path = `fotos/${campaign_id}/${name}`;
    const repo = Deno.env.get('GITHUB_REPO')!, branch = Deno.env.get('GITHUB_BRANCH') ?? 'main';
    const r = await fetch(`https://api.github.com/repos/${repo}/contents/${path}`, {
      method: 'PUT',
      headers: { Authorization: `Bearer ${Deno.env.get('GITHUB_TOKEN')}`, Accept: 'application/vnd.github+json', 'Content-Type': 'application/json', 'User-Agent': 'xandecortes-site' },
      body: JSON.stringify({ message: `Foto da campanha ${campaign_id}`, content: content_base64, branch }),
    });
    const out = await r.json();
    if (!r.ok) return json({ error: out?.message ?? 'Erro no GitHub' }, 502);
    const site = (Deno.env.get('SITE_URL') ?? '').replace(/\/$/, '');
    return json({ url: `${site}/${path}`, path });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
