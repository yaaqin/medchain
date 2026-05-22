# MedChain — Smart Contract Documentation

Decentralized medical records system on **Sui blockchain**.  
Patient data stays encrypted off-chain (IPFS). Only metadata, hashes, and audit logs live on-chain.

---

## Project Structure

```
medchain/
├── Move.toml
├── sources/
│   ├── patient_registry.move       # Patient identity & lookup
│   ├── fee_manager.move            # SGT fee configuration
│   ├── medical_records.move        # Record creation & access logs
│   ├── doctor_registry.move        # Verified doctor credentials
│   └── emergency_break_glass.move  # Emergency access with audit trail
└── tests/
    ├── patient_registry_tests.move
    ├── fee_manager_tests.move
    ├── medical_records_tests.move
    ├── doctor_registry_tests.move
    └── emergency_break_glass_tests.move
```

**Test coverage:** 51 tests, all passing.

---

## Mutability Patterns

In Move/Sui, mutability is explicit at every level — both variable binding and object references.

### `&mut` vs `&` on Shared Objects

| Pattern | Meaning | Example |
|---|---|---|
| `registry: &mut PatientRegistry` | Caller can modify this shared object | `register_patient`, `deactivate_patient` |
| `registry: &PatientRegistry` | Read-only, no state change | `patient_exists`, `get_wallet_pubkey` |
| `_cap: &AdminCap` | Read-only borrow of capability (just proves ownership) | All admin functions |

All **write functions** take `&mut` on the registry. All **view functions** take `&` (immutable reference). This is enforced by the Move type system at compile time — you cannot accidentally write to an object borrowed as `&`.

### `let mut` vs `let`

```move
// Mutable — value will be reassigned or fields will change
let mut key = *nik_hash;
string::append_utf8(&mut key, b":");   // mutating key in-place

// Immutable — read once, never changed
let now = clock::timestamp_ms(clock);
let caller = ctx.sender();
```

Rule of thumb: if you only read a value, declare with `let`. If you need to modify it later, declare with `let mut`.

---

## Module Reference

---

### 1. `patient_registry`

Handles patient registration and identity lookup. No PII stored on-chain — only SHA256 hashes.

#### Shared Objects Created at Deploy

| Object | Type | Description |
|---|---|---|
| `PatientRegistry` | `shared` | Global registry, accessible by all hospitals |

#### Capability Objects Created at Deploy

| Object | Held By | Controls |
|---|---|---|
| `AdminCap` | Deployer wallet | `deactivate_patient`, `reactivate_patient` |

#### Structs

**`PatientRegistry`** — mutable shared object, one per deployment.
```
patients:        Table<String, PatientRecord>   # patient_id → record
nik_index:       Table<String, String>          # nik_hash → patient_id
combined_index:  Table<String, String>          # nik_hash:ibu_hash → patient_id
total_patients:  u64
created_at:      u64
```

**`PatientRecord`** — stored inside `patients` table, mutable only via admin functions.
```
patient_id:       String   # "PAT-0001"
nik_hash:         String   # sha256(NIK) — 64 hex chars
ibu_kandung_hash: String   # sha256(namaIbuKandung) — 64 hex chars
wallet_pubkey:    String   # deterministic wallet pubkey
patient_name:     String   # display name (non-sensitive)
registered_by:    address  # hospital/backend that registered
created_at:       u64      # milliseconds timestamp
updated_at:       u64
status:           u8       # 1 = ACTIVE, 0 = INACTIVE
```

#### Write Functions (require `&mut PatientRegistry`)

**`register_patient`**
```
Inputs:
  registry:          &mut PatientRegistry   # mutable — adds new record
  patient_id:        String                 # "PAT-0001", must be unique
  nik_hash:          String                 # sha256(NIK), exactly 64 chars
  ibu_kandung_hash:  String                 # sha256(ibuKandung), exactly 64 chars
  wallet_pubkey:     String                 # hex pubkey from deterministic derivation
  patient_name:      String                 # display name
  clock:             &Clock                 # immutable — read timestamp only
  ctx:               &mut TxContext         # mutable — read sender address

Validations:
  - nik_hash length == 64
  - ibu_kandung_hash length == 64
  - patient_id not already in registry
  - nik_hash not already in nik_index
  - combined key not already in combined_index

Emits: PatientRegistered { patient_id, nik_hash, wallet_pubkey, registered_by, timestamp }
```

