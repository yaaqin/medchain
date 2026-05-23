# MedChain — Smart Contract Documentation

> **Network:** Sui Testnet  
> **Package ID:** `0xae9dad95555d2ed4410d4e3721ac3e332211f0ed52e70d0985a0af98a2e9e916`  
> **Published:** 22 Mei 2026 · Version 1 · Immutable  
> **Token:** SGT (`0x831d1156089ec1caeb5ee8f5a3ea309bbed417da778dc9bc800e76c7ebc7488b::sgt::SGT`)

Sistem rekam medis elektronik berbasis blockchain di Sui. Data rekam disimpan di IPFS, hash-nya di-chain. Semua akses tercatat sebagai audit log on-chain. Autentikasi pasien menggunakan NIK hash + ibu kandung hash.

---

## Modules

| Modul | Deskripsi |
|---|---|
| `patient_registry` | Registrasi & manajemen data pasien |
| `doctor_registry` | Verifikasi & revokasi dokter |
| `medical_records` | Buat, akses, dan audit rekam medis |
| `fee_manager` | Manajemen biaya layanan dalam token SGT |
| `emergency_break_glass` | Akses darurat ke rekam medis dengan audit trail |

---

## 1. `patient_registry`

Registrasi pasien dengan NIK hash & ibu kandung hash sebagai autentikasi. Mendukung lookup by NIK dan combined (NIK + ibu kandung).

### Structs

#### `PatientRegistry` *(key object)*
Registry utama. Shared object yang menyimpan semua data pasien.

| Field | Type | Keterangan |
|---|---|---|
| `id` | `UID` | Object ID |
| `patients` | `Table<String, PatientRecord>` | Data pasien by patient_id |
| `nik_index` | `Table<String, String>` | Lookup patient_id by NIK hash |
| `combined_index` | `Table<String, String>` | Lookup patient_id by NIK+ibu_kandung hash |
| `total_patients` | `u64` | Total pasien terdaftar |
| `created_at` | `u64` | Timestamp pembuatan (ms) |

#### `AdminCap` *(key object)*
Capability object untuk fungsi admin. Harus dimiliki caller untuk deactivate/reactivate pasien.

| Field | Type |
|---|---|
| `id` | `UID` |

#### `PatientRecord` *(store)*
Data satu pasien.

| Field | Type | Keterangan |
|---|---|---|
| `patient_id` | `String` | ID unik pasien |
| `nik_hash` | `String` | Hash NIK KTP |
| `ibu_kandung_hash` | `String` | Hash nama ibu kandung (untuk 2FA) |
| `wallet_pubkey` | `String` | Public key wallet pasien |
| `patient_name` | `String` | Nama pasien |
| `registered_by` | `address` | Alamat yang mendaftarkan |
| `created_at` | `u64` | Timestamp registrasi (ms) |
| `updated_at` | `u64` | Timestamp update terakhir (ms) |
| `status` | `u8` | Status aktif/nonaktif |

### Events

#### `PatientRegistered`
| Field | Type |
|---|---|
| `patient_id` | `String` |
| `nik_hash` | `String` |
| `wallet_pubkey` | `String` |
| `registered_by` | `address` |
| `timestamp` | `u64` |

#### `PatientMetadataUpdated`
| Field | Type |
|---|---|
| `patient_id` | `String` |
| `updated_by` | `address` |
| `timestamp` | `u64` |

#### `PatientStatusChanged`
| Field | Type |
|---|---|
| `patient_id` | `String` |
| `old_status` | `u8` |
| `new_status` | `u8` |
| `changed_by` | `address` |
| `timestamp` | `u64` |

### Functions

#### `register_patient` *(public)*
Mendaftarkan pasien baru ke registry.

```
register_patient(
    registry:          &mut PatientRegistry,
    patient_id:        String,
    nik_hash:          String,
    ibu_kandung_hash:  String,
    wallet_pubkey:     String,
    patient_name:      String,
    clock:             &Clock,
    ctx:               &mut TxContext
)
```

#### `update_patient_name` *(public)*
Update nama pasien.

```
update_patient_name(
    registry:    &mut PatientRegistry,
    patient_id:  String,
    new_name:    String,
    clock:       &Clock,
    ctx:         &mut TxContext
)
```

