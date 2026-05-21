/// Tests for medchain::patient_registry
#[test_only]
module medchain::patient_registry_tests {

    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock;
    use std::string;
    use medchain::patient_registry::{Self, PatientRegistry, AdminCap};

    // ===== Test Addresses =====
    const ADMIN:    address = @0xAD;
    const HOSPITAL: address = @0xB0;
    const STRANGER: address = @0xFF;

    // ===== Test Data =====
    // Realistic-looking sha256 hex strings (64 chars each)
    const NIK_HASH: vector<u8>  = b"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const IBU_HASH: vector<u8>  = b"b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3";
    const WALLET:   vector<u8>  = b"0x5c2e1f9a8b7d3e4f5a6b7c8d9e0f1a2b3c4d5e6f";
    const PAT_ID:   vector<u8>  = b"PAT-0001";
    const PAT_NAME: vector<u8>  = b"Budi Santoso";

    // Second patient
    const NIK_HASH_2: vector<u8> = b"c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4";
    const IBU_HASH_2: vector<u8> = b"d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5";
    const WALLET_2:   vector<u8> = b"0xdeadbeef1234567890abcdef";
    const PAT_ID_2:   vector<u8> = b"PAT-0002";
    const PAT_NAME_2: vector<u8> = b"Sari Dewi";

