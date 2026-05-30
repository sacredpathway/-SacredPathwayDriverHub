-- Fix Supabase Auth signup profile trigger search path.
--
-- The original handle_new_user() trigger referenced `profiles` without a
-- schema-qualified table name. Supabase Auth can execute signup triggers with
-- a restricted search_path, which makes the unqualified table lookup fail with
-- "relation profiles does not exist" and blocks new account creation.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;

  return new;
end;
$$;

comment on function public.handle_new_user() is
  'Creates a profile row for new Supabase Auth users. Uses an explicit public search_path so Auth signup cannot fail on unqualified table lookup.';
