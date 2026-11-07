//! Optional on-device XCTest owner. No network work runs until explicitly started.
//! The pinned idevice library owns RPPairing/DTX; this crate owns one native lifetime.
use std::ffi::{CStr, CString, c_char};
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use idevice::RsdService;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::lockdown::LockdownClient;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::services::dvt::xctest::{TestConfig, listener::XCUITestListener, run_rsd};
use idevice::tcp::{adapter::Adapter, handle::AdapterHandle};
use rsa::{RsaPublicKey, pkcs1::DecodeRsaPublicKey, traits::PublicKeyParts};
use serde::Deserialize;
use tokio::net::TcpStream;
use tokio::sync::watch;

const READY_PREFIX: &str = "DSH_PHONE_READY_V1:";
const DVT_SERVICE: &str = "com.apple.instruments.dtservicehub";
const TEST_SERVICE: &str = "com.apple.dt.testmanagerd.remote";
const MAX_CONFIG: usize = 16 * 1024;

type Callback = extern "C" fn(*const c_char, i32, *const c_char);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Config {
    run_id: String,
    pairing_file: String,
    host: String,
    port: u16,
    runner_bundle_id: String,
    target_bundle_id: String,
    public_key_base64: String,
}

impl Config {
    fn parse(bytes: &[u8]) -> Option<Self> {
        if bytes.len() > MAX_CONFIG {
            return None;
        }
        let value: Self = serde_json::from_slice(bytes).ok()?;
        let host: IpAddr = value.host.parse().ok()?;
        let self_route = host.is_loopback() || value.host == "10.7.0.1";
        let bundle = |value: &str| {
            !value.is_empty()
                && value.len() <= 255
                && value.contains('.')
                && value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        };
        let key = STANDARD.decode(&value.public_key_base64).ok()?;
        let key = RsaPublicKey::from_pkcs1_der(&key).ok()?;
        if uuid::Uuid::parse_str(&value.run_id).is_err()
            || value.run_id.contains('\0')
            || !self_route
            || value.port == 0
            || !Path::new(&value.pairing_file).is_absolute()
            || value.pairing_file.len() > 4096
            || value.pairing_file.contains('\0')
            || !bundle(&value.runner_bundle_id)
            || !bundle(&value.target_bundle_id)
            || key.n().bits() != 2048
        {
            return None;
        }
        Some(value)
    }
}

#[derive(Clone, Copy, Debug)]
struct Failure(&'static str);
const PAIRING: Failure = Failure(
    "ERR_PHONE_PAIRING_REQUIRED: Import a valid remote pairing record and enable LocalDevVPN.",
);
const TUNNEL: Failure =
    Failure("ERR_PHONE_TUNNEL: Could not establish the device developer tunnel.");
const DDI: Failure = Failure(
    "ERR_PHONE_DDI_REQUIRED: Developer services are unavailable; mount the matching developer disk image first.",
);
const CONFIGURATION: Failure = Failure(
    "ERR_PHONE_RUNNER_NOT_INSTALLED: Install the signed PhoneRunner xctrunner for this app.",
);
const SESSION: Failure =
    Failure("ERR_PHONE_XCTEST_SESSION: The XCTest session failed or disconnected.");
const PROTOCOL: Failure =
    Failure("ERR_PHONE_RUNNER_PROTOCOL: The runner did not return a valid encrypted endpoint.");
const STOP_UNCONFIRMED: Failure = Failure("ERR_PHONE_STOP_UNCONFIRMED");

fn emit(callback: Callback, run_id: &str, kind: i32, payload: &str) {
    // run_id is validated, and every payload is static text or canonical base64.
    if let (Ok(run_id), Ok(payload)) = (CString::new(run_id), CString::new(payload)) {
        callback(run_id.as_ptr(), kind, payload.as_ptr());
    }
}

struct Owner {
    handle: u64,
    stop: watch::Sender<bool>,
    cancelled: Arc<AtomicBool>,
}
static OWNER: OnceLock<Mutex<Option<Owner>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
fn owner() -> &'static Mutex<Option<Owner>> {
    OWNER.get_or_init(|| Mutex::new(None))
}

