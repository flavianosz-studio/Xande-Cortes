-- Rifa Xande Cortes — rode no Supabase: SQL Editor > New query > Run
create extension if not exists pgcrypto;

create table if not exists admins (user_id uuid primary key references auth.users on delete cascade);
create or replace function is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from admins where user_id = auth.uid()) $$;

create table if not exists campaigns (
  id uuid primary key default gen_random_uuid(),
  title text not null, description text default '',
  price numeric(10,2) not null default 0.50,
  total int not null default 100000 check (total > 0),
  min_qty int not null default 10, spins_every int not null default 50,
  draw_info text default 'Resultado pela Loteria Federal',
  images text[] default '{}', combos jsonb default '[]', quick int[] default '{25,50,100,250,500,1000}',
  ranking_on boolean default true, ranking_mode text default 'menor', ranking_text text default '',
  wheel jsonb default '[]',
  status text not null default 'active' check (status in ('active','sold_out','finished')),
  created_at timestamptz default now()
);
create table if not exists prize_numbers (
  id bigserial primary key, campaign_id uuid references campaigns on delete cascade,
  number int not null, prize text not null, unique (campaign_id, number)
);
create table if not exists orders (
  id text primary key default 'XC' || upper(substr(md5(random()::text), 1, 6)),
  campaign_id uuid references campaigns on delete cascade,
  name text not null, phone text not null, qty int not null check (qty > 0), total numeric(10,2) not null,
  status text not null default 'pending' check (status in ('pending','paid','canceled')),
  created_at timestamptz default now(), paid_at timestamptz
);
create index if not exists orders_phone on orders (phone);
create table if not exists order_numbers (
  campaign_id uuid references campaigns on delete cascade,
  number int not null, order_id text references orders on delete cascade,
  primary key (campaign_id, number)
);
create table if not exists spins (
  id bigserial primary key, campaign_id uuid references campaigns on delete cascade,
  phone text not null, name text, label text not null, loss boolean not null, created_at timestamptz default now()
);
create table if not exists results (
  campaign_id uuid primary key references campaigns on delete cascade,
  concurso text, draw_date date, p1 text, p2 text, drawn int, win int, order_id text references orders,
  created_at timestamptz default now()
);

alter table admins enable row level security;
alter table campaigns enable row level security;
alter table prize_numbers enable row level security;
alter table orders enable row level security;
alter table order_numbers enable row level security;
alter table spins enable row level security;
alter table results enable row level security;

-- leitura pública só do que é público; o resto via funções abaixo
create policy "campanhas públicas" on campaigns for select using (true);
create policy "cotas premiadas públicas" on prize_numbers for select using (true);
create policy "resultado público" on results for select using (true);
-- admin pode tudo
create policy "admin campaigns" on campaigns for all using (is_admin()) with check (is_admin());
create policy "admin prizes" on prize_numbers for all using (is_admin()) with check (is_admin());
create policy "admin orders" on orders for all using (is_admin()) with check (is_admin());
create policy "admin numbers" on order_numbers for all using (is_admin()) with check (is_admin());
create policy "admin spins" on spins for all using (is_admin()) with check (is_admin());
create policy "admin results" on results for all using (is_admin()) with check (is_admin());
create policy "admin self" on admins for select using (user_id = auth.uid());

-- Preço calculado no servidor (combo exato ou qty * preço)
create or replace function price_for(c campaigns, q int) returns numeric language sql immutable as $$
  select coalesce((select (x->>'price')::numeric from jsonb_array_elements(c.combos) x where (x->>'qty')::int = q limit 1), q * c.price)
$$;

create or replace function create_order(p_campaign uuid, p_name text, p_phone text, p_qty int)
returns orders language plpgsql security definer set search_path = public as $$
declare c campaigns; o orders; sold int;
begin
  select * into c from campaigns where id = p_campaign for update;
  if c.status <> 'active' then raise exception 'Campanha encerrada'; end if;
  if p_qty < c.min_qty then raise exception 'Compra mínima de % cotas', c.min_qty; end if;
  select count(*) into sold from order_numbers where campaign_id = c.id;
  if p_qty > c.total - sold then raise exception 'Restam apenas % cotas', c.total - sold; end if;
  insert into orders (campaign_id, name, phone, qty, total)
  values (c.id, trim(p_name), regexp_replace(p_phone, '\D', '', 'g'), p_qty, price_for(c, p_qty))
  returning * into o;
  return o;