**`deactivate_patient`** _(requires AdminCap)_
```
Inputs:
  _cap:        &AdminCap              # immutable — proves admin ownership
  registry:    &mut PatientRegistry   # mutable — updates status field
  patient_id:  String
  clock:       &Clock
  ctx:         &mut TxContext

Mutations: record.status = INACTIVE, record.updated_at = now
Emits: PatientStatusChanged { patient_id, old_status, new_status, changed_by, timestamp }
```

**`reactivate_patient`** _(requires AdminCap)_
```
Inputs: same as deactivate_patient
Mutations: record.status = ACTIVE, record.updated_at = now
Emits: PatientStatusChanged
```

**`update_patient_name`**
```
Inputs:
  registry:    &mut PatientRegistry
  patient_id:  String
  new_name:    String
  clock:       &Clock
  ctx:         &mut TxContext         # caller must == record.registered_by

Mutations: record.patient_name = new_name, record.updated_at = now
Emits: PatientMetadataUpdated
```

#### View Functions (require `&PatientRegistry`, no state change)

| Function | Input | Returns | Description |
|---|---|---|---|
| `patient_exists` | `patient_id: &String` | `bool` | Check if ID is registered |
| `nik_hash_exists` | `nik_hash: &String` | `bool` | Check if NIK hash is registered |
| `get_patient_id_by_nik` | `nik_hash: &String` | `String` | Lookup patient_id by NIK hash |
| `get_patient_id_by_combined` | `nik_hash, ibu_kandung_hash: &String` | `String` | Secure login lookup |
| `verify_patient_credentials` | `patient_id, nik_hash, ibu_kandung_hash: &String` | `bool` | Verify login credentials |
| `get_wallet_pubkey` | `patient_id: &String` | `String` | Get pubkey for encryption |
| `get_nik_hash` | `patient_id: &String` | `String` | Get NIK hash for record linking |
| `get_patient_status` | `patient_id: &String` | `u8` | Get current status |
| `total_patients` | — | `u64` | Total registered patients |
| `get_patient_info` | `patient_id: &String` | `(String, String, String, String, address, u64, u8)` | Full record tuple |

#### Error Codes

| Code | Constant | Trigger |
|---|---|---|
| 1001 | `E_PATIENT_ALREADY_EXISTS` | Duplicate patient_id or nik_hash |
| 1002 | `E_PATIENT_NOT_FOUND` | ID or hash not in registry |
| 1003 | `E_UNAUTHORIZED` | Caller is not original registrar |
| 1004 | `E_INVALID_NIK_HASH` | nik_hash not exactly 64 chars |
| 1005 | `E_INVALID_IBU_HASH` | ibu_kandung_hash not exactly 64 chars |
| 1006 | `E_PATIENT_INACTIVE` | Operation on deactivated patient |

---

### 2. `fee_manager`

Manages configurable SGT fee structure. All fee changes are logged on-chain permanently.

#### Shared Objects Created at Deploy

| Object | Type | Description |
|---|---|---|
| `FeeConfig` | `shared` | Fee configuration, queried by `medical_records` before charging |

#### Capability Objects Created at Deploy

| Object | Held By | Controls |
|---|---|---|
| `FeeAdminCap` | Deployer wallet | All fee update functions |

> Note: `FeeAdminCap` is intentionally separate from `patient_registry::AdminCap` — fee admin can be a different multisig wallet.

#### Structs

**`FeeConfig`** — mutable shared object.
```
record_fee_sgt:            u64    # fee per record creation (SGT units, not base units)
record_fee_enabled:        bool   # false = free period, calculated fee = 0
export_base_fee_sgt:       u64    # flat fee for files ≤ threshold
export_size_threshold_mb:  u64    # default 2 MB — threshold for flat vs size-based
export_multiplier_bps:     u64    # basis points: 10000 = 1.0x, 7000 = 0.7x
export_fee_enabled:        bool
change_history:            Table<String, vector<FeeChangeLog>>
total_fee_changes:         u64
created_at:                u64
last_updated_at:           u64
```