    // ===== Helper: Setup scenario with registry initialized =====
    fun setup(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            patient_registry::init_for_testing(ts::ctx(&mut scenario));
        };
        scenario
    }

    fun register_default_patient(scenario: &mut Scenario) {
        ts::next_tx(scenario, HOSPITAL);
        {
            let mut registry = ts::take_shared<PatientRegistry>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));

            patient_registry::register_patient(
                &mut registry,
                string::utf8(PAT_ID),
                string::utf8(NIK_HASH),
                string::utf8(IBU_HASH),
                string::utf8(WALLET),
                string::utf8(PAT_NAME),
                &clock,
                ts::ctx(scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };
    }

    // ===== Tests =====

    #[test]
    fun test_register_patient_success() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let registry = ts::take_shared<PatientRegistry>(&scenario);

            // Patient should exist
            let patient_id = string::utf8(PAT_ID);
            assert!(patient_registry::patient_exists(&registry, &patient_id), 0);
            assert!(patient_registry::total_patients(&registry) == 1, 1);

            // NIK hash should be indexed
            let nik_hash = string::utf8(NIK_HASH);
            assert!(patient_registry::nik_hash_exists(&registry, &nik_hash), 2);

            // Wallet pubkey should be retrievable
            let wallet = patient_registry::get_wallet_pubkey(&registry, &patient_id);
            assert!(wallet == string::utf8(WALLET), 3);

            // Status should be active
            let status = patient_registry::get_patient_status(&registry, &patient_id);
            assert!(status == patient_registry::get_status_active(), 4);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_lookup_by_nik_hash() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let registry = ts::take_shared<PatientRegistry>(&scenario);
            let nik_hash = string::utf8(NIK_HASH);

            let found_id = patient_registry::get_patient_id_by_nik(&registry, &nik_hash);
            assert!(found_id == string::utf8(PAT_ID), 0);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_lookup_by_combined_hash() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let registry = ts::take_shared<PatientRegistry>(&scenario);
            let nik_hash = string::utf8(NIK_HASH);
            let ibu_hash = string::utf8(IBU_HASH);

            let found_id = patient_registry::get_patient_id_by_combined(
                &registry, &nik_hash, &ibu_hash
            );
            assert!(found_id == string::utf8(PAT_ID), 0);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_verify_credentials_success() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let registry = ts::take_shared<PatientRegistry>(&scenario);

            let valid = patient_registry::verify_patient_credentials(
                &registry,
                &string::utf8(PAT_ID),
                &string::utf8(NIK_HASH),
                &string::utf8(IBU_HASH),
            );
            assert!(valid == true, 0);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_verify_credentials_wrong_ibu() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let registry = ts::take_shared<PatientRegistry>(&scenario);

            // Use wrong ibu hash
            let valid = patient_registry::verify_patient_credentials(
                &registry,
                &string::utf8(PAT_ID),
                &string::utf8(NIK_HASH),
                &string::utf8(NIK_HASH_2), // wrong ibu hash
            );
            assert!(valid == false, 0);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_deactivate_and_reactivate_patient() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        // Deactivate
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut registry = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            patient_registry::deactivate_patient(
                &cap,
                &mut registry,
                string::utf8(PAT_ID),
                &clock,
                ts::ctx(&mut scenario),
            );

            let status = patient_registry::get_patient_status(
                &registry, &string::utf8(PAT_ID)
            );
            assert!(status == patient_registry::get_status_inactive(), 0);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(registry);
        };

        // Verify credentials fail for inactive patient
        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let registry = ts::take_shared<PatientRegistry>(&scenario);

            let valid = patient_registry::verify_patient_credentials(
                &registry,
                &string::utf8(PAT_ID),
                &string::utf8(NIK_HASH),
                &string::utf8(IBU_HASH),
            );
            assert!(valid == false, 1);

            ts::return_shared(registry);
        };

        // Reactivate
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut registry = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            patient_registry::reactivate_patient(
                &cap,
                &mut registry,
                string::utf8(PAT_ID),
                &clock,
                ts::ctx(&mut scenario),
            );

            let status = patient_registry::get_patient_status(
                &registry, &string::utf8(PAT_ID)
            );
            assert!(status == patient_registry::get_status_active(), 2);

            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_multiple_patients() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        // Register second patient
        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let mut registry = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            patient_registry::register_patient(
                &mut registry,
                string::utf8(PAT_ID_2),
                string::utf8(NIK_HASH_2),
                string::utf8(IBU_HASH_2),
                string::utf8(WALLET_2),
                string::utf8(PAT_NAME_2),
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(patient_registry::total_patients(&registry) == 2, 0);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_update_patient_name() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        // Hospital (original registrar) updates name
        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let mut registry = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            patient_registry::update_patient_name(
                &mut registry,
                string::utf8(PAT_ID),
                string::utf8(b"Budi Santoso S.T."),
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // ===== Abort Tests (expected failures) =====

    #[test]
    #[expected_failure(abort_code = patient_registry::E_PATIENT_ALREADY_EXISTS)]
    fun test_duplicate_registration_aborts() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        // Try to register same patient again
        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let mut registry = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            patient_registry::register_patient(
                &mut registry,
                string::utf8(PAT_ID),         // same ID
                string::utf8(NIK_HASH),        // same NIK hash
                string::utf8(IBU_HASH),
                string::utf8(WALLET),
                string::utf8(PAT_NAME),
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = patient_registry::E_PATIENT_NOT_FOUND)]
    fun test_get_nonexistent_patient_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let registry = ts::take_shared<PatientRegistry>(&scenario);
            let non_existent = string::utf8(b"PAT-9999");

            // Should abort
            let _ = patient_registry::get_wallet_pubkey(&registry, &non_existent);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = patient_registry::E_INVALID_NIK_HASH)]
    fun test_invalid_nik_hash_length_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, HOSPITAL);
        {
            let mut registry = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            // 32 chars instead of 64 — should abort
            patient_registry::register_patient(
                &mut registry,
                string::utf8(PAT_ID),
                string::utf8(b"tooshort"),  // invalid hash
                string::utf8(IBU_HASH),
                string::utf8(WALLET),
                string::utf8(PAT_NAME),
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = patient_registry::E_UNAUTHORIZED)]
    fun test_update_name_by_stranger_aborts() {
        let mut scenario = setup();
        register_default_patient(&mut scenario);

        // Stranger tries to update name — should abort
        ts::next_tx(&mut scenario, STRANGER);
        {
            let mut registry = ts::take_shared<PatientRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            patient_registry::update_patient_name(
                &mut registry,
                string::utf8(PAT_ID),
                string::utf8(b"Hacker Name"),
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }
}
