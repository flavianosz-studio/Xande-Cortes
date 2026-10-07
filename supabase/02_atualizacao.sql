-- Rifa Xande Cortes — atualização 02. Rode no SQL Editor (depois do schema.sql).
alter table orders add column if not exists mp_payment_id text;
alter table orders add column if not exists pix_code text;
alter table orders add column if not exists pix_qr text;
alter table results add column if not exists winner_name text;

-- permite confirmação pelo webhook do Mercado Pago (service_role) além do admin
create or replace function confirm_order(p_order text) returns setof int
language plpgsql security definer set search_path = public as $$
declare o orders; c campaigns; got int := 0; n int; tries int := 0; sold int;
begin
  if not is_admin() and coalesce(auth.jwt()->>'role', '') <> 'service_role' then raise exception 'Sem permissão'; end if;
  select * into o from orders where id = p_order for update;
  if o is null then raise exception 'Pedido não encontrado'; end if;
  if o.status = 'paid' then return query select number from order_numbers where order_id = o.id order by 1; return; end if;
  select * into c from campaigns where id = o.campaign_id for update;
  while got < o.qty and tries < o.qty * 30 loop
    n := floor(random() * c.total)::int; tries := tries + 1;
    insert into order_numbers values (c.id, n, o.id) on conflict do nothing;
    if found then got := got + 1; end if;
  end loop;
  if got < o.qty then
    insert into order_numbers
      select c.id, g, o.id from generate_series(0, c.total - 1) g
      where not exists (select 1 from order_numbers x where x.campaign_id = c.id and x.number = g)
      limit o.qty - got;
  end if;
  update orders set status = 'paid', paid_at = now() where id = o.id;
  select count(*) into sold from order_numbers where campaign_id = c.id;
  if sold >= c.total then update campaigns set status = 'sold_out' where id = c.id; end if;
  return query select number from order_numbers where order_id = o.id order by 1;
end $$;

-- status de um pedido (usado pelo checkout para detectar o pagamento)
create or replace function order_status(p_order text) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('status', o.status,
    'numbers', coalesce((select jsonb_agg(number order by number) from order_numbers where order_id = o.id), '[]'::jsonb))
  from orders o where o.id = p_order
$$;

-- giros disponíveis
create or replace function spins_left(p_campaign uuid, p_phone text) returns int
language sql security definer set search_path = public as $$
  select greatest(0,
    coalesce((select sum(qty / nullif(c.spins_every, 0)) from orders o, campaigns c
              where c.id = p_campaign and o.campaign_id = c.id and o.phone = regexp_replace(p_phone, '\D', '', 'g') and o.status = 'paid'), 0)::int
    - (select count(*) from spins where campaign_id = p_campaign and phone = regexp_replace(p_phone, '\D', '', 'g'))::int)
$$;

-- roleta desativada quando spins_every = 0
create or replace function spin_wheel(p_campaign uuid, p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c campaigns; ph text := regexp_replace(p_phone, '\D', '', 'g'); left_ int; r numeric; acc numeric := 0; w jsonb; idx int := 0; pick int := 0; nm text;
begin
  select * into c from campaigns where id = p_campaign;
  if c.spins_every <= 0 or jsonb_array_length(c.wheel) < 2 then raise exception 'Roleta indisponível'; end if;
  left_ := spins_left(p_campaign, ph);
  if left_ <= 0 then raise exception 'Sem giros disponíveis'; end if;
  select max(name) into nm from orders where campaign_id = c.id and phone = ph;
  r := random() * (select sum(greatest((x->>'weight')::numeric, 0)) from jsonb_array_elements(c.wheel) x);
  for w in select * from jsonb_array_elements(c.wheel) loop
    acc := acc + greatest((w->>'weight')::numeric, 0);
    if r < acc then pick := idx; exit; end if; idx := idx + 1;
  end loop;
  w := c.wheel -> pick;
  insert into spins (campaign_id, phone, name, label, loss) values (c.id, ph, nm, w->>'label', coalesce((w->>'loss')::boolean, false));
  return jsonb_build_object('index', pick, 'label', w->>'label', 'loss', coalesce((w->>'loss')::boolean, false), 'left', left_ - 1);
end $$;

-- prêmios da roleta para a página Ganhadores (nome abreviado)
create or replace function public_wins(p_campaign uuid) returns table (name text, label text, created_at timestamptz)
language sql security definer set search_path = public as $$
  select split_part(coalesce(name, ''), ' ', 1) || ' ' || left(reverse(split_part(reverse(coalesce(name, '')), ' ', 1)), 1) || '.', label, created_at
  from spins where campaign_id = p_campaign and not loss order by created_at desc limit 50
$$;

grant execute on function order_status, spins_left, spin_wheel, public_wins to anon, authenticated;
