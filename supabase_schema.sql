-- MathMaster: run this file in Supabase SQL Editor, then configure OAuth providers and Storage.
create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('student', 'teacher', 'admin');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.exam_standard as enum ('VACT', 'THPTQG', 'TSA');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.attempt_status as enum ('in_progress', 'submitted', 'expired');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.question_option as enum ('A', 'B', 'C', 'D');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.document_status as enum ('draft', 'published', 'archived');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  role public.app_role not null default 'student',
  total_xp integer not null default 0 check (total_xp >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.exams (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete set null,
  title text not null check (char_length(title) between 3 and 180),
  description text,
  standard public.exam_standard not null,
  duration_minutes integer not null check (duration_minutes between 1 and 300),
  question_count integer not null default 0 check (question_count >= 0),
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.exam_questions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  position integer not null check (position > 0),
  content text not null,
  explanation text,
  option_a text not null,
  option_b text not null,
  option_c text not null,
  option_d text not null,
  created_at timestamptz not null default now(),
  unique (exam_id, position)
);

-- This separate table prevents answer keys being sent with normal question reads.
create table if not exists public.question_answer_keys (
  question_id uuid primary key references public.exam_questions(id) on delete cascade,
  exam_id uuid not null references public.exams(id) on delete cascade,
  correct_option public.question_option not null
);

create table if not exists public.exam_attempts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status public.attempt_status not null default 'in_progress',
  score numeric(5,2) not null default 0 check (score between 0 and 100),
  correct_count integer not null default 0 check (correct_count >= 0),
  total_questions integer not null default 0 check (total_questions >= 0),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.attempt_answers (
  attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
  question_id uuid not null references public.exam_questions(id) on delete restrict,
  selected_option public.question_option,
  is_correct boolean not null default false,
  primary key (attempt_id, question_id)
);

create table if not exists public.pvp_matches (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete restrict,
  status text not null check (status in ('active', 'completed', 'time_up', 'forfeit')),
  started_at timestamptz not null,
  ended_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.pvp_match_players (
  match_id uuid not null references public.pvp_matches(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  display_name text not null,
  score integer not null default 0,
  finished_at timestamptz,
  is_winner boolean not null default false,
  primary key (match_id, display_name)
);

create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 160),
  description text check (char_length(description) <= 1000),
  subject text not null check (char_length(subject) between 2 and 80),
  file_name text not null,
  file_path text not null unique,
  file_type text not null,
  file_size bigint not null check (file_size > 0 and file_size <= 26214400),
  download_count integer not null default 0 check (download_count >= 0),
  status public.document_status not null default 'draft',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists exams_published_standard_idx on public.exams (is_published, standard, created_at desc);
create index if not exists exam_questions_exam_idx on public.exam_questions (exam_id, position);
create index if not exists attempts_user_submitted_idx on public.exam_attempts (user_id, submitted_at desc);
create index if not exists documents_status_created_idx on public.documents (status, created_at desc);

create or replace function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists exams_updated_at on public.exams;
create trigger exams_updated_at before update on public.exams for each row execute function public.set_updated_at();
drop trigger if exists documents_updated_at on public.documents;
create trigger documents_updated_at before update on public.documents for each row execute function public.set_updated_at();

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(coalesce(new.email, 'Khách'), '@', 1)), new.raw_user_meta_data ->> 'avatar_url')
  on conflict (id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('teacher', 'admin'));
$$;

alter table public.profiles enable row level security;
alter table public.exams enable row level security;
alter table public.exam_questions enable row level security;
alter table public.question_answer_keys enable row level security;
alter table public.exam_attempts enable row level security;
alter table public.attempt_answers enable row level security;
alter table public.pvp_matches enable row level security;
alter table public.pvp_match_players enable row level security;
alter table public.documents enable row level security;