**`FeeChangeLog`** — immutable log entry stored inside `change_history`.
```
fee_type:    String    # "RECORD_CREATION" | "EXPORT_BASE" | "EXPORT_MULTIPLIER"
old_value:   u64
new_value:   u64
changed_by:  address
reason:      String    # admin-provided reason
timestamp:   u64
```

#### Default Values at Deploy

| Setting | Default | Notes |
|---|---|---|
| `record_fee_sgt` | `1` | 1 SGT per record |
| `export_base_fee_sgt` | `1` | 1 SGT flat for ≤ 2MB |
| `export_size_threshold_mb` | `2` | 2 MB threshold |
| `export_multiplier_bps` | `10_000` | 1.0x (no discount) |
| `SGT_DECIMALS` | `1_000_000_000` | 1 SGT = 1,000,000,000 base units |
| Max fee cap | `100` SGT | Safety limit — admin cannot set higher |
| Multiplier min | `1_000` bps | 0.1x minimum |
| Multiplier max | `50_000` bps | 5.0x maximum |

#### Write Functions (require `FeeAdminCap` + `&mut FeeConfig`)

**`update_record_fee`**
```
Inputs:
  _cap:         &FeeAdminCap     # immutable — proves admin ownership
  config:       &mut FeeConfig   # mutable — updates record_fee_sgt
  new_fee_sgt:  u64              # 0–100 SGT
  reason:       String           # logged to change_history
  clock:        &Clock
  ctx:          &mut TxContext

Mutations: config.record_fee_sgt, config.total_fee_changes, appends to change_history
Emits: RecordFeeUpdated
```

**`update_export_base_fee`**
```
Inputs: same pattern, updates config.export_base_fee_sgt
Emits: ExportBaseFeeUpdated
```

**`update_export_multiplier`**
```
Inputs:
  new_multiplier_bps:  u64   # must be 1_000–50_000 bps

Mutations: config.export_multiplier_bps
Emits: ExportMultiplierUpdated
```

**`toggle_record_fee`** / **`toggle_export_fee`**
```
Inputs:
  enabled:  bool   # true = fee active, false = free period

Mutations: config.record_fee_enabled / config.export_fee_enabled
Emits: FeeToggled
```

#### View / Calculation Functions (read-only `&FeeConfig`)

| Function | Input | Returns | Description |
|---|---|---|---|
| `calculate_record_fee` | — | `u64` | Fee in base SGT units. Returns 0 if disabled. |
| `calculate_export_fee` | `file_size_kb: u64` | `u64` | Size-based export fee in base units |
| `record_fee_sgt` | — | `u64` | Current fee in SGT (human-readable) |
| `export_base_fee_sgt` | — | `u64` | Current export base fee in SGT |
| `export_multiplier_bps` | — | `u64` | Current multiplier in basis points |
| `is_record_fee_enabled` | — | `bool` | Whether record fee is active |
| `is_export_fee_enabled` | — | `bool` | Whether export fee is active |
| `total_fee_changes` | — | `u64` | Total changes ever made |
| `sgt_decimals` | — | `u64` | Returns `1_000_000_000` |

**Export fee formula:**
```
if file_size_kb <= threshold_kb:
    fee = base_fee_sgt * SGT_DECIMALS

else:
    fee = (file_size_kb * multiplier_bps * SGT_DECIMALS) / (1024 * 10_000)
    # equivalent to: (size_mb * multiplier_float) * SGT_DECIMALS
```

#### Error Codes

| Code | Constant | Trigger |
|---|---|---|
| 2002 | `E_INVALID_FEE` | `new_fee_sgt > 100` |
| 2003 | `E_INVALID_MULTIPLIER` | Multiplier outside 1_000–50_000 bps |
| 2005 | `E_ZERO_FILE_SIZE` | `file_size_kb == 0` passed to `calculate_export_fee` |

---

### 3. `medical_records`

Stores medical record metadata on-chain. Actual data is encrypted and stored on IPFS.

#### Shared Objects Created at Deploy

| Object | Type | Description |
|---|---|---|
| `RecordRegistry` | `shared` | All records + access logs |

#### Capability Objects Created at Deploy

| Object | Held By | Controls |
|---|---|---|
| `RecordAdminCap` | Deployer wallet | `revoke_record` |

#### Structs

