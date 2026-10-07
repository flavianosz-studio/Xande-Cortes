-- Rifa Xande Cortes — 07: cotas reservadas ao gerar o PIX, vencimento em 30 min
-- Rode no SQL Editor > New query > Run (depois do 04 e do 05)

alter table orders drop constraint if exists orders_status_check;
alter table orders add constraint orders_status_check check (status in ('pending','paid','canceled','expired'));

-- vence pedidos não pagos em 30 min e libera os números reservados
create or replace function expire_orders() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with v as (
    update orders set status = 'expired'
    where status = 'pending' and created_at < now() - interval '30 minutes'
    returning id
  ), d as (delete from order_numbers where order_id in (select id from v) returning 1)
  select count(*) into n from v;
  return n;
end $$;

-- sorteia números livres para um pedido (até completar a quantidade)
create or replace function assign_numbers(p_order text) returns void
language plpgsql security definer set search_path = public as $$
declare o orders; c campaigns; have int; got int := 0; n int; tries int := 0;
begin
  select * into o from orders where id = p_order;
  select * into c from campaigns where id = o.campaign_id for update;
  select count(*) into have from order_numbers where order_id = o.id;
  while have + got < o.qty and tries < o.qty * 30 loop
    n := floor(random() * c.total)::int; tries := tries + 1;
    insert into order_numbers values (c.id, n, o.id) on conflict do nothing;
    if found then got := got + 1; end if;
  end loop;
  if have + got < o.qty then
    insert into order_numbers
      select c.id, g, o.id from generate_series(0, c.total - 1) g
      where not exists (select 1 from order_numbers x where x.campaign_id = c.id and x.number = g)
      limit o.qty - have - got;
  end if;
end $$;
revoke all on function assign_numbers(text) from public, anon, authenticated;

-- cria o pedido já reservando os números
create or replace function create_order(p_campaign uuid, p_name text, p_phone text, p_qty int)
returns orders language plpgsql security definer set search_path = public as $$
declare c campaigns; o orders; used int;
begin
  perform expire_orders();
  select * into c from campaigns where id = p_campaign for update;
  if c.status <> 'active' then raise exception 'Campanha encerrada'; end if;
  if p_qty < c.min_qty then raise exception 'Compra mínima de % cotas', c.min_qty; end if;
  select count(*) into used from order_numbers where campaign_id = c.id;
  if p_qty > c.total - used then raise exception 'Restam apenas % cotas disponíveis no momento', c.total - used; end if;
  insert into orders (campaign_id, name, phone, qty, total)
  values (c.id, trim(p_name), regexp_replace(p_phone, '\D', '', 'g'), p_qty, price_for(c, p_qty))
  returning * into o;
  perform assign_numbers(o.id);
  return o;
end $$;

-- confirmação: usa os números reservados; se o pedido venceu e foi pago depois, sorteia novos
create or replace function system_confirm_order(p_order text) returns setof int
language plpgsql security definer set search_path = public as $$
declare o orders; c campaigns; sold int;
begin
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Pedido % não encontrado', p_order; end if;
  if o.status <> 'paid' then
    perform assign_numbers(o.id);
    update orders set status = 'paid', paid_at = now() where id = o.id;
    select * into c from campaigns where id = o.campaign_id;
    select count(*) into sold from order_numbers x join orders y on y.id = x.order_id where x.campaign_id = c.id and y.status = 'paid';
    if sold >= c.total then update campaigns set status = 'sold_out' where id = c.id; end if;
  end if;
  return query select number from order_numbers where order_id = o.id order by 1;
end $$;
revoke all on function system_confirm_order(text) from public, anon, authenticated;
grant execute on function system_confirm_order(text) to service_role;

-- status + números (reservados ou pagos)
create or replace function order_status(p_order text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform expire_orders();
  return (select jsonb_build_object('status', o.status, 'created_at', o.created_at,
    'numbers', coalesce((select jsonb_agg(number order by number) from order_numbers where order_id = o.id), '[]'::jsonb))
    from orders o where o.id = p_order);
end $$;

-- estatísticas públicas contam só cotas PAGAS
create or replace function campaign_public(p_campaign uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform expire_orders();
  return jsonb_build_object(
    'sold', (select count(*) from order_numbers x join orders o on o.id = x.order_id where x.campaign_id = p_campaign and o.status = 'paid'),
    'ranking', (select coalesce(jsonb_agg(r), '[]') from (
        select x.number, split_part(o.name, ' ', 1) || ' ' || left(reverse(split_part(reverse(o.name), ' ', 1)), 1) || '.' as name, o.paid_at
        from order_numbers x join orders o on o.id = x.order_id join campaigns c on c.id = x.campaign_id
        where x.campaign_id = p_campaign and o.status = 'paid'
        order by case when c.ranking_mode = 'maior' then -x.number else x.number end limit 3) r),
    'prizes_out', (select coalesce(jsonb_agg(jsonb_build_object('number', p.number, 'name', split_part(o.name, ' ', 1))), '[]')
        from prize_numbers p join order_numbers x on x.campaign_id = p.campaign_id and x.number = p.number
        join orders o on o.id = x.order_id where p.campaign_id = p_campaign and o.status = 'paid')
  );
end $$;

grant execute on function create_order, order_status, campaign_public to anon, authenticated;
grant execute on function expire_orders to anon, authenticated;

-- (opcional) vencimento automático a cada minuto mesmo sem ninguém no site
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('xc-expire-orders', '* * * * *', 'select public.expire_orders()');
exception when others then raise notice 'pg_cron indisponível — o vencimento roda quando o site é acessado';
end $$;

-- vence agora os pedidos antigos que já passaram de 30 min
select expire_orders();
