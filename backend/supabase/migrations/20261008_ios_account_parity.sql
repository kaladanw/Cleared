-- iOS account parity: private screenshot storage for authenticated POST /check.
-- Safe to re-run. Apply after 20261007_share_seller.sql.

-- 1) Storage object paths for screenshots uploaded by an authenticated /check.
--    Format: {user_id}/{report_id}/{n}.{jpg|png|webp|gif} in the private
--    `check-images` bucket. Kept separate from `image_urls`, which holds
--    public CDN URLs captured by the Chrome extension.
alter table reports add column if not exists image_paths jsonb not null default '[]'::jsonb;

-- 2) PRIVATE bucket (public = false). 10 MB per object, images only.
--    Equivalent dashboard steps: Storage → New bucket → name `check-images`,
--    Public OFF, file size limit 10 MB, allowed MIME types
--    image/jpeg, image/png, image/webp, image/gif.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'check-images',
  'check-images',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 3) Policies: NONE on purpose. The backend reads/writes with the service-role
--    key (bypasses RLS). With RLS on storage.objects and no policy for this
--    bucket, anon/authenticated clients cannot list, read, or write it, and the
--    public share endpoint never returns paths or URLs.
--
--    If clients ever need direct read access to their own screenshots, add an
--    owner-scoped SELECT policy instead of making the bucket public, e.g.:
--
--    create policy "check-images owner read" on storage.objects
--      for select to authenticated
--      using (bucket_id = 'check-images'
--             and (storage.foldername(name))[1] = auth.uid()::text);