#### `deactivate_patient` *(public — butuh AdminCap)*
Nonaktifkan akun pasien.

```
deactivate_patient(
    _cap:        &AdminCap,
    registry:    &mut PatientRegistry,
    patient_id:  String,
    clock:       &Clock,
    ctx:         &mut TxContext
)
```

#### `reactivate_patient` *(public — butuh AdminCap)*
Aktifkan kembali akun pasien.

```
reactivate_patient(
    _cap:        &AdminCap,
    registry:    &mut PatientRegistry,
    patient_id:  String,
    clock:       &Clock,
    ctx:         &mut TxContext
)
```

#### `verify_patient_credentials` *(public)*
Verifikasi kombinasi patient_id + NIK hash + ibu kandung hash.

```
verify_patient_credentials(
    registry:         &PatientRegistry,
    patient_id:       &String,
    nik_hash:         &String,
    ibu_kandung_hash: &String
) → bool
```

#### `get_patient_info` *(public)*
Ambil info lengkap pasien.

```
get_patient_info(
    registry:    &PatientRegistry,
    patient_id:  &String
) → (String, String, String, String, address, u64, u8)
  -- (nik_hash, ibu_kandung_hash, wallet_pubkey, patient_name, registered_by, created_at, status)
```

#### Query functions lainnya

| Fungsi | Parameter | Returns |
|---|---|---|
| `patient_exists` | `registry, patient_id` | `bool` |
| `nik_hash_exists` | `registry, nik_hash` | `bool` |
| `get_patient_status` | `registry, patient_id` | `u8` |
| `get_nik_hash` | `registry, patient_id` | `String` |
| `get_wallet_pubkey` | `registry, patient_id` | `String` |
| `get_patient_id_by_nik` | `registry, nik_hash` | `String` |
| `get_patient_id_by_combined` | `registry, nik_hash, ibu_kandung_hash` | `String` |
| `total_patients` | `registry` | `u64` |

---

## 2. `doctor_registry`

Registrasi dan verifikasi dokter. Menyimpan data STR, SIP, spesialisasi, dan hospital. Mendukung revokasi dengan alasan.

### Structs

#### `DoctorRegistry` *(key object)*

| Field | Type | Keterangan |
|---|---|---|
| `id` | `UID` | Object ID |
| `doctors` | `Table<String, DoctorRecord>` | Data dokter by doctor_id |
| `nik_index` | `Table<String, String>` | Lookup doctor_id by NIK hash |
| `total_verified` | `u64` | Total dokter terverifikasi aktif |
| `created_at` | `u64` | Timestamp pembuatan (ms) |

#### `DoctorAdminCap` *(key object)*
Capability untuk verify/revoke dokter.

#### `DoctorRecord` *(store)*

| Field | Type | Keterangan |
|---|---|---|
| `doctor_id` | `String` | ID unik dokter |
| `nik_hash` | `String` | Hash NIK dokter |
| `str_number` | `String` | Nomor STR (Surat Tanda Registrasi) |
| `sip_number` | `String` | Nomor SIP (Surat Izin Praktik) |
| `hospital_id` | `String` | ID rumah sakit tempat praktik |
| `specialization` | `String` | Spesialisasi dokter |
| `verified_by` | `address` | Alamat yang memverifikasi |
| `verified_at` | `u64` | Timestamp verifikasi (ms) |
| `status` | `u8` | 1 = verified, 2 = revoked |
| `revoked_at` | `u64` | Timestamp revokasi (ms) |
| `revoke_reason` | `String` | Alasan revokasi |

### Events

#### `DoctorVerified`
| Field | Type |
|---|---|
| `doctor_id` | `String` |
| `nik_hash` | `String` |
| `hospital_id` | `String` |
| `str_number` | `String` |
| `verified_by` | `address` |
| `timestamp` | `u64` |

#### `DoctorRevoked`
| Field | Type |
|---|---|
| `doctor_id` | `String` |
| `hospital_id` | `String` |
| `revoked_by` | `address` |
| `reason` | `String` |
| `timestamp` | `u64` |

### Functions

