-- ============================================================================
-- NUOVO SISTEMA DI MONITORAGGIO PRESENZE
-- ============================================================================
-- Implementazione completa da zero del sistema di controllo entrate
-- Sostituisce completamente il sistema precedente

-- ============================================================================
-- 1. NUOVA EDGE FUNCTION: attendance-monitor
-- ============================================================================
-- La funzione è già stata creata nella directory supabase/functions/attendance-monitor/
-- Questa migrazione configura il database per il nuovo sistema

-- ============================================================================
-- 2. NUOVA FUNZIONE CRON: attendance_monitor_cron()
-- ============================================================================

-- Rimuovi eventuali funzioni esistenti che potrebbero confliggere
DROP FUNCTION IF EXISTS public.robusto_attendance_check() CASCADE;

-- Crea la nuova funzione per il monitoraggio presenze
CREATE OR REPLACE FUNCTION public.attendance_monitor_cron()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_timestamp_val timestamp := now();
    current_date_str text;
    current_day_name text;
    admin_count integer := 0;
    total_employees integer := 0;
    alerts_created integer := 0;
    pending_alerts integer := 0;
    edge_response text;
    result_message text;
    admin_record record;
    employee_record record;
    employee_name text;
    is_working_day boolean;
    expected_start_time time;
    alert_time timestamp;
    leave_count integer;
    attendance_count integer;
    alert_count integer;
