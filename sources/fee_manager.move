/// MedChain - Fee Manager Module
///
/// Manages configurable SGT fee structure + on-chain Treasury.
/// All fees paid in SGT are collected into Treasury.
/// Admin can withdraw SGT from Treasury anytime.
module medchain::fee_manager {

    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use std::string::{Self, String};
    use sgt::sgt::SGT;

    // ===== Error Codes =====
    const E_INVALID_FEE:         u64 = 2002;
    const E_INVALID_MULTIPLIER:  u64 = 2003;
    const E_ZERO_FILE_SIZE:      u64 = 2005;
    const E_INSUFFICIENT_FEE:    u64 = 2006;
    const E_INSUFFICIENT_BALANCE: u64 = 2007;

    // ===== Constants =====
    const SGT_DECIMALS: u64 = 1_000_000_000;

    const DEFAULT_RECORD_FEE_SGT:           u64 = 1;
    const DEFAULT_EXPORT_BASE_FEE_SGT:      u64 = 1;
    const DEFAULT_EXPORT_SIZE_THRESHOLD_MB: u64 = 2;
    const DEFAULT_EXPORT_MULTIPLIER_BPS:    u64 = 10_000;

    const MAX_FEE_SGT:      u64 = 100;
    const MIN_MULTIPLIER_BPS: u64 = 1_000;
    const MAX_MULTIPLIER_BPS: u64 = 50_000;

    const FEE_TYPE_RECORD:      vector<u8> = b"RECORD_CREATION";
    const FEE_TYPE_EXPORT_BASE: vector<u8> = b"EXPORT_BASE";
    const FEE_TYPE_EXPORT_MULT: vector<u8> = b"EXPORT_MULTIPLIER";

    // ===== Structs =====

    public struct FeeAdminCap has key, store {
        id: UID,
    }

    /// On-chain SGT treasury — collects all fees paid to the platform.
    public struct Treasury has key {
        id: UID,
        balance: Balance<SGT>,
        total_collected: u64,   // base SGT units ever collected
        total_withdrawn: u64,   // base SGT units ever withdrawn
    }

    public struct FeeConfig has key {
        id: UID,
        record_fee_sgt: u64,
        record_fee_enabled: bool,
        export_base_fee_sgt: u64,
        export_size_threshold_mb: u64,
        export_multiplier_bps: u64,
        export_fee_enabled: bool,
        change_history: Table<String, vector<FeeChangeLog>>,
        total_fee_changes: u64,
        created_at: u64,
        last_updated_at: u64,
    }

    public struct FeeChangeLog has store, copy, drop {
        fee_type: String,
        old_value: u64,
        new_value: u64,
        changed_by: address,
        reason: String,
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

    public struct FeeCollected has copy, drop {
        fee_type: String,   // "RECORD" | "EXPORT"
        amount: u64,        // base SGT units
        payer: address,
        timestamp: u64,
    }

    public struct TreasuryWithdrawn has copy, drop {
        amount: u64,
        recipient: address,
        timestamp: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let mut history: Table<String, vector<FeeChangeLog>> = table::new(ctx);
        table::add(&mut history, string::utf8(FEE_TYPE_RECORD), vector[]);
        table::add(&mut history, string::utf8(FEE_TYPE_EXPORT_BASE), vector[]);
        table::add(&mut history, string::utf8(FEE_TYPE_EXPORT_MULT), vector[]);

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

        // Treasury — shared so anyone can deposit, only admin can withdraw
        let treasury = Treasury {
            id: object::new(ctx),
            balance: balance::zero<SGT>(),
            total_collected: 0,
            total_withdrawn: 0,
        };
        transfer::share_object(treasury);

        let admin_cap = FeeAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, ctx.sender());

        event::emit(FeeConfigInitialized {
            config_id,
            record_fee_sgt: DEFAULT_RECORD_FEE_SGT,
            export_base_fee_sgt: DEFAULT_EXPORT_BASE_FEE_SGT,
            timestamp: 0,
        });
    }

    // ===== Payment Functions =====

