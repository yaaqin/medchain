/// Tests for medchain::medical_records
#[test_only]
module medchain::medical_records_tests {

    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock;
    use sui::coin::{Self, Coin};
    use sui::balance;
    use std::string;
    use std::option;

    use sgt::sgt::SGT;

    use medchain::patient_registry::{Self, PatientRegistry};

    use medchain::fee_manager::{
        Self,
        FeeConfig,
        FeeAdminCap,
        Treasury
    };

    use medchain::medical_records::{
        Self,
        RecordRegistry,
        RecordAdminCap
    };

    // ===== Addresses =====
    const ADMIN:       address = @0xAD;
    const HOSPITAL_A:  address = @0xA1;
    const HOSPITAL_B:  address = @0xB1;

    // ===== Patient data =====
    const NIK_HASH:  vector<u8> = b"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const IBU_HASH:  vector<u8> = b"b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3";
    const WALLET:    vector<u8> = b"0x5c2e1f9a8b7d3e4f5a6b7c8d9e0f1a2b";
    const PAT_ID:    vector<u8> = b"PAT-0001";
    const PAT_NAME:  vector<u8> = b"Budi Santoso";

    // ===== Record data =====
    const REC_ID_1:  vector<u8> = b"REC-2024-0001";
    const REC_ID_2:  vector<u8> = b"REC-2024-0002";

    const IPFS_1:    vector<u8> = b"QmABCD1234567890abcdef";
    const HASH_1:    vector<u8> = b"3f4a2b1c5d6e7f8a9b0c1d2e3f4a5b6c";

    const HOSP_A:    vector<u8> = b"PUSKESMAS-C";
    const HOSP_B:    vector<u8> = b"RSUD-B";

    const DOC_1:     vector<u8> = b"DOC-0001";
    const REC_TYPE:  vector<u8> = b"CONSULTATION";

    // ===== Helpers =====