#### `verify_doctor` *(public — butuh DoctorAdminCap)*
Verifikasi dan daftarkan dokter baru.

```
verify_doctor(
    _cap:           &DoctorAdminCap,
    registry:       &mut DoctorRegistry,
    doctor_id:      String,
    nik_hash:       String,
    str_number:     String,
    sip_number:     String,
    hospital_id:    String,
    specialization: String,
    clock:          &Clock,
    ctx:            &mut TxContext
)
```

#### `revoke_doctor` *(public — butuh DoctorAdminCap)*
Cabut status verifikasi dokter.

```
revoke_doctor(
    _cap:       &DoctorAdminCap,
    registry:   &mut DoctorRegistry,
    doctor_id:  String,
    reason:     String,
    clock:      &Clock,
    ctx:        &mut TxContext
)
```

#### `get_doctor_info` *(public)*
Ambil info lengkap dokter.

```
get_doctor_info(
    registry:   &DoctorRegistry,
    doctor_id:  &String
) → (String, String, String, String, String, u8)
  -- (nik_hash, str_number, sip_number, hospital_id, specialization, status)
```

#### Query functions lainnya

| Fungsi | Parameter | Returns |
|---|---|---|
| `doctor_exists` | `registry, doctor_id` | `bool` |
| `is_verified` | `registry, doctor_id` | `bool` |
| `get_doctor_str` | `registry, doctor_id` | `String` |
| `get_doctor_hospital` | `registry, doctor_id` | `String` |
| `total_verified` | `registry` | `u64` |
| `status_verified` | — | `u8` (= 1) |
| `status_revoked` | — | `u8` (= 2) |

---

## 3. `medical_records`

Modul inti. Membuat rekam medis dengan referensi IPFS dan data hash on-chain. Setiap akses dicatat sebagai audit log. Pembayaran fee dalam SGT.

### Structs

#### `RecordRegistry` *(key object)*

| Field | Type | Keterangan |
|---|---|---|
| `id` | `UID` | Object ID |
| `records` | `Table<String, MedicalRecord>` | Rekam medis by record_id |
| `patient_records` | `Table<String, vector<String>>` | List record_id by patient NIK hash |
| `hospital_records` | `Table<String, vector<String>>` | List record_id by hospital_id |
| `access_logs` | `Table<String, AccessLog>` | Log akses by access_id |
| `total_records` | `u64` | Total rekam terdaftar |
| `total_accesses` | `u64` | Total log akses |
| `created_at` | `u64` | Timestamp pembuatan (ms) |

#### `RecordAdminCap` *(key object)*
Capability untuk revoke rekam medis.

#### `MedicalRecord` *(store)*

| Field | Type | Keterangan |
|---|---|---|
| `record_id` | `String` | ID unik rekam medis |
| `patient_nik_hash` | `String` | NIK hash pasien |
| `hospital_id` | `String` | ID rumah sakit |
| `doctor_id` | `String` | ID dokter yang membuat |
| `ipfs_ref` | `String` | CID/referensi IPFS |
| `data_hash` | `String` | Hash isi data (integritas) |
| `record_type` | `String` | Tipe rekam (diagnosis, lab, dll) |
| `fee_charged` | `u64` | Biaya SGT yang dibayar |
| `created_at` | `u64` | Timestamp pembuatan (ms) |
| `status` | `u8` | 1 = active, 2 = revoked |
| `revoked_at` | `u64` | Timestamp revokasi (ms) |
| `revoke_reason` | `String` | Alasan revokasi |

#### `AccessLog` *(store)*

| Field | Type | Keterangan |
|---|---|---|
| `access_id` | `String` | ID unik akses |
| `patient_nik_hash` | `String` | NIK hash pasien yang diakses |
| `accessing_hospital` | `String` | Hospital yang mengakses |
| `accessed_records` | `vector<String>` | List record_id yang diakses |
| `purpose` | `String` | Tujuan akses |
| `accessed_by` | `address` | Alamat yang mengakses |
| `timestamp` | `u64` | Timestamp akses (ms) |

### Events

#### `RecordCreated`
| Field | Type |
|---|---|
| `record_id` | `String` |
| `patient_nik_hash` | `String` |
| `hospital_id` | `String` |
| `doctor_id` | `String` |
| `ipfs_ref` | `String` |
| `record_type` | `String` |
| `fee_charged` | `u64` |
| `timestamp` | `u64` |

