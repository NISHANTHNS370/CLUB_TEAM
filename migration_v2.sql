-- BiteSite v2 migration. Run ONCE in Supabase > SQL Editor (after schema.sql).

-- 1) Food photos + details
alter table public.menu_items add column if not exists description text default '' check (char_length(description) <= 200);
alter table public.menu_items add column if not exists image_path text;

-- 2) Student note (comment) on orders
alter table public.orders add column if not exists note text default '' check (char_length(note) <= 200);

-- 3) Support contacts (admin edits in Settings)
alter table public.settings add column if not exists support_phone text;
alter table public.settings add column if not exists support_email text;
alter table public.settings add column if not exists whatsapp text;

-- 4) Public bucket for food photos (only admin can upload/change/delete)
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('food','food',true,1048576,array['image/jpeg','image/png','image/webp']) on conflict do nothing;
create policy "food admin insert" on storage.objects for insert to authenticated with check (bucket_id='food' and public.is_admin());
create policy "food admin update" on storage.objects for update to authenticated using (bucket_id='food' and public.is_admin());
create policy "food admin delete" on storage.objects for delete to authenticated using (bucket_id='food' and public.is_admin());

-- 5) place_order now accepts a note
drop function if exists public.place_order(jsonb,text,text);
create function public.place_order(p_items jsonb, p_method text, p_shot text, p_note text default '') returns uuid
language plpgsql security definer set search_path = public as $$
declare v_items jsonb := '[]'; v_total numeric := 0; r record; p public.profiles; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  if p_method not in ('Cash','Online') then raise exception 'Bad payment method'; end if;
  if p_method = 'Online' and (p_shot is null or p_shot not like auth.uid()::text || '/%') then raise exception 'Payment screenshot required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'Bad cart'; end if;
  for r in select m.name, m.price, least(greatest((i->>'qty')::int,1),20) as qty
           from jsonb_array_elements(p_items) i
           join public.menu_items m on m.id = (i->>'id')::uuid and m.available
  loop
    v_items := v_items || jsonb_build_object('name', r.name, 'price', r.price, 'qty', r.qty);
    v_total := v_total + r.price * r.qty;
  end loop;
  if jsonb_array_length(v_items) = 0 then raise exception 'No available items'; end if;
  select * into p from public.profiles where id = auth.uid();
  insert into public.orders(user_id,cust_name,cust_roll,cust_dept,cust_phone,items,total,method,shot_path,note)
  values (auth.uid(),p.name,p.roll,p.dept,p.phone,v_items,v_total,p_method, case when p_method='Online' then p_shot end, left(coalesce(p_note,''),200))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.place_order(jsonb,text,text,text) from public, anon;
grant execute on function public.place_order(jsonb,text,text,text) to authenticated;