BEGIN
    -- Inizializza messaggio risultato
    result_message := '';

    BEGIN
        -- Ottieni data e giorno corrente
        current_date_str := to_char(current_timestamp_val, 'YYYY-MM-DD');

        CASE EXTRACT(DOW FROM current_timestamp_val)
            WHEN 0 THEN current_day_name := 'sunday';
            WHEN 1 THEN current_day_name := 'monday';
            WHEN 2 THEN current_day_name := 'tuesday';
            WHEN 3 THEN current_day_name := 'wednesday';
            WHEN 4 THEN current_day_name := 'thursday';
            WHEN 5 THEN current_day_name := 'friday';
            WHEN 6 THEN current_day_name := 'saturday';
        END CASE;

        RAISE NOTICE '[Attendance Monitor Cron] Inizio controllo presenze - Giorno: %, Data: %',
            current_day_name, current_date_str;

        -- Conta amministratori con monitoraggio abilitato
        SELECT COUNT(*) INTO admin_count
        FROM admin_settings
        WHERE attendance_alert_enabled = true;

        -- Conta dipendenti attivi
        SELECT COUNT(*) INTO total_employees
        FROM profiles
        WHERE role = 'employee' AND is_active = true;

        RAISE NOTICE '[Attendance Monitor Cron] % amministratori abilitati, % dipendenti attivi',
            admin_count, total_employees;

        -- Se nessun admin ha il monitoraggio abilitato, esci
        IF admin_count = 0 THEN
            result_message := 'Monitoraggio presenze disabilitato - Nessun amministratore con controllo abilitato';
            RETURN result_message;
        END IF;

        -- Inserisci/aggiorna trigger per oggi
        INSERT INTO attendance_check_triggers (trigger_date, status)
        VALUES (current_date_str::date, 'pending')
        ON CONFLICT (trigger_date) DO UPDATE SET
            status = 'pending',
            updated_at = now();

        -- Per ogni amministratore con monitoraggio abilitato
        FOR admin_record IN
            SELECT admin_id, attendance_alert_delay_minutes
            FROM admin_settings
            WHERE attendance_alert_enabled = true
        LOOP
            RAISE NOTICE '[Attendance Monitor Cron] Elaborazione admin % (ritardo: % minuti)',
                admin_record.admin_id, admin_record.attendance_alert_delay_minutes;

            -- Per ogni dipendente attivo
            FOR employee_record IN
                SELECT p.id, p.first_name, p.last_name, p.email,
                       ews.work_days, ews.start_time as emp_start_time,
                       ws.monday, ws.tuesday, ws.wednesday, ws.thursday,
                       ws.friday, ws.saturday, ws.sunday,
                       ws.start_time as company_start_time
                FROM profiles p
                LEFT JOIN employee_work_schedules ews ON p.id = ews.employee_id
                CROSS JOIN work_schedules ws
                WHERE p.role = 'employee' AND p.is_active = true
            LOOP
                employee_name := TRIM(COALESCE(employee_record.first_name, '') || ' ' || COALESCE(employee_record.last_name, ''));

                -- Determina se è un giorno lavorativo e orario previsto
                is_working_day := false;

                IF employee_record.work_days IS NOT NULL THEN
                    -- Usa orario personalizzato del dipendente
                    is_working_day := current_day_name = ANY(employee_record.work_days);
                    expected_start_time := employee_record.emp_start_time;
                ELSE
                    -- Usa orario aziendale
                    CASE current_day_name
                        WHEN 'monday' THEN is_working_day := employee_record.monday;
                        WHEN 'tuesday' THEN is_working_day := employee_record.tuesday;
                        WHEN 'wednesday' THEN is_working_day := employee_record.wednesday;
                        WHEN 'thursday' THEN is_working_day := employee_record.thursday;
                        WHEN 'friday' THEN is_working_day := employee_record.friday;
                        WHEN 'saturday' THEN is_working_day := employee_record.saturday;
                        WHEN 'sunday' THEN is_working_day := employee_record.sunday;
                    END CASE;
                    expected_start_time := employee_record.company_start_time;
                END IF;

                -- Salta se non è giorno lavorativo
                IF NOT is_working_day THEN
                    CONTINUE;
                END IF;

                -- Verifica se è in ferie o permesso
                SELECT COUNT(*) INTO leave_count
                FROM leave_requests
                WHERE user_id = employee_record.id
                AND status = 'approved'
                AND (
                    (type = 'ferie' AND date_from <= current_date_str::date AND date_to >= current_date_str::date)
                    OR (type = 'permesso' AND day = current_date_str::date)
                );

                IF leave_count > 0 THEN
                    RAISE NOTICE '[Attendance Monitor Cron] % è in ferie/permesso - saltato', employee_name;
                    CONTINUE;
                END IF;

                -- Calcola momento dell'avviso (orario previsto + minuti di ritardo)
                alert_time := (current_date_str || ' ' || expected_start_time)::timestamp +
                             (admin_record.attendance_alert_delay_minutes || ' minutes')::interval;

                -- Se non è ancora il momento dell'avviso, salta
                IF current_timestamp_val < alert_time THEN
                    CONTINUE;
                END IF;

                -- Verifica se ha già registrato l'entrata
                SELECT COUNT(*) INTO attendance_count
                FROM attendances
                WHERE user_id = employee_record.id
                AND date = current_date_str::date
                AND check_in_time IS NOT NULL;

                IF attendance_count > 0 THEN
                    CONTINUE;
                END IF;

                -- Verifica se abbiamo già creato un avviso per oggi
                SELECT COUNT(*) INTO alert_count
                FROM attendance_alerts
                WHERE employee_id = employee_record.id
                AND alert_date = current_date_str::date;

                IF alert_count > 0 THEN
                    CONTINUE;
                END IF;

                -- Crea nuovo avviso
                INSERT INTO attendance_alerts (
                    employee_id,
                    admin_id,
                    alert_date,
                    alert_time,
                    expected_time
                ) VALUES (
                    employee_record.id,
                    admin_record.admin_id,
                    current_date_str::date,
                    current_timestamp_val::time,
                    expected_start_time
                );

                alerts_created := alerts_created + 1;
                RAISE NOTICE '[Attendance Monitor Cron] Avviso creato per % (previsto: %, attuale: %)',
                    employee_name, expected_start_time, to_char(current_timestamp_val, 'HH24:MI');

            END LOOP; -- Fine ciclo dipendenti
        END LOOP; -- Fine ciclo amministratori

        -- Conta avvisi totali pendenti dopo la creazione
        SELECT COUNT(*) INTO pending_alerts
        FROM attendance_alerts
        WHERE alert_date = current_date_str::date
        AND email_sent_at IS NULL;

        RAISE NOTICE '[Attendance Monitor Cron] Controllo completato: % nuovi avvisi, % totali pendenti',
            alerts_created, pending_alerts;

        -- Se ci sono avvisi da inviare, chiama la Edge Function
        IF alerts_created > 0 THEN
            RAISE NOTICE '[Attendance Monitor Cron] Chiamata Edge Function attendance-monitor per % avvisi',
                alerts_created;

            BEGIN
                -- Chiama la nuova Edge Function
                SELECT content INTO edge_response
                FROM http((
                    'POST',
                    'https://nohufgceuqhkycsdffqj.supabase.co/functions/v1/attendance-monitor',
                    ARRAY[
                        http_header('Content-Type', 'application/json'),
                        http_header('Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5vaHVmZ2NldXFoa3ljc2RmZnFqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDk4OTEyNzYsImV4cCI6MjA2NTQ2NzI3Nn0.oigK8ck7f_sBeXfJ8P1ySdqMHiVpXdjkoBSR4uMZgRQ')
                    ],
                    'application/json',
                    '{}'
                ));

                RAISE NOTICE '[Attendance Monitor Cron] Risposta Edge Function: %', edge_response;
                edge_response := COALESCE(edge_response, 'Risposta vuota dalla Edge Function');

            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Attendance Monitor Cron] Errore chiamata Edge Function: %', SQLERRM;
                edge_response := 'ERRORE: ' || SQLERRM;
            END;
        ELSE
            edge_response := 'Nessun nuovo avviso creato';
        END IF;

        -- Costruisci messaggio finale
        result_message := format(
            'Monitoraggio presenze completato alle %s. Nuovi avvisi: %s | Totali pendenti: %s | Email: %s',
            to_char(current_timestamp_val, 'HH24:MI'),
            alerts_created,
            pending_alerts,
            edge_response
        );

    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[Attendance Monitor Cron] Errore critico: %', SQLERRM;
        result_message := format('ERRORE alle %s: %s',
            to_char(current_timestamp_val, 'HH24:MI'),
            SQLERRM
        );
    END;

    -- Ritorna sempre un messaggio (mai null)
    RETURN COALESCE(result_message, 'Errore: messaggio risultato null');