/// Copy the configuration and start one native lifetime. Invalid pointers are a
/// caller contract violation; null pointers and malformed JSON are rejected.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsh_phone_xctest_start(
    config_json: *const c_char,
    callback: Option<Callback>,
) -> u64 {
    if config_json.is_null() {
        return 0;
    }
    let Some(callback) = callback else {
        return 0;
    };
    let Some(config) = Config::parse(unsafe { CStr::from_ptr(config_json) }.to_bytes()) else {
        return 0;
    };
    let Ok(mut slot) = owner().lock() else {
        return 0;
    };
    if slot.is_some() {
        return 0;
    }
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    if handle == 0 {
        return 0;
    }
    let (stop, receiver) = watch::channel(false);
    let cancelled = Arc::new(AtomicBool::new(false));
    *slot = Some(Owner {
        handle,
        stop,
        cancelled: cancelled.clone(),
    });
    drop(slot);
    let spawned = std::thread::Builder::new()
        .name("dsh-phone-xctest".into())
        .spawn(move || {
            emit(callback, &config.run_id, 0, "");
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|_| SESSION)?;
                // Dropping this runtime closes all tunnel tasks before terminal delivery.
                runtime.block_on(run_session(&config, callback, receiver))
            }))
            .unwrap_or(Err(STOP_UNCONFIRMED));
            finish_owner(
                handle,
                &config.run_id,
                callback,
                cancelled.load(Ordering::Acquire),
                result,
            );
        });
    if spawned.is_err() {
        if let Ok(mut slot) = owner().lock() {
            if slot.as_ref().is_some_and(|entry| entry.handle == handle) {
                *slot = None;
            }
        }
        return 0;
    }
    handle
}

fn finish_owner(
    handle: u64,
    run_id: &str,
    callback: Callback,
    cancelled: bool,
    result: Result<(), Failure>,
) {
    if result
        .as_ref()
        .err()
        .is_some_and(|error| error.0 == STOP_UNCONFIRMED.0)
    {
        // All native resources have closed, but no new launch may overlap an
        // unconfirmed device process. Keep a small poisoned owner until restart.
        emit(callback, run_id, 4, STOP_UNCONFIRMED.0);
        return;
    }
    if let Ok(mut slot) = owner().lock() {
        if slot.as_ref().is_some_and(|entry| entry.handle == handle) {
            *slot = None;
        }
    }
    if cancelled {
        emit(callback, run_id, 2, "");
    } else {
        let error = result.err().unwrap_or(SESSION); // A serving test must not finish on its own.
        emit(callback, run_id, 3, error.0);
    }
}

fn session_failure(error: idevice::IdeviceError) -> Failure {
    match error {
        idevice::IdeviceError::UnexpectedResponse(message)
            if message == "DSH_RUNNER_EXIT_UNCONFIRMED" =>
        {
            STOP_UNCONFIRMED
        }
        _ => SESSION,
    }
}

/// Signal only this exact owner. Never block the Swift/main thread on network IO.
#[unsafe(no_mangle)]
pub extern "C" fn dsh_phone_xctest_stop(handle: u64) {
    if let Ok(slot) = owner().lock() {
        if let Some(entry) = slot.as_ref().filter(|entry| entry.handle == handle) {
            entry.cancelled.store(true, Ordering::Release);
            let _ = entry.stop.send(true);
        }
    }
}

struct Tunnel {
    adapter: AdapterHandle,
    handshake: RsdHandshake,
    _pairing: RemotePairingClient<RpPairingSocket<TcpStream>>,
}

