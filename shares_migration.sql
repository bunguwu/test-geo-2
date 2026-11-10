-- GeoFolio: chia sẻ Nhật ký thực địa và Dự án cho nhiều lớp.
-- Chạy SAU supabase_schema.sql, trong Supabase > SQL Editor. Chạy lại nhiều lần vẫn an toàn và KHÔNG xóa dữ liệu.

-- 1. Bảng trung gian: một dòng = một mục (kind + item_id) được chia sẻ cho một lớp
create table if not exists public.shares(
  kind text not null check (kind in ('stop','project')),   -- 'stop' = field_stops, 'project' = projects
  item_id uuid not null,                                    -- không có khóa ngoại vì trỏ tới 2 bảng; trigger bên dưới dọn dữ liệu
  class_id uuid not null references public.classes(id) on delete cascade,
  created_at timestamptz default now(),
  primary key(kind, item_id, class_id));
create index if not exists shares_class_idx on public.shares(class_id);
alter table public.shares enable row level security;

-- 2. Hàm trợ giúp (security definer để tránh vòng lặp RLS)
create or replace function public.owns_item(k text, i uuid) returns boolean
language sql security definer stable set search_path=public as
$$ select case k
     when 'stop'    then exists(select 1 from field_stops where id=i and student_id=auth.uid())
     when 'project' then exists(select 1 from projects    where id=i and student_id=auth.uid())
     else false end $$;

create or replace function public.shared_with_me(k text, i uuid) returns boolean
language sql security definer stable set search_path=public as
$$ select exists(select 1 from shares s join classes c on c.id=s.class_id
                 where s.kind=k and s.item_id=i and c.teacher_id=auth.uid()) $$;

-- 3. Chính sách cho shares
-- Học sinh: chỉ chia sẻ mục của mình, và chỉ cho lớp mình đã tham gia
drop policy if exists "shares_owner_all" on public.shares;
create policy "shares_owner_all" on public.shares for all to authenticated
  using (public.owns_item(kind, item_id))
  with check (public.owns_item(kind, item_id) and public.is_member_of_class(class_id));
-- Giáo viên: xem các lượt chia sẻ vào lớp mình dạy
drop policy if exists "shares_teacher_select" on public.shares;
create policy "shares_teacher_select" on public.shares for select to authenticated
  using (public.is_teacher_of_class(class_id));

-- 4. Giáo viên chỉ đọc được mục đã chia sẻ cho lớp mình (thay cho quyền đọc toàn bộ trước đây)
drop policy if exists "stops_teacher_read" on public.field_stops;
create policy "stops_teacher_read" on public.field_stops for select to authenticated
  using (public.shared_with_me('stop', id));
drop policy if exists "projects_teacher_read" on public.projects;
create policy "projects_teacher_read" on public.projects for select to authenticated
  using (public.shared_with_me('project', id));

-- 5. Xóa mục thì xóa luôn các lượt chia sẻ của nó
create or replace function public.cleanup_shares() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  delete from shares where kind = tg_argv[0] and item_id = old.id;
  return old;
end $$;
drop trigger if exists stops_cleanup on public.field_stops;
create trigger stops_cleanup after delete on public.field_stops
  for each row execute function public.cleanup_shares('stop');
drop trigger if exists projects_cleanup on public.projects;
create trigger projects_cleanup after delete on public.projects
  for each row execute function public.cleanup_shares('project');
