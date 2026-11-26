// Fotos da campanha guardadas no GitHub (pasta /fotos).
// POST = envia a foto (só admin) | GET ?path=fotos/... = mostra a foto
// Publicar com "Verify JWT" DESLIGADO (as fotos são abertas direto no site)
// Secrets: GITHUB_TOKEN, GITHUB_REPO (usuario/repositorio), GITHUB_BRANCH (main)
// Opcional: GITHUB_AUTHOR_NAME e GITHUB_AUTHOR_EMAIL (o mesmo e-mail da sua conta Vercel/GitHub)
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (b: unknown) => new Response(JSON.stringify(b), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } });

const token = () => (Deno.env.get('GITHUB_TOKEN') ?? '').trim();
const repo = () => (Deno.env.get('GITHUB_REPO') ?? '').trim().replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '').replace(/\/$/, '');
const branch = () => (Deno.env.get('GITHUB_BRANCH') ?? 'main').trim();
const gh = (path: string, init: RequestInit = {}) => fetch(`https://api.github.com/repos/${repo()}/contents/${path}`, {
  ...init, headers: { Authorization: `Bearer ${token()}`, Accept: 'application/vnd.github+json', 'User-Agent': 'xandecortes-site', ...(init.headers ?? {}) },
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  // ---- mostrar foto ----
  if (req.method === 'GET') {
    const path = new URL(req.url).searchParams.get('path') ?? '';
    if (!/^fotos\/[\w-]+\/[\w.-]+\.(jpg|jpeg|png|webp)$/i.test(path)) return new Response('not found', { status: 404, headers: cors });
    const r = await gh(`${path}?ref=${branch()}`, { headers: { Accept: 'application/vnd.github.raw' } });
    if (!r.ok) return new Response('not found', { status: 404, headers: cors });
    return new Response(r.body, { headers: { ...cors, 'Content-Type': 'image/jpeg', 'Cache-Control': 'public, max-age=31536000, immutable' } });
  }

  // ---- enviar foto ----
  try {
    const auth = req.headers.get('Authorization') ?? '';
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
    const { data: isAdmin } = await sb.rpc('is_admin');
    if (isAdmin !== true) return json({ error: 'Sem permissão: entre no painel com um usuário admin' });
    if (!token()) return json({ error: 'Secret GITHUB_TOKEN não configurado' });
    if (!/^[^/]+\/[^/]+$/.test(repo())) return json({ error: `Secret GITHUB_REPO inválido ("${repo()}"). Use usuario/repositorio` });

    const { campaign_id, content_base64 } = await req.json();
    if (!campaign_id || !content_base64) return json({ error: 'Dados incompletos' });
    if (content_base64.length > 8_000_000) return json({ error: 'Foto muito grande' });

    const path = `fotos/${campaign_id}/${Date.now()}-${Math.random().toString(36).slice(2, 7)}.jpg`;
    const name = (Deno.env.get('GITHUB_AUTHOR_NAME') ?? '').trim(), email = (Deno.env.get('GITHUB_AUTHOR_EMAIL') ?? '').trim();
    const body: Record<string, unknown> = { message: `Foto da campanha [skip ci]`, content: content_base64, branch: branch() };
    if (name && email) { body.author = { name, email }; body.committer = { name, email }; }
    const r = await gh(path, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const out = await r.json().catch(() => ({}));
    if (!r.ok) {
      const dica = r.status === 401 ? ' (token inválido ou expirado)' : r.status === 403 ? ' (token sem permissão Contents: Read and write)' : r.status === 404 ? ' (repositório ou branch não encontrado, ou token sem acesso a ele)' : '';
      return json({ error: `GitHub ${r.status}: ${out?.message ?? 'erro'}${dica}` });
    }
    // a foto é servida por esta função: aparece na hora, sem depender de deploy na Vercel
    const url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/github-upload?path=${encodeURIComponent(path)}`;
    return json({ url, path });
  } catch (e) {
    return json({ error: 'Erro na função: ' + String(e) });
  }
});