**`RecordRegistry`** — mutable shared object.
```
records:          Table<String, MedicalRecord>      # record_id → record
patient_records:  Table<String, vector<String>>     # nik_hash → [record_id, ...]
hospital_records: Table<String, vector<String>>     # hospital_id → [record_id, ...]
access_logs:      Table<String, AccessLog>          # access_id → log
total_records:    u64
total_accesses:   u64
created_at:       u64
```

**`MedicalRecord`** — stored inside `records` table.
```
record_id:        String   # "REC-2024-0001"
patient_nik_hash: String   # links to PatientRegistry (NOT patient_id)
hospital_id:      String   # "PUSKESMAS-C"
doctor_id:        String   # "DOC-0001"
ipfs_ref:         String   # IPFS CID of encrypted blob e.g. "QmABCD1234..."
data_hash:        String   # sha256(encrypted blob) — tamper detection
record_type:      String   # "CONSULTATION" | "LAB_RESULT" | "PRESCRIPTION" | etc.
fee_charged:      u64      # SGT base units paid at creation
created_at:       u64
status:           u8       # 1 = ACTIVE, 0 = REVOKED
revoked_at:       u64      # 0 if never revoked
revoke_reason:    String   # empty if never revoked
```

**`AccessLog`** — immutable audit log, never modified after creation.
```
access_id:           String           # "ACC-001"
patient_nik_hash:    String
accessing_hospital:  String
accessed_records:    vector<String>   # list of record_ids accessed
purpose:             String           # "Patient consultation"
accessed_by:         address
timestamp:           u64
```

#### Write Functions

**`create_record`**
```
Inputs:
  registry:          &mut RecordRegistry   # mutable — adds record to all indexes
  patient_registry:  &PatientRegistry      # immutable — verify patient exists
  fee_config:        &FeeConfig            # immutable — calculate required fee
  record_id:         String                # unique, e.g. "REC-2024-0001"
  patient_nik_hash:  String                # must exist in PatientRegistry
  hospital_id:       String                # non-empty
  doctor_id:         String
  ipfs_ref:          String                # non-empty IPFS CID
  data_hash:         String                # non-empty sha256 of encrypted blob
  record_type:       String
  fee_paid:          u64                   # must be >= calculate_record_fee()
  clock:             &Clock
  _ctx:              &mut TxContext        # unused, kept for PTB compatibility

Mutations:
  - Adds record_id to patient_records[nik_hash]
  - Adds record_id to hospital_records[hospital_id]
  - Adds MedicalRecord to records table
  - Increments total_records

Emits: RecordCreated { record_id, patient_nik_hash, hospital_id, doctor_id, ipfs_ref, record_type, fee_charged, timestamp }
```

**`log_access`**
```
Inputs:
  registry:            &mut RecordRegistry
  access_id:           String               # unique access event ID
  patient_nik_hash:    String
  accessing_hospital:  String
  record_ids:          vector<String>       # which records were accessed
  purpose:             String
  clock:               &Clock
  ctx:                 &mut TxContext       # used for ctx.sender() → accessed_by

Mutations:
  - Adds AccessLog to access_logs table
  - Increments total_accesses

Emits: RecordAccessed { access_id, patient_nik_hash, accessing_hospital, record_count, purpose, timestamp }

Important: call this BEFORE returning decrypted data to requester.
```

**`revoke_record`** _(requires RecordAdminCap)_
```
Inputs:
  _cap:        &RecordAdminCap
  registry:    &mut RecordRegistry
  record_id:   String
  reason:      String
  clock:       &Clock
  ctx:         &mut TxContext

Mutations: record.status = REVOKED, record.revoked_at = now, record.revoke_reason = reason
Emits: RecordRevoked
```

#### View Functions (read-only `&RecordRegistry`)

| Function | Input | Returns |
|---|---|---|
| `record_exists` | `record_id: &String` | `bool` |
| `total_records` | — | `u64` |
| `total_accesses` | — | `u64` |
| `patient_record_count` | `nik_hash: &String` | `u64` |
| `get_patient_record_ids` | `nik_hash: &String` | `vector<String>` |
| `get_hospital_record_ids` | `hospital_id: &String` | `vector<String>` |
| `get_record_info` | `record_id: &String` | `(record_id, nik_hash, hospital_id, ipfs_ref, data_hash, record_type, created_at, status)` |
| `get_record_ipfs` | `record_id: &String` | `(ipfs_ref, data_hash)` |
| `get_record_status` | `record_id: &String` | `u8` |
| `access_log_exists` | `access_id: &String` | `bool` |
| `get_record_fee_charged` | `record_id: &String` | `u64` |

