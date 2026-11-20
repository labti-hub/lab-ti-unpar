-- =====================================================================
-- UNPAR LAB INVENTORY MANAGEMENT SYSTEM — skema Supabase (PostgreSQL)
-- Jalankan sekali di Supabase > SQL Editor.
-- Aturan utama:
--   * Hanya email @unpar.ac.id yang bisa mendaftar (divalidasi di database).
--   * Hanya made.gusthawan@unpar.ac.id (Laboran) yang bisa mengubah inventaris
--     dan memproses peminjaman. Mahasiswa & Dosen hanya baca + ajukan pinjam.
--   * Stok hanya berubah lewat fungsi database (aman untuk permintaan bersamaan).
-- =====================================================================

-- ---------- 0. Pembantu ----------
create or replace function public.is_laboran() returns boolean
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email','')) = 'made.gusthawan@unpar.ac.id'
$$;

create or replace function public.is_unpar() returns boolean
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email','')) like '%@unpar.ac.id'
$$;

-- ---------- 1. Validasi domain saat akun dibuat ----------
create or replace function public.enforce_unpar_domain() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if lower(coalesce(new.email,'')) not like '%@unpar.ac.id' then
    raise exception 'Hanya email @unpar.ac.id yang diizinkan';
  end if;
  return new;
end $$;

drop trigger if exists trg_enforce_unpar_domain on auth.users;
create trigger trg_enforce_unpar_domain
  before insert on auth.users
  for each row execute function public.enforce_unpar_domain();

-- ---------- 2. Tabel ----------
create table if not exists public.users (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null unique check (lower(email) like '%@unpar.ac.id'),
  full_name  text,
  avatar_url text,
  role       text not null default 'mahasiswa' check (role in ('mahasiswa','dosen','laboran')),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.users (id, email, full_name, avatar_url, role)
  values (
    new.id, lower(new.email),
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email,'@',1)),
    new.raw_user_meta_data ->> 'avatar_url',
    case when lower(new.email) = 'made.gusthawan@unpar.ac.id' then 'laboran' else 'mahasiswa' end
  );
  return new;
end $$;

drop trigger if exists trg_handle_new_user on auth.users;
create trigger trg_handle_new_user
  after insert on auth.users
  for each row execute function public.handle_new_user();

create table if not exists public.laboratories (
  id          text primary key,            -- PP, EPSK, PSTI, STAT, OTO
  name        text not null,
  description text,
  icon        text,
  sort_order  int  not null default 0
);

create table if not exists public.inventory_categories (
  id   serial primary key,
  name text not null unique
);

create table if not exists public.inventory_items (
  id               uuid primary key default gen_random_uuid(),
  laboratory_id    text not null references public.laboratories(id),
  code             text not null,
  name             text not null,
  category_id      int  references public.inventory_categories(id),
  specification    text,
  brand            text,
  qty_total        int  not null default 0 check (qty_total >= 0),
  qty_available    int  not null default 0 check (qty_available >= 0),
  unit             text not null default 'unit',
  condition        text not null default 'Baik'
                   check (condition in ('Baik','Perawatan','Rusak Ringan','Rusak Berat')),
  location         text,
  notes            text,
  calibration_date date,
  photo_path       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (laboratory_id, code),
  check (qty_available <= qty_total)
);
create index if not exists idx_items_lab on public.inventory_items(laboratory_id);

create sequence if not exists public.trx_seq;

create table if not exists public.borrow_requests (
  id            uuid primary key default gen_random_uuid(),
  trx_no        text not null unique,
  borrower_id   uuid not null references public.users(id),
  borrower_name text not null,
  borrower_email text not null,
  nid           text not null,                -- NPM / NIP
  study_program text not null,
  laboratory_id text not null references public.laboratories(id),
  purpose       text not null,
  notes         text,
  borrow_date   date not null,
  return_date   date not null,
  letter_path   text not null,                -- bukti surat peminjaman (Storage)
  status        text not null default 'Menunggu Persetujuan'
                check (status in ('Menunggu Persetujuan','Disetujui','Ditolak','Sedang Dipinjam',
                                  'Menunggu Pengembalian','Selesai','Terlambat')),
  reject_reason text,
  return_note   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (return_date >= borrow_date)
);
create index if not exists idx_br_borrower on public.borrow_requests(borrower_id);
create index if not exists idx_br_lab on public.borrow_requests(laboratory_id);

