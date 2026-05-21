/// MedChain - Fee Manager Module
///
/// Manages configurable SGT fee structure for:
///   - Record creation (hospital creates a record)
///   - Data export (patient/hospital downloads PDF)
///
/// Key design decisions:
/// - Fees stored as u64 in MIST-equivalent units (1 SGT = 1_000_000_000 base units)
/// - All fee changes logged on-chain as immutable history (audit trail)
/// - AdminCap from patient_registry is NOT reused — FeeManager has its own cap
///   so fee admin can be a separate multisig wallet from registry admin
/// - Emergency Break Glass access is always free (life safety)
/// - Cross-hospital read access is always free (promotes data sharing)
module medchain::fee_manager {

    // ===== Imports =====
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::string::{Self, String};

    // ===== Error Codes =====
    const E_INVALID_FEE:            u64 = 2002;  // fee exceeds max cap
    const E_INVALID_MULTIPLIER:     u64 = 2003;  // multiplier out of range
    const E_ZERO_FILE_SIZE:         u64 = 2005;

    // ===== Constants =====

    // SGT base unit: 1 SGT = 1_000_000_000 (like SUI uses MIST)
    const SGT_DECIMALS: u64 = 1_000_000_000;

    // Default fees
    const DEFAULT_RECORD_FEE_SGT:       u64 = 1;   // 1 SGT per record creation
    const DEFAULT_EXPORT_BASE_FEE_SGT:  u64 = 1;   // 1 SGT base for export ≤ 2MB
    const DEFAULT_EXPORT_SIZE_THRESHOLD_MB: u64 = 2; // 2 MB threshold
    // multiplier stored as basis points: 10000 = 1.0x, 7000 = 0.7x
    const DEFAULT_EXPORT_MULTIPLIER_BPS: u64 = 10_000;

    // Safety cap: max fee = 100 SGT (prevent admin mistakes)
    const MAX_FEE_SGT: u64 = 100;

    // Multiplier bounds: 0.1x (1000 bps) to 5.0x (50000 bps)
    const MIN_MULTIPLIER_BPS: u64 = 1_000;
    const MAX_MULTIPLIER_BPS: u64 = 50_000;

    // Fee type identifiers (used as keys in history table)
    const FEE_TYPE_RECORD:      vector<u8> = b"RECORD_CREATION";
    const FEE_TYPE_EXPORT_BASE: vector<u8> = b"EXPORT_BASE";
    const FEE_TYPE_EXPORT_MULT: vector<u8> = b"EXPORT_MULTIPLIER";

    // ===== Structs =====

    /// Separate admin cap for fee management.
    /// Can be held by a different address than PatientRegistry admin.
    public struct FeeAdminCap has key, store {
        id: UID,
    }

    /// Shared fee configuration object.
    /// One per deployment, queried by all modules that charge fees.
    public struct FeeConfig has key {
        id: UID,

        // --- Record creation fee ---
        record_fee_sgt: u64,          // SGT units (not base units)
        record_fee_enabled: bool,     // false = free period

        // --- Export fee ---
        export_base_fee_sgt: u64,     // fee for files ≤ threshold
        export_size_threshold_mb: u64,// files above this → size-based pricing
        export_multiplier_bps: u64,   // multiplier in basis points (10000 = 1.0x)
        export_fee_enabled: bool,

        // --- Always-free operations (stored for transparency) ---
        // cross_hospital_access_fee: always 0
        // emergency_break_glass_fee: always 0

        // --- History ---
        // fee_type_string → vector of FeeChangeLog
        change_history: Table<String, vector<FeeChangeLog>>,

        // Metadata
        total_fee_changes: u64,
        created_at: u64,
        last_updated_at: u64,
    }

    /// One entry in the immutable fee change history.
    public struct FeeChangeLog has store, copy, drop {
        fee_type: String,
        old_value: u64,
        new_value: u64,
        changed_by: address,
        reason: String,       // admin-provided reason (e.g. "launch promo")
        timestamp: u64,
    }

    // ===== Events =====

    public struct FeeConfigInitialized has copy, drop {
        config_id: address,
        record_fee_sgt: u64,
        export_base_fee_sgt: u64,
        timestamp: u64,
    }

    public struct RecordFeeUpdated has copy, drop {
        old_fee_sgt: u64,
        new_fee_sgt: u64,
        enabled: bool,
        changed_by: address,
        reason: String,
        timestamp: u64,
    }

    public struct ExportBaseFeeUpdated has copy, drop {
        old_fee_sgt: u64,
        new_fee_sgt: u64,
        enabled: bool,
        changed_by: address,
        reason: String,
        timestamp: u64,
    }

    public struct ExportMultiplierUpdated has copy, drop {
        old_multiplier_bps: u64,
        new_multiplier_bps: u64,
        changed_by: address,
        reason: String,
        timestamp: u64,
    }

    public struct FeeToggled has copy, drop {
        fee_type: String,
        enabled: bool,
        changed_by: address,
        timestamp: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let mut history: Table<String, vector<FeeChangeLog>> = table::new(ctx);

