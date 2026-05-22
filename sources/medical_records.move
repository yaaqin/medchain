/// MedChain - Medical Records Module
///
/// Handles creation, storage, and querying of medical records on Sui blockchain.
/// Actual medical data is encrypted off-chain (IPFS) — only metadata lives here.
///
/// Key design decisions:
/// - Records linked to patients via nik_hash (no direct patient_id coupling)
/// - IPFS hash stored on-chain for data retrieval
/// - data_hash stored for integrity verification (detect tampering)
/// - Access logs written on every cross-hospital read (immutable audit trail)
/// - Fee charged at record creation time via fee_manager
/// - Records are immutable once created (append-only)
module medchain::medical_records {

    // ===== Imports =====
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::string::{Self, String};
    use medchain::patient_registry::{Self, PatientRegistry};
    use medchain::fee_manager::{Self, FeeConfig};

    // ===== Error Codes =====
    const E_RECORD_NOT_FOUND:       u64 = 3001;
    const E_PATIENT_NOT_FOUND:      u64 = 3002;
    const E_DUPLICATE_RECORD_ID:    u64 = 3003;
    const E_INVALID_IPFS_REF:       u64 = 3004;
    const E_INVALID_DATA_HASH:      u64 = 3005;
    const E_INVALID_HOSPITAL_ID:    u64 = 3006;
    const E_INSUFFICIENT_FEE:       u64 = 3007;
    const E_RECORD_ALREADY_REVOKED: u64 = 3008;

    // ===== Constants =====
    const STATUS_ACTIVE:  u8 = 1;
    const STATUS_REVOKED: u8 = 0;

    // ===== Structs =====

    public struct RecordAdminCap has key, store {
        id: UID,
    }

    /// Shared registry of all medical records.
    public struct RecordRegistry has key {
        id: UID,
        records: Table<String, MedicalRecord>,
        patient_records: Table<String, vector<String>>,
        hospital_records: Table<String, vector<String>>,
        access_logs: Table<String, AccessLog>,
        total_records: u64,
        total_accesses: u64,
        created_at: u64,
    }

    /// On-chain metadata for one medical record.
    /// Actual medical data is encrypted and stored on IPFS.
    public struct MedicalRecord has store {
        record_id: String,
        patient_nik_hash: String,
        hospital_id: String,
        doctor_id: String,
        ipfs_ref: String,
        data_hash: String,
        record_type: String,
        fee_charged: u64,
        created_at: u64,
        status: u8,
        revoked_at: u64,
        revoke_reason: String,
    }

    /// Immutable log entry for every cross-hospital data access.
    public struct AccessLog has store {
        access_id: String,
        patient_nik_hash: String,
        accessing_hospital: String,
        accessed_records: vector<String>,
        purpose: String,
        accessed_by: address,
        timestamp: u64,
    }

    // ===== Events =====

    public struct RecordCreated has copy, drop {
        record_id: String,
        patient_nik_hash: String,
        hospital_id: String,
        doctor_id: String,
        ipfs_ref: String,
        record_type: String,
        fee_charged: u64,
        timestamp: u64,
    }

    public struct RecordRevoked has copy, drop {
        record_id: String,
        patient_nik_hash: String,
        revoked_by: address,
        reason: String,
        timestamp: u64,
    }

    public struct RecordAccessed has copy, drop {
        access_id: String,
        patient_nik_hash: String,
        accessing_hospital: String,
        record_count: u64,
        purpose: String,
        timestamp: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let registry = RecordRegistry {
            id: object::new(ctx),
            records: table::new(ctx),
            patient_records: table::new(ctx),
            hospital_records: table::new(ctx),
            access_logs: table::new(ctx),
            total_records: 0,
            total_accesses: 0,
            created_at: 0,
        };
        transfer::share_object(registry);

