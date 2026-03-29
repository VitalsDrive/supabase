-- VitalsDrive Functions and Triggers
-- Version: 1.0.0
-- Description: Database functions, triggers, and realtime configuration

BEGIN;

-- ============================================
-- HELPER FUNCTION: get_user_fleet_ids (already in 002, included for completeness)
-- ============================================
CREATE OR REPLACE FUNCTION get_user_fleet_ids()
RETURNS SETOF UUID AS $$
    SELECT fleet_id FROM fleet_members WHERE user_id = auth.uid();
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- ============================================
-- FUNCTION: update_updated_at_column
-- Description: Auto-updates the updated_at column on row changes
-- ============================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- TRIGGERS: updated_at auto-update
-- ============================================
CREATE TRIGGER update_vehicles_updated_at
    BEFORE UPDATE ON vehicles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_fleets_updated_at
    BEFORE UPDATE ON fleets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- FUNCTION: generate_alert_if_needed
-- Description: Trigger function to create alerts based on telemetry threshold violations
-- ============================================
CREATE OR REPLACE FUNCTION generate_alert_if_needed()
RETURNS TRIGGER AS $$
DECLARE
    v_fleet_id UUID;
    v_rule RECORD;
    v_metric_value FLOAT;
    v_condition_met BOOLEAN;
BEGIN
    -- Get fleet_id for the vehicle
    SELECT fleet_id INTO v_fleet_id FROM vehicles WHERE id = NEW.vehicle_id;
    
    IF v_fleet_id IS NULL THEN
        RETURN NEW;  -- Vehicle not found, skip alert generation
    END IF;
    
    -- Check each enabled rule for this fleet
    FOR v_rule IN 
        SELECT * FROM telemetry_rules 
        WHERE fleet_id = v_fleet_id AND enabled = TRUE
    LOOP
        -- Get the metric value based on rule
        v_metric_value := CASE v_rule.metric
            WHEN 'temp' THEN NEW.temp
            WHEN 'voltage' THEN NEW.voltage
            WHEN 'rpm' THEN NEW.rpm::FLOAT
            ELSE NULL
        END;
        
        -- Skip if metric value is NULL
        IF v_metric_value IS NULL THEN
            CONTINUE;
        END IF;
        
        -- Check if condition is met
        v_condition_met := CASE v_rule.operator
            WHEN 'gt' THEN v_metric_value > v_rule.threshold
            WHEN 'lt' THEN v_metric_value < v_rule.threshold
            WHEN 'gte' THEN v_metric_value >= v_rule.threshold
            WHEN 'lte' THEN v_metric_value <= v_rule.threshold
            WHEN 'eq' THEN v_metric_value = v_rule.threshold
            ELSE FALSE
        END;
        
        -- If condition met and no recent alert (cooldown), create alert
        IF v_condition_met AND (
            SELECT COUNT(*) FROM alerts 
            WHERE vehicle_id = NEW.vehicle_id 
            AND code = v_rule.name
            AND created_at > NOW() - (v_rule.cooldown_seconds || ' seconds')::INTERVAL
        ) = 0 THEN
            
            INSERT INTO alerts (
                vehicle_id, fleet_id, severity, code, message,
                dtc_codes, lat, lng
            ) VALUES (
                NEW.vehicle_id,
                v_fleet_id,
                v_rule.severity,
                v_rule.name,
                v_rule.name || ' threshold exceeded: ' || ROUND(v_metric_value::NUMERIC, 2) || ' (threshold: ' || v_rule.threshold || ')',
                NEW.dtc_codes,
                NEW.lat,
                NEW.lng
            );
        END IF;
    END LOOP;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- TRIGGER: Alert generation on telemetry insert
-- ============================================
CREATE TRIGGER trigger_generate_alert
    AFTER INSERT ON telemetry_logs
    FOR EACH ROW
    EXECUTE FUNCTION generate_alert_if_needed();