create table if not exists public.borrow_request_items (
  id             uuid primary key default gen_random_uuid(),
  request_id     uuid not null references public.borrow_requests(id) on delete cascade,
  item_id        uuid not null references public.inventory_items(id),
  qty            int  not null check (qty > 0),
  stock_deducted boolean not null default false
);

create table if not exists public.inventory_transactions (
  id         uuid primary key default gen_random_uuid(),
  item_id    uuid not null references public.inventory_items(id),
  request_id uuid references public.borrow_requests(id),
  type       text not null check (type in ('keluar','masuk')),
  qty        int  not null,
  actor      text,
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_logs (
  id         uuid primary key default gen_random_uuid(),
  actor      text,
  action     text not null,
  entity     text not null,
  entity_id  text,
  detail     jsonb,
  created_at timestamptz not null default now()
);

-- ---------- 3. Log perubahan inventaris otomatis ----------
create or replace function public.log_item_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.updated_at := now(); end if;
  insert into public.inventory_logs(actor, action, entity, entity_id, detail)
  values (
    auth.jwt() ->> 'email', tg_op, 'inventory_items',
    coalesce(new.id, old.id)::text,
    case tg_op when 'DELETE' then to_jsonb(old)
               when 'INSERT' then to_jsonb(new)
               else jsonb_build_object('before', to_jsonb(old), 'after', to_jsonb(new)) end
  );
  return coalesce(new, old);
end $$;

drop trigger if exists trg_item_log_iu on public.inventory_items;
create trigger trg_item_log_iu before insert or update on public.inventory_items
  for each row execute function public.log_item_change();
drop trigger if exists trg_item_log_d on public.inventory_items;
create trigger trg_item_log_d before delete on public.inventory_items
  for each row execute function public.log_item_change();

-- ---------- 4. Fungsi peminjaman (transaksi atomik) ----------
create or replace function public.submit_borrow(
  p_item uuid, p_qty int, p_nid text, p_prodi text,
  p_borrow date, p_return date, p_purpose text, p_notes text, p_letter_path text
) returns text
language plpgsql security definer set search_path = public as $$
declare it public.inventory_items; u public.users; v_id uuid; v_no text;
begin
  if not public.is_unpar() then raise exception 'Akses ditolak'; end if;
  select * into u from public.users where id = auth.uid();
  select * into it from public.inventory_items where id = p_item;
  if it.id is null then raise exception 'Barang tidak ditemukan'; end if;
  if it.condition = 'Perawatan' then raise exception 'Barang sedang perawatan'; end if;
  if p_qty < 1 or p_qty > it.qty_available then
    raise exception 'Jumlah melebihi stok tersedia (%)', it.qty_available;
  end if;
  if p_letter_path is null or length(p_letter_path) = 0 then
    raise exception 'Surat peminjaman wajib diunggah';
  end if;
  v_no := 'TRX-' || to_char(now(),'YYYY') || '-' || lpad(nextval('public.trx_seq')::text, 4, '0');
  insert into public.borrow_requests(trx_no, borrower_id, borrower_name, borrower_email, nid,
      study_program, laboratory_id, purpose, notes, borrow_date, return_date, letter_path)
  values (v_no, auth.uid(), coalesce(u.full_name, u.email), u.email, p_nid, p_prodi,
      it.laboratory_id, p_purpose, p_notes, p_borrow, p_return, p_letter_path)
  returning id into v_id;
  insert into public.borrow_request_items(request_id, item_id, qty) values (v_id, p_item, p_qty);
  return v_no;
end $$;

create or replace function public.approve_borrow(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_laboran() then raise exception 'Hanya Laboran'; end if;
  update public.borrow_requests set status='Disetujui', updated_at=now()
   where id = p_id and status = 'Menunggu Persetujuan';
  if not found then raise exception 'Status pengajuan tidak valid'; end if;
  insert into public.inventory_logs(actor, action, entity, entity_id)
  values (auth.jwt()->>'email','APPROVE','borrow_requests',p_id::text);
end $$;

create or replace function public.reject_borrow(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_laboran() then raise exception 'Hanya Laboran'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
  update public.borrow_requests set status='Ditolak', reject_reason=p_reason, updated_at=now()
   where id = p_id and status = 'Menunggu Persetujuan';
  if not found then raise exception 'Status pengajuan tidak valid'; end if;
  insert into public.inventory_logs(actor, action, entity, entity_id, detail)
  values (auth.jwt()->>'email','REJECT','borrow_requests',p_id::text, jsonb_build_object('reason',p_reason));
end $$;

-- Barang diserahkan: stok dikurangi (dengan kunci baris agar aman dari permintaan bersamaan)
create or replace function public.pickup_borrow(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.is_laboran() then raise exception 'Hanya Laboran'; end if;
  perform 1 from public.borrow_requests where id = p_id and status = 'Disetujui' for update;
  if not found then raise exception 'Pengajuan belum disetujui atau sudah diproses'; end if;
  for r in select bi.id, bi.item_id, bi.qty from public.borrow_request_items bi
            where bi.request_id = p_id and not bi.stock_deducted loop
    update public.inventory_items set qty_available = qty_available - r.qty
     where id = r.item_id and qty_available >= r.qty;
    if not found then raise exception 'Stok tidak mencukupi'; end if;
    update public.borrow_request_items set stock_deducted = true where id = r.id;
    insert into public.inventory_transactions(item_id, request_id, type, qty, actor)
    values (r.item_id, p_id, 'keluar', r.qty, auth.jwt()->>'email');
  end loop;
  update public.borrow_requests set status='Sedang Dipinjam', updated_at=now() where id = p_id;
end $$;

-- Barang kembali: stok dikembalikan
create or replace function public.return_borrow(p_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.is_laboran() then raise exception 'Hanya Laboran'; end if;
  perform 1 from public.borrow_requests
   where id = p_id and status in ('Sedang Dipinjam','Menunggu Pengembalian','Terlambat') for update;
  if not found then raise exception 'Pengajuan tidak sedang dipinjam'; end if;
  for r in select bi.id, bi.item_id, bi.qty from public.borrow_request_items bi
            where bi.request_id = p_id and bi.stock_deducted loop
    update public.inventory_items
       set qty_available = least(qty_total, qty_available + r.qty) where id = r.item_id;
    update public.borrow_request_items set stock_deducted = false where id = r.id;
    insert into public.inventory_transactions(item_id, request_id, type, qty, actor)
    values (r.item_id, p_id, 'masuk', r.qty, auth.jwt()->>'email');
  end loop;
  update public.borrow_requests set status='Selesai', return_note=p_note, updated_at=now() where id = p_id;
end $$;

-- Tampilan: status "Terlambat" dihitung otomatis
create or replace view public.borrow_requests_view with (security_invoker = true) as
select br.*,
  case when br.status in ('Sedang Dipinjam','Menunggu Pengembalian') and br.return_date < current_date
       then 'Terlambat' else br.status end as display_status
from public.borrow_requests br;

-- ---------- 5. Row Level Security ----------
alter table public.users                  enable row level security;
alter table public.laboratories           enable row level security;
alter table public.inventory_categories   enable row level security;
alter table public.inventory_items        enable row level security;
alter table public.borrow_requests        enable row level security;
alter table public.borrow_request_items   enable row level security;
alter table public.inventory_transactions enable row level security;
alter table public.inventory_logs         enable row level security;

-- users
create policy users_select on public.users for select
  using (public.is_unpar() and (id = auth.uid() or public.is_laboran()));
create policy users_update_self on public.users for update
  using (id = auth.uid())
  with check (id = auth.uid() and role in ('mahasiswa','dosen') and email <> 'made.gusthawan@unpar.ac.id');
-- (mahasiswa/dosen boleh memilih peran sendiri; 'laboran' tidak bisa diberikan lewat sini)

-- laboratories & kategori: baca semua pengguna UNPAR, ubah hanya Laboran
create policy labs_select on public.laboratories for select using (public.is_unpar());
create policy labs_write  on public.laboratories for all using (public.is_laboran()) with check (public.is_laboran());
create policy cat_select  on public.inventory_categories for select using (public.is_unpar());
create policy cat_write   on public.inventory_categories for all using (public.is_laboran()) with check (public.is_laboran());

-- inventaris: baca semua, tulis hanya Laboran
create policy items_select on public.inventory_items for select using (public.is_unpar());
create policy items_write  on public.inventory_items for all using (public.is_laboran()) with check (public.is_laboran());

-- peminjaman: pemilik atau Laboran boleh membaca; perubahan lewat fungsi saja
create policy br_select on public.borrow_requests for select
  using (public.is_unpar() and (borrower_id = auth.uid() or public.is_laboran()));
create policy bri_select on public.borrow_request_items for select
  using (exists (select 1 from public.borrow_requests b
                  where b.id = request_id and (b.borrower_id = auth.uid() or public.is_laboran())));
create policy trx_select  on public.inventory_transactions for select using (public.is_laboran());
create policy logs_select on public.inventory_logs for select using (public.is_laboran());

-- ---------- 6. Storage: bukti surat peminjaman (privat, maks 1 MB) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('surat-peminjaman','surat-peminjaman', false, 1048576,
        array['application/pdf','image/jpeg','image/png'])
on conflict (id) do nothing;

create policy surat_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'surat-peminjaman' and public.is_unpar()
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy surat_select on storage.objects for select to authenticated
  using (bucket_id = 'surat-peminjaman'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_laboran()));

-- Foto barang (publik dibaca, hanya Laboran yang mengunggah)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('foto-barang','foto-barang', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy foto_write on storage.objects for all to authenticated
  using (bucket_id = 'foto-barang' and public.is_laboran())
  with check (bucket_id = 'foto-barang' and public.is_laboran());

-- ---------- 7. Data awal ----------
insert into public.laboratories (id, name, description, icon, sort_order) values
 ('PP',  'Lab Proses Produksi', 'Peralatan permesinan, pengukuran, dan proses manufaktur.', '🏭', 1),
 ('EPSK','Lab EPSK',            'Ergonomi, perancangan sistem kerja, dan pengukuran kerja.', '⚙️', 2),
 ('PSTI','Lab PSTI',            'Perancangan sistem teknik industri dan komputasi.', '💻', 3),
 ('STAT','Lab Statistika',      'Analisis data, statistika, dan pengendalian kualitas.', '📊', 4),
 ('OTO', 'Lab Otomasi',         'Otomasi industri, PLC, sensor, pneumatik, dan robotika.', '🤖', 5)
on conflict (id) do nothing;

insert into public.inventory_categories (name) values
 ('Mesin'),('Alat Ukur'),('Elektronik'),('Komputer'),('Perkakas'),('Lainnya')
on conflict (name) do nothing;

-- ---------- 8. Realtime ----------
-- Perubahan pada tabel berikut akan langsung dikirim ke semua perangkat yang terbuka.
-- Realtime tetap mengikuti aturan RLS di atas (pengguna hanya menerima data yang boleh dilihatnya).
alter table public.inventory_items      replica identity full;
alter table public.borrow_requests      replica identity full;
alter table public.laboratories         replica identity full;

do $$
declare t text;
begin
  foreach t in array array['inventory_items','borrow_requests','laboratories'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
