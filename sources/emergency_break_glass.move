/// MedChain - Emergency Break Glass Module
///
/// Allows VERIFIED doctors to access patient records in life-threatening emergencies
/// WITHOUT normal patient consent — but with strict audit trail.
///
/// Security gates (from doc spec):
///   Gate 1: Only VERIFIED_DOCTOR role (checked via DoctorRegistry)
///   Gate 2: Justification mandatory (min 50 chars)
///   Gate 3: Single-use session token (enforced by Redis on backend)
///   Gate 4: Pre-access blockchain log BEFORE data is opened
///   Gate 5: Rate limit (3x per doctor per 24h) — tracked on-chain
///   Gate 6: No data persistence (handled by backend/NestJS)
///
/// On-chain responsibility:
///   - Write INITIATED log before data access
///   - Write COMPLETED/FAILED/EXPIRED log after session
///   - Store justification hash (not plaintext — privacy)
///   - Track rate limiting per doctor
module medchain::emergency_break_glass {

    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::string::{Self, String};
    use medchain::doctor_registry::{Self, DoctorRegistry};
    use medchain::patient_registry::{Self, PatientRegistry};

    // ===== Error Codes =====
    const E_DOCTOR_NOT_VERIFIED:      u64 = 5001;
    const E_PATIENT_NOT_FOUND:        u64 = 5002;
    const E_JUSTIFICATION_TOO_SHORT:  u64 = 5003;
    const E_INVALID_EMERGENCY_TYPE:   u64 = 5004;
    const E_EBG_NOT_FOUND:            u64 = 5005;
    const E_EBG_ALREADY_COMPLETED:    u64 = 5006;
    const E_RATE_LIMIT_EXCEEDED:      u64 = 5007;
    const E_DUPLICATE_EBG_ID:         u64 = 5008;
    const E_INVALID_EBG_ID:           u64 = 5009;

    // ===== Constants =====
    const MAX_EBG_PER_DAY:       u64 = 3;
    const MS_PER_DAY:            u64 = 86_400_000; // 24h in milliseconds

    // EBG status
    const STATUS_INITIATED: u8 = 1;
    const STATUS_COMPLETED: u8 = 2;
    const STATUS_EXPIRED:   u8 = 3;
    const STATUS_FAILED:    u8 = 4;

    // Emergency types (validated as strings)
    const TYPE_LIFE_THREATENING:  vector<u8> = b"LIFE_THREATENING";
    const TYPE_UNCONSCIOUS:       vector<u8> = b"UNCONSCIOUS";
    const TYPE_CRITICAL_SURGERY:  vector<u8> = b"CRITICAL_SURGERY";

    // ===== Structs =====

    public struct EBGAdminCap has key, store {
        id: UID,
    }

    /// Shared EBG registry — stores all emergency access logs.
    public struct EBGRegistry has key {
        id: UID,
        /// ebg_id → EBGLog
        logs: Table<String, EBGLog>,
        /// doctor_id → DoctorRateLimit
        rate_limits: Table<String, DoctorRateLimit>,
        total_ebg_events: u64,
        created_at: u64,
    }

    /// One complete EBG event lifecycle.
    public struct EBGLog has store {
        ebg_id: String,                   // "EBG-2024-0001"
        doctor_id: String,
        doctor_str_number: String,        // snapshot at time of access
        hospital_id: String,              // doctor's hospital at time of access
        patient_nik_hash: String,
        emergency_type: String,
        justification_hash: String,       // sha256(justification) — not plaintext
        session_id: String,               // UUID from backend (for Redis cross-ref)
        status: u8,                       // INITIATED → COMPLETED/EXPIRED/FAILED
        records_accessed: vector<String>, // filled on COMPLETED
        initiated_at: u64,
        completed_at: u64,                // 0 if not yet completed
        session_duration_ms: u64,
        initiated_by: address,
    }

    /// Per-doctor rate limit tracking.
    /// Resets after 24h window from first request.
    public struct DoctorRateLimit has store {
        doctor_id: String,
        window_start: u64,    // timestamp of first EBG in current window
        count_in_window: u64, // how many EBGs in current 24h window
    }

    // ===== Events =====

    public struct EmergencyAccessInitiated has copy, drop {
        ebg_id: String,
        doctor_id: String,
        patient_nik_hash: String,
        emergency_type: String,
        justification_hash: String,
        session_id: String,
        timestamp: u64,
    }

    public struct EmergencyAccessCompleted has copy, drop {
        ebg_id: String,
        doctor_id: String,
        records_accessed: vector<String>,
        session_duration_ms: u64,
        timestamp: u64,
    }

    public struct EmergencyAccessFailed has copy, drop {
        ebg_id: String,
        doctor_id: String,
        reason: String,
        timestamp: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let registry = EBGRegistry {
            id: object::new(ctx),
            logs: table::new(ctx),
            rate_limits: table::new(ctx),
            total_ebg_events: 0,
            created_at: 0,
        };
        transfer::share_object(registry);