#### `RecordAccessed`
| Field | Type |
|---|---|
| `access_id` | `String` |
| `patient_nik_hash` | `String` |
| `accessing_hospital` | `String` |
| `record_count` | `u64` |
| `purpose` | `String` |
| `timestamp` | `u64` |

#### `RecordRevoked`
| Field | Type |
|---|---|
| `record_id` | `String` |
| `patient_nik_hash` | `String` |
| `revoked_by` | `address` |
| `reason` | `String` |
| `timestamp` | `u64` |

### Functions

#### `create_record` *(public)*
Buat rekam medis baru. Otomatis memungut fee SGT dari payment coin.

```
create_record(
    registry:         &mut RecordRegistry,
    patient_reg:      &PatientRegistry,
    fee_config:       &FeeConfig,
    treasury:         &mut Treasury,
    record_id:        String,
    patient_nik_hash: String,
    hospital_id:      String,
    doctor_id:        String,
    ipfs_ref:         String,
    data_hash:        String,
    record_type:      String,
    payment:          Coin<SGT>,
    clock:            &Clock,
    ctx:              &mut TxContext
)
```

#### `revoke_record` *(public — butuh RecordAdminCap)*
Cabut rekam medis.

```
revoke_record(
    _cap:       &RecordAdminCap,
    registry:   &mut RecordRegistry,
    record_id:  String,
    reason:     String,
    clock:      &Clock,
    ctx:        &mut TxContext
)
```

#### `log_access` *(public)*
Catat akses ke rekam medis (audit trail).

```
log_access(
    registry:          &mut RecordRegistry,
    access_id:         String,
    patient_nik_hash:  String,
    accessing_hospital: String,
    accessed_records:  vector<String>,
    purpose:           String,
    clock:             &Clock,
    ctx:               &mut TxContext
)
```

#### `get_record_info` *(public)*
Ambil info lengkap satu rekam medis.

```
get_record_info(
    registry:   &RecordRegistry,
    record_id:  &String
) → (String, String, String, String, String, String, u64, u8)
  -- (patient_nik_hash, hospital_id, doctor_id, ipfs_ref, data_hash, record_type, fee_charged, status)
```

#### `get_record_ipfs` *(public)*
Ambil referensi IPFS dan data hash saja.

```
get_record_ipfs(
    registry:   &RecordRegistry,
    record_id:  &String
) → (String, String)   -- (ipfs_ref, data_hash)
```

#### Query functions lainnya

| Fungsi | Parameter | Returns |
|---|---|---|
| `record_exists` | `registry, record_id` | `bool` |
| `access_log_exists` | `registry, access_id` | `bool` |
| `get_record_status` | `registry, record_id` | `u8` |
| `get_record_fee_charged` | `registry, record_id` | `u64` |
| `get_patient_record_ids` | `registry, patient_nik_hash` | `vector<String>` |
| `get_hospital_record_ids` | `registry, hospital_id` | `vector<String>` |
| `patient_record_count` | `registry, patient_nik_hash` | `u64` |
| `total_records` | `registry` | `u64` |
| `total_accesses` | `registry` | `u64` |
| `status_active` | — | `u8` (= 1) |
| `status_revoked` | — | `u8` (= 2) |

---

## 4. `fee_manager`

Manajemen biaya layanan dalam token SGT. Ada dua jenis fee: per rekam medis (flat) dan ekspor data (base + multiplier berdasarkan ukuran file). Semua perubahan fee tersimpan di change history.

### Structs

#### `FeeConfig` *(key object)*

| Field | Type | Keterangan |
|---|---|---|
| `id` | `UID` | Object ID |
| `record_fee_sgt` | `u64` | Biaya per rekam medis (dalam SGT) |
| `record_fee_enabled` | `bool` | Apakah fee rekam aktif |
| `export_base_fee_sgt` | `u64` | Biaya dasar ekspor data |
| `export_size_threshold_mb` | `u64` | Batas ukuran (MB) sebelum multiplier aktif |
| `export_multiplier_bps` | `u64` | Multiplier dalam basis points (1 bps = 0.01%) |
| `export_fee_enabled` | `bool` | Apakah fee ekspor aktif |
| `change_history` | `Table<String, vector<FeeChangeLog>>` | Riwayat perubahan fee |
| `total_fee_changes` | `u64` | Total perubahan konfigurasi |
| `created_at` | `u64` | Timestamp pembuatan (ms) |
| `last_updated_at` | `u64` | Timestamp update terakhir (ms) |