#### Error Codes

| Code | Constant | Trigger |
|---|---|---|
| 3001 | `E_RECORD_NOT_FOUND` | record_id not in registry |
| 3002 | `E_PATIENT_NOT_FOUND` | nik_hash not in PatientRegistry |
| 3003 | `E_DUPLICATE_RECORD_ID` | record_id already exists |
| 3004 | `E_INVALID_IPFS_REF` | empty ipfs_ref string |
| 3005 | `E_INVALID_DATA_HASH` | empty data_hash string |
| 3006 | `E_INVALID_HOSPITAL_ID` | empty hospital_id string |
| 3007 | `E_INSUFFICIENT_FEE` | fee_paid < required fee |
| 3008 | `E_RECORD_ALREADY_REVOKED` | revoke called on already-revoked record |

---

### 4. `doctor_registry`

Manages verified doctor credentials. Only verified doctors can trigger Emergency Break Glass.

#### Shared Objects Created at Deploy

| Object | Type | Description |
|---|---|---|
| `DoctorRegistry` | `shared` | All verified doctor records |

#### Capability Objects Created at Deploy

| Object | Held By | Controls |
|---|---|---|
| `DoctorAdminCap` | Deployer wallet | `verify_doctor`, `revoke_doctor` |

#### Structs

**`DoctorRegistry`** — mutable shared object.
```
doctors:        Table<String, DoctorRecord>   # doctor_id → record
nik_index:      Table<String, String>         # nik_hash → doctor_id
total_verified: u64
created_at:     u64
```

**`DoctorRecord`** — stored inside `doctors` table.
```
doctor_id:      String   # "DOC-0001"
nik_hash:       String   # sha256(doctor NIK)
str_number:     String   # Surat Tanda Registrasi e.g. "503/XXX/STR/2023"
sip_number:     String   # Surat Izin Praktik e.g. "SIP/001/DINKES/2024"
hospital_id:    String   # affiliated hospital
specialization: String   # "Emergency Medicine", "General", etc.
verified_by:    address  # admin who granted verification
verified_at:    u64
status:         u8       # 1 = VERIFIED, 0 = REVOKED
revoked_at:     u64
revoke_reason:  String
```

#### Write Functions

**`verify_doctor`** _(requires DoctorAdminCap)_
```
Inputs:
  _cap:           &DoctorAdminCap
  registry:       &mut DoctorRegistry
  doctor_id:      String              # non-empty, unique
  nik_hash:       String              # sha256(NIK), unique
  str_number:     String              # non-empty
  sip_number:     String
  hospital_id:    String              # non-empty
  specialization: String
  clock:          &Clock
  ctx:            &mut TxContext

Mutations:
  - Adds DoctorRecord to doctors table
  - Adds nik_hash → doctor_id to nik_index
  - Increments total_verified

Emits: DoctorVerified { doctor_id, nik_hash, hospital_id, str_number, verified_by, timestamp }
```

**`revoke_doctor`** _(requires DoctorAdminCap)_
```
Inputs:
  _cap:       &DoctorAdminCap
  registry:   &mut DoctorRegistry
  doctor_id:  String
  reason:     String
  clock:      &Clock
  ctx:        &mut TxContext

Mutations: doctor.status = REVOKED, doctor.revoked_at = now, doctor.revoke_reason = reason
Emits: DoctorRevoked
```

#### View Functions

| Function | Input | Returns |
|---|---|---|
| `is_verified` | `doctor_id: &String` | `bool` — main gate check for EBG |
| `doctor_exists` | `doctor_id: &String` | `bool` |
| `total_verified` | — | `u64` |
| `get_doctor_hospital` | `doctor_id: &String` | `String` |
| `get_doctor_str` | `doctor_id: &String` | `String` |
| `get_doctor_info` | `doctor_id: &String` | `(doctor_id, nik_hash, str_number, hospital_id, specialization, status)` |

#### Error Codes