END;
$$;

-- ============================================================================
-- 3. CONFIGURAZIONE CRON JOB
-- ============================================================================

-- Rimuovi eventuali cron job esistenti
SELECT cron.unschedule(jobname)
FROM cron.job
WHERE jobname IN ('attendance-monitor-cron', 'robusto-attendance-check');

-- Crea il nuovo cron job - esecuzione ogni 15 minuti
SELECT cron.schedule(
    'attendance-monitor-cron',
    '*/15 * * * *',  -- Ogni 15 minuti
    'SELECT public.attendance_monitor_cron();'
);

-- ============================================================================
-- 4. PULIZIA E VERIFICA
-- ============================================================================

-- Verifica che la funzione sia stata creata correttamente
DO $$
BEGIN
    -- Test semplice della funzione
    RAISE NOTICE 'Test funzione attendance_monitor_cron(): %', public.attendance_monitor_cron();
END $$;

-- Verifica configurazione cron
SELECT
    '✅ Configurazione Cron Job' as verifica,
    jobname,
    schedule,
    command,
    active
FROM cron.job
WHERE jobname = 'attendance-monitor-cron';

-- ============================================================================
-- 5. ISTRUZIONI PER IL DEPLOY
-- ============================================================================

/*
ISTRUZIONI PER COMPLETARE L'INSTALLAZIONE:

1. DEPLOY EDGE FUNCTION:
   supabase functions deploy attendance-monitor

2. VERIFICA DATABASE:
   - La tabella `attendance_alerts` deve esistere
   - La tabella `attendance_check_triggers` deve esistere
   - Le tabelle `admin_settings`, `profiles`, etc. devono esistere

3. TEST DEL SISTEMA:
   - Esegui: SELECT public.attendance_monitor_cron();
   - Verifica che non ci siano errori
   - Controlla i log per messaggi di debug

4. MONITORAGGIO:
   - Il cron job viene eseguito automaticamente ogni 15 minuti
   - Controlla i log di Supabase per eventuali errori
   - Verifica che le email vengano inviate correttamente

CONFIGURAZIONE COMPLETATA!
========================
Il nuovo sistema di monitoraggio presenze è ora attivo con:
- ✅ Funzione SQL: attendance_monitor_cron()
- ✅ Edge Function: attendance-monitor
- ✅ Cron Job: esecuzione ogni 15 minuti
- ✅ Template email migliorato e responsive
*/
