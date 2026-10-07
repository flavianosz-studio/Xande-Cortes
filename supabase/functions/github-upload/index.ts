// Envia fotos da campanha para o repositório do GitHub (pasta /fotos).
// Secrets (Edge Functions > Secrets):
//   GITHUB_TOKEN  = token com permissão "Contents: Read and write" no repositório do site
//   GITHUB_REPO   = usuario/repositorio   (ex: xandecortes/site)
//   GITHUB_BRANCH = main
//   SITE_URL      = https://xandecortes.com.br
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
// sempre 200 para o site conseguir mostrar a mensagem de erro real
const json = (b: unknown) => new Response(JSON.stringify(b), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const auth = req.headers.get('Authorization') ?? '';
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
    const { data: isAdmin } = await sb.rpc('is_admin');
    if (isAdmin !== true) return json({ error: 'Sem permissão: entre no painel com um usuário admin' });

    const token = (Deno.env.get('GITHUB_TOKEN') ?? '').trim();
    const repo = (Deno.env.get('GITHUB_REPO') ?? '').trim().replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '').replace(/\/$/, '');
    const branch = (Deno.env.get('GITHUB_BRANCH') ?? 'main').trim();
    if (!token) return json({ error: 'Secret GITHUB_TOKEN não configurado' });
    if (!/^[^/]+\/[^/]+$/.test(repo)) return json({ error: `Secret GITHUB_REPO inválido ("${repo}"). Use usuario/repositorio` });

    const { campaign_id, content_base64 } = await req.json();
    if (!campaign_id || !content_base64) return json({ error: 'Dados incompletos' });
    if (content_base64.length > 8_000_000) return json({ error: 'Foto muito grande' });

    const path = `fotos/${campaign_id}/${Date.now()}-${Math.random().toString(36).slice(2, 7)}.jpg`;
    const r = await fetch(`https://api.github.com/repos/${repo}/contents/${path}`, {
      method: 'PUT',
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'Content-Type': 'application/json', 'User-Agent': 'xandecortes-site' },
      body: JSON.stringify({ message: `Foto da campanha ${campaign_id}`, content: content_base64, branch }),
    });
    const out = await r.json().catch(() => ({}));
    if (!r.ok) {
      const dica = r.status === 401 ? ' (token inválido ou expirado)' : r.status === 403 ? ' (token sem permissão Contents: Read and write)' : r.status === 404 ? ' (repositório ou branch não encontrado, ou token sem acesso a ele)' : '';
      return json({ error: `GitHub ${r.status}: ${out?.message ?? 'erro'}${dica}` });
    }
    const site = (Deno.env.get('SITE_URL') ?? '').trim().replace(/\/$/, '');
    // CDN do GitHub mostra a foto na hora; o site publica a cópia em /fotos depois do deploy
    const cdn = `https://cdn.jsdelivr.net/gh/${repo}@${branch}/${path}`;
    return json({ url: site ? `${site}/${path}` : cdn, cdn, path });
  } catch (e) {
    return json({ error: 'Erro na função: ' + String(e) });
  }
});
