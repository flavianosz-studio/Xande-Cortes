-- Rifa Xande Cortes — 05: desconto progressivo (quanto mais cotas, menor o valor de cada uma)
-- Rode no SQL Editor > New query > Run
alter table campaigns add column if not exists tiers jsonb default '[]';
update campaigns set tiers = '[]' where tiers is null;

create or replace function price_for(c campaigns, q int) returns numeric language sql stable as $$
  select coalesce(
    (select (x->>'price')::numeric from jsonb_array_elements(coalesce(c.combos,'[]')) x where (x->>'qty')::int = q limit 1),
    round(q * least(c.price, coalesce((select min((t->>'price')::numeric) from jsonb_array_elements(coalesce(c.tiers,'[]')) t
      where (t->>'from')::int <= q and (t->>'price')::numeric > 0), c.price)), 2)
  )
$$;