| Code | Constant | Trigger |
|---|---|---|
| 4001 | `E_DOCTOR_ALREADY_VERIFIED` | Duplicate doctor_id or nik_hash |
| 4002 | `E_DOCTOR_NOT_FOUND` | doctor_id not in registry |
| 4004 | `E_DOCTOR_ALREADY_REVOKED` | Revoke called on already-revoked doctor |
| 4005 | `E_INVALID_DOCTOR_ID` | Empty doctor_id string |
| 4006 | `E_INVALID_STR_NUMBER` | Empty str_number string |
| 4007 | `E_INVALID_HOSPITAL_ID` | Empty hospital_id string |

---

### 5. `emergency_break_glass`

Emergency access mechanism with strict security gates and immutable audit trail.

#### Shared Objects Created at Deploy

| Object | Type | Description |
|---|---|---|
| `EBGRegistry` | `shared` | All EBG logs + rate limit tracking |

#### Capability Objects Created at Deploy

| Object | Held By | Controls |
|---|---|---|
| `EBGAdminCap` | Deployer wallet | Reserved for future admin operations |

#### Security Gates (in order)

| Gate | Enforced By | What It Checks |
|---|---|---|
| 1 | Smart contract | `doctor_id` must have `STATUS_VERIFIED` in DoctorRegistry |
| 2 | NestJS + contract | Justification plaintext ≥ 50 chars (NestJS), hash non-empty (contract) |
| 3 | Redis (backend) | Session token single-use enforcement |
| 4 | Smart contract | `EmergencyAccessInitiated` event written BEFORE data is opened |
| 5 | Smart contract | Max 3 EBG requests per doctor per 24h sliding window |
| 6 | NestJS | Data not cached after session ends |

#### Structs

**`EBGRegistry`** — mutable shared object.
```
logs:              Table<String, EBGLog>           # ebg_id → log
rate_limits:       Table<String, DoctorRateLimit>  # doctor_id → rate limit
total_ebg_events:  u64
created_at:        u64
```

**`EBGLog`** — stores full lifecycle of one emergency access event.
```
ebg_id:              String           # "EBG-2024-0001"
doctor_id:           String
doctor_str_number:   String           # snapshot of STR at time of access
hospital_id:         String           # snapshot of hospital at time of access
patient_nik_hash:    String
emergency_type:      String           # "LIFE_THREATENING" | "UNCONSCIOUS" | "CRITICAL_SURGERY"
justification_hash:  String           # sha256(justification plaintext)
session_id:          String           # UUID for Redis cross-reference
status:              u8               # 1=INITIATED 2=COMPLETED 3=EXPIRED 4=FAILED
records_accessed:    vector<String>   # filled when COMPLETED
initiated_at:        u64
completed_at:        u64              # 0 if not yet completed
session_duration_ms: u64
initiated_by:        address
```

**`DoctorRateLimit`** — per-doctor sliding window counter.
```
doctor_id:        String
window_start:     u64    # timestamp of first EBG in current 24h window
count_in_window:  u64    # resets to 1 when window expires
```

#### EBG Session Lifecycle

```
NestJS validates justification length (≥ 50 chars)
    ↓
initiate_emergency_access()    → status: INITIATED (written before data access)
    ↓
NestJS issues Redis session token (TTL 15 min)
    ↓
Doctor accesses data (Redis enforces single-use)
    ↓
complete_emergency_access()    → status: COMPLETED (records_accessed filled)
  OR fail_emergency_access()   → status: FAILED
  OR expire_emergency_access() → status: EXPIRED (TTL passed)
```

#### Write Functions

**`initiate_emergency_access`**
```
Inputs:
  registry:           &mut EBGRegistry
  doctor_registry:    &DoctorRegistry    # immutable — verify doctor status
  patient_registry:   &PatientRegistry   # immutable — verify patient exists
  ebg_id:             String             # unique, e.g. "EBG-2024-0001"
  doctor_id:          String             # must be VERIFIED
  patient_nik_hash:   String             # must exist in PatientRegistry
  emergency_type:     String             # must be valid enum value
  justification_hash: String             # sha256(plaintext), non-empty
  session_id:         String             # UUID from backend
  clock:              &Clock
  ctx:                &mut TxContext

Mutations:
  - Adds EBGLog with STATUS_INITIATED
  - Updates/creates DoctorRateLimit entry
  - Increments total_ebg_events

Emits: EmergencyAccessInitiated { ebg_id, doctor_id, patient_nik_hash, emergency_type, justification_hash, session_id, timestamp }
```

