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

        {
            fee_manager::init_for_testing(ts::ctx(&mut scenario));
        };

        scenario
    }

    // ===== Initial State =====

    #[test]
    fun test_initial_fees_are_defaults() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);

        {
            let config = ts::take_shared<FeeConfig>(&scenario);

            assert!(
                fee_manager::record_fee_sgt(&config)
                    == fee_manager::get_default_record_fee_sgt(),
                0
            );

            assert!(
                fee_manager::export_base_fee_sgt(&config)
                    == fee_manager::get_default_export_base_fee_sgt(),
                1
            );

            assert!(
                fee_manager::export_multiplier_bps(&config)
                    == fee_manager::get_default_multiplier_bps(),
                2
            );

            assert!(fee_manager::is_record_fee_enabled(&config), 3);
            assert!(fee_manager::is_export_fee_enabled(&config), 4);

            assert!(fee_manager::total_fee_changes(&config) == 0, 5);

            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    // ===== Record Fee =====

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
                string::utf8(b"Double fee"),
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
    fun test_record_fee_zero() {
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
                string::utf8(b"Free launch"),
                &clock,
                ts::ctx(&mut scenario),
            );

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

            fee_manager::toggle_record_fee(
                &cap,
                &mut config,
                false,
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(!fee_manager::is_record_fee_enabled(&config), 0);

            assert!(fee_manager::record_fee_sgt(&config) == 1, 1);

            assert!(fee_manager::calculate_record_fee(&config) == 0, 2);

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

            fee_manager::toggle_record_fee(
                &cap,
                &mut config,
                false,
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(fee_manager::calculate_record_fee(&config) == 0, 0);

            fee_manager::toggle_record_fee(
                &cap,
                &mut config,
                true,
                &clock,
                ts::ctx(&mut scenario),
            );

            let decimals = fee_manager::get_sgt_decimals();

            assert!(
                fee_manager::calculate_record_fee(&config)
                    == (1 * decimals),
                1
            );

            clock::destroy_for_testing(clock);

            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    // ===== Export Fee =====

    #[test]
    fun test_export_fee_small_file() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);

        {
            let config = ts::take_shared<FeeConfig>(&scenario);

            let decimals = fee_manager::get_sgt_decimals();

            let fee_1mb =
                fee_manager::calculate_export_fee(&config, 1024);

            assert!(fee_1mb == (1 * decimals), 0);

            let fee_2mb =
                fee_manager::calculate_export_fee(&config, 2048);

            assert!(fee_2mb == (1 * decimals), 1);

            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_export_fee_large_file() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);

        {
            let config = ts::take_shared<FeeConfig>(&scenario);

            let decimals = fee_manager::get_sgt_decimals();

            let fee_2867 =
                fee_manager::calculate_export_fee(&config, 2867);

            assert!(fee_2867 > (2 * decimals), 0);
            assert!(fee_2867 < (3 * decimals), 1);

            let fee_4mb =
                fee_manager::calculate_export_fee(&config, 4096);

            assert!(fee_4mb == (4 * decimals), 2);

            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_export_fee_discount_multiplier() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);

        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);

            let mut config = ts::take_shared<FeeConfig>(&scenario);

            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::update_export_multiplier(
                &cap,
                &mut config,
                7_000,
                string::utf8(b"Discount"),
                &clock,
                ts::ctx(&mut scenario),
            );

            let decimals = fee_manager::get_sgt_decimals();

            let fee =
                fee_manager::calculate_export_fee(&config, 4096);

            assert!(fee > (2 * decimals), 0);
            assert!(fee < (3 * decimals), 1);

            clock::destroy_for_testing(clock);

            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_export_fee_disabled() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);

        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);

            let mut config = ts::take_shared<FeeConfig>(&scenario);

            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::toggle_export_fee(
                &cap,
                &mut config,
                false,
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(
                fee_manager::calculate_export_fee(&config, 512) == 0,
                0
            );

            assert!(
                fee_manager::calculate_export_fee(&config, 4096) == 0,
                1
            );

            clock::destroy_for_testing(clock);

            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_multiple_fee_changes() {
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
                string::utf8(b"1"),
                &clock,
                ts::ctx(&mut scenario),
            );

            fee_manager::update_record_fee(
                &cap,
                &mut config,
                0,
                string::utf8(b"2"),
                &clock,
                ts::ctx(&mut scenario),
            );

            fee_manager::update_export_base_fee(
                &cap,
                &mut config,
                3,
                string::utf8(b"3"),
                &clock,
                ts::ctx(&mut scenario),
            );

            fee_manager::update_export_multiplier(
                &cap,
                &mut config,
                5_000,
                string::utf8(b"4"),
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(
                fee_manager::total_fee_changes(&config) == 4,
                0
            );

            clock::destroy_for_testing(clock);

            ts::return_to_sender(&scenario, cap);
            ts::return_shared(config);
        };

        ts::end(scenario);
    }

    // ===== Abort Tests =====

    #[test]
    #[expected_failure(abort_code = fee_manager::E_INVALID_FEE)]
    fun test_fee_above_max_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);

        {
            let cap = ts::take_from_sender<FeeAdminCap>(&scenario);

            let mut config = ts::take_shared<FeeConfig>(&scenario);

            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            fee_manager::update_record_fee(
                &cap,
                &mut config,
                101,
                string::utf8(b"Too high"),
                &clock,
                ts::ctx(&mut scenario),
            );

            abort 999
        };
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

            fee_manager::update_export_multiplier(
                &cap,
                &mut config,
                500,
                string::utf8(b"Too low"),
                &clock,
                ts::ctx(&mut scenario),
            );

            abort 999
        };
    }

    #[test]
    #[expected_failure(abort_code = fee_manager::E_ZERO_FILE_SIZE)]
    fun test_zero_file_size_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);

        {
            let config = ts::take_shared<FeeConfig>(&scenario);

            fee_manager::calculate_export_fee(&config, 0);

            abort 999
        };
    }
}