    /// Collect record creation fee into Treasury.
    /// Called by medical_records::create_record.
    /// Takes exact fee amount — caller must split coin beforehand.
    /// Returns any overpayment back to caller.
    public fun collect_record_fee(
        treasury: &mut Treasury,
        config: &FeeConfig,
        payment: Coin<SGT>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<SGT> {
        let required = calculate_record_fee(config);
        let paid = coin::value(&payment);
        assert!(paid >= required, E_INSUFFICIENT_FEE);

        // Split exact fee amount into treasury
        let mut payment_mut = payment;
        let fee_coin = coin::split(&mut payment_mut, required, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
        treasury.total_collected = treasury.total_collected + required;

        event::emit(FeeCollected {
            fee_type: string::utf8(b"RECORD"),
            amount: required,
            payer: ctx.sender(),
            timestamp: clock::timestamp_ms(clock),
        });

        // Return remainder (overpayment or zero-value coin)
        payment_mut
    }

    /// Collect export fee into Treasury.
    /// Called by export service.
    public fun collect_export_fee(
        treasury: &mut Treasury,
        config: &FeeConfig,
        payment: Coin<SGT>,
        file_size_kb: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<SGT> {
        let required = calculate_export_fee(config, file_size_kb);
        let paid = coin::value(&payment);
        assert!(paid >= required, E_INSUFFICIENT_FEE);

        let mut payment_mut = payment;
        let fee_coin = coin::split(&mut payment_mut, required, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
        treasury.total_collected = treasury.total_collected + required;

        event::emit(FeeCollected {
            fee_type: string::utf8(b"EXPORT"),
            amount: required,
            payer: ctx.sender(),
            timestamp: clock::timestamp_ms(clock),
        });

        payment_mut
    }

    // ===== Admin: Treasury =====

    /// Withdraw SGT from treasury to admin wallet.
    /// Requires FeeAdminCap.
    public fun withdraw(
        _cap: &FeeAdminCap,
        treasury: &mut Treasury,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(balance::value(&treasury.balance) >= amount, E_INSUFFICIENT_BALANCE);

        let withdrawn = coin::from_balance(
            balance::split(&mut treasury.balance, amount),
            ctx,
        );

        treasury.total_withdrawn = treasury.total_withdrawn + amount;

        event::emit(TreasuryWithdrawn {
            amount,
            recipient: ctx.sender(),
            timestamp: clock::timestamp_ms(clock),
        });

        transfer::public_transfer(withdrawn, ctx.sender());
    }

    /// Withdraw all SGT from treasury.
    public fun withdraw_all(
        _cap: &FeeAdminCap,
        treasury: &mut Treasury,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let amount = balance::value(&treasury.balance);
        if (amount == 0) { return };

        let withdrawn = coin::from_balance(
            balance::split(&mut treasury.balance, amount),
            ctx,
        );

        treasury.total_withdrawn = treasury.total_withdrawn + amount;

        event::emit(TreasuryWithdrawn {
            amount,
            recipient: ctx.sender(),
            timestamp: clock::timestamp_ms(clock),
        });

        transfer::public_transfer(withdrawn, ctx.sender());
    }

    // ===== Admin: Update Fees =====

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

        let log = FeeChangeLog {
            fee_type: string::utf8(FEE_TYPE_RECORD),
            old_value: old_fee,
            new_value: new_fee_sgt,
            changed_by: caller,
            reason,
            timestamp: now,
        };
        vector::push_back(
            table::borrow_mut(&mut config.change_history, string::utf8(FEE_TYPE_RECORD)),
            log,
        );

        event::emit(RecordFeeUpdated {
            old_fee_sgt: old_fee,
            new_fee_sgt,
            enabled: config.record_fee_enabled,
            changed_by: caller,
            reason: log.reason,
            timestamp: now,
        });
    }

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
        vector::push_back(
            table::borrow_mut(&mut config.change_history, string::utf8(FEE_TYPE_EXPORT_BASE)),
            log,
        );

        event::emit(ExportBaseFeeUpdated {
            old_fee_sgt: old_fee,
            new_fee_sgt,
            enabled: config.export_fee_enabled,
            changed_by: caller,
            reason: log.reason,
            timestamp: now,
        });
    }

    public fun update_export_multiplier(
        _cap: &FeeAdminCap,
        config: &mut FeeConfig,
        new_multiplier_bps: u64,
        reason: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(
            new_multiplier_bps >= MIN_MULTIPLIER_BPS && new_multiplier_bps <= MAX_MULTIPLIER_BPS,
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
        vector::push_back(
            table::borrow_mut(&mut config.change_history, string::utf8(FEE_TYPE_EXPORT_MULT)),
            log,
        );

        event::emit(ExportMultiplierUpdated {
            old_multiplier_bps: old_mult,
            new_multiplier_bps,
            changed_by: caller,
            reason: log.reason,
            timestamp: now,
        });
    }

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

    // ===== View Functions =====

    public fun calculate_record_fee(config: &FeeConfig): u64 {
        if (!config.record_fee_enabled) { return 0 };
        config.record_fee_sgt * SGT_DECIMALS
    }

    public fun calculate_export_fee(config: &FeeConfig, file_size_kb: u64): u64 {
        assert!(file_size_kb > 0, E_ZERO_FILE_SIZE);
        if (!config.export_fee_enabled) { return 0 };

        let threshold_kb = config.export_size_threshold_mb * 1024;
        if (file_size_kb <= threshold_kb) {
            config.export_base_fee_sgt * SGT_DECIMALS
        } else {
            (file_size_kb * config.export_multiplier_bps * SGT_DECIMALS) / (1024 * 10_000)
        }
    }

    public fun treasury_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.balance)
    }

    public fun treasury_total_collected(treasury: &Treasury): u64 {
        treasury.total_collected
    }

    public fun treasury_total_withdrawn(treasury: &Treasury): u64 {
        treasury.total_withdrawn
    }

    public fun record_fee_sgt(config: &FeeConfig): u64        { config.record_fee_sgt }
    public fun export_base_fee_sgt(config: &FeeConfig): u64   { config.export_base_fee_sgt }
    public fun export_multiplier_bps(config: &FeeConfig): u64 { config.export_multiplier_bps }
    public fun export_size_threshold_mb(config: &FeeConfig): u64 { config.export_size_threshold_mb }
    public fun is_record_fee_enabled(config: &FeeConfig): bool { config.record_fee_enabled }
    public fun is_export_fee_enabled(config: &FeeConfig): bool { config.export_fee_enabled }
    public fun total_fee_changes(config: &FeeConfig): u64     { config.total_fee_changes }
    public fun sgt_decimals(): u64                            { SGT_DECIMALS }

    // ===== Test-only =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

    #[test_only]
    public fun get_default_record_fee_sgt(): u64    { DEFAULT_RECORD_FEE_SGT }
    #[test_only]
    public fun get_default_export_base_fee_sgt(): u64 { DEFAULT_EXPORT_BASE_FEE_SGT }
    #[test_only]
    public fun get_default_multiplier_bps(): u64    { DEFAULT_EXPORT_MULTIPLIER_BPS }
    #[test_only]
    public fun get_max_fee_sgt(): u64               { MAX_FEE_SGT }
    #[test_only]
    public fun get_sgt_decimals(): u64              { SGT_DECIMALS }
}