async fn tunnel(config: &Config) -> Result<Tunnel, Failure> {
    let metadata = tokio::fs::metadata(&config.pairing_file)
        .await
        .map_err(|_| PAIRING)?;
    if !metadata.is_file() || metadata.len() > 64 * 1024 {
        return Err(PAIRING);
    }
    let mut pairing = RpPairingFile::read_from_file(&config.pairing_file)
        .await
        .map_err(|_| PAIRING)?;
    let address = SocketAddr::new(config.host.parse().map_err(|_| TUNNEL)?, config.port);
    let stream = TcpStream::connect(address).await.map_err(|_| TUNNEL)?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "dsh-go-self-runner");
    // This is a use-existing-pairing path, never a background PIN/pairing prompt.
    rpc.attempt_pair_verify().await.map_err(|_| PAIRING)?;
    rpc.validate_pairing(&mut pairing)
        .await
        .map_err(|_| PAIRING)?;
    let port = rpc.create_tcp_listener().await.map_err(|_| TUNNEL)?;
    let stream = TcpStream::connect(SocketAddr::new(address.ip(), port))
        .await
        .map_err(|_| TUNNEL)?;
    let tunnel = connect_tls_psk_tunnel_native(stream, rpc.encryption_key())
        .await
        .map_err(|_| TUNNEL)?;
    let client = tunnel.info.client_address.parse().map_err(|_| TUNNEL)?;
    let server = tunnel.info.server_address.parse().map_err(|_| TUNNEL)?;
    let rsd_port = tunnel.info.server_rsd_port;
    let mtu = tunnel.info.mtu as usize;
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client, server);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let stream = adapter.connect(rsd_port).await.map_err(|_| TUNNEL)?;
    let handshake = RsdHandshake::new(stream).await.map_err(|_| TUNNEL)?;
    Ok(Tunnel {
        adapter,
        handshake,
        _pairing: rpc,
    })
}

struct ReadyListener<'a> {
    run_id: &'a str,
    callback: Callback,
    seen: bool,
    test_started: bool,
}
fn readiness(title: &str) -> Result<Option<&str>, Failure> {
    let Some(value) = title.strip_prefix(READY_PREFIX) else {
        return Ok(None);
    };
    if value.len() > 1024 {
        return Err(PROTOCOL);
    }
    let bytes = STANDARD.decode(value).map_err(|_| PROTOCOL)?;
    if bytes.len() != 256 || STANDARD.encode(&bytes) != value {
        return Err(PROTOCOL);
    }
    Ok(Some(value))
}
// iOS 26 can report None/None even for activities within the selected test.
// Only the sole configured test may start this listener, on this paired channel;
// Swift additionally decrypts the fresh per-run RSA payload and verifies runId.
fn runner_test(class: &str, method: &str) -> bool {
    (class.ends_with("PhoneRunnerUITests") && ["testServe", "testServe()"].contains(&method))
        || (class.eq_ignore_ascii_case("none") && method.eq_ignore_ascii_case("none"))
}
impl ReadyListener<'_> {
    fn report_startup_log(&self, message: &str) {
        if self.seen { return; }
        if !["CASE_START", "ACTIVITY class=", "PROCESS_STATUS_ERROR", "isRunningPid", "BOOTSTRAP_FAILURE"].iter().any(|prefix| message.starts_with(prefix)) { return; }
        let lower = message.to_ascii_lowercase();
        if ["token", "password", "secret", "authorization", "pairing", "key"].iter().any(|value| lower.contains(value)) { return; }
        let message = message.split_once("] ").map(|(_, value)| value).unwrap_or(message);
        let text: String = message.chars().take(80).map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' }).collect();
        emit(self.callback, self.run_id, 0, &format!("XCTLOG_{text}"));
    }
}
impl XCUITestListener for ReadyListener<'_> {
    async fn did_fail_to_bootstrap(&mut self, message: &str) -> Result<(), idevice::IdeviceError> {
        self.report_startup_log(&format!("BOOTSTRAP_FAILURE {message}")); Ok(())
    }
    async fn log_message(&mut self, message: &str) -> Result<(), idevice::IdeviceError> {
        self.report_startup_log(message); Ok(())
    }
    async fn log_debug_message(&mut self, message: &str) -> Result<(), idevice::IdeviceError> {
        self.report_startup_log(message); Ok(())
    }
    async fn test_bundle_ready(&mut self) -> Result<(), idevice::IdeviceError> {
        emit(self.callback, self.run_id, 0, "BUNDLE_READY"); Ok(())
    }
    async fn test_runner_ready_with_capabilities(&mut self) -> Result<(), idevice::IdeviceError> {
        emit(self.callback, self.run_id, 0, "RUNNER_CAPABILITIES"); Ok(())
    }
    async fn did_begin_executing_test_plan(&mut self) -> Result<(), idevice::IdeviceError> {
        emit(self.callback, self.run_id, 0, "TEST_PLAN_BEGAN"); Ok(())
    }
    async fn test_case_did_start(&mut self, class: &str, method: &str) -> Result<(), idevice::IdeviceError> {
        self.report_startup_log(&format!("CASE_START class={class} method={method}"));
        self.test_started = runner_test(class, method);
        emit(self.callback, self.run_id, 0, "TEST_CASE_BEGAN"); Ok(())
    }

    fn bootstrap_stage(&mut self, stage: &'static str) {
        emit(self.callback, self.run_id, 0, stage);
    }

    async fn test_case_will_start_activity(
        &mut self,
        class: &str,
        method: &str,
        title: &str,
    ) -> Result<(), idevice::IdeviceError> {
        self.report_startup_log(&format!("ACTIVITY class={class} method={method} ready={} length={}", title.starts_with(READY_PREFIX), title.len()));
        if !self.test_started || !runner_test(class, method) {
            return Ok(());
        }
        match readiness(title) {
            Ok(Some(value)) if !self.seen => {
                self.seen = true;
                emit(self.callback, self.run_id, 1, value);
            }
            Err(_) => {
                return Err(idevice::IdeviceError::UnexpectedResponse(
                    "Invalid encrypted runner endpoint".into(),
                ));
            }
            _ => {}
        }
        Ok(())
    }
}