#### `Treasury` *(key object)*

| Field | Type | Keterangan |
|---|---|---|
| `id` | `UID` | Object ID |
| `balance` | `Balance<SGT>` | Saldo SGT saat ini |
| `total_collected` | `u64` | Total SGT yang pernah masuk |
| `total_withdrawn` | `u64` | Total SGT yang pernah ditarik |

#### `FeeAdminCap` *(key object)*
Capability untuk update fee dan withdraw treasury.

#### `FeeChangeLog` *(store, copy, drop)*

| Field | Type |
|---|---|
| `fee_type` | `String` |
| `old_value` | `u64` |
| `new_value` | `u64` |
| `changed_by` | `address` |
| `reason` | `String` |
| `timestamp` | `u64` |

### Events

#### `RecordFeeUpdated` / `ExportBaseFeeUpdated`
| Field | Type |
|---|---|
| `old_fee_sgt` | `u64` |
| `new_fee_sgt` | `u64` |
| `enabled` | `bool` |
| `changed_by` | `address` |
| `reason` | `String` |
| `timestamp` | `u64` |

#### `ExportMultiplierUpdated`
| Field | Type |
|---|---|
| `old_multiplier_bps` | `u64` |
| `new_multiplier_bps` | `u64` |
| `changed_by` | `address` |
| `reason` | `String` |
| `timestamp` | `u64` |

#### `FeeToggled`
| Field | Type |
|---|---|
| `fee_type` | `String` |
| `enabled` | `bool` |
| `changed_by` | `address` |
| `timestamp` | `u64` |

#### `FeeCollected`
| Field | Type |
|---|---|
| `fee_type` | `String` |
| `amount` | `u64` |
| `payer` | `address` |
| `timestamp` | `u64` |

#### `TreasuryWithdrawn`
| Field | Type |
|---|---|
| `amount` | `u64` |
| `recipient` | `address` |
| `timestamp` | `u64` |

### Functions

#### `collect_record_fee` *(public)*
Pungut biaya rekam medis dari Coin SGT, kembalikan kembalian.

```
collect_record_fee(
    treasury:  &mut Treasury,
    config:    &FeeConfig,
    payment:   Coin<SGT>,
    clock:     &Clock,
    ctx:       &mut TxContext
) → Coin<SGT>   -- kembalian
```

#### `collect_export_fee` *(public)*
Pungut biaya ekspor data berdasarkan ukuran file.

```
collect_export_fee(
    treasury:  &mut Treasury,
    config:    &FeeConfig,
    payment:   Coin<SGT>,
    size_mb:   u64,
    clock:     &Clock,
    ctx:       &mut TxContext
) → Coin<SGT>   -- kembalian
```

#### `update_record_fee` *(public — butuh FeeAdminCap)*
```
update_record_fee(
    _cap:      &FeeAdminCap,
    config:    &mut FeeConfig,
    new_fee:   u64,
    reason:    String,
    clock:     &Clock,
    ctx:       &mut TxContext
)
```

#### `update_export_base_fee` *(public — butuh FeeAdminCap)*
```
update_export_base_fee(
    _cap:      &FeeAdminCap,
    config:    &mut FeeConfig,
    new_fee:   u64,
    reason:    String,
    clock:     &Clock,
    ctx:       &mut TxContext
)
```

#### `update_export_multiplier` *(public — butuh FeeAdminCap)*
```
update_export_multiplier(
    _cap:      &FeeAdminCap,
    config:    &mut FeeConfig,
    new_bps:   u64,
    reason:    String,
    clock:     &Clock,
    ctx:       &mut TxContext
)
```