        let admin_cap = EBGAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, ctx.sender());
    }

    // ===== Public Functions =====

    /// Gate 1-5: Validate + write INITIATED log on-chain.
    /// Called by NestJS BEFORE issuing the EBG session token.
    /// If this succeeds, the session token can be issued.
    /// If this fails, no token is issued and no data access happens.
    ///
    /// @param ebg_id             unique ID "EBG-2024-0001" (generated by backend)
    /// @param doctor_id          must be VERIFIED in DoctorRegistry
    /// @param patient_nik_hash   patient to access
    /// @param emergency_type     LIFE_THREATENING | UNCONSCIOUS | CRITICAL_SURGERY
    /// @param justification_hash sha256(justification plaintext) — plaintext stays in backend DB
    /// @param session_id         UUID for Redis session tracking
    public fun initiate_emergency_access(
        registry: &mut EBGRegistry,
        doctor_registry: &DoctorRegistry,
        patient_registry: &PatientRegistry,
        ebg_id: String,
        doctor_id: String,
        patient_nik_hash: String,
        emergency_type: String,
        justification_hash: String,
        session_id: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // --- Gate 1: Doctor must be verified ---
        assert!(
            doctor_registry::is_verified(doctor_registry, &doctor_id),
            E_DOCTOR_NOT_VERIFIED
        );

        // --- Patient must exist ---
        assert!(
            patient_registry::nik_hash_exists(patient_registry, &patient_nik_hash),
            E_PATIENT_NOT_FOUND
        );

        // --- Gate 2: Justification hash must be non-empty ---
        // (length check on plaintext is done by NestJS before hashing)
        assert!(string::length(&justification_hash) > 0, E_JUSTIFICATION_TOO_SHORT);

        // --- Validate emergency type ---
        assert!(is_valid_emergency_type(&emergency_type), E_INVALID_EMERGENCY_TYPE);

        // --- No duplicate EBG ID ---
        assert!(!table::contains(&registry.logs, ebg_id), E_DUPLICATE_EBG_ID);
        assert!(string::length(&ebg_id) > 0, E_INVALID_EBG_ID);

        let now = clock::timestamp_ms(clock);

        // --- Gate 5: Rate limit check ---
        check_and_update_rate_limit(registry, &doctor_id, now);

        // --- Get doctor snapshot info for audit ---
        let doctor_str = doctor_registry::get_doctor_str(doctor_registry, &doctor_id);
        let hospital_id = doctor_registry::get_doctor_hospital(doctor_registry, &doctor_id);

        // --- Gate 4: Write INITIATED log BEFORE data access ---
        event::emit(EmergencyAccessInitiated {
            ebg_id,
            doctor_id,
            patient_nik_hash,
            emergency_type,
            justification_hash,
            session_id,
            timestamp: now,
        });

        table::add(&mut registry.logs, ebg_id, EBGLog {
            ebg_id,
            doctor_id,
            doctor_str_number: doctor_str,
            hospital_id,
            patient_nik_hash,
            emergency_type,
            justification_hash,
            session_id,
            status: STATUS_INITIATED,
            records_accessed: vector[],
            initiated_at: now,
            completed_at: 0,
            session_duration_ms: 0,
            initiated_by: ctx.sender(),
        });

        registry.total_ebg_events = registry.total_ebg_events + 1;
    }

    /// Mark EBG session as COMPLETED.
    /// Called by NestJS after doctor closes session or 15min TTL expires.
    /// Records which record_ids were accessed during the session.
    public fun complete_emergency_access(
        registry: &mut EBGRegistry,
        ebg_id: String,
        records_accessed: vector<String>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&registry.logs, ebg_id), E_EBG_NOT_FOUND);
        let log = table::borrow_mut(&mut registry.logs, ebg_id);
        assert!(log.status == STATUS_INITIATED, E_EBG_ALREADY_COMPLETED);

        let now = clock::timestamp_ms(clock);
        let duration = if (now >= log.initiated_at) { now - log.initiated_at } else { 0 };

        log.status = STATUS_COMPLETED;
        log.completed_at = now;
        log.session_duration_ms = duration;
        log.records_accessed = records_accessed;

        event::emit(EmergencyAccessCompleted {
            ebg_id,
            doctor_id: log.doctor_id,
            records_accessed: log.records_accessed,
            session_duration_ms: duration,
            timestamp: now,
        });

        // Suppress unused variable warning
        let _ = ctx;
    }

    /// Mark EBG session as FAILED (e.g. patient not found, decryption error).
    /// Called by NestJS if data access failed after INITIATED was logged.
    public fun fail_emergency_access(
        registry: &mut EBGRegistry,
        ebg_id: String,
        reason: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&registry.logs, ebg_id), E_EBG_NOT_FOUND);
        let log = table::borrow_mut(&mut registry.logs, ebg_id);
        assert!(log.status == STATUS_INITIATED, E_EBG_ALREADY_COMPLETED);

        let now = clock::timestamp_ms(clock);
        log.status = STATUS_FAILED;
        log.completed_at = now;
        log.session_duration_ms = if (now >= log.initiated_at) { now - log.initiated_at } else { 0 };

        event::emit(EmergencyAccessFailed {
            ebg_id,
            doctor_id: log.doctor_id,
            reason,
            timestamp: now,
        });

        let _ = ctx;
    }

    /// Mark EBG session as EXPIRED (TTL passed without explicit close).
    /// Can be called by anyone — session_id in Redis already expired anyway.
    public fun expire_emergency_access(
        registry: &mut EBGRegistry,
        ebg_id: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&registry.logs, ebg_id), E_EBG_NOT_FOUND);
        let log = table::borrow_mut(&mut registry.logs, ebg_id);
        assert!(log.status == STATUS_INITIATED, E_EBG_ALREADY_COMPLETED);

        let now = clock::timestamp_ms(clock);
        log.status = STATUS_EXPIRED;
        log.completed_at = now;
        log.session_duration_ms = if (now >= log.initiated_at) { now - log.initiated_at } else { 0 };

        let _ = ctx;
    }

    // ===== View Functions =====

    public fun ebg_exists(registry: &EBGRegistry, ebg_id: &String): bool {
        table::contains(&registry.logs, *ebg_id)
    }

    public fun total_ebg_events(registry: &EBGRegistry): u64 {
        registry.total_ebg_events
    }

    /// Get EBG log status.
    public fun get_ebg_status(registry: &EBGRegistry, ebg_id: &String): u8 {
        assert!(table::contains(&registry.logs, *ebg_id), E_EBG_NOT_FOUND);
        table::borrow(&registry.logs, *ebg_id).status
    }

    /// Get full EBG log for audit.
    /// Returns: (ebg_id, doctor_id, patient_nik_hash, emergency_type, status, initiated_at, completed_at)
    public fun get_ebg_info(
        registry: &EBGRegistry,
        ebg_id: &String,
    ): (String, String, String, String, u8, u64, u64) {
        assert!(table::contains(&registry.logs, *ebg_id), E_EBG_NOT_FOUND);
        let l = table::borrow(&registry.logs, *ebg_id);
        (l.ebg_id, l.doctor_id, l.patient_nik_hash, l.emergency_type, l.status, l.initiated_at, l.completed_at)
    }

    /// Get records accessed in a completed EBG session.
    public fun get_ebg_records_accessed(
        registry: &EBGRegistry,
        ebg_id: &String,
    ): vector<String> {
        assert!(table::contains(&registry.logs, *ebg_id), E_EBG_NOT_FOUND);
        table::borrow(&registry.logs, *ebg_id).records_accessed
    }

    /// Get doctor's current rate limit count in active window.
    public fun get_doctor_ebg_count(registry: &EBGRegistry, doctor_id: &String): u64 {
        if (!table::contains(&registry.rate_limits, *doctor_id)) { return 0 };
        table::borrow(&registry.rate_limits, *doctor_id).count_in_window
    }

    public fun status_initiated(): u8 { STATUS_INITIATED }
    public fun status_completed(): u8 { STATUS_COMPLETED }
    public fun status_expired(): u8   { STATUS_EXPIRED }
    public fun status_failed(): u8    { STATUS_FAILED }

    // ===== Internal Helpers =====

    /// Check and update rate limit for a doctor.
    /// Aborts if doctor has exceeded MAX_EBG_PER_DAY in current 24h window.
    fun check_and_update_rate_limit(
        registry: &mut EBGRegistry,
        doctor_id: &String,
        now: u64,
    ) {
        if (!table::contains(&registry.rate_limits, *doctor_id)) {
            // First EBG ever for this doctor
            table::add(&mut registry.rate_limits, *doctor_id, DoctorRateLimit {
                doctor_id: *doctor_id,
                window_start: now,
                count_in_window: 1,
            });
            return
        };

        let limit = table::borrow_mut(&mut registry.rate_limits, *doctor_id);

        if (now - limit.window_start >= MS_PER_DAY) {
            // Window expired — reset
            limit.window_start = now;
            limit.count_in_window = 1;
        } else {
            // Same window — check limit
            assert!(limit.count_in_window < MAX_EBG_PER_DAY, E_RATE_LIMIT_EXCEEDED);
            limit.count_in_window = limit.count_in_window + 1;
        };
    }

    /// Validate emergency type is one of the allowed values.
    fun is_valid_emergency_type(emergency_type: &String): bool {
        *emergency_type == string::utf8(TYPE_LIFE_THREATENING)
            || *emergency_type == string::utf8(TYPE_UNCONSCIOUS)
            || *emergency_type == string::utf8(TYPE_CRITICAL_SURGERY)
    }

    // ===== Test-only =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    #[test_only]
    public fun get_max_ebg_per_day(): u64 { MAX_EBG_PER_DAY }

    #[test_only]
    public fun get_ms_per_day(): u64 { MS_PER_DAY }
}