async fn cancelled(receiver: &mut watch::Receiver<bool>) {
    if !*receiver.borrow() {
        let _ = receiver.changed().await;
    }
}

async fn run_session(
    config: &Config,
    callback: Callback,
    mut receiver: watch::Receiver<bool>,
) -> Result<(), Failure> {
    let mut tunnel = tokio::select! {
        biased;
        _ = cancelled(&mut receiver) => return Ok(()),
        result = tokio::time::timeout(Duration::from_secs(90), tunnel(config)) => result.map_err(|_| TUNNEL)??,
    };
    if !tunnel.handshake.services.contains_key(TEST_SERVICE)
        || !tunnel.handshake.services.contains_key(DVT_SERVICE)
    {
        return Err(DDI);
    }
    let prepared = async {
        let mut lockdown = LockdownClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake)
            .await
            .map_err(|_| TUNNEL)?;
        let version = lockdown
            .get_value(Some("ProductVersion"), None)
            .await
            .map_err(|_| TUNNEL)?;
        let major: u8 = version
            .as_string()
            .and_then(|v| v.split('.').next())
            .and_then(|v| v.parse().ok())
            .filter(|v| *v >= 17)
            .ok_or(DDI)?;
        let mut proxy =
            InstallationProxyClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake)
                .await
                .map_err(|_| CONFIGURATION)?;
        let mut cfg = TestConfig::from_installation_proxy(
            &mut proxy,
            &config.runner_bundle_id,
            Some(&config.target_bundle_id),
        )
        .await
        .map_err(|_| CONFIGURATION)?;
        let mut environment = plist::Dictionary::new();
        environment.insert("DSH_PHONE_RUN_ID".into(), config.run_id.clone().into());
        environment.insert(
            "DSH_PHONE_PUBLIC_KEY".into(),
            config.public_key_base64.clone().into(),
        );
        cfg.runner_env = Some(environment);
        cfg.tests_to_run = Some(vec!["PhoneRunnerUITests/testServe".into()]);
        // RPPairing/RSD owns this connection's lifetime. The legacy lockdown
        // Marco/Polo heartbeat is not part of this transport; requiring it can
        // abort a healthy authenticated session before XCTest starts.
        Ok::<_, Failure>((cfg, major))
    };
    let (cfg, major) = tokio::select! {
        biased;
        _ = cancelled(&mut receiver) => return Ok(()),
        result = tokio::time::timeout(Duration::from_secs(60), prepared) => result.map_err(|_| SESSION)??,
    };
    let mut listener = ReadyListener {
        run_id: &config.run_id,
        callback,
        seen: false,
        test_started: false,
    };
    run_rsd(
        tunnel.adapter,
        tunnel.handshake,
        cfg,
        major,
        &mut listener,
        receiver,
    ).await.map_err(session_failure)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::pkcs1::EncodeRsaPublicKey;
    use std::sync::{Condvar, Mutex};

    static TEST_LOCK: Mutex<()> = Mutex::new(());
    static EVENTS: (Mutex<Vec<(String, i32, String)>>, Condvar) =
        (Mutex::new(Vec::new()), Condvar::new());
    extern "C" fn record(run_id: *const c_char, kind: i32, payload: *const c_char) {
        let event = unsafe {
            (
                CStr::from_ptr(run_id).to_string_lossy().into_owned(),
                kind,
                CStr::from_ptr(payload).to_string_lossy().into_owned(),
            )
        };
        EVENTS.0.lock().unwrap().push(event);
        EVENTS.1.notify_all();
    }
    fn config() -> serde_json::Value {
        let key = RsaPublicKey::new(
            rsa::BigUint::from(1u8) << 2047 | rsa::BigUint::from(0x12345u32),
            rsa::BigUint::from(65537u32),
        )
        .unwrap();
        serde_json::json!({"runId":"12345678-1234-4234-8234-123456789abc","pairingFile":"/nonexistent/dsh-remote-pairing.plist","host":"10.7.0.1","port":49152,"runnerBundleId":"example.dsh.PhoneRunner.xctrunner","targetBundleId":"example.dsh","publicKeyBase64":STANDARD.encode(key.to_pkcs1_der().unwrap().as_bytes())})
    }
    #[tokio::test(start_paused = true)]
    async fn prelaunch_pending_work_is_cancelled_without_waiting_for_deadline() {
        use idevice::services::dvt::xctest::run_rsd_prelaunch;
        let (sender, mut receiver) = watch::channel(false);
        let before = tokio::time::Instant::now();
        tokio::spawn(async move {
            sender.send(true).unwrap();
        });
        let pending = std::future::pending::<Result<u8, idevice::IdeviceError>>();
        assert_eq!(
            run_rsd_prelaunch(&mut receiver, Duration::from_secs(90), pending)
                .await
                .unwrap(),
            None
        );
        assert_eq!(tokio::time::Instant::now() - before, Duration::ZERO);
    }
    #[tokio::test(start_paused = true)]
    async fn prelaunch_initialization_has_a_real_deadline() {
        use idevice::services::dvt::xctest::run_rsd_prelaunch;
        let (_sender, mut receiver) = watch::channel(false);
        let before = tokio::time::Instant::now();
        let pending = std::future::pending::<Result<u8, idevice::IdeviceError>>();
        let result = run_rsd_prelaunch(&mut receiver, Duration::from_secs(90), pending).await;
        assert!(matches!(
            result,
            Err(idevice::IdeviceError::TestRunnerTimeout)
        ));
        assert_eq!(
            tokio::time::Instant::now() - before,
            Duration::from_secs(90)
        );
    }
    #[tokio::test(start_paused = true)]
    async fn submitted_launch_waits_for_pid_or_reports_unknown_on_timeout() {
        use idevice::services::dvt::xctest::run_rsd_launch;
        let (sender, receiver) = watch::channel(false);
        tokio::spawn(async move {
            sender.send(true).unwrap();
        });
        let before = tokio::time::Instant::now();
        let pid = run_rsd_launch(Duration::from_secs(30), async {
            tokio::time::sleep(Duration::from_secs(10)).await;
            Ok(42u64)
        })
        .await
        .unwrap();
        assert_eq!(pid, 42);
        assert!(*receiver.borrow());
        assert_eq!(
            tokio::time::Instant::now() - before,
            Duration::from_secs(10)
        );
        let pending = std::future::pending::<Result<u64, idevice::IdeviceError>>();
        let error = run_rsd_launch(Duration::from_secs(30), pending)
            .await
            .unwrap_err();
        assert_eq!(session_failure(error).0, STOP_UNCONFIRMED.0);
        assert_eq!(
            tokio::time::Instant::now() - before,
            Duration::from_secs(40)
        );
        let error = run_rsd_launch(Duration::from_secs(30), async {
            Err::<u64, _>(idevice::IdeviceError::ServiceNotFound)
        })
        .await
        .unwrap_err();
        assert_eq!(session_failure(error).0, STOP_UNCONFIRMED.0);
        for invalid_pid in [0u64, u32::MAX as u64 + 1] {
            let error = run_rsd_launch(Duration::from_secs(30), async { Ok(invalid_pid) })
                .await
                .unwrap_err();
            assert_eq!(session_failure(error).0, STOP_UNCONFIRMED.0);
        }
    }
    #[test]
    fn config_validation_never_accepts_arbitrary_env_or_bad_keys() {
        assert!(Config::parse(&serde_json::to_vec(&config()).unwrap()).is_some());
        for (field, value) in [
            ("port", serde_json::json!(0)),
            ("host", serde_json::json!("example.com")),
            ("pairingFile", serde_json::json!("relative.plist")),
            ("runId", serde_json::json!("bad")),
            ("publicKeyBase64", serde_json::json!("token")),
            ("runnerBundleId", serde_json::json!("../runner")),
            ("token", serde_json::json!("must-not-be-in-config")),
        ] {
            let mut input = config();
            input[field] = value;
            assert!(
                Config::parse(&serde_json::to_vec(&input).unwrap()).is_none(),
                "{field}"
            );
        }
    }
    #[test]
    fn encrypted_readiness_is_bounded_and_never_plaintext() {
        assert!(readiness("unrelated activity").unwrap().is_none());
        assert!(readiness("DSH_PHONE_READY_V1:{\"token\":\"secret\"}").is_err());
        let ciphertext = STANDARD.encode([42u8; 256]);
        let title = format!("{READY_PREFIX}{ciphertext}");
        assert_eq!(readiness(&title).unwrap(), Some(ciphertext.as_str()));
        assert!(readiness(&format!("{READY_PREFIX}{}", STANDARD.encode([1u8; 255]))).is_err());
    }
    #[tokio::test]
    async fn readiness_requires_selected_test_start_and_ignores_duplicates() {
        let _guard = TEST_LOCK.lock().unwrap();
        EVENTS.0.lock().unwrap().clear();
        let mut listener = ReadyListener {
            run_id: "12345678-1234-4234-8234-123456789abc",
            callback: record,
            seen: false,
            test_started: false,
        };
        let title = format!("{READY_PREFIX}{}", STANDARD.encode([42u8; 256]));
        listener.test_case_will_start_activity("None", "None", &title).await.unwrap();
        assert!(!listener.seen);
        listener.test_case_did_start("ForeignTests", "testOther").await.unwrap();
        listener.test_case_will_start_activity("None", "None", &title).await.unwrap();
        assert!(!listener.seen);
        listener.test_case_did_start("PhoneRunnerUITests", "testServe").await.unwrap();
        listener.test_case_will_start_activity("ForeignTests", "testOther", &title).await.unwrap();
        assert!(!listener.seen);
        listener.test_case_will_start_activity("None", "None", &title).await.unwrap();
        assert!(listener.seen);
        listener.test_case_will_start_activity("PhoneRunnerUITests", "testServe", &title).await.unwrap();
        assert_eq!(EVENTS.0.lock().unwrap().iter().filter(|event| event.1 == 1).count(), 1);
        assert!(runner_test("none", "none"));
        assert!(!runner_test("None", "testOther"));
        assert!(!runner_test("PhoneRunnerUITests", "None"));
    }
    #[test]
    fn null_and_malformed_ffi_inputs_are_rejected_synchronously() {
        assert_eq!(
            unsafe { dsh_phone_xctest_start(std::ptr::null(), Some(record)) },
            0
        );
        let invalid = CString::new("{}").unwrap();
        assert_eq!(
            unsafe { dsh_phone_xctest_start(invalid.as_ptr(), Some(record)) },
            0
        );
        assert_eq!(unsafe { dsh_phone_xctest_start(invalid.as_ptr(), None) }, 0);
    }
    #[test]
    fn owner_slot_rejects_overlap_and_stale_stop() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (sender, receiver) = watch::channel(false);
        let cancelled = Arc::new(AtomicBool::new(false));
        *owner().lock().unwrap() = Some(Owner {
            handle: 123,
            stop: sender,
            cancelled: cancelled.clone(),
        });
        let input = CString::new(config().to_string()).unwrap();
        assert_eq!(
            unsafe { dsh_phone_xctest_start(input.as_ptr(), Some(record)) },
            0
        );
        dsh_phone_xctest_stop(122);
        assert!(!*receiver.borrow() && !cancelled.load(Ordering::Acquire));
        dsh_phone_xctest_stop(123);
        dsh_phone_xctest_stop(123);
        assert!(*receiver.borrow() && cancelled.load(Ordering::Acquire));
        *owner().lock().unwrap() = None;
    }
    #[test]
    fn unconfirmed_exit_poison_is_not_a_normal_terminal_state() {
        let _guard = TEST_LOCK.lock().unwrap();
        EVENTS.0.lock().unwrap().clear();
        let (stop, _) = watch::channel(false);
        *owner().lock().unwrap() = Some(Owner {
            handle: 456,
            stop,
            cancelled: Arc::new(AtomicBool::new(true)),
        });
        finish_owner(
            456,
            "12345678-1234-4234-8234-123456789abc",
            record,
            true,
            Err(STOP_UNCONFIRMED),
        );
        let events = EVENTS.0.lock().unwrap();
        assert_eq!(events.iter().map(|v| v.1).collect::<Vec<_>>(), vec![4]);
        assert_eq!(events[0].2, "ERR_PHONE_STOP_UNCONFIRMED");
        drop(events);
        let input = CString::new(config().to_string()).unwrap();
        assert_eq!(
            unsafe { dsh_phone_xctest_start(input.as_ptr(), Some(record)) },
            0
        );
        dsh_phone_xctest_stop(456);
        assert!(owner().lock().unwrap().is_some());
        *owner().lock().unwrap() = None;
    }
    #[test]
    fn real_ffi_stop_can_cancel_during_startup_without_launching() {
        extern "C" fn stop_at_start(run_id: *const c_char, kind: i32, payload: *const c_char) {
            if kind == 0 {
                let handle = owner().lock().unwrap().as_ref().unwrap().handle;
                dsh_phone_xctest_stop(handle);
            }
            record(run_id, kind, payload);
        }
        let _guard = TEST_LOCK.lock().unwrap();
        EVENTS.0.lock().unwrap().clear();
        let input = CString::new(config().to_string()).unwrap();
        assert_ne!(
            unsafe { dsh_phone_xctest_start(input.as_ptr(), Some(stop_at_start)) },
            0
        );
        let events = EVENTS.0.lock().unwrap();
        let (events, timeout) = EVENTS
            .1
            .wait_timeout_while(events, Duration::from_secs(5), |events| {
                !events.iter().any(|v| v.1 == 2)
            })
            .unwrap();
        assert!(!timeout.timed_out());
        assert_eq!(events.iter().map(|v| v.1).collect::<Vec<_>>(), vec![0, 2]);
        assert!(owner().lock().unwrap().is_none());
    }
    #[test]
    fn real_ffi_failure_releases_owner_before_terminal_callback() {
        let _guard = TEST_LOCK.lock().unwrap();
        EVENTS.0.lock().unwrap().clear();
        let input = CString::new(config().to_string()).unwrap();
        let handle = unsafe { dsh_phone_xctest_start(input.as_ptr(), Some(record)) };
        assert_ne!(handle, 0);
        let events = EVENTS.0.lock().unwrap();
        let (events, timeout) = EVENTS
            .1
            .wait_timeout_while(events, Duration::from_secs(5), |events| {
                !events.iter().any(|v| v.1 == 3)
            })
            .unwrap();
        assert!(!timeout.timed_out());
        assert_eq!(events.iter().map(|v| v.1).collect::<Vec<_>>(), vec![0, 3]);
        assert!(events[1].2.starts_with("ERR_PHONE_PAIRING_REQUIRED"));
        assert!(owner().lock().unwrap().is_none());
        dsh_phone_xctest_stop(handle); // A terminal/stale handle is a no-op.
    }
}
