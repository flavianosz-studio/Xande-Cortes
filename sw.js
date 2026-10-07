const V='xc-v2';const STATIC=[/fonts\.(googleapis|gstatic)\.com/,/cdn\.jsdelivr\.net/,/\.(png|jpg|jpeg|webp|svg|woff2?)$/i];
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{const r=e.request;if(r.method!=='GET')return;const u=r.url;if(/supabase\.co/.test(u))return;
if(STATIC.some(x=>x.test(u))){e.respondWith(caches.open(V).then(c=>c.match(r).then(hit=>hit||fetch(r).then(res=>{if(res.ok||res.type==='opaque')c.put(r,res.clone());return res;}))));return;}
if(r.mode==='navigate'){e.respondWith(fetch(r).then(res=>{caches.open(V).then(c=>c.put(r,res.clone()));return res;}).catch(()=>caches.match(r)));}});