    fun mint_test_sgt(
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<SGT> {
        coin::from_balance(
            balance::create_for_testing<SGT>(amount),
            ctx,
        )
    }

    fun setup_all(): Scenario {
        let mut scenario = ts::begin(ADMIN);

        {
            patient_registry::init_for_testing(
                ts::ctx(&mut scenario)
            );

            fee_manager::init_for_testing(
                ts::ctx(&mut scenario)
            );

            medical_records::init_for_testing(
                ts::ctx(&mut scenario)
            );
        };

        scenario
    }

    fun register_default_patient(
        scenario: &mut Scenario
    ) {
        ts::next_tx(scenario, HOSPITAL_A);

        {
            let mut pat_reg =
                ts::take_shared<PatientRegistry>(scenario);

            let clock =
                clock::create_for_testing(
                    ts::ctx(scenario)
                );

            patient_registry::register_patient(
                &mut pat_reg,
                string::utf8(PAT_ID),
                string::utf8(NIK_HASH),
                string::utf8(IBU_HASH),
                string::utf8(WALLET),
                string::utf8(PAT_NAME),
                &clock,
                ts::ctx(scenario),
            );

            clock::destroy_for_testing(clock);

            ts::return_shared(pat_reg);
        };
    }

    fun create_record_helper(
        scenario: &mut Scenario,
        record_id: vector<u8>,
        hospital: vector<u8>,
        caller: address,
        fee_override: option::Option<u64>,
    ) {
        ts::next_tx(scenario, caller);

        {
            let mut rec_reg =
                ts::take_shared<RecordRegistry>(scenario);

            let pat_reg =
                ts::take_shared<PatientRegistry>(scenario);

            let fee_config =
                ts::take_shared<FeeConfig>(scenario);

            let mut treasury =
                ts::take_shared<Treasury>(scenario);

            let clock =
                clock::create_for_testing(
                    ts::ctx(scenario)
                );

            let required_fee =
                fee_manager::calculate_record_fee(
                    &fee_config
                );

            let payment_amount =
                if (option::is_some(&fee_override)) {
                    *option::borrow(&fee_override)
                } else {
                    required_fee
                };

            let payment: Coin<SGT> =
                mint_test_sgt(
                    payment_amount,
                    ts::ctx(scenario),
                );

            medical_records::create_record(
                &mut rec_reg,
                &pat_reg,
                &fee_config,
                &mut treasury,

                string::utf8(record_id),
                string::utf8(NIK_HASH),

                string::utf8(hospital),
                string::utf8(DOC_1),

                string::utf8(IPFS_1),
                string::utf8(HASH_1),

                string::utf8(REC_TYPE),

                payment,

                &clock,
                ts::ctx(scenario),
            );

            clock::destroy_for_testing(clock);

            ts::return_shared(rec_reg);
            ts::return_shared(pat_reg);
            ts::return_shared(fee_config);
            ts::return_shared(treasury);
        };
    }

    // ===== Tests =====

    #[test]
    fun test_create_record_success() {
        let mut scenario = setup_all();

        register_default_patient(&mut scenario);

        create_record_helper(
            &mut scenario,
            REC_ID_1,
            HOSP_A,
            HOSPITAL_A,
            option::none(),
        );

        ts::next_tx(&mut scenario, HOSPITAL_A);

        {
            let rec_reg =
                ts::take_shared<RecordRegistry>(&scenario);

            assert!(
                medical_records::record_exists(
                    &rec_reg,
                    &string::utf8(REC_ID_1)
                ),
                0
            );

            assert!(
                medical_records::total_records(
                    &rec_reg
                ) == 1,
                1
            );

            assert!(
                medical_records::patient_record_count(
                    &rec_reg,
                    &string::utf8(NIK_HASH)
                ) == 1,
                2
            );

            ts::return_shared(rec_reg);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_fee_charged_matches_config() {
        let mut scenario = setup_all();

        register_default_patient(&mut scenario);

        create_record_helper(
            &mut scenario,
            REC_ID_1,
            HOSP_A,
            HOSPITAL_A,
            option::none(),
        );

        ts::next_tx(&mut scenario, HOSPITAL_A);

        {
            let rec_reg =
                ts::take_shared<RecordRegistry>(&scenario);

            let fee_config =
                ts::take_shared<FeeConfig>(&scenario);

            let charged =
                medical_records::get_record_fee_charged(
                    &rec_reg,
                    &string::utf8(REC_ID_1),
                );

            let expected =
                fee_manager::calculate_record_fee(
                    &fee_config
                );

            assert!(charged == expected, 0);

            ts::return_shared(rec_reg);
            ts::return_shared(fee_config);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_record_creation_when_fee_disabled() {
        let mut scenario = setup_all();

        register_default_patient(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);

        {
            let cap =
                ts::take_from_sender<FeeAdminCap>(&scenario);

            let mut fee_config =
                ts::take_shared<FeeConfig>(&scenario);

            let clock =
                clock::create_for_testing(
                    ts::ctx(&mut scenario)
                );

            fee_manager::toggle_record_fee(
                &cap,
                &mut fee_config,
                false,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);

            ts::return_to_sender(&scenario, cap);

            ts::return_shared(fee_config);
        };

        create_record_helper(
            &mut scenario,
            REC_ID_1,
            HOSP_A,
            HOSPITAL_A,
            option::some(0),
        );

        ts::next_tx(&mut scenario, HOSPITAL_A);

        {
            let rec_reg =
                ts::take_shared<RecordRegistry>(&scenario);

            assert!(
                medical_records::record_exists(
                    &rec_reg,
                    &string::utf8(REC_ID_1)
                ),
                0
            );

            ts::return_shared(rec_reg);
        };

        ts::end(scenario);
    }

    // ===== Abort Tests =====

    #[test]
    #[expected_failure(
        abort_code = medical_records::E_DUPLICATE_RECORD_ID
    )]
    fun test_duplicate_record_aborts() {
        let mut scenario = setup_all();

        register_default_patient(&mut scenario);

        create_record_helper(
            &mut scenario,
            REC_ID_1,
            HOSP_A,
            HOSPITAL_A,
            option::none(),
        );

        create_record_helper(
            &mut scenario,
            REC_ID_1,
            HOSP_A,
            HOSPITAL_A,
            option::none(),
        );

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(
        abort_code = medical_records::E_PATIENT_NOT_FOUND
    )]
    fun test_unregistered_patient_aborts() {
        let mut scenario = setup_all();

        create_record_helper(
            &mut scenario,
            REC_ID_1,
            HOSP_A,
            HOSPITAL_A,
            option::none(),
        );

        ts::end(scenario);
    }
}