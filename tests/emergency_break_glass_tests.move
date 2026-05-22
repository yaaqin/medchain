#[test_only]
module medchain::emergency_break_glass_tests {

    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock;
    use std::string;
    use medchain::patient_registry::{Self, PatientRegistry};
    use medchain::doctor_registry::{Self, DoctorRegistry, DoctorAdminCap};
    use medchain::emergency_break_glass::{Self, EBGRegistry};

    const ADMIN:   address = @0xAD;
    const DOCTOR:  address = @0xD0;

    // Patient
    const NIK_HASH: vector<u8> = b"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const IBU_HASH: vector<u8> = b"b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3";
    const WALLET:   vector<u8> = b"0x5c2e1f9a8b7d3e4f5a6b7c8d9e0f1a2b";
    const PAT_ID:   vector<u8> = b"PAT-0001";
    const PAT_NAME: vector<u8> = b"Budi Santoso";

    // Doctor
    const DOC_ID:   vector<u8> = b"DOC-0001";
    const DOC_NIK:  vector<u8> = b"c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4";
    const STR_NUM:  vector<u8> = b"503/XXX/STR/2023";
    const SIP_NUM:  vector<u8> = b"SIP/001/DINKES/2024";
    const HOSP_ID:  vector<u8> = b"RSUD-B";
    const SPEC:     vector<u8> = b"Emergency Medicine";

    // EBG
    const EBG_ID:       vector<u8> = b"EBG-2024-0001";
    const EBG_ID_2:     vector<u8> = b"EBG-2024-0002";
    const EBG_ID_3:     vector<u8> = b"EBG-2024-0003";
    const EBG_ID_4:     vector<u8> = b"EBG-2024-0004";
    const JUST_HASH:    vector<u8> = b"f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2";
    const SESSION_ID:   vector<u8> = b"ebg-session-uuid-v4-0001";
    const EMERG_TYPE:   vector<u8> = b"LIFE_THREATENING";

    // ===== Setup =====