drop policy if exists "profiles are visible" on public.profiles;
create policy "profiles are visible" on public.profiles for select using (true);
drop policy if exists "users update their profile" on public.profiles;
create policy "users update their profile" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id and role = (select role from public.profiles where id = auth.uid()));
drop policy if exists "published exams readable" on public.exams;
create policy "published exams readable" on public.exams for select using (is_published or author_id = auth.uid() or public.is_staff());
drop policy if exists "staff manages exams" on public.exams;
create policy "staff manages exams" on public.exams for all using (public.is_staff()) with check (public.is_staff());
drop policy if exists "published questions readable" on public.exam_questions;
create policy "published questions readable" on public.exam_questions for select using (exists (select 1 from public.exams e where e.id = exam_id and (e.is_published or e.author_id = auth.uid() or public.is_staff())));
drop policy if exists "staff manages questions" on public.exam_questions;
create policy "staff manages questions" on public.exam_questions for all using (public.is_staff()) with check (public.is_staff());
drop policy if exists "staff reads answer keys" on public.question_answer_keys;
create policy "staff reads answer keys" on public.question_answer_keys for select using (public.is_staff());
drop policy if exists "staff manages answer keys" on public.question_answer_keys;
create policy "staff manages answer keys" on public.question_answer_keys for all using (public.is_staff()) with check (public.is_staff());
drop policy if exists "users read own attempts" on public.exam_attempts;
create policy "users read own attempts" on public.exam_attempts for select using (user_id = auth.uid());
drop policy if exists "users read own answers" on public.attempt_answers;
create policy "users read own answers" on public.attempt_answers for select using (exists (select 1 from public.exam_attempts a where a.id = attempt_id and a.user_id = auth.uid()));
drop policy if exists "players read their matches" on public.pvp_matches;
create policy "players read their matches" on public.pvp_matches for select using (exists (select 1 from public.pvp_match_players p where p.match_id = id and p.user_id = auth.uid()));
drop policy if exists "players read match participants" on public.pvp_match_players;
create policy "players read match participants" on public.pvp_match_players for select using (exists (select 1 from public.pvp_match_players own where own.match_id = match_id and own.user_id = auth.uid()));
drop policy if exists "published documents readable" on public.documents;
create policy "published documents readable" on public.documents for select using (status = 'published' or user_id = auth.uid());
drop policy if exists "users create documents" on public.documents;
create policy "users create documents" on public.documents for insert with check (user_id = auth.uid());
drop policy if exists "users update own documents" on public.documents;
create policy "users update own documents" on public.documents for update using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "users delete own documents" on public.documents;
create policy "users delete own documents" on public.documents for delete using (user_id = auth.uid());

-- Only this transactional function ever receives answer keys for grading.
create or replace function public.submit_exam_attempt(p_exam_id uuid, p_answers jsonb)
returns table (attempt_id uuid, score numeric, correct_count integer, total_questions integer, submitted_at timestamptz, answers jsonb)
language plpgsql security definer set search_path = public as $$
declare
  v_attempt uuid := gen_random_uuid(); v_total integer; v_correct integer; v_score numeric(5,2); v_time timestamptz := now(); v_answers jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.exams where id = p_exam_id and is_published) then raise exception 'Exam unavailable'; end if;
  select count(*) into v_total from public.exam_questions where exam_id = p_exam_id;
  if v_total = 0 then raise exception 'Exam has no questions'; end if;
  insert into public.exam_attempts (id, exam_id, user_id, status, total_questions, started_at, submitted_at) values (v_attempt, p_exam_id, auth.uid(), 'submitted', v_total, v_time, v_time);
  with raw_answers as (
    select distinct on (x.question_id) x.question_id, x.selected_option
    from jsonb_to_recordset(p_answers) as x(question_id uuid, selected_option public.question_option)
    order by x.question_id
  ), valid_answers as (
    select q.id question_id, raw.selected_option, (raw.selected_option = key.correct_option) is_correct
    from raw_answers raw join public.exam_questions q on q.id = raw.question_id and q.exam_id = p_exam_id
    join public.question_answer_keys key on key.question_id = q.id
  ), inserted as (
    insert into public.attempt_answers (attempt_id, question_id, selected_option, is_correct)
    select v_attempt, question_id, selected_option, is_correct from valid_answers
    returning question_id, selected_option, is_correct
  ) select coalesce(count(*) filter (where is_correct), 0), coalesce(jsonb_agg(jsonb_build_object('questionId', question_id, 'selectedOption', selected_option, 'isCorrect', is_correct)), '[]'::jsonb) into v_correct, v_answers from inserted;
  v_score := round((v_correct::numeric / v_total::numeric) * 100, 2);
  update public.exam_attempts set score = v_score, correct_count = v_correct where id = v_attempt;
  return query select v_attempt, v_score, v_correct, v_total, v_time, v_answers;
