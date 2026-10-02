-- Chạy trong Supabase > SQL Editor (xóa bản cũ nếu có)
drop table if exists public.appointments cascade;
drop table if exists public.tickets cascade;

create table public.tickets (
  id uuid primary key default gen_random_uuid(),
  visit_date date not null,
  dept text not null check (dept in ('nhi','san')),          -- nhi = Khám Nhi, san = Khám Sản
  queue_no int not null,                                      -- số thứ tự (đăng ký trước = số 1)
  full_name text not null check (char_length(full_name) between 2 and 100),
  phone text not null check (phone ~ '^[0-9+ ]{9,15}$'),
  age_text text,
  gender text,
  category text not null,                                     -- nhóm bệnh để bác sĩ phân loại
  symptoms text check (char_length(symptoms) <= 800),
  details jsonb not null default '{}',                        -- cân nặng, tuổi thai, thuốc, dị ứng...
  urgent boolean not null default false,                      -- có dấu hiệu nguy hiểm
  status text not null default 'waiting' check (status in ('waiting','done','absent','cancelled')),
  created_at timestamptz not null default now(),
  unique (visit_date, dept, queue_no)
);

alter table public.tickets enable row level security;

-- Bác sĩ được phép xem dữ liệu. dept: 'all' = xem cả 2 phòng, 'nhi' = chỉ phòng Nhi, 'san' = chỉ phòng Sản
create table if not exists public.admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.admins add column if not exists dept text not null default 'all';
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;
create or replace function public.my_dept() returns text
language sql security definer stable set search_path = public as $$
  select dept from admins where user_id = auth.uid();
$$;
create or replace function public.can_see(d text) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid() and (dept = 'all' or dept = d));
$$;
grant execute on function public.is_admin(), public.my_dept(), public.can_see(text) to authenticated;

drop policy if exists "staff read" on public.tickets;
drop policy if exists "staff update" on public.tickets;
drop policy if exists "admin read" on public.tickets;
drop policy if exists "admin update" on public.tickets;
create policy "admin read"   on public.tickets for select to authenticated using (public.can_see(dept));
create policy "admin update" on public.tickets for update to authenticated using (public.can_see(dept)) with check (public.can_see(dept));

-- Khách đăng ký qua hàm này: kiểm tra giờ 11:00–15:00 (giờ VN), bỏ thứ 4 & CN, cấp số tự động
create or replace function public.register_ticket(
  p_dept text, p_name text, p_phone text, p_age text, p_gender text,
  p_category text, p_symptoms text, p_details jsonb, p_urgent boolean
) returns int
language plpgsql security definer set search_path = public as $$
declare
  vn timestamp := now() at time zone 'Asia/Ho_Chi_Minh';
  d date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  t time := (now() at time zone 'Asia/Ho_Chi_Minh')::time;
  n int;
begin
  if p_dept not in ('nhi','san') then raise exception 'BAD_DEPT'; end if;
  if extract(dow from d) in (0,3) then raise exception 'CLOSED_DAY'; end if;
  if t < time '11:00' or t >= time '15:00' then raise exception 'CLOSED_TIME'; end if;

  perform pg_advisory_xact_lock(hashtext(d::text || p_dept));   -- tránh trùng số khi nhiều người bấm cùng lúc

  if (select count(*) from tickets
      where visit_date = d and phone = trim(p_phone) and status <> 'cancelled') >= 3
  then raise exception 'PHONE_LIMIT'; end if;

  select coalesce(max(queue_no),0) + 1 into n from tickets where visit_date = d and dept = p_dept;
  if n > 20 then raise exception 'FULL'; end if;

  insert into tickets(visit_date, dept, queue_no, full_name, phone, age_text, gender, category, symptoms, details, urgent)
  values (d, p_dept, n, trim(p_name), trim(p_phone), p_age, p_gender, p_category, p_symptoms, coalesce(p_details,'{}'), coalesce(p_urgent,false));
  return n;
end $$;

-- Trạng thái đăng ký hiện tại (công khai, không lộ thông tin bệnh nhân)
create or replace function public.queue_status()
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'dow',  extract(dow from (now() at time zone 'Asia/Ho_Chi_Minh')::date),
    'time', to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI'),
    'nhi',  (select count(*) from tickets where visit_date = (now() at time zone 'Asia/Ho_Chi_Minh')::date and dept='nhi' and status<>'cancelled'),
    'san',  (select count(*) from tickets where visit_date = (now() at time zone 'Asia/Ho_Chi_Minh')::date and dept='san' and status<>'cancelled')
  );
$$;

grant execute on function public.register_ticket(text,text,text,text,text,text,text,jsonb,boolean) to anon, authenticated;
grant execute on function public.queue_status() to anon, authenticated;

-- CẤP QUYỀN (sau khi tạo user ở Authentication > Users; thay email cho đúng):
-- Bác sĩ Hậu chỉ xem phòng Nhi:
-- insert into public.admins(user_id, dept) select id, 'nhi' from auth.users where email = 'EMAIL_BS_HAU@gmail.com' on conflict (user_id) do update set dept = excluded.dept;
-- Bác sĩ Nhã chỉ xem phòng Sản:
-- insert into public.admins(user_id, dept) select id, 'san' from auth.users where email = 'EMAIL_BS_NHA@gmail.com' on conflict (user_id) do update set dept = excluded.dept;
-- Quản lý xem cả hai phòng:
-- insert into public.admins(user_id, dept) select id, 'all' from auth.users where email = 'EMAIL_QUAN_LY@gmail.com' on conflict (user_id) do update set dept = excluded.dept;
