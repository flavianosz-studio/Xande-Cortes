-- Rifa Xande Cortes — 08: guarda os números de pedidos vencidos (para o admin ver)
-- Rode no SQL Editor > New query > Run
alter table orders add column if not exists expired_numbers int[];

create or replace function expire_orders() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with v as (
    update orders o set status = 'expired',
      expired_numbers = (select array_agg(x.number order by x.number) from order_numbers x where x.order_id = o.id)
    where o.status = 'pending' and o.created_at < now() - interval '30 minutes'
    returning o.id
  ), d as (delete from order_numbers where order_id in (select id from v) returning 1)
  select count(*) into n from v;
  return n;
end $$;
grant execute on function expire_orders to anon, authenticated;
select expire_orders();
