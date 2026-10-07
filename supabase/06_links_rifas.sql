-- Rifa Xande Cortes — 06: várias rifas com link personalizado
-- Rode no SQL Editor > New query > Run
alter table campaigns add column if not exists slug text;
update campaigns set slug = 'rifa-' || substr(replace(id::text, '-', ''), 1, 6) where slug is null or slug = '';
create unique index if not exists campaigns_slug_key on campaigns (slug);