**`complete_emergency_access`**
```
Inputs:
  registry:          &mut EBGRegistry
  ebg_id:            String
  records_accessed:  vector<String>   # record_ids that were actually accessed
  clock:             &Clock
  ctx:               &mut TxContext

Mutations: log.status = COMPLETED, log.records_accessed, log.session_duration_ms
Emits: EmergencyAccessCompleted { ebg_id, doctor_id, records_accessed, session_duration_ms, timestamp }
```

**`fail_emergency_access`**
```
Inputs:
  registry:  &mut EBGRegistry
  ebg_id:    String
  reason:    String
  clock:     &Clock
  ctx:       &mut TxContext

Mutations: log.status = FAILED, log.session_duration_ms
Emits: EmergencyAccessFailed { ebg_id, doctor_id, reason, timestamp }
```

**`expire_emergency_access`**
```
Inputs:
  registry:  &mut EBGRegistry
  ebg_id:    String
  clock:     &Clock
  ctx:       &mut TxContext

Mutations: log.status = EXPIRED, log.session_duration_ms
No event emitted — expiry is passive.
```

#### View Functions

| Function | Input | Returns |
|---|---|---|
| `ebg_exists` | `ebg_id: &String` | `bool` |
| `total_ebg_events` | — | `u64` |
| `get_ebg_status` | `ebg_id: &String` | `u8` |
| `get_ebg_info` | `ebg_id: &String` | `(ebg_id, doctor_id, patient_nik_hash, emergency_type, status, initiated_at, completed_at)` |
| `get_ebg_records_accessed` | `ebg_id: &String` | `vector<String>` |
| `get_doctor_ebg_count` | `doctor_id: &String` | `u64` — count in current 24h window |

#### Rate Limit Constants

| Setting | Value |
|---|---|
| Max EBG per doctor per day | `3` |
| Window duration | `86_400_000` ms (24 hours) |
| Window reset | Sliding — resets from first request in window |

#### Error Codes

| Code | Constant | Trigger |
|---|---|---|
| 5001 | `E_DOCTOR_NOT_VERIFIED` | doctor_id not VERIFIED in DoctorRegistry |
| 5002 | `E_PATIENT_NOT_FOUND` | nik_hash not in PatientRegistry |
| 5003 | `E_JUSTIFICATION_TOO_SHORT` | justification_hash is empty string |
| 5004 | `E_INVALID_EMERGENCY_TYPE` | Not one of the 3 valid types |
| 5005 | `E_EBG_NOT_FOUND` | ebg_id not in registry |
| 5006 | `E_EBG_ALREADY_COMPLETED` | complete/fail/expire called on non-INITIATED session |
| 5007 | `E_RATE_LIMIT_EXCEEDED` | Doctor exceeded 3 EBGs in 24h window |
| 5008 | `E_DUPLICATE_EBG_ID` | ebg_id already exists in registry |
| 5009 | `E_INVALID_EBG_ID` | Empty ebg_id string |

---

## Cross-Module Dependency Graph

```
patient_registry   ←── medical_records
       ↑                      ↑
       └──── emergency_break_glass
                              ↑
doctor_registry   ────────────┘

fee_manager       ←── medical_records
```

Dependencies are read-only (immutable `&`) — no circular writes.

---

## Deploying to Testnet

```bash
# 1. Ensure wallet is funded
sui client gas

# 2. Build
sui move build

# 3. Deploy
sui client publish --gas-budget 1000000000
```

---

## ✅ Deployed — Sui Testnet

**Transaction Digest:** `C3TQbZApBkYLZc2FXn6FR6YYBnzmkxCAmL6JhBgWpqMm`  
**Deployed By:** `0xb95e07406a27e0cc8e2f5da4b31dcc7aa01003c4155b9760980970f66a795756`  
**Epoch:** 1107  
**Gas Used:** 165,282,520 MIST (~0.165 SUI)

### Package

| | ID |
|---|---|
| **Package ID** | `0xae9dad95555d2ed4410d4e3721ac3e332211f0ed52e70d0985a0af98a2e9e916` |

### Shared Objects (accessible by all)

