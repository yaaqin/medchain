#[test_only]
module medchain::doctor_registry_tests {

    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock;
    use std::string;
    use medchain::doctor_registry::{Self, DoctorRegistry, DoctorAdminCap};

    const ADMIN:    address = @0xAD;

    const DOC_ID:   vector<u8> = b"DOC-0001";
    const NIK_HASH: vector<u8> = b"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const STR_NUM:  vector<u8> = b"503/XXX/STR/2023";
    const SIP_NUM:  vector<u8> = b"SIP/001/DINKES/2024";
    const HOSP_ID:  vector<u8> = b"RSUD-B";
    const SPEC:     vector<u8> = b"Emergency Medicine";

    fun setup(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        { doctor_registry::init_for_testing(ts::ctx(&mut scenario)); };
        scenario
    }

    fun verify_default_doctor(scenario: &mut Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap = ts::take_from_sender<DoctorAdminCap>(scenario);
            let mut registry = ts::take_shared<DoctorRegistry>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));

            doctor_registry::verify_doctor(
                &cap, &mut registry,
                string::utf8(DOC_ID), string::utf8(NIK_HASH),
                string::utf8(STR_NUM), string::utf8(SIP_NUM),
                string::utf8(HOSP_ID), string::utf8(SPEC),
                &clock, ts::ctx(scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_to_sender(scenario, cap);
            ts::return_shared(registry);
        };
    }

    #[test]
    fun test_verify_doctor_success() {
        let mut scenario = setup();
        verify_default_doctor(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<DoctorRegistry>(&scenario);
            assert!(doctor_registry::is_verified(&registry, &string::utf8(DOC_ID)), 0);
            assert!(doctor_registry::doctor_exists(&registry, &string::utf8(DOC_ID)), 1);
            assert!(doctor_registry::total_verified(&registry) == 1, 2);
            let hosp = doctor_registry::get_doctor_hospital(&registry, &string::utf8(DOC_ID));
            assert!(hosp == string::utf8(HOSP_ID), 3);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_revoke_doctor() {
        let mut scenario = setup();
        verify_default_doctor(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<DoctorAdminCap>(&scenario);
            let mut registry = ts::take_shared<DoctorRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            doctor_registry::revoke_doctor(
                &cap, &mut registry,
                string::utf8(DOC_ID),
                string::utf8(b"License expired"),
                &clock, ts::ctx(&mut scenario),
            );

            assert!(!doctor_registry::is_verified(&registry, &string::utf8(DOC_ID)), 0);
            let (_id, _nik, _str, _hosp, _spec, status) =
                doctor_registry::get_doctor_info(&registry, &string::utf8(DOC_ID));
            assert!(status == doctor_registry::status_revoked(), 1);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_unregistered_doctor_is_not_verified() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<DoctorRegistry>(&scenario);
            assert!(!doctor_registry::is_verified(&registry, &string::utf8(DOC_ID)), 0);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = doctor_registry::E_DOCTOR_ALREADY_VERIFIED)]
    fun test_duplicate_doctor_aborts() {
        let mut scenario = setup();
        verify_default_doctor(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<DoctorAdminCap>(&scenario);
            let mut registry = ts::take_shared<DoctorRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            doctor_registry::verify_doctor(
                &cap, &mut registry,
                string::utf8(DOC_ID), string::utf8(NIK_HASH),
                string::utf8(STR_NUM), string::utf8(SIP_NUM),
                string::utf8(HOSP_ID), string::utf8(SPEC),
                &clock, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = doctor_registry::E_DOCTOR_ALREADY_REVOKED)]
    fun test_double_revoke_aborts() {
        let mut scenario = setup();
        verify_default_doctor(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<DoctorAdminCap>(&scenario);
            let mut registry = ts::take_shared<DoctorRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            doctor_registry::revoke_doctor(&cap, &mut registry, string::utf8(DOC_ID), string::utf8(b"First"), &clock, ts::ctx(&mut scenario));
            doctor_registry::revoke_doctor(&cap, &mut registry, string::utf8(DOC_ID), string::utf8(b"Second"), &clock, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }
}