        let admin_cap = RecordAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, ctx.sender());
    }

    // ===== Public Functions =====

    /// Create a new medical record.
    /// Called by hospital backend after encrypting data and uploading to IPFS.
    public fun create_record(
        registry: &mut RecordRegistry,
        patient_registry: &PatientRegistry,
        fee_config: &FeeConfig,
        record_id: String,
        patient_nik_hash: String,
        hospital_id: String,
        doctor_id: String,
        ipfs_ref: String,
        data_hash: String,
        record_type: String,
        fee_paid: u64,
        clock: &Clock,
        _ctx: &mut TxContext,
    ) {
        // --- Validations ---
        assert!(!table::contains(&registry.records, record_id), E_DUPLICATE_RECORD_ID);
        assert!(patient_registry::nik_hash_exists(patient_registry, &patient_nik_hash), E_PATIENT_NOT_FOUND);
        assert!(string::length(&ipfs_ref) > 0, E_INVALID_IPFS_REF);
        assert!(string::length(&data_hash) > 0, E_INVALID_DATA_HASH);
        assert!(string::length(&hospital_id) > 0, E_INVALID_HOSPITAL_ID);

        // --- Fee check ---
        let required_fee = fee_manager::calculate_record_fee(fee_config);
        assert!(fee_paid >= required_fee, E_INSUFFICIENT_FEE);

        let now = clock::timestamp_ms(clock);

        // --- Patient index ---
        if (!table::contains(&registry.patient_records, patient_nik_hash)) {
            table::add(&mut registry.patient_records, patient_nik_hash, vector[]);
        };
        vector::push_back(
            table::borrow_mut(&mut registry.patient_records, patient_nik_hash),
            record_id,
        );

        // --- Hospital index ---
        if (!table::contains(&registry.hospital_records, hospital_id)) {
            table::add(&mut registry.hospital_records, hospital_id, vector[]);
        };
        vector::push_back(
            table::borrow_mut(&mut registry.hospital_records, hospital_id),
            record_id,
        );

        registry.total_records = registry.total_records + 1;

        // --- Event ---
        event::emit(RecordCreated {
            record_id,
            patient_nik_hash,
            hospital_id,
            doctor_id,
            ipfs_ref,
            record_type,
            fee_charged: fee_paid,
            timestamp: now,
        });

        // --- Store ---
        table::add(&mut registry.records, record_id, MedicalRecord {
            record_id,
            patient_nik_hash,
            hospital_id,
            doctor_id,
            ipfs_ref,
            data_hash,
            record_type,
            fee_charged: fee_paid,
            created_at: now,
            status: STATUS_ACTIVE,
            revoked_at: 0,
            revoke_reason: string::utf8(b""),
        });
    }

    /// Log a cross-hospital access event.
    /// Must be called BEFORE returning data to the accessing hospital.
    public fun log_access(
        registry: &mut RecordRegistry,
        access_id: String,
        patient_nik_hash: String,
        accessing_hospital: String,
        record_ids: vector<String>,
        purpose: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now = clock::timestamp_ms(clock);
        let record_count = vector::length(&record_ids);

        event::emit(RecordAccessed {
            access_id,
            patient_nik_hash,
            accessing_hospital,
            record_count,
            purpose,
            timestamp: now,
        });

        table::add(&mut registry.access_logs, access_id, AccessLog {
            access_id,
            patient_nik_hash,
            accessing_hospital,
            accessed_records: record_ids,
            purpose,
            accessed_by: ctx.sender(),
            timestamp: now,
        });

        registry.total_accesses = registry.total_accesses + 1;
    }

    /// Soft-revoke a medical record (admin only).
    public fun revoke_record(
        _cap: &RecordAdminCap,
        registry: &mut RecordRegistry,
        record_id: String,
        reason: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&registry.records, record_id), E_RECORD_NOT_FOUND);
        let record = table::borrow_mut(&mut registry.records, record_id);
        assert!(record.status == STATUS_ACTIVE, E_RECORD_ALREADY_REVOKED);

        let now = clock::timestamp_ms(clock);
        record.status = STATUS_REVOKED;
        record.revoked_at = now;
        record.revoke_reason = reason;

        event::emit(RecordRevoked {
            record_id,
            patient_nik_hash: record.patient_nik_hash,
            revoked_by: ctx.sender(),
            reason: record.revoke_reason,
            timestamp: now,
        });
    }

    // ===== View Functions =====

    public fun record_exists(registry: &RecordRegistry, record_id: &String): bool {
        table::contains(&registry.records, *record_id)
    }

    public fun total_records(registry: &RecordRegistry): u64 {
        registry.total_records
    }

    public fun total_accesses(registry: &RecordRegistry): u64 {
        registry.total_accesses
    }

    public fun patient_record_count(registry: &RecordRegistry, nik_hash: &String): u64 {
        if (!table::contains(&registry.patient_records, *nik_hash)) { return 0 };
        vector::length(table::borrow(&registry.patient_records, *nik_hash))
    }

    public fun get_patient_record_ids(registry: &RecordRegistry, nik_hash: &String): vector<String> {
        if (!table::contains(&registry.patient_records, *nik_hash)) { return vector[] };
        *table::borrow(&registry.patient_records, *nik_hash)
    }

    public fun get_hospital_record_ids(registry: &RecordRegistry, hospital_id: &String): vector<String> {
        if (!table::contains(&registry.hospital_records, *hospital_id)) { return vector[] };
        *table::borrow(&registry.hospital_records, *hospital_id)
    }

    public fun get_record_info(
        registry: &RecordRegistry,
        record_id: &String,
    ): (String, String, String, String, String, String, u64, u8) {
        assert!(table::contains(&registry.records, *record_id), E_RECORD_NOT_FOUND);
        let r = table::borrow(&registry.records, *record_id);
        (r.record_id, r.patient_nik_hash, r.hospital_id, r.ipfs_ref, r.data_hash, r.record_type, r.created_at, r.status)
    }

    public fun get_record_ipfs(registry: &RecordRegistry, record_id: &String): (String, String) {
        assert!(table::contains(&registry.records, *record_id), E_RECORD_NOT_FOUND);
        let r = table::borrow(&registry.records, *record_id);
        (r.ipfs_ref, r.data_hash)
    }

    public fun get_record_status(registry: &RecordRegistry, record_id: &String): u8 {
        assert!(table::contains(&registry.records, *record_id), E_RECORD_NOT_FOUND);
        table::borrow(&registry.records, *record_id).status
    }

    public fun access_log_exists(registry: &RecordRegistry, access_id: &String): bool {
        table::contains(&registry.access_logs, *access_id)
    }

    public fun get_record_fee_charged(registry: &RecordRegistry, record_id: &String): u64 {
        assert!(table::contains(&registry.records, *record_id), E_RECORD_NOT_FOUND);
        table::borrow(&registry.records, *record_id).fee_charged
    }

    public fun status_active(): u8 { STATUS_ACTIVE }
    public fun status_revoked(): u8 { STATUS_REVOKED }

    // ===== Test-only =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}
