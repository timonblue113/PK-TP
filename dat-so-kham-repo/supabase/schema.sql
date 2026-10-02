-- Chạy trong Supabase > SQL Editor.
-- File này AN TOÀN để chạy lại nhiều lần: KHÔNG xóa dữ liệu bệnh nhân đã đăng ký.
drop table if exists public.appointments cascade;   -- bảng cũ của bản đầu (nếu còn)

-- ============ BẢNG SỐ THỨ TỰ ============
create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(),
  visit_date date not null,
  dept text not null check (dept in ('nhi','san')),
  queue_no int not null,
  full_name text not null check (char_length(full_name) between 2 and 100),
  phone text not null check (phone ~ '^[0-9+ ]{9,15}$'),
  age_text text,
  gender text,
  category text not null,
  symptoms text check (char_length(symptoms) <= 800),
  details jsonb not null default '{}',
  urgent boolean not null default false,
  status text not null default 'waiting' check (status in ('waiting','done','absent','cancelled')),
  created_at timestamptz not null default now(),
  unique (visit_date, dept, queue_no)
);
alter table public.tickets enable row level security;

-- ============ BÁC SĨ ============
-- dept: 'all' = cả 2 phòng + được chỉnh cài đặt | 'nhi' = phòng Nhi | 'san' = phòng Sản
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

-- ============ CÀI ĐẶT GIỜ MỞ / ĐÓNG (chỉnh được trên trang admin) ============
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  open_time time not null default '11:00',          -- mở đăng ký
  close_time time not null default '15:00',         -- đóng đăng ký
  max_per_dept int not null default 20 check (max_per_dept between 1 and 500),
  closed_dow int[] not null default '{0,3}',        -- ngày nghỉ: 0=Chủ nhật, 1=Thứ 2 ... 3=Thứ 4 ... 6=Thứ 7
  manual text not null default 'auto' check (manual in ('auto','open','closed')),  -- auto theo giờ | open = mở ngay | closed = tạm đóng
  visit_hours text not null default '17:00 – 20:00',
  notice text check (char_length(notice) <= 200),
  check (open_time < close_time)
);
insert into public.settings (id) values (1) on conflict (id) do nothing;
alter table public.settings enable row level security;
drop policy if exists "settings read" on public.settings;
drop policy if exists "settings update" on public.settings;
-- Chỉ tài khoản quản lý (dept = 'all') được xem/sửa cài đặt trực tiếp
create policy "settings read"   on public.settings for select to authenticated using (public.can_see('all'));
create policy "settings update" on public.settings for update to authenticated using (public.can_see('all')) with check (public.can_see('all'));

-- ============ ĐĂNG KÝ LẤY SỐ (khách gọi hàm này) ============
create or replace function public.register_ticket(
  p_dept text, p_name text, p_phone text, p_age text, p_gender text,
  p_category text, p_symptoms text, p_details jsonb, p_urgent boolean
) returns int
language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  vn timestamp := now() at time zone 'Asia/Ho_Chi_Minh';
  d date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  t time := (now() at time zone 'Asia/Ho_Chi_Minh')::time;
  n int;
begin
  select * into s from settings where id = 1;
  if p_dept not in ('nhi','san') then raise exception 'BAD_DEPT'; end if;
  if extract(dow from d)::int = any (s.closed_dow) then raise exception 'CLOSED_DAY'; end if;
  if s.manual = 'closed' then raise exception 'CLOSED_MANUAL'; end if;
  if s.manual <> 'open' and (t < s.open_time or t >= s.close_time) then raise exception 'CLOSED_TIME'; end if;

  perform pg_advisory_xact_lock(hashtext(d::text || p_dept));

  if (select count(*) from tickets
      where visit_date = d and phone = trim(p_phone) and status <> 'cancelled') >= 3
  then raise exception 'PHONE_LIMIT'; end if;

  select coalesce(max(queue_no),0) + 1 into n from tickets where visit_date = d and dept = p_dept;
  if n > s.max_per_dept then raise exception 'FULL'; end if;

  insert into tickets(visit_date, dept, queue_no, full_name, phone, age_text, gender, category, symptoms, details, urgent)
  values (d, p_dept, n, trim(p_name), trim(p_phone), p_age, p_gender, p_category, p_symptoms, coalesce(p_details,'{}'), coalesce(p_urgent,false));
  return n;
end $$;

-- ============ TRẠNG THÁI CÔNG KHAI (không lộ thông tin bệnh nhân) ============
create or replace function public.queue_status()
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  vn timestamp := now() at time zone 'Asia/Ho_Chi_Minh';
  d date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  t time := (now() at time zone 'Asia/Ho_Chi_Minh')::time;
  dw int := extract(dow from (now() at time zone 'Asia/Ho_Chi_Minh'))::int;
  off boolean; isopen boolean;
begin
  select * into s from settings where id = 1;
  off := dw = any (s.closed_dow);
  isopen := not off and s.manual <> 'closed' and (s.manual = 'open' or (t >= s.open_time and t < s.close_time));
  return json_build_object(
    'dow', dw, 'time', to_char(vn, 'HH24:MI'),
    'is_open', isopen, 'day_off', off, 'manual', s.manual,
    'open_time', to_char(s.open_time, 'HH24:MI'), 'close_time', to_char(s.close_time, 'HH24:MI'),
    'max', s.max_per_dept, 'closed_dow', s.closed_dow, 'visit_hours', s.visit_hours, 'notice', s.notice,
    'nhi', (select count(*) from tickets where visit_date = d and dept = 'nhi' and status <> 'cancelled'),
    'san', (select count(*) from tickets where visit_date = d and dept = 'san' and status <> 'cancelled')
  );
end $$;

grant execute on function public.register_ticket(text,text,text,text,text,text,text,jsonb,boolean) to anon, authenticated;
grant execute on function public.queue_status() to anon, authenticated;

-- ============ CẤP QUYỀN BÁC SĨ (sau khi tạo user ở Authentication > Users; thay email) ============
-- Quản lý (xem cả 2 phòng + chỉnh giờ mở/đóng):
-- insert into public.admins(user_id, dept) select id, 'all' from auth.users where email = 'EMAIL_QUAN_LY@gmail.com' on conflict (user_id) do update set dept = excluded.dept;
-- Bác sĩ Hậu chỉ xem phòng Nhi:
-- insert into public.admins(user_id, dept) select id, 'nhi' from auth.users where email = 'EMAIL_BS_HAU@gmail.com' on conflict (user_id) do update set dept = excluded.dept;
-- Bác sĩ Nhã chỉ xem phòng Sản:
-- insert into public.admins(user_id, dept) select id, 'san' from auth.users where email = 'EMAIL_BS_NHA@gmail.com' on conflict (user_id) do update set dept = excluded.dept;
