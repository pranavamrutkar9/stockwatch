-- Deterministic per-table row count and content hash for schema public (excluding the
-- migration ledger). Used to prove backups/restores/replicas are identical. Read-only.
SELECT t.relname || ' rows=' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', t.relname), false, true, '')))[1]::text
  || ' sha256=' || left(encode(sha256(convert_to(coalesce((xpath('/row/h/text()', query_to_xml(format(
     'SELECT string_agg(md5(x::text), '','' ORDER BY md5(x::text)) AS h FROM public.%I x', t.relname), false, true, '')))[1]::text, ''), 'UTF8')), 'hex'), 16)
FROM pg_class t JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public' AND t.relkind = 'r' AND t.relname <> '_prisma_migrations' ORDER BY 1;
