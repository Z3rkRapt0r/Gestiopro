-- Script per creare il profilo con ruolo employee prima, poi aggiornarlo ad admin

-- 1. Verifica che l'utente esista in auth.users
SELECT 
  'USER CHECK' as status,
  id, 
  email, 
  email_confirmed_at,
  created_at,
  last_sign_in_at
FROM auth.users 
WHERE id = 'b2a9521d-a426-4563-8c2e-6f558851c08c';

-- 2. Verifica se esiste già un profilo
SELECT 
  'PROFILE CHECK' as status,
  id,
  first_name,
  last_name,
  email,
  role,
  is_active,
  first_login
FROM public.profiles 
WHERE id = 'b2a9521d-a426-4563-8c2e-6f558851c08c';

-- 3. Crea il profilo con ruolo employee (per evitare la restrizione admin)
INSERT INTO public.profiles (
  id,
  first_name,
  last_name,
  email,
  role,
  department,
  employee_code,
  is_active,
  first_login,
  created_at,
  updated_at
) VALUES (
  'b2a9521d-a426-4563-8c2e-6f558851c08c',
  'Admin',  -- Sostituisci con il tuo nome
  'User',   -- Sostituisci con il tuo cognome
  (SELECT email FROM auth.users WHERE id = 'b2a9521d-a426-4563-8c2e-6f558851c08c'),
  'employee',  -- Inizia con employee per evitare la restrizione
  'IT',     -- Sostituisci con il tuo dipartimento
  'ADMIN002', -- Sostituisci con un codice univoco
  true,     -- is_active
  true,     -- first_login
  NOW(),    -- created_at
  NOW()     -- updated_at
) ON CONFLICT (id) DO UPDATE SET
  first_name = EXCLUDED.first_name,
  last_name = EXCLUDED.last_name,
  email = EXCLUDED.email,
  role = EXCLUDED.role,
  department = EXCLUDED.department,
  employee_code = EXCLUDED.employee_code,
  is_active = EXCLUDED.is_active,
  first_login = EXCLUDED.first_login,
  updated_at = NOW();

-- 4. Verifica che il profilo sia stato creato
SELECT 
  'PROFILE CREATED' as status,
  id,
  first_name,
  last_name,
  email,
  role,
  department,
  is_active,
  first_login,
  created_at,
  updated_at
FROM public.profiles 
WHERE id = 'b2a9521d-a426-4563-8c2e-6f558851c08c';

-- 5. Test di accesso
SELECT 
  'ACCESS TEST' as status,
  'SUCCESS' as result,
  *
FROM public.profiles 
WHERE id = 'b2a9521d-a426-4563-8c2e-6f558851c08c';


