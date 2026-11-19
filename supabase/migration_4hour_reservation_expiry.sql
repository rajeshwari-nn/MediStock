-- ==============================================================================
-- MediStock Migration: 4-Hour Reservation Expiry & Isolated Stock Restoration
-- ==============================================================================
-- PURPOSE:
-- 1. Updates default reservation expiry window from 48 hours to exactly 4 hours.
-- 2. Updates the server-side atomic auto-cancellation and stock restoration function.
-- 3. Guarantees 100% data safety: NO tables are dropped, NO records are deleted.
--
-- EXECUTION:
-- Run this in your Supabase Project -> SQL Editor.
-- ==============================================================================

BEGIN;

-- 1. Update default for new reservations in public.reservations table
ALTER TABLE public.reservations 
  ALTER COLUMN expires_at SET DEFAULT (timezone('utc'::text, now()) + interval '4 hours');

-- 2. Update atomic reservation expiry and stock restoration function
CREATE OR REPLACE FUNCTION expire_stale_reservations_atomic()
RETURNS JSONB AS $$
DECLARE
  v_rec RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR v_rec IN 
    SELECT r.id, r.user_id, r.pharmacy_id, r.medicine_id, r.quantity, r.expires_at, m.display_name AS medicine_name, p.name AS pharmacy_name
    FROM public.reservations r
    JOIN public.medicines m ON m.id = r.medicine_id
    JOIN public.pharmacies p ON p.id = r.pharmacy_id
    WHERE r.status IN ('PENDING', 'ACCEPTED', 'READY_FOR_COLLECTION')
      AND (
        (r.expires_at IS NOT NULL AND r.expires_at <= timezone('utc'::text, now()))
        OR (r.expires_at IS NULL AND r.created_at <= (timezone('utc'::text, now()) - interval '4 hours'))
      )
      AND r.stock_restored = false
    FOR UPDATE OF r
  LOOP
    -- A. Mark reservation as EXPIRED and record stock_restored
    UPDATE public.reservations
    SET status = 'EXPIRED',
        stock_restored = true,
        updated_at = timezone('utc'::text, now())
    WHERE id = v_rec.id;

    -- B. Restore stock to pharmacy inventory atomically
    UPDATE public.inventory
    SET quantity = quantity + v_rec.quantity,
        status = CASE 
          WHEN (quantity + v_rec.quantity) >= 10 THEN 'AVAILABLE'
          WHEN (quantity + v_rec.quantity) > 0 THEN 'LOW_STOCK'
          ELSE 'OUT_OF_STOCK'
        END,
        last_updated = timezone('utc'::text, now())
    WHERE pharmacy_id = v_rec.pharmacy_id AND medicine_id = v_rec.medicine_id;

    -- C. Notify Pharmacy
    INSERT INTO public.alerts (pharmacy_id, listing_id, type, message)
    VALUES (
      v_rec.pharmacy_id,
      (SELECT id FROM public.inventory WHERE pharmacy_id = v_rec.pharmacy_id AND medicine_id = v_rec.medicine_id LIMIT 1),
      'STOCK_AUTO_RESTORED',
      format('⚠️ Customer Did Not Pick Up: Reservation #%s for %s (Qty: %s) expired after 4h. Stock (+%s units) automatically restored.', upper(substring(replace(v_rec.id::text, '-', ''), 1, 6)), v_rec.medicine_name, v_rec.quantity, v_rec.quantity)
    );

    -- D. Notify Customer
    INSERT INTO public.alerts (pharmacy_id, user_id, type, message)
    VALUES (
      v_rec.pharmacy_id,
      v_rec.user_id,
      'RESERVATION_EXPIRED',
      format('❌ Reservation Expired: You did not collect your medicine (%s) from %s within 4 hours. Stock was released.', v_rec.medicine_name, v_rec.pharmacy_name)
    );

    -- E. Record in system audit trail
    INSERT INTO public.audit_logs (actor_user_id, action, entity_type, entity_id, details)
    VALUES (
      v_rec.user_id,
      'RESERVATION_AUTO_EXPIRED_4H',
      'RESERVATIONS',
      v_rec.id::text,
      jsonb_build_object(
        'quantity_restored', v_rec.quantity, 
        'medicine_name', v_rec.medicine_name, 
        'pharmacy_name', v_rec.pharmacy_name,
        'rule', '4-hour customer pickup window'
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'expired_count', v_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Log migration in audit trail
INSERT INTO public.audit_logs (id, action, entity_type, details, created_at)
VALUES (
  gen_random_uuid(),
  'MIGRATION_4HOUR_EXPIRY',
  'SYSTEM',
  '{"message": "Reservation expiry window updated to 4 hours with atomic stock recovery. Zero data deleted."}'::jsonb,
  NOW()
);

COMMIT;

-- 4. Optional Supabase pg_cron job (Runs every 5 minutes in background):
-- Uncomment when pg_cron extension is enabled:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('medistock-auto-expire-4h', '*/5 * * * *', 'SELECT expire_stale_reservations_atomic();');
