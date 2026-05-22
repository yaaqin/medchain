/// MedChain - Doctor Registry Module
///
/// Manages verified doctor credentials on-chain.
/// Only VERIFIED doctors can trigger Emergency Break Glass access.
///
/// Key design decisions:
/// - Doctor verification stored on-chain for transparency + auditability
/// - AdminCap required to grant/revoke verification
/// - STR (Surat Tanda Registrasi) + SIP (Surat Izin Praktik) stored as proof
/// - Revocation is permanent on-chain (can re-verify with new entry)
module medchain::doctor_registry {

    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::string::{Self, String};

    // ===== Error Codes =====
    const E_DOCTOR_ALREADY_VERIFIED: u64 = 4001;
    const E_DOCTOR_NOT_FOUND:        u64 = 4002;
    const E_DOCTOR_ALREADY_REVOKED:  u64 = 4004;
    const E_INVALID_DOCTOR_ID:       u64 = 4005;
    const E_INVALID_STR_NUMBER:      u64 = 4006;
    const E_INVALID_HOSPITAL_ID:     u64 = 4007;

    // ===== Constants =====
    const STATUS_VERIFIED: u8 = 1;
    const STATUS_REVOKED:  u8 = 0;

    // ===== Structs =====

    public struct DoctorAdminCap has key, store {
        id: UID,
    }

    /// Shared registry of all verified doctors.
    public struct DoctorRegistry has key {
        id: UID,
        /// doctor_id → DoctorRecord
        doctors: Table<String, DoctorRecord>,
        /// nik_hash → doctor_id (lookup by doctor's NIK)
        nik_index: Table<String, String>,
        total_verified: u64,
        created_at: u64,
    }

    /// On-chain record of a verified doctor.
    public struct DoctorRecord has store {
        doctor_id: String,          // "DOC-0001"
        nik_hash: String,           // sha256(doctor NIK)
        str_number: String,         // Surat Tanda Registrasi
        sip_number: String,         // Surat Izin Praktik
        hospital_id: String,        // affiliated hospital
        specialization: String,     // "Emergency Medicine", "General", etc.
        verified_by: address,       // admin who granted verification
        verified_at: u64,
        status: u8,                 // STATUS_VERIFIED | STATUS_REVOKED
        revoked_at: u64,
        revoke_reason: String,
    }

    // ===== Events =====

    public struct DoctorVerified has copy, drop {
        doctor_id: String,
        nik_hash: String,
        hospital_id: String,
        str_number: String,
        verified_by: address,
        timestamp: u64,
    }

    public struct DoctorRevoked has copy, drop {
        doctor_id: String,
        hospital_id: String,
        revoked_by: address,
        reason: String,
        timestamp: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let registry = DoctorRegistry {
            id: object::new(ctx),
            doctors: table::new(ctx),
            nik_index: table::new(ctx),
            total_verified: 0,
            created_at: 0,
        };
        transfer::share_object(registry);

        let admin_cap = DoctorAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, ctx.sender());
    }

    // ===== Admin Functions =====

    /// Grant VERIFIED_DOCTOR status to a doctor.
    /// Requires DoctorAdminCap.
    public fun verify_doctor(
        _cap: &DoctorAdminCap,
        registry: &mut DoctorRegistry,
        doctor_id: String,
        nik_hash: String,
        str_number: String,
        sip_number: String,
        hospital_id: String,
        specialization: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(string::length(&doctor_id) > 0, E_INVALID_DOCTOR_ID);
        assert!(string::length(&str_number) > 0, E_INVALID_STR_NUMBER);
        assert!(string::length(&hospital_id) > 0, E_INVALID_HOSPITAL_ID);
        assert!(!table::contains(&registry.doctors, doctor_id), E_DOCTOR_ALREADY_VERIFIED);
        assert!(!table::contains(&registry.nik_index, nik_hash), E_DOCTOR_ALREADY_VERIFIED);

        let now = clock::timestamp_ms(clock);
        let caller = ctx.sender();

        event::emit(DoctorVerified {
            doctor_id,
            nik_hash,
            hospital_id,
            str_number,
            verified_by: caller,
            timestamp: now,
        });

        table::add(&mut registry.nik_index, nik_hash, doctor_id);
        table::add(&mut registry.doctors, doctor_id, DoctorRecord {
            doctor_id,
            nik_hash,
            str_number,
            sip_number,
            hospital_id,
            specialization,
            verified_by: caller,
            verified_at: now,
            status: STATUS_VERIFIED,
            revoked_at: 0,
            revoke_reason: string::utf8(b""),
        });

        registry.total_verified = registry.total_verified + 1;
    }

    /// Revoke a doctor's verified status.
    /// Record stays on-chain — blockchain is immutable.
    public fun revoke_doctor(
        _cap: &DoctorAdminCap,
        registry: &mut DoctorRegistry,
        doctor_id: String,
        reason: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&registry.doctors, doctor_id), E_DOCTOR_NOT_FOUND);
        let doctor = table::borrow_mut(&mut registry.doctors, doctor_id);
        assert!(doctor.status == STATUS_VERIFIED, E_DOCTOR_ALREADY_REVOKED);

        let now = clock::timestamp_ms(clock);
        doctor.status = STATUS_REVOKED;
        doctor.revoked_at = now;
        doctor.revoke_reason = reason;

        event::emit(DoctorRevoked {
            doctor_id,
            hospital_id: doctor.hospital_id,
            revoked_by: ctx.sender(),
            reason: doctor.revoke_reason,
            timestamp: now,
        });
    }

    // ===== View Functions =====

    /// Check if a doctor is currently verified (active).
    /// This is the main gate check used by EBG module.
    public fun is_verified(registry: &DoctorRegistry, doctor_id: &String): bool {
        if (!table::contains(&registry.doctors, *doctor_id)) { return false };
        table::borrow(&registry.doctors, *doctor_id).status == STATUS_VERIFIED
    }

    public fun doctor_exists(registry: &DoctorRegistry, doctor_id: &String): bool {
        table::contains(&registry.doctors, *doctor_id)
    }

    public fun total_verified(registry: &DoctorRegistry): u64 {
        registry.total_verified
    }

    /// Get doctor's hospital affiliation.
    public fun get_doctor_hospital(registry: &DoctorRegistry, doctor_id: &String): String {
        assert!(table::contains(&registry.doctors, *doctor_id), E_DOCTOR_NOT_FOUND);
        table::borrow(&registry.doctors, *doctor_id).hospital_id
    }

    /// Get doctor's STR number (for EBG audit log).
    public fun get_doctor_str(registry: &DoctorRegistry, doctor_id: &String): String {
        assert!(table::contains(&registry.doctors, *doctor_id), E_DOCTOR_NOT_FOUND);
        table::borrow(&registry.doctors, *doctor_id).str_number
    }

    /// Get full doctor info for audit purposes.
    /// Returns: (doctor_id, nik_hash, str_number, hospital_id, specialization, status)
    public fun get_doctor_info(
        registry: &DoctorRegistry,
        doctor_id: &String,
    ): (String, String, String, String, String, u8) {
        assert!(table::contains(&registry.doctors, *doctor_id), E_DOCTOR_NOT_FOUND);
        let d = table::borrow(&registry.doctors, *doctor_id);
        (d.doctor_id, d.nik_hash, d.str_number, d.hospital_id, d.specialization, d.status)
    }

    public fun status_verified(): u8 { STATUS_VERIFIED }
    public fun status_revoked(): u8  { STATUS_REVOKED }

    // ===== Test-only =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}