-- ============================================
-- FUNCTION: get_fleet_statistics
-- Description: Returns aggregated statistics for a fleet
-- ============================================
CREATE OR REPLACE FUNCTION get_fleet_statistics(p_fleet_id UUID)
RETURNS TABLE (
    total_vehicles BIGINT,
    active_vehicles BIGINT,
    inactive_vehicles BIGINT,
    active_alerts BIGINT,
    critical_alerts BIGINT,
    warning_alerts BIGINT,
    last_telemetry TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(DISTINCT v.id)::BIGINT as total_vehicles,
        COUNT(DISTINCT CASE WHEN v.status = 'active' THEN v.id END)::BIGINT as active_vehicles,
        COUNT(DISTINCT CASE WHEN v.status = 'inactive' THEN v.id END)::BIGINT as inactive_vehicles,
        COUNT(DISTINCT CASE WHEN a.acknowledged = FALSE THEN a.id END)::BIGINT as active_alerts,
        COUNT(DISTINCT CASE WHEN a.acknowledged = FALSE AND a.severity = 'critical' THEN a.id END)::BIGINT as critical_alerts,
        COUNT(DISTINCT CASE WHEN a.acknowledged = FALSE AND a.severity = 'warning' THEN a.id END)::BIGINT as warning_alerts,
        MAX(t.timestamp) as last_telemetry
    FROM vehicles v
    LEFT JOIN alerts a ON v.id = a.vehicle_id
    LEFT JOIN telemetry_logs t ON v.id = t.vehicle_id
    WHERE v.fleet_id = p_fleet_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ============================================
-- FUNCTION: assign_vehicles_to_fleet
-- Description: Bulk assign vehicles to a fleet
-- ============================================
CREATE OR REPLACE FUNCTION assign_vehicles_to_fleet(
    p_vehicle_ids UUID[],
    p_fleet_id UUID
)
RETURNS VOID AS $$
BEGIN
    -- Verify caller is fleet admin
    IF NOT is_fleet_admin(p_fleet_id) THEN
        RAISE EXCEPTION 'Access denied: Only fleet admins can assign vehicles';
    END IF;
    
    UPDATE vehicles 
    SET fleet_id = p_fleet_id, updated_at = NOW()
    WHERE id = ANY(p_vehicle_ids);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- FUNCTION: cleanup_old_telemetry
-- Description: Delete telemetry data older than retention period
-- ============================================
CREATE OR REPLACE FUNCTION cleanup_old_telemetry(p_retention_days INTEGER DEFAULT 90)
RETURNS INTEGER AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    WITH deleted AS (
        DELETE FROM telemetry_logs 
        WHERE timestamp < NOW() - (p_retention_days || ' days')::INTERVAL
        RETURNING id
    )
    SELECT COUNT(*) INTO v_deleted_count FROM deleted;
    
    RETURN v_deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- FUNCTION: get_latest_telemetry_per_vehicle
-- Description: Get the most recent telemetry for each vehicle in a fleet
-- ============================================
CREATE OR REPLACE FUNCTION get_latest_telemetry_per_vehicle(p_fleet_id UUID)
RETURNS TABLE (
    vehicle_id UUID,
    lat DECIMAL(10, 7),
    lng DECIMAL(10, 7),
    temp FLOAT,
    voltage FLOAT,
    rpm INTEGER,
    dtc_codes TEXT[],
    timestamp TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ON (t.vehicle_id)
        t.vehicle_id,
        t.lat,
        t.lng,
        t.temp,
        t.voltage,
        t.rpm,
        t.dtc_codes,
        t.timestamp
    FROM telemetry_logs t
    JOIN vehicles v ON t.vehicle_id = v.id
    WHERE v.fleet_id = p_fleet_id
    ORDER BY t.vehicle_id, t.timestamp DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ============================================
-- FUNCTION: acknowledge_alert
-- Description: Acknowledge an alert with user tracking
-- ============================================
CREATE OR REPLACE FUNCTION acknowledge_alert(p_alert_id UUID, p_user_id UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE alerts
    SET 
        acknowledged = TRUE,
        acknowledged_by = p_user_id,
        acknowledged_at = NOW()
    WHERE id = p_alert_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ENABLE REALTIME
-- Note: This is done via Supabase dashboard or CLI
-- The tables must be added to the supabase_realtime publication
-- ============================================

-- Add tables to realtime publication
-- Run these in Supabase SQL Editor or via CLI:
-- ALTER PUBLICATION supabase_realtime ADD TABLE telemetry_logs;
-- ALTER PUBLICATION supabase_realtime ADD TABLE alerts;

COMMIT;