    fun setup_all(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            patient_registry::init_for_testing(ts::ctx(&mut scenario));
            doctor_registry::init_for_testing(ts::ctx(&mut scenario));
            emergency_break_glass::init_for_testing(ts::ctx(&mut scenario));
        };
        scenario
    }

    fun setup_patient(scenario: &mut Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            let mut pat_reg = ts::take_shared<PatientRegistry>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            patient_registry::register_patient(
                &mut pat_reg,
                string::utf8(PAT_ID), string::utf8(NIK_HASH),
                string::utf8(IBU_HASH), string::utf8(WALLET),
                string::utf8(PAT_NAME), &clock, ts::ctx(scenario),
            );
            clock::destroy_for_testing(clock);
            ts::return_shared(pat_reg);
        };
    }

    fun setup_verified_doctor(scenario: &mut Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap = ts::take_from_sender<DoctorAdminCap>(scenario);
            let mut doc_reg = ts::take_shared<DoctorRegistry>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));

            doctor_registry::verify_doctor(
                &cap, &mut doc_reg,
                string::utf8(DOC_ID), string::utf8(DOC_NIK),
                string::utf8(STR_NUM), string::utf8(SIP_NUM),
                string::utf8(HOSP_ID), string::utf8(SPEC),
                &clock, ts::ctx(scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_to_sender(scenario, cap);
            ts::return_shared(doc_reg);
        };
    }

    fun initiate_ebg(scenario: &mut Scenario, ebg_id: vector<u8>, session_id: vector<u8>, time_ms: u64) {
        ts::next_tx(scenario, DOCTOR);
        {
            let mut ebg_reg = ts::take_shared<EBGRegistry>(scenario);
            let doc_reg = ts::take_shared<DoctorRegistry>(scenario);
            let pat_reg = ts::take_shared<PatientRegistry>(scenario);
            let mut clock = clock::create_for_testing(ts::ctx(scenario));
            clock::set_for_testing(&mut clock, time_ms);

            emergency_break_glass::initiate_emergency_access(
                &mut ebg_reg, &doc_reg, &pat_reg,
                string::utf8(ebg_id), string::utf8(DOC_ID),
                string::utf8(NIK_HASH), string::utf8(EMERG_TYPE),
                string::utf8(JUST_HASH), string::utf8(session_id),
                &clock, ts::ctx(scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(ebg_reg);
            ts::return_shared(doc_reg);
            ts::return_shared(pat_reg);
        };
    }

    // ===== Tests =====

    #[test]
    fun test_initiate_ebg_success() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);
        initiate_ebg(&mut scenario, EBG_ID, SESSION_ID, 1000);

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            assert!(emergency_break_glass::ebg_exists(&ebg_reg, &string::utf8(EBG_ID)), 0);
            assert!(emergency_break_glass::total_ebg_events(&ebg_reg) == 1, 1);
            assert!(emergency_break_glass::get_ebg_status(&ebg_reg, &string::utf8(EBG_ID)) == emergency_break_glass::status_initiated(), 2);
            ts::return_shared(ebg_reg);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_complete_ebg() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);
        initiate_ebg(&mut scenario, EBG_ID, SESSION_ID, 1000);

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let mut ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 60_000); // 1 minute later

            let records = vector[string::utf8(b"REC-2024-0001"), string::utf8(b"REC-2024-0002")];
            emergency_break_glass::complete_emergency_access(
                &mut ebg_reg, string::utf8(EBG_ID), records, &clock, ts::ctx(&mut scenario),
            );

            assert!(emergency_break_glass::get_ebg_status(&ebg_reg, &string::utf8(EBG_ID)) == emergency_break_glass::status_completed(), 0);
            let accessed = emergency_break_glass::get_ebg_records_accessed(&ebg_reg, &string::utf8(EBG_ID));
            assert!(vector::length(&accessed) == 2, 1);

            clock::destroy_for_testing(clock);
            ts::return_shared(ebg_reg);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_fail_ebg() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);
        initiate_ebg(&mut scenario, EBG_ID, SESSION_ID, 1000);

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let mut ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            emergency_break_glass::fail_emergency_access(
                &mut ebg_reg, string::utf8(EBG_ID),
                string::utf8(b"IPFS fetch failed"),
                &clock, ts::ctx(&mut scenario),
            );

            assert!(emergency_break_glass::get_ebg_status(&ebg_reg, &string::utf8(EBG_ID)) == emergency_break_glass::status_failed(), 0);

            clock::destroy_for_testing(clock);
            ts::return_shared(ebg_reg);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_rate_limit_allows_3_per_day() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);

        // 3 EBGs in same 24h window — all should succeed
        initiate_ebg(&mut scenario, EBG_ID,   SESSION_ID,             1_000);
        initiate_ebg(&mut scenario, EBG_ID_2, b"session-uuid-0002",   2_000);
        initiate_ebg(&mut scenario, EBG_ID_3, b"session-uuid-0003",   3_000);

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            assert!(emergency_break_glass::get_doctor_ebg_count(&ebg_reg, &string::utf8(DOC_ID)) == 3, 0);
            ts::return_shared(ebg_reg);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_rate_limit_resets_after_24h() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);

        // 3 EBGs in window 1
        initiate_ebg(&mut scenario, EBG_ID,   SESSION_ID,           1_000);
        initiate_ebg(&mut scenario, EBG_ID_2, b"session-uuid-0002", 2_000);
        initiate_ebg(&mut scenario, EBG_ID_3, b"session-uuid-0003", 3_000);

        // 4th EBG after 24h — should succeed (new window)
        let day_plus_one = emergency_break_glass::get_ms_per_day() + 5_000;
        initiate_ebg(&mut scenario, EBG_ID_4, b"session-uuid-0004", day_plus_one);

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            // Counter reset to 1 for new window
            assert!(emergency_break_glass::get_doctor_ebg_count(&ebg_reg, &string::utf8(DOC_ID)) == 1, 0);
            ts::return_shared(ebg_reg);
        };

        ts::end(scenario);
    }

    // ===== Abort tests =====

    #[test]
    #[expected_failure(abort_code = emergency_break_glass::E_DOCTOR_NOT_VERIFIED)]
    fun test_unverified_doctor_aborts() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        // Doctor NOT verified — should abort

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let mut ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            let doc_reg = ts::take_shared<DoctorRegistry>(&scenario);
            let pat_reg = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            emergency_break_glass::initiate_emergency_access(
                &mut ebg_reg, &doc_reg, &pat_reg,
                string::utf8(EBG_ID), string::utf8(DOC_ID),
                string::utf8(NIK_HASH), string::utf8(EMERG_TYPE),
                string::utf8(JUST_HASH), string::utf8(SESSION_ID),
                &clock, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(ebg_reg);
            ts::return_shared(doc_reg);
            ts::return_shared(pat_reg);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = emergency_break_glass::E_INVALID_EMERGENCY_TYPE)]
    fun test_invalid_emergency_type_aborts() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let mut ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            let doc_reg = ts::take_shared<DoctorRegistry>(&scenario);
            let pat_reg = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            emergency_break_glass::initiate_emergency_access(
                &mut ebg_reg, &doc_reg, &pat_reg,
                string::utf8(EBG_ID), string::utf8(DOC_ID),
                string::utf8(NIK_HASH),
                string::utf8(b"INVALID_TYPE"), // bad type
                string::utf8(JUST_HASH), string::utf8(SESSION_ID),
                &clock, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(ebg_reg);
            ts::return_shared(doc_reg);
            ts::return_shared(pat_reg);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = emergency_break_glass::E_RATE_LIMIT_EXCEEDED)]
    fun test_rate_limit_4th_request_aborts() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);

        // 3 allowed
        initiate_ebg(&mut scenario, EBG_ID,   SESSION_ID,           1_000);
        initiate_ebg(&mut scenario, EBG_ID_2, b"session-uuid-0002", 2_000);
        initiate_ebg(&mut scenario, EBG_ID_3, b"session-uuid-0003", 3_000);
        // 4th in same window → abort
        initiate_ebg(&mut scenario, EBG_ID_4, b"session-uuid-0004", 4_000);

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = emergency_break_glass::E_EBG_ALREADY_COMPLETED)]
    fun test_complete_already_completed_aborts() {
        let mut scenario = setup_all();
        setup_patient(&mut scenario);
        setup_verified_doctor(&mut scenario);
        initiate_ebg(&mut scenario, EBG_ID, SESSION_ID, 1000);

        ts::next_tx(&mut scenario, DOCTOR);
        {
            let mut ebg_reg = ts::take_shared<EBGRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 5_000); // after initiated_at=1000

            emergency_break_glass::complete_emergency_access(&mut ebg_reg, string::utf8(EBG_ID), vector[], &clock, ts::ctx(&mut scenario));
            // Complete again → abort
            emergency_break_glass::complete_emergency_access(&mut ebg_reg, string::utf8(EBG_ID), vector[], &clock, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            ts::return_shared(ebg_reg);
        };

        ts::end(scenario);
    }
}