#### `toggle_record_fee` / `toggle_export_fee` *(public — butuh FeeAdminCap)*
```
toggle_record_fee(
    _cap:     &FeeAdminCap,
    config:   &mut FeeConfig,
    enabled:  bool,
    clock:    &Clock,
    ctx:      &mut TxContext
)
```

#### `withdraw` *(public — butuh FeeAdminCap)*
Tarik sejumlah SGT dari treasury.

```
withdraw(
    _cap:      &FeeAdminCap,
    treasury:  &mut Treasury,
    amount:    u64,
    clock:     &Clock,
    ctx:       &mut TxContext
)
```

#### `withdraw_all` *(public — butuh FeeAdminCap)*
Tarik semua SGT dari treasury.

```
withdraw_all(
    _cap:      &FeeAdminCap,
    treasury:  &mut Treasury,
    clock:     &Clock,
    ctx:       &mut TxContext
)
```

#### Query functions lainnya

| Fungsi | Parameter | Returns |
|---|---|---|
| `calculate_record_fee` | `config` | `u64` |
| `calculate_export_fee` | `config, size_mb` | `u64` |
| `record_fee_sgt` | `config` | `u64` |
| `export_base_fee_sgt` | `config` | `u64` |
| `export_multiplier_bps` | `config` | `u64` |
| `export_size_threshold_mb` | `config` | `u64` |
| `is_record_fee_enabled` | `config` | `bool` |
| `is_export_fee_enabled` | `config` | `bool` |
| `treasury_balance` | `treasury` | `u64` |
| `treasury_total_collected` | `treasury` | `u64` |
| `treasury_total_withdrawn` | `treasury` | `u64` |
| `total_fee_changes` | `config` | `u64` |
| `sgt_decimals` | — | `u64` |

---

## 5. `emergency_break_glass`

Mekanisme akses darurat ke rekam medis pasien. Dokter terverifikasi bisa inisiasi sesi EBG dengan justifikasi. Ada rate limiting per dokter dan full lifecycle tracking (initiated → completed/failed/expired).

### Structs

#### `EBGRegistry` *(key object)*

| Field | Type | Keterangan |
|---|---|---|
| `id` | `UID` | Object ID |
| `logs` | `Table<String, EBGLog>` | Log sesi EBG by ebg_id |
| `rate_limits` | `Table<String, DoctorRateLimit>` | Tracking rate limit per dokter |
| `total_ebg_events` | `u64` | Total sesi EBG yang pernah terjadi |
| `created_at` | `u64` | Timestamp pembuatan (ms) |

#### `EBGAdminCap` *(key object)*
Capability admin untuk modul ini.

#### `EBGLog` *(store)*
Audit log lengkap satu sesi akses darurat.

| Field | Type | Keterangan |
|---|---|---|
| `ebg_id` | `String` | ID unik sesi EBG |
| `doctor_id` | `String` | ID dokter |
| `doctor_str_number` | `String` | Nomor STR dokter |
| `hospital_id` | `String` | ID rumah sakit |
| `patient_nik_hash` | `String` | NIK hash pasien yang diakses |
| `emergency_type` | `String` | Jenis kedaruratan |
| `justification_hash` | `String` | Hash dokumen justifikasi |
| `session_id` | `String` | ID sesi unik |
| `status` | `u8` | Status sesi (lihat konstanta) |
| `records_accessed` | `vector<String>` | List record_id yang diakses |
| `initiated_at` | `u64` | Timestamp mulai (ms) |
| `completed_at` | `u64` | Timestamp selesai (ms) |
| `session_duration_ms` | `u64` | Durasi sesi (ms) |
| `initiated_by` | `address` | Alamat inisiator |

#### `DoctorRateLimit` *(store)*

| Field | Type | Keterangan |
|---|---|---|
| `doctor_id` | `String` | ID dokter |
| `window_start` | `u64` | Awal window rate limit (ms) |
| `count_in_window` | `u64` | Jumlah EBG dalam window saat ini |

### Status Constants

| Fungsi | Nilai | Keterangan |
|---|---|---|
| `status_initiated()` | `u8` | Sesi baru dimulai |
| `status_completed()` | `u8` | Sesi selesai normal |
| `status_failed()` | `u8` | Sesi gagal |
| `status_expired()` | `u8` | Sesi kedaluwarsa |