        // Pre-create history buckets for each fee type
        table::add(
            &mut history,
            string::utf8(FEE_TYPE_RECORD),
            vector[],
        );
        table::add(
            &mut history,
            string::utf8(FEE_TYPE_EXPORT_BASE),
            vector[],
        );
        table::add(
            &mut history,
            string::utf8(FEE_TYPE_EXPORT_MULT),
            vector[],
        );

        let config = FeeConfig {
            id: object::new(ctx),
            record_fee_sgt: DEFAULT_RECORD_FEE_SGT,
            record_fee_enabled: true,
            export_base_fee_sgt: DEFAULT_EXPORT_BASE_FEE_SGT,
            export_size_threshold_mb: DEFAULT_EXPORT_SIZE_THRESHOLD_MB,
            export_multiplier_bps: DEFAULT_EXPORT_MULTIPLIER_BPS,
            export_fee_enabled: true,
            change_history: history,
            total_fee_changes: 0,
            created_at: 0,
            last_updated_at: 0,
        };

        let config_id = object::id_address(&config);
        transfer::share_object(config);

        let admin_cap = FeeAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, ctx.sender());

        event::emit(FeeConfigInitialized {
            config_id,
            record_fee_sgt: DEFAULT_RECORD_FEE_SGT,
            export_base_fee_sgt: DEFAULT_EXPORT_BASE_FEE_SGT,
            timestamp: 0,
        });
    }

    // ===== Admin: Update Fees =====

    /// Update the record creation fee.
    /// Set to 0 to make record creation free (e.g. launch period).
    public fun update_record_fee(
        _cap: &FeeAdminCap,
        config: &mut FeeConfig,
        new_fee_sgt: u64,
        reason: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(new_fee_sgt <= MAX_FEE_SGT, E_INVALID_FEE);

        let old_fee = config.record_fee_sgt;
        let now = clock::timestamp_ms(clock);
        let caller = ctx.sender();

        config.record_fee_sgt = new_fee_sgt;
        config.last_updated_at = now;
        config.total_fee_changes = config.total_fee_changes + 1;

        // Append to history
        let log = FeeChangeLog {
            fee_type: string::utf8(FEE_TYPE_RECORD),
            old_value: old_fee,
            new_value: new_fee_sgt,
            changed_by: caller,
            reason,
            timestamp: now,
        };
        let history = table::borrow_mut(
            &mut config.change_history,
            string::utf8(FEE_TYPE_RECORD),
        );
        vector::push_back(history, log);

        event::emit(RecordFeeUpdated {
            old_fee_sgt: old_fee,
            new_fee_sgt,
            enabled: config.record_fee_enabled,
            changed_by: caller,
            reason: log.reason,
            timestamp: now,
        });
    }

    /// Update the base export fee (for files ≤ threshold).
    public fun update_export_base_fee(
        _cap: &FeeAdminCap,
        config: &mut FeeConfig,
        new_fee_sgt: u64,
        reason: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(new_fee_sgt <= MAX_FEE_SGT, E_INVALID_FEE);

        let old_fee = config.export_base_fee_sgt;
        let now = clock::timestamp_ms(clock);
        let caller = ctx.sender();

        config.export_base_fee_sgt = new_fee_sgt;
        config.last_updated_at = now;
        config.total_fee_changes = config.total_fee_changes + 1;

        let log = FeeChangeLog {
            fee_type: string::utf8(FEE_TYPE_EXPORT_BASE),
            old_value: old_fee,
            new_value: new_fee_sgt,
            changed_by: caller,
            reason,
            timestamp: now,
        };
        let history = table::borrow_mut(
            &mut config.change_history,
            string::utf8(FEE_TYPE_EXPORT_BASE),
        );
        vector::push_back(history, log);

        event::emit(ExportBaseFeeUpdated {
            old_fee_sgt: old_fee,
            new_fee_sgt,
            enabled: config.export_fee_enabled,
            changed_by: caller,
            reason: log.reason,
            timestamp: now,
        });
    }

    /// Update export multiplier (in basis points).
    /// 10000 = 1.0x, 7000 = 0.7x, 15000 = 1.5x
    /// Applied to file size in MB for files above threshold.
    public fun update_export_multiplier(
        _cap: &FeeAdminCap,
        config: &mut FeeConfig,
        new_multiplier_bps: u64,
        reason: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(
            new_multiplier_bps >= MIN_MULTIPLIER_BPS
                && new_multiplier_bps <= MAX_MULTIPLIER_BPS,
            E_INVALID_MULTIPLIER
        );

        let old_mult = config.export_multiplier_bps;
        let now = clock::timestamp_ms(clock);
        let caller = ctx.sender();

        config.export_multiplier_bps = new_multiplier_bps;
        config.last_updated_at = now;
        config.total_fee_changes = config.total_fee_changes + 1;

        let log = FeeChangeLog {
            fee_type: string::utf8(FEE_TYPE_EXPORT_MULT),
            old_value: old_mult,
            new_value: new_multiplier_bps,
            changed_by: caller,
            reason,
            timestamp: now,
        };
        let history = table::borrow_mut(
            &mut config.change_history,
            string::utf8(FEE_TYPE_EXPORT_MULT),
        );
        vector::push_back(history, log);

        event::emit(ExportMultiplierUpdated {
            old_multiplier_bps: old_mult,
            new_multiplier_bps,
            changed_by: caller,
            reason: log.reason,
            timestamp: now,
        });
    }

    /// Toggle record creation fee on/off without changing the fee amount.
    /// Useful for free periods without losing the configured fee value.
    public fun toggle_record_fee(
        _cap: &FeeAdminCap,
        config: &mut FeeConfig,
        enabled: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        config.record_fee_enabled = enabled;
        config.last_updated_at = clock::timestamp_ms(clock);

        event::emit(FeeToggled {
            fee_type: string::utf8(FEE_TYPE_RECORD),
            enabled,
            changed_by: ctx.sender(),
            timestamp: config.last_updated_at,
        });
    }

    /// Toggle export fee on/off.
    public fun toggle_export_fee(
        _cap: &FeeAdminCap,
        config: &mut FeeConfig,
        enabled: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        config.export_fee_enabled = enabled;
        config.last_updated_at = clock::timestamp_ms(clock);

        event::emit(FeeToggled {
            fee_type: string::utf8(FEE_TYPE_EXPORT_BASE),
            enabled,
            changed_by: ctx.sender(),
            timestamp: config.last_updated_at,
        });
    }

    // ===== Public View: Fee Calculation =====

    /// Calculate record creation fee in base SGT units.
    /// Returns 0 if fee is disabled.
    /// Called by medical_records module before charging.
    public fun calculate_record_fee(config: &FeeConfig): u64 {
        if (!config.record_fee_enabled) {
            return 0
        };
        config.record_fee_sgt * SGT_DECIMALS
    }

    /// Calculate export fee in base SGT units based on file size.
    ///
    /// Pricing logic (matches doc spec):
    ///   file_size_mb ≤ threshold  →  base_fee
    ///   file_size_mb > threshold  →  file_size_mb × multiplier × SGT_DECIMALS
    ///
    /// @param file_size_kb  file size in kilobytes (avoids float math)
    public fun calculate_export_fee(config: &FeeConfig, file_size_kb: u64): u64 {
        assert!(file_size_kb > 0, E_ZERO_FILE_SIZE);

        if (!config.export_fee_enabled) {
            return 0
        };

        let threshold_kb = config.export_size_threshold_mb * 1024;

        if (file_size_kb <= threshold_kb) {
            // Small file → flat base fee
            config.export_base_fee_sgt * SGT_DECIMALS
        } else {
            // Large file → size-based: (size_kb / 1024) × multiplier × decimals
            // To avoid integer division loss, multiply first
            // fee = (file_size_kb * multiplier_bps * SGT_DECIMALS) / (1024 * 10000)
            let numerator = file_size_kb * config.export_multiplier_bps * SGT_DECIMALS;
            let denominator = 1024 * 10_000;
            numerator / denominator
        }
    }

    /// Get record fee in SGT (human-readable, not base units).
    public fun record_fee_sgt(config: &FeeConfig): u64 {
        config.record_fee_sgt
    }

    /// Get export base fee in SGT.
    public fun export_base_fee_sgt(config: &FeeConfig): u64 {
        config.export_base_fee_sgt
    }

    /// Get export multiplier in basis points.
    public fun export_multiplier_bps(config: &FeeConfig): u64 {
        config.export_multiplier_bps
    }

    /// Get export size threshold in MB.
    public fun export_size_threshold_mb(config: &FeeConfig): u64 {
        config.export_size_threshold_mb
    }

    /// Check if record fee is currently enabled.
    public fun is_record_fee_enabled(config: &FeeConfig): bool {
        config.record_fee_enabled
    }

    /// Check if export fee is currently enabled.
    public fun is_export_fee_enabled(config: &FeeConfig): bool {
        config.export_fee_enabled
    }

    /// Get total number of fee configuration changes ever made.
    public fun total_fee_changes(config: &FeeConfig): u64 {
        config.total_fee_changes
    }

    /// Get the SGT_DECIMALS constant (for external callers).
    public fun sgt_decimals(): u64 {
        SGT_DECIMALS
    }

    // ===== Test-only =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    #[test_only]
    public fun get_default_record_fee_sgt(): u64 { DEFAULT_RECORD_FEE_SGT }

    #[test_only]
    public fun get_default_export_base_fee_sgt(): u64 { DEFAULT_EXPORT_BASE_FEE_SGT }

    #[test_only]
    public fun get_default_multiplier_bps(): u64 { DEFAULT_EXPORT_MULTIPLIER_BPS }

    #[test_only]
    public fun get_max_fee_sgt(): u64 { MAX_FEE_SGT }

    #[test_only]
    public fun get_sgt_decimals(): u64 { SGT_DECIMALS }
}
