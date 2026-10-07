-- Rifa Xande Cortes — atualização 04: confirmação automática à prova de falhas
-- Rode no SQL Editor > New query > Run

-- núcleo da confirmação (sem checagem de usuário) — só o servidor (service_role) pode chamar
create or replace function system_confirm_order(p_order text) returns setof int
language plpgsql security definer set search_path = public as $$
declare o orders; c campaigns; got int := 0; n int; tries int := 0; sold int;
begin
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Pedido % não encontrado', p_order; end if;
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
revoke all on function system_confirm_order(text) from public, anon, authenticated;
grant execute on function system_confirm_order(text) to service_role;

-- confirmação manual pelo admin usa o mesmo núcleo
create or replace function confirm_order(p_order text) returns setof int
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Sem permissão'; end if;
  return query select * from system_confirm_order(p_order);
end $$;
grant execute on function confirm_order(text) to authenticated;

-- garante as colunas do PIX
alter table orders add column if not exists mp_payment_id text;
alter table orders add column if not exists pix_code text;
alter table orders add column if not exists pix_qr text;