### Events

#### `EmergencyAccessInitiated`
| Field | Type |
|---|---|
| `ebg_id` | `String` |
| `doctor_id` | `String` |
| `patient_nik_hash` | `String` |
| `emergency_type` | `String` |
| `justification_hash` | `String` |
| `session_id` | `String` |
| `timestamp` | `u64` |

#### `EmergencyAccessCompleted`
| Field | Type |
|---|---|
| `ebg_id` | `String` |
| `doctor_id` | `String` |
| `records_accessed` | `vector<String>` |
| `session_duration_ms` | `u64` |
| `timestamp` | `u64` |

#### `EmergencyAccessFailed`
| Field | Type |
|---|---|
| `ebg_id` | `String` |
| `doctor_id` | `String` |
| `reason` | `String` |
| `timestamp` | `u64` |

### Functions

#### `initiate_emergency_access` *(public)*
Mulai sesi akses darurat. Memverifikasi dokter (harus `is_verified`) dan pasien ada di registry. Cek rate limit.

```
initiate_emergency_access(
    ebg_registry:     &mut EBGRegistry,
    doctor_registry:  &DoctorRegistry,
    patient_registry: &PatientRegistry,
    ebg_id:           String,
    doctor_id:        String,
    patient_nik_hash: String,
    emergency_type:   String,
    justification_hash: String,
    session_id:       String,
    clock:            &Clock,
    ctx:              &mut TxContext
)
```

#### `complete_emergency_access` *(public)*
Tandai sesi EBG selesai dan catat rekam yang diakses.

```
complete_emergency_access(
    ebg_registry:     &mut EBGRegistry,
    ebg_id:           String,
    records_accessed: vector<String>,
    clock:            &Clock,
    ctx:              &mut TxContext
)
```

#### `fail_emergency_access` *(public)*
Tandai sesi EBG gagal dengan alasan.

```
fail_emergency_access(
    ebg_registry:  &mut EBGRegistry,
    ebg_id:        String,
    reason:        String,
    clock:         &Clock,
    ctx:           &mut TxContext
)
```

#### `expire_emergency_access` *(public)*
Tandai sesi EBG kedaluwarsa.

```
expire_emergency_access(
    ebg_registry:  &mut EBGRegistry,
    ebg_id:        String,
    clock:         &Clock,
    ctx:           &mut TxContext
)
```

#### `get_ebg_info` *(public)*
Ambil info sesi EBG.

```
get_ebg_info(
    registry:  &EBGRegistry,
    ebg_id:    &String
) → (String, String, String, String, u8, u64, u64)
  -- (doctor_id, patient_nik_hash, emergency_type, session_id, status, initiated_at, completed_at)
```

#### Query functions lainnya

| Fungsi | Parameter | Returns |
|---|---|---|
| `ebg_exists` | `registry, ebg_id` | `bool` |
| `get_ebg_status` | `registry, ebg_id` | `u8` |
| `get_ebg_records_accessed` | `registry, ebg_id` | `vector<String>` |
| `get_doctor_ebg_count` | `registry, doctor_id` | `u64` |
| `total_ebg_events` | `registry` | `u64` |

---

## Alur Penggunaan Umum

### Registrasi & verifikasi dokter
```
1. register_patient(...)          -- daftarkan pasien
2. verify_doctor(...)             -- admin verifikasi dokter (butuh DoctorAdminCap)
```

### Buat rekam medis
```
1. calculate_record_fee(fee_config)               -- cek biaya
2. create_record(registry, patient_reg, fee_config, treasury, ..., payment)
3. log_access(registry, ...) jika ada akses dari RS lain
```

### Akses darurat (EBG)
```
1. initiate_emergency_access(ebg_reg, doctor_reg, patient_reg, ...)
2.   -- akses rekam medis yang diperlukan --
3. complete_emergency_access(ebg_reg, ebg_id, records_accessed, ...)
   -- atau fail_emergency_access / expire_emergency_access
```

### Update fee (admin)
```
1. update_record_fee(_cap, config, new_fee, reason, ...)
2. toggle_record_fee(_cap, config, true/false, ...)
3. withdraw(_cap, treasury, amount, ...)
```