| Object | ID |
|---|---|
| `PatientRegistry` | `0x0ea770c3e185829bbedaa860f48c0a593545162a5624caf3fee1e1b564a23d77` |
| `RecordRegistry` | `0x0d4cc02965725389edc97a926616a914acc360b966c25e6d845efc4c23ce6cae` |
| `EBGRegistry` | `0x9f1a9efb97e31070fd58f16c9476c2430740440475080a20bb549f192837e593` |
| `FeeConfig` | `0xb082977f166a0b6ee80b97ab5dba5502e2c82b6b020ef215b3e8844ed21ebe8c` |
| `Treasury` | `0xb48c0939362158bc191a0f7a0e992f34c48ad270a613dbede6ebba6030be31f3` |
| `DoctorRegistry` | `0xcca60c5cbd83adb6d7afafd50f61c04e7f6751611aa7ac4cfd78a66b8d7b908d` |

### Capability Objects (held by deployer wallet)

| Object | ID |
|---|---|
| `FeeAdminCap` | `0x61cc91acaf75800b4575f19d4131c565fa04502eb07a2bb140c7664d3d34fbb9` |
| `AdminCap` (patient_registry) | `0x896c6992ddff14e0db5bf69ffe3af893849f668c29b5bcb12f8ad7d01a828300` |
| `RecordAdminCap` | `0x9601846e03e75bcb3b0a31171572af7758ceb60b2b750b6f46a496d5d5b9f22b` |
| `EBGAdminCap` | `0xa2417b78c1406057d54beff4f219b9ccd910850b53b5a3dae7fbc29b4c452816` |
| `DoctorAdminCap` | `0xf754c36a5ab3aada565e6d47b32b7621e2954176a07e8ee00d152130257ae92b` |
| `UpgradeCap` | `0x6de6675efcfeb5775fceab5ec7bebe5cafd91b7b0155cee9f3cbb65a46c6a65a` |

> **UpgradeCap** — simpan baik-baik. Ini yang dipakai untuk upgrade package di masa depan.

### NestJS `.env`

```env
SUI_NETWORK=testnet
SUI_PACKAGE_ID=0xae9dad95555d2ed4410d4e3721ac3e332211f0ed52e70d0985a0af98a2e9e916

# Shared Objects
PATIENT_REGISTRY_ID=0x0ea770c3e185829bbedaa860f48c0a593545162a5624caf3fee1e1b564a23d77
RECORD_REGISTRY_ID=0x0d4cc02965725389edc97a926616a914acc360b966c25e6d845efc4c23ce6cae
EBG_REGISTRY_ID=0x9f1a9efb97e31070fd58f16c9476c2430740440475080a20bb549f192837e593
FEE_CONFIG_ID=0xb082977f166a0b6ee80b97ab5dba5502e2c82b6b020ef215b3e8844ed21ebe8c
TREASURY_ID=0xb48c0939362158bc191a0f7a0e992f34c48ad270a613dbede6ebba6030be31f3
DOCTOR_REGISTRY_ID=0xcca60c5cbd83adb6d7afafd50f61c04e7f6751611aa7ac4cfd78a66b8d7b908d

# Admin Caps (deployer wallet only)
FEE_ADMIN_CAP_ID=0x61cc91acaf75800b4575f19d4131c565fa04502eb07a2bb140c7664d3d34fbb9
PATIENT_ADMIN_CAP_ID=0x896c6992ddff14e0db5bf69ffe3af893849f668c29b5bcb12f8ad7d01a828300
RECORD_ADMIN_CAP_ID=0x9601846e03e75bcb3b0a31171572af7758ceb60b2b750b6f46a496d5d5b9f22b
EBG_ADMIN_CAP_ID=0xa2417b78c1406057d54beff4f219b9ccd910850b53b5a3dae7fbc29b4c452816
DOCTOR_ADMIN_CAP_ID=0xf754c36a5ab3aada565e6d47b32b7621e2954176a07e8ee00d152130257ae92b
```

Verify on explorer: https://testnet.suivision.xyz/txblock/C3TQbZApBkYLZc2FXn6FR6YYBnzmkxCAmL6JhBgWpqMm

---

## Running Tests

```bash
sui move test
# Expected: Test result: ok. Total tests: 51; passed: 51; failed: 0
```