end $$;

-- Confirma pagamento (admin ou webhook do gateway com service_role) e gera números aleatórios únicos
create or replace function confirm_order(p_order text) returns setof int
language plpgsql security definer set search_path = public as $$
declare o orders; c campaigns; got int := 0; n int; tries int := 0; sold int;
begin
  if not is_admin() and current_setting('request.jwt.claim.role', true) is distinct from 'service_role' then
    raise exception 'Sem permissão'; end if;
  select * into o from orders where id = p_order for update;
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
  if sold >= c.total then update campaigns set status = 'sold_out' where id = c.id; end if; -- encerra só quando esgota
  return query select number from order_numbers where order_id = o.id order by 1;
end $$;

-- "Meus títulos" por WhatsApp
create or replace function my_orders(p_phone text) returns table (id text, qty int, total numeric, status text, created_at timestamptz, numbers int[])
language sql security definer set search_path = public as $$
  select o.id, o.qty, o.total, o.status, o.created_at,
         coalesce(array(select number from order_numbers x where x.order_id = o.id order by 1), '{}')
  from orders o where o.phone = regexp_replace(p_phone, '\D', '', 'g') order by o.created_at desc
$$;

-- Estatísticas públicas: vendidos, ranking (nomes abreviados) e cotas premiadas que já saíram
create or replace function campaign_public(p_campaign uuid) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'sold', (select count(*) from order_numbers where campaign_id = p_campaign),
    'ranking', (select coalesce(jsonb_agg(r), '[]') from (
        select x.number, split_part(o.name, ' ', 1) || ' ' || left(reverse(split_part(reverse(o.name), ' ', 1)), 1) || '.' as name, o.paid_at
        from order_numbers x join orders o on o.id = x.order_id join campaigns c on c.id = x.campaign_id
        where x.campaign_id = p_campaign
        order by case when c.ranking_mode = 'maior' then -x.number else x.number end limit 3) r),
    'prizes_out', (select coalesce(jsonb_agg(jsonb_build_object('number', p.number, 'name', split_part(o.name, ' ', 1))), '[]')
        from prize_numbers p join order_numbers x on x.campaign_id = p.campaign_id and x.number = p.number
        join orders o on o.id = x.order_id where p.campaign_id = p_campaign)
  )
$$;

-- Roleta: sorteio no servidor, respeitando giros disponíveis
create or replace function spin_wheel(p_campaign uuid, p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c campaigns; ph text := regexp_replace(p_phone, '\D', '', 'g'); earned int; used int; r numeric; acc numeric := 0; w jsonb; idx int := 0; pick int := 0; nm text;
begin
  select * into c from campaigns where id = p_campaign;
  select coalesce(sum(qty / greatest(c.spins_every, 1)), 0), max(name) into earned, nm from orders where campaign_id = c.id and phone = ph and status = 'paid';
  select count(*) into used from spins where campaign_id = c.id and phone = ph;
  if earned - used <= 0 then raise exception 'Sem giros disponíveis'; end if;
  r := random() * (select sum(greatest((x->>'weight')::numeric, 0)) from jsonb_array_elements(c.wheel) x);
  for w in select * from jsonb_array_elements(c.wheel) loop
    acc := acc + greatest((w->>'weight')::numeric, 0);
    if r < acc then pick := idx; exit; end if; idx := idx + 1;
  end loop;
  w := c.wheel -> pick;
  insert into spins (campaign_id, phone, name, label, loss) values (c.id, ph, nm, w->>'label', coalesce((w->>'loss')::boolean, false));
  return jsonb_build_object('index', pick, 'label', w->>'label', 'loss', coalesce((w->>'loss')::boolean, false), 'left', earned - used - 1);
end $$;

grant execute on function create_order, my_orders, campaign_public, spin_wheel to anon, authenticated;
grant execute on function confirm_order to authenticated;

-- Depois de criar seu usuário em Authentication > Users, torne-o admin:
-- insert into admins (user_id) values ('COLE-AQUI-O-UUID-DO-USUARIO');