end; $$;
grant execute on function public.submit_exam_attempt(uuid, jsonb) to authenticated;

create or replace function public.increment_document_download(p_document_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.documents set download_count = download_count + 1 where id = p_document_id and status = 'published';
end; $$;
grant execute on function public.increment_document_download(uuid) to anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 26214400, array['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "owners upload documents" on storage.objects;
create policy "owners upload documents" on storage.objects for insert to authenticated with check (bucket_id = 'documents' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "owners read documents" on storage.objects;
create policy "owners read documents" on storage.objects for select to authenticated using (bucket_id = 'documents' and ((storage.foldername(name))[1] = auth.uid()::text or exists (select 1 from public.documents d where d.file_path = name and d.status = 'published')));
drop policy if exists "owners delete documents" on storage.objects;
create policy "owners delete documents" on storage.objects for delete to authenticated using (bucket_id = 'documents' and (storage.foldername(name))[1] = auth.uid()::text);

-- Starter exams are legitimate, editable content for first-run deployments.
insert into public.exams (id, title, description, standard, duration_minutes, question_count, is_published) values
  ('10000000-0000-4000-8000-000000000001', 'VACT Toán tư duy — Đề số 01', 'Luyện tư duy định lượng, đại số và xác suất.', 'VACT', 60, 6, true),
  ('10000000-0000-4000-8000-000000000002', 'THPT Quốc gia — Chuyên đề hàm số', 'Tổng hợp câu hỏi vận dụng từ hàm số và khảo sát đồ thị.', 'THPTQG', 50, 6, true),
  ('10000000-0000-4000-8000-000000000003', 'TSA HSA — Toán định lượng', 'Đề mô phỏng năng lực với các bài toán thực tế.', 'TSA', 45, 6, true)
on conflict (id) do nothing;
insert into public.exam_questions (id, exam_id, position, content, explanation, option_a, option_b, option_c, option_d) values
  ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',1,'Giá trị của 3/4 + 5/6 là:','Quy đồng mẫu 12: 9/12 + 10/12 = 19/12.','19/12','3/2','13/10','7/12'),
  ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',2,'Nghiệm của phương trình 2x - 7 = 9 là:','2x = 16, suy ra x = 8.','x = 1','x = 8','x = -8','x = 16'),
  ('20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001',3,'Một tam giác có ba góc lần lượt là 50°, 60° và:','Tổng ba góc trong tam giác bằng 180°, nên góc còn lại là 70°.','60°','70°','80°','90°'),
  ('20000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001',4,'Đạo hàm của f(x)=x³-2x là:','(x³)''=3x² và (-2x)''=-2.','3x²-2','x²-2','3x²','x³-2'),
  ('20000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001',5,'Xác suất tung một đồng xu cân đối được mặt ngửa là:','Có 2 kết quả đồng khả năng, trong đó có 1 kết quả thuận lợi.','0','1/4','1/2','1'),
  ('20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000001',6,'Cho cấp số cộng u1=3, d=4. Giá trị u5 bằng:','u5 = u1 + 4d = 3 + 16 = 19.','15','19','20','23')
on conflict (id) do nothing;
insert into public.question_answer_keys (question_id, exam_id, correct_option) values
  ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','A'),
  ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','B'),
  ('20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001','B'),
  ('20000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001','A'),
  ('20000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','C'),
  ('20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000001','B')
on conflict (question_id) do nothing;

insert into public.exam_questions (id, exam_id, position, content, explanation, option_a, option_b, option_c, option_d) values
  ('20100000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002',1,'Tập xác định của y = 1/(x - 2) là:','Mẫu số phải khác 0 nên x khác 2.','R','R \ {2}','(2; +∞)','(-∞; 2)'),
  ('20100000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002',2,'Hàm số y = x² - 4x + 3 có đỉnh là:','xđỉnh = -b/(2a) = 2, thay vào y được -1.','(2; -1)','(-2; -1)','(2; 1)','(-2; 1)'),
  ('20100000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000002',3,'Giá trị nhỏ nhất của x² + 2x + 5 là:','x² + 2x + 5 = (x + 1)² + 4 nên GTNN là 4.','3','4','5','0'),
  ('20100000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000002',4,'Nghiệm của bất phương trình 3x + 1 > 10 là:','3x > 9 nên x > 3.','x > 3','x ≥ 3','x < 3','x ≤ 3'),
  ('20100000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002',5,'Đường tiệm cận đứng của y = (2x+1)/(x-1) là:','Tiệm cận đứng xảy ra khi mẫu bằng 0: x = 1.','y = 2','x = 1','y = 1','x = -1'),
  ('20100000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000002',6,'Nếu f''(x) > 0 trên R thì hàm số:','Đạo hàm dương trên toàn miền xác định thì hàm số đồng biến.','Đồng biến trên R','Nghịch biến trên R','Có cực đại','Có cực tiểu')
on conflict (id) do nothing;
insert into public.question_answer_keys (question_id, exam_id, correct_option) values
  ('20100000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','B'),
  ('20100000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','A'),
  ('20100000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000002','B'),
  ('20100000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000002','A'),
  ('20100000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002','B'),
  ('20100000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000002','A')
on conflict (question_id) do nothing;

insert into public.exam_questions (id, exam_id, position, content, explanation, option_a, option_b, option_c, option_d) values
  ('20200000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003',1,'Một sản phẩm giảm giá 20% từ 500.000 đồng. Giá mới là:','500.000 × (1 - 20%) = 400.000 đồng.','350.000 đồng','400.000 đồng','420.000 đồng','480.000 đồng'),
  ('20200000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000003',2,'Trung bình cộng của 4, 7, 9 và 10 là:','Tổng là 30, chia cho 4 được 7,5.','7','7,5','8','8,5'),
  ('20200000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003',3,'Một hình chữ nhật rộng 5 cm, dài 8 cm có diện tích:','Diện tích = dài × rộng = 8 × 5 = 40 cm².','13 cm²','26 cm²','40 cm²','80 cm²'),
  ('20200000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000003',4,'Giải hệ: x + y = 10, x - y = 2. Khi đó x bằng:','Cộng hai phương trình: 2x = 12 nên x = 6.','4','5','6','8'),
  ('20200000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000003',5,'Số cách chọn 2 học sinh từ 5 học sinh là:','C(5,2) = 5×4/(2×1) = 10.','5','8','10','20'),
  ('20200000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000003',6,'Lãi đơn của 10 triệu đồng trong 1 năm với lãi suất 6% là:','10.000.000 × 6% = 600.000 đồng.','60.000 đồng','600.000 đồng','1.060.000 đồng','6.000.000 đồng')
on conflict (id) do nothing;
insert into public.question_answer_keys (question_id, exam_id, correct_option) values
  ('20200000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003','B'),
  ('20200000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000003','B'),
  ('20200000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003','C'),
  ('20200000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000003','C'),
  ('20200000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000003','C'),
  ('20200000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000003','B')
on conflict (question_id) do nothing;
