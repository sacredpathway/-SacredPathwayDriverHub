-- ============================================
-- SACRED PATHWAY DRIVER HUB — BASE SCHEMA
-- ============================================
-- Creates the 8 core tables (profiles, drivers, loads, expenses,
-- documents, settlements, brokers, broker_contacts), enables RLS,
-- installs per-row policies, and wires up the auth.users signup
-- trigger that auto-creates a profile row for new users.
--
-- This migration was originally maintained as supabase_schema_full.sql
-- at the project root and applied manually via the SQL editor. It has
-- been moved into the migrations pipeline so that `supabase db push`
-- can rebuild the schema from zero (staging, CI, fresh dev instances).
--
-- Fully idempotent — safe to re-run against an already-initialised DB.
-- Timestamp predates all feature migrations (April 2026+) so it runs first.
-- ============================================

-- 1. PROFILES
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  company_name TEXT,
  mc_number TEXT,
  dot_number TEXT,
  phone TEXT,
  subscription_tier TEXT DEFAULT 'free',
  subscription_status TEXT DEFAULT 'active',
  stripe_customer_id TEXT,
  driver_pay_percentage DECIMAL(5,2) DEFAULT 25.00,
  dispatcher_fee_percentage DECIMAL(5,2) DEFAULT 5.00,
  factoring_fee_percentage DECIMAL(5,2) DEFAULT 3.00,
  authority_fee DECIMAL(10,2) DEFAULT 50.00,
  maintenance_reserve DECIMAL(10,2) DEFAULT 100.00,
  pay_basis TEXT DEFAULT 'gross_profit',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
-- 2. DRIVERS
CREATE TABLE IF NOT EXISTS drivers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  name TEXT NOT NULL,
  truck_number TEXT,
  pay_percentage DECIMAL(5,2) DEFAULT 25.00,
  phone TEXT,
  email TEXT,
  active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- 3. LOADS
CREATE TABLE IF NOT EXISTS loads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  driver_id UUID REFERENCES drivers(id),
  load_number TEXT,
  broker_name TEXT,
  broker_mc_number TEXT,
  pickup_date DATE,
  delivery_date DATE,
  origin TEXT,
  destination TEXT,
  total_miles DECIMAL(10,2),
  line_haul_rate DECIMAL(10,2),
  fuel_surcharge DECIMAL(10,2) DEFAULT 0,
  accessorial_charges DECIMAL(10,2) DEFAULT 0,
  total_revenue DECIMAL(10,2),
  status TEXT DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
-- 4. EXPENSES
CREATE TABLE IF NOT EXISTS expenses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  load_id UUID REFERENCES loads(id) ON DELETE CASCADE,
  profile_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  category TEXT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  vendor_name TEXT,
  description TEXT,
  gallons DECIMAL(10,2),
  price_per_gallon DECIMAL(6,3),
  receipt_date DATE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- 5. DOCUMENTS
CREATE TABLE IF NOT EXISTS documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  load_id UUID REFERENCES loads(id),
  document_type TEXT,
  storage_path TEXT NOT NULL,
  extracted_data JSONB,
  confidence TEXT,
  processed BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- 6. SETTLEMENTS
CREATE TABLE IF NOT EXISTS settlements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  driver_id UUID REFERENCES drivers(id),
  settlement_period_start DATE,
  settlement_period_end DATE,
  total_revenue DECIMAL(10,2),
  total_expenses DECIMAL(10,2),
  gross_profit DECIMAL(10,2),
  driver_pay_percentage DECIMAL(5,2),
  driver_pay_amount DECIMAL(10,2),
  dispatcher_fee_percentage DECIMAL(5,2) DEFAULT 0,
  dispatcher_fee_amount DECIMAL(10,2) DEFAULT 0,
  factoring_fee_percentage DECIMAL(5,2) DEFAULT 0,
  factoring_fee_amount DECIMAL(10,2) DEFAULT 0,
  authority_fee DECIMAL(10,2) DEFAULT 0,
  maintenance_reserve DECIMAL(10,2) DEFAULT 0,
  net_pay DECIMAL(10,2),
  pdf_storage_path TEXT,
  status TEXT DEFAULT 'draft',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- 7. BROKERS (broker intelligence / memory feature)
CREATE TABLE IF NOT EXISTS brokers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  broker_name TEXT NOT NULL,
  normalized_name TEXT,
  mc_number TEXT,
  total_loads INTEGER DEFAULT 0,
  total_revenue DECIMAL(12,2) DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
-- 8. BROKER_CONTACTS
CREATE TABLE IF NOT EXISTS broker_contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  broker_id UUID REFERENCES brokers(id) ON DELETE CASCADE NOT NULL,
  contact_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  last_interaction_at TIMESTAMPTZ
);
-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE drivers ENABLE ROW LEVEL SECURITY;
ALTER TABLE loads ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE brokers ENABLE ROW LEVEL SECURITY;
ALTER TABLE broker_contacts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users manage own profile" ON profiles;
CREATE POLICY "Users manage own profile" ON profiles
  FOR ALL USING (id = auth.uid());
DROP POLICY IF EXISTS "Users manage own drivers" ON drivers;
CREATE POLICY "Users manage own drivers" ON drivers
  FOR ALL USING (profile_id = auth.uid());
DROP POLICY IF EXISTS "Users manage own loads" ON loads;
CREATE POLICY "Users manage own loads" ON loads
  FOR ALL USING (profile_id = auth.uid());
DROP POLICY IF EXISTS "Users manage own expenses" ON expenses;
CREATE POLICY "Users manage own expenses" ON expenses
  FOR ALL USING (profile_id = auth.uid());
DROP POLICY IF EXISTS "Users manage own documents" ON documents;
CREATE POLICY "Users manage own documents" ON documents
  FOR ALL USING (profile_id = auth.uid());
DROP POLICY IF EXISTS "Users manage own settlements" ON settlements;
CREATE POLICY "Users manage own settlements" ON settlements
  FOR ALL USING (profile_id = auth.uid());
DROP POLICY IF EXISTS "Users manage own brokers" ON brokers;
CREATE POLICY "Users manage own brokers" ON brokers
  FOR ALL USING (profile_id = auth.uid());
DROP POLICY IF EXISTS "Users manage own broker_contacts" ON broker_contacts;
CREATE POLICY "Users manage own broker_contacts" ON broker_contacts
  FOR ALL USING (broker_id IN (SELECT id FROM brokers WHERE profile_id = auth.uid()));
-- ============================================
-- AUTO-CREATE PROFILE ON SIGNUP
-- ============================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id) VALUES (NEW.id) ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
-- ============================================
-- BACKFILL: create profile rows for existing auth users
-- (The trigger above only fires for NEW signups; existing users
--  need a profile row created manually.)
-- ============================================

INSERT INTO profiles (id)
SELECT id FROM auth.users
WHERE id NOT IN (SELECT id FROM profiles);
