create table if not exists public.compliance_documents (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete cascade not null,
  category text not null check (category in ('company','truck','trailer','driver')),
  title text not null,
  storage_path text,
  issue_date date,
  expiration_date date,
  notes text,
  file_mime_type text,
  file_size int,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists idx_compliance_profile on public.compliance_documents(profile_id);
create index if not exists idx_compliance_expiration on public.compliance_documents(expiration_date);
alter table public.compliance_documents enable row level security;
drop policy if exists "own compliance docs" on public.compliance_documents;
create policy "own compliance docs" on public.compliance_documents
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());
-- Storage bucket for uploaded files (private; access via signed URLs)
insert into storage.buckets (id, name, public)
  values ('compliance-docs', 'compliance-docs', false)
  on conflict (id) do nothing;
drop policy if exists "own compliance files" on storage.objects;
create policy "own compliance files" on storage.objects
  for all using (bucket_id = 'compliance-docs' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'compliance-docs' and (storage.foldername(name))[1] = auth.uid()::text);
