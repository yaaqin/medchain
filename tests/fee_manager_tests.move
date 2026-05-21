/// Tests for medchain::fee_manager
#[test_only]
module medchain::fee_manager_tests {

    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock;
    use std::string;
    use medchain::fee_manager::{Self, FeeConfig, FeeAdminCap};

    // ===== Test Addresses =====
    const ADMIN: address = @0xAD;

    // ===== Helper =====
    fun setup(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        { fee_manager::init_for_testing(ts::ctx(&mut scenario)); };
        scenario
    }

    // ===== Tests: Initial State =====

    #[test]
    fun test_initial_fees_are_defaults() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let config = ts::take_shared<FeeConfig>(&scenario);

            assert!(fee_manager::record_fee_sgt(&config) == fee_manager::get_default_record_fee_sgt(), 0);
            assert!(fee_manager::export_base_fee_sgt(&config) == fee_manager::get_default_export_base_fee_sgt(), 1);
            assert!(fee_manager::export_multiplier_bps(&config) == fee_manager::get_default_multiplier_bps(), 2);
            assert!(fee_manager::is_record_fee_enabled(&config) == true, 3);
            assert!(fee_manager::is_export_fee_enabled(&config) == true, 4);
            assert!(fee_manager::total_fee_changes(&config) == 0, 5);

            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    // ===== Tests: Record Fee =====

    #[test]
    fun test_update_record_fee() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::update_record_fee(
                &cap,
                &mut config,
                2,
                string::utf8(b"Double fee test"),
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(fee_manager::record_fee_sgt(&config) == 2, 0);
            assert!(fee_manager::total_fee_changes(&config) == 1, 1);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_set_record_fee_to_zero_free_period() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::update_record_fee(
                &cap,
                &mut config,
                0,
                string::utf8(b"Launch free period"),
                &clock,
                ts::ctx(&mut scenario),
            );

            // Fee is 0 SGT but still enabled
            let fee = fee_manager::calculate_record_fee(&config);
            assert!(fee == 0, 0);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_toggle_record_fee_off() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            // Disable fee — value stays at 1 SGT but returns 0
            fee_manager::toggle_record_fee(
                &cap, &mut config, false, &clock, ts::ctx(&mut scenario),
            );

            assert!(fee_manager::is_record_fee_enabled(&config) == false, 0);
            assert!(fee_manager::record_fee_sgt(&config) == 1, 1); // value preserved
            assert!(fee_manager::calculate_record_fee(&config) == 0, 2); // but calc returns 0

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_toggle_record_fee_on_off_on() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            // off
            fee_manager::toggle_record_fee(&cap, &mut config, false, &clock, ts::ctx(&mut scenario));
            assert!(fee_manager::calculate_record_fee(&config) == 0, 0);

            // back on
            fee_manager::toggle_record_fee(&cap, &mut config, true, &clock, ts::ctx(&mut scenario));
            let decimals = fee_manager::get_sgt_decimals();
            assert!(fee_manager::calculate_record_fee(&config) == 1 * decimals, 1);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    // ===== Tests: Export Fee Calculation =====

    #[test]
    fun test_export_fee_small_file_flat_rate() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let config = ts::take_shared<FeeConfig>(&scenario);
            let decimals = fee_manager::get_sgt_decimals();

            // 1 MB file — under 2 MB threshold → flat 1 SGT
            let fee = fee_manager::calculate_export_fee(&config, 1024);
            assert!(fee == 1 * decimals, 0);

            // 2 MB exactly → still flat 1 SGT
            let fee2 = fee_manager::calculate_export_fee(&config, 2048);
            assert!(fee2 == 1 * decimals, 1);

            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_export_fee_large_file_size_based() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let config = ts::take_shared<FeeConfig>(&scenario);
            let decimals = fee_manager::get_sgt_decimals();

            // 2.8 MB file → per doc spec: 2.8 SGT
            // 2867 KB (≈ 2.8 MB) with 1.0x multiplier (10000 bps)
            // fee = (2867 * 10000 * decimals) / (1024 * 10000)
            //     = 2867 * decimals / 1024
            //     = 2.799... SGT ≈ 2 SGT (integer division)
            let fee_2867kb = fee_manager::calculate_export_fee(&config, 2867);
            // Should be around 2 SGT in base units
            assert!(fee_2867kb > 2 * decimals, 0);
            assert!(fee_2867kb < 3 * decimals, 1);

            // 4 MB → should be around 4 SGT
            let fee_4mb = fee_manager::calculate_export_fee(&config, 4096);
            assert!(fee_4mb == 4 * decimals, 2);

            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_export_fee_with_discount_multiplier() {
        let mut scenario = setup();

        // Set 0.7x multiplier (70% discount for large files)
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::update_export_multiplier(
                &cap, &mut config, 7_000,
                string::utf8(b"30% large file discount"),
                &clock, ts::ctx(&mut scenario),
            );

            // 4 MB with 0.7x multiplier → 2.8 SGT → 2 SGT (integer div)
            let decimals = fee_manager::get_sgt_decimals();
            let fee = fee_manager::calculate_export_fee(&config, 4096);
            // 4096 * 7000 * decimals / (1024 * 10000) = 4 * 0.7 * decimals = 2.8 → 2
            assert!(fee > 2 * decimals, 0);
            assert!(fee < 3 * decimals, 1);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_export_fee_disabled_returns_zero() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::toggle_export_fee(&cap, &mut config, false, &clock, ts::ctx(&mut scenario));

            // Any file size → 0 when disabled
            assert!(fee_manager::calculate_export_fee(&config, 512) == 0, 0);
            assert!(fee_manager::calculate_export_fee(&config, 4096) == 0, 1);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_multiple_fee_changes_tracked() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::update_record_fee(&cap, &mut config, 2, string::utf8(b"change 1"), &clock, ts::ctx(&mut scenario));
            fee_manager::update_record_fee(&cap, &mut config, 0, string::utf8(b"change 2"), &clock, ts::ctx(&mut scenario));
            fee_manager::update_export_base_fee(&cap, &mut config, 3, string::utf8(b"change 3"), &clock, ts::ctx(&mut scenario));
            fee_manager::update_export_multiplier(&cap, &mut config, 5_000, string::utf8(b"change 4"), &clock, ts::ctx(&mut scenario));

            assert!(fee_manager::total_fee_changes(&config) == 4, 0);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    // ===== Abort Tests =====

    #[test]
    #[expected_failure(abort_code = fee_manager::E_INVALID_FEE)]
    fun test_fee_above_max_cap_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            // MAX is 100 SGT — try 101
            fee_manager::update_record_fee(
                &cap, &mut config, 101,
                string::utf8(b"too high"),
                &clock, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee_manager::E_INVALID_MULTIPLIER)]
    fun test_multiplier_below_min_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);
            let mut config = ts::take_shared<FeeConfig>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            // MIN is 1000 bps (0.1x) — try 500 bps (0.05x)
            fee_manager::update_export_multiplier(
                &cap, &mut config, 500,
                string::utf8(b"too low"),
                &clock, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee_manager::E_ZERO_FILE_SIZE)]
    fun test_zero_file_size_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let config = ts::take_shared<FeeConfig>(&scenario);

            // 0 KB file → should abort
            let _ = fee_manager::calculate_export_fee(&config, 0);

            ts::return_shared(config);
        };

        ts::end(scenario);
    }
}
