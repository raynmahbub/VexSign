// SPDX-License-Identifier: MIT
// VexSign's bounded, consent-separated integration with jkcoxson/idevice.
// Built into that pinned crate, never into a second copy of its Rust handle ABI.
use std::ffi::{CStr, c_char, c_void};
use std::net::{IpAddr, SocketAddr};
use std::os::fd::FromRawFd;
use std::ptr::null_mut;
use std::sync::Arc;
use std::time::Duration;

use idevice::IdeviceError;
use idevice::remote_pairing::{PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket};
use tokio::sync::Semaphore;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::{IdeviceFfiError, ffi_err, run_sync_local};

const MAX_RECORD: usize = 2 * 1024 * 1024;
const MAX_ADVERTISEMENT: usize = 16 * 1024;

/// This ABI is distinct from unpatched upstream convenience functions. Swift
/// checks it before advertising or parsing remote credentials with native code.
#[unsafe(no_mangle)]
pub extern "C" fn vexsign_device_bridge_abi() -> u32 { 1 }

pub struct VexsignDeviceCancel(Arc<Semaphore>);

#[unsafe(no_mangle)]
pub extern "C" fn vexsign_device_cancel_new() -> *mut VexsignDeviceCancel {
    Box::into_raw(Box::new(VexsignDeviceCancel(Arc::new(Semaphore::new(0)))))
}

/// # Safety
/// `cancel` is live until the owning worker retires. The caller synchronizes
/// signal/free; no pointer may be signalled concurrently with destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vexsign_device_cancel_signal(cancel: *const VexsignDeviceCancel) {
    if !cancel.is_null() { unsafe { &*cancel }.0.close(); }
}

/// # Safety
/// The worker has returned and no signal can race this call. Null is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vexsign_device_cancel_free(cancel: *mut VexsignDeviceCancel) {
    if !cancel.is_null() { drop(unsafe { Box::from_raw(cancel) }); }
}

fn copy_cancel(cancel: *const VexsignDeviceCancel) -> Result<Arc<Semaphore>, IdeviceError> {
    if cancel.is_null() { return Err(IdeviceError::FfiInvalidArg); }
    Ok(unsafe { &*cancel }.0.clone())
}

async fn bounded<T>(cancel: Arc<Semaphore>, milliseconds: u32,
                    work: impl std::future::Future<Output = Result<T, IdeviceError>>) -> Result<T, IdeviceError> {
    if !(1..=180_000).contains(&milliseconds) { return Err(IdeviceError::FfiInvalidArg); }
    // Biased cancellation also refuses a token signalled before entry. Dropping
    // these owned futures closes streams; the Swift worker still owns its handles.
    tokio::select! {
        biased;
        _ = cancel.acquire() => Err(IdeviceError::CanceledByUser),
        result = tokio::time::timeout(Duration::from_millis(milliseconds.into()), work) => {
            result.map_err(|_| IdeviceError::InternalError("VexSign device deadline".into()))?
        }
    }
}

fn parse_record(bytes: &[u8]) -> Result<RpPairingFile, IdeviceError> {
    if bytes.is_empty() || bytes.len() > MAX_RECORD { return Err(IdeviceError::FfiInvalidArg); }
    let record = RpPairingFile::from_bytes(bytes)?;
    if record.e_private_key.verifying_key() != record.e_public_key
        || uuid::Uuid::parse_str(&record.identifier).is_err()
        || record.alt_irk.as_ref().is_some_and(|key| key.len() != 16) {
        return Err(IdeviceError::FfiInvalidArg);
    }
    Ok(record)
}

fn output_bytes(bytes: Vec<u8>, data: *mut *mut u8, length: *mut usize) {
    // Boxed slices have exactly the layout used by the matching destructor.
    // Never forget a Vec whose capacity may exceed the exported length.
    let bytes = bytes.into_boxed_slice();
    unsafe { *length = bytes.len(); *data = Box::into_raw(bytes) as *mut u8; }
}

/// # Safety
/// `data/length` are exactly one result of a vexsign_* buffer function. Null is
/// accepted. Never pass buffers from libplist or another allocator here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vexsign_device_bytes_free(data: *mut u8, length: usize) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, length)) });
    }
}

/// Open a remote tunnel using an EXISTING pairing only. In particular this must
/// never call RemotePairingClient.connect(), pair(), or a default PIN callback.
/// The selected VPN peer is also used for the dynamically returned listener port;
/// never substitute localhost, the RSD tunnel's virtual IP, or the host interface.
///
/// # Safety
/// Input pointers are valid for this blocking call. `cancel` is live. Output
/// pointers are valid and are cleared before work; ownership transfers only on
/// success. Returned handles use the ordinary adapter/RSD destructors.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vexsign_tunnel_rppairing_verified(
    data: *const u8, length: usize, peer: *const c_char, port: u16,
    cancel: *const VexsignDeviceCancel, milliseconds: u32,
    out_adapter: *mut *mut AdapterHandle, out_handshake: *mut *mut RsdHandshakeHandle,
) -> *mut IdeviceFfiError {
    if out_adapter.is_null() || out_handshake.is_null() { return ffi_err!(IdeviceError::FfiInvalidArg); }
    unsafe { *out_adapter = null_mut(); *out_handshake = null_mut(); }
    if data.is_null() || peer.is_null() || port == 0 || length == 0 || length > MAX_RECORD {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let cancel = match copy_cancel(cancel) { Ok(value) => value, Err(e) => return ffi_err!(e) };
    let host = match unsafe { CStr::from_ptr(peer) }.to_str().ok().and_then(|v| v.parse::<IpAddr>().ok()) {
        Some(IpAddr::V4(ip)) if ip.is_private() || ip.is_link_local() => IpAddr::V4(ip),
        _ => return ffi_err!(IdeviceError::FfiInvalidArg),
    };
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let mut record = match parse_record(bytes) { Ok(record) => record, Err(e) => return ffi_err!(e) };
    let address = SocketAddr::new(host, port);
    let result = run_sync_local(bounded(cancel, milliseconds, async {
        let stream = tokio::net::TcpStream::connect(address).await.map_err(IdeviceError::Socket)?;
        let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "VexSign");
        client.attempt_pair_verify().await?;
        client.validate_pairing(&mut record).await?;
        crate::tunnel_provider::finish_tunnel(&mut client, address).await
    }));
    match result {
        Ok((adapter, handshake)) => {
            unsafe {
                *out_adapter = Box::into_raw(Box::new(AdapterHandle(adapter)));
                *out_handshake = Box::into_raw(Box::new(RsdHandshakeHandle(handshake)));
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// One ephemeral enrollment, not an unattended server or a persistent trust grant.
pub struct VexsignPairableHost { record: RpPairingFile, info: PairableHostInfo }

/// Prepare keys/TXT locally. Swift owns publication using system Bonjour and owns
/// its listening socket; creating this handle does not advertise or connect.
/// Pinless pairing is not an option in this ABI.
///
/// # Safety
/// All pointers are valid. Outputs are cleared before work. Returned TXT plist
/// uses vexsign_device_bytes_free; the handle uses vexsign_pairable_host_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vexsign_pairable_host_prepare(
    name: *const c_char, out_host: *mut *mut VexsignPairableHost,
    out_txt: *mut *mut u8, out_length: *mut usize,
) -> *mut IdeviceFfiError {
    if out_host.is_null() || out_txt.is_null() || out_length.is_null() { return ffi_err!(IdeviceError::FfiInvalidArg); }
    unsafe { *out_host = null_mut(); *out_txt = null_mut(); *out_length = 0; }
    if name.is_null() { return ffi_err!(IdeviceError::FfiInvalidArg); }
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(value) if !value.is_empty() && value.len() <= 64 && !value.chars().any(char::is_control) => value,
        _ => return ffi_err!(IdeviceError::FfiInvalidString),
    };
    let mut record = RpPairingFile::generate(name);
    // Upstream generate() derives identifier from the hostname. Enrollment must
    // not reuse an identifier with unrelated freshly generated signing keys.
    record.identifier = uuid::Uuid::new_v4().to_string();
    let mut info = PairableHostInfo::generate(name, "Mac17,7");
    info.allows_pinless_pairing = false;
    let dictionary = info.mdns_txt_records(&record.identifier).into_iter()
        .map(|(k, v)| (k, plist::Value::String(v))).collect::<plist::Dictionary>();
    let mut txt = Vec::new();
    if plist::to_writer_xml(&mut txt, &dictionary).is_err() || txt.len() > MAX_ADVERTISEMENT {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    unsafe { *out_host = Box::into_raw(Box::new(VexsignPairableHost { record, info })); }
    output_bytes(txt, out_txt, out_length);
    null_mut()
}

fn enrolled_record(record: &RpPairingFile, info: &PairableHostInfo,
                   peer: &idevice::remote_pairing::PeerDevice) -> Result<Vec<u8>, IdeviceError> {
    let mut dictionary: plist::Dictionary = plist::from_bytes(&record.to_bytes())?;
    dictionary.insert("host_alt_irk".into(), plist::Value::Data(info.alt_irk.to_vec()));
    dictionary.insert("remotepairing_udid".into(), plist::Value::String(peer.remotepairing_udid.clone()));
    // Device identifier is not the host UUID. Preserve both explicitly.
    let mut bytes = Vec::new();
    plist::to_writer_xml(&mut bytes, &dictionary)?;
    if bytes.len() > MAX_RECORD { return Err(IdeviceError::FfiInvalidArg); }
    Ok(bytes)
}

/// Pair exactly one caller-accepted TCP connection with a displayed random PIN.
/// The fd is duplicated; Swift retains its original until this call returns.
/// Cancel/timeout drop native sockets before returning. Successful bytes include
/// this host's altIRK for protected, atomic persistence beside its signing keys.
/// No native filesystem write or automatic record replacement occurs.
///
/// # Safety
/// `host` is exclusively borrowed; `fd` is a live connected TCP socket. The PIN
/// callback/context remain valid until return. Outputs use the matching bytes
/// destructor. All required pointers, callback, and cancel must be non-null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vexsign_pairable_host_accept_fd(
    host: *mut VexsignPairableHost, fd: i32,
    pin_callback: Option<extern "C" fn(*const c_char, *mut c_void)>, context: *mut c_void,
    cancel: *const VexsignDeviceCancel, milliseconds: u32,
    out_record: *mut *mut u8, out_length: *mut usize,
) -> *mut IdeviceFfiError {
    if out_record.is_null() || out_length.is_null() { return ffi_err!(IdeviceError::FfiInvalidArg); }
    unsafe { *out_record = null_mut(); *out_length = 0; }
    if host.is_null() || fd < 0 || pin_callback.is_none() { return ffi_err!(IdeviceError::FfiInvalidArg); }
    let cancel = match copy_cancel(cancel) { Ok(value) => value, Err(e) => return ffi_err!(e) };
    let host = unsafe { &*host };
    let mut record = host.record.clone();
    let info = host.info.clone();
    let result = run_sync_local(bounded(cancel, milliseconds, async {
        let duplicate = unsafe { libc::dup(fd) };
        if duplicate < 0 { return Err(IdeviceError::Socket(std::io::Error::last_os_error())); }
        let socket = unsafe { std::net::TcpStream::from_raw_fd(duplicate) };
        socket.set_nonblocking(true).map_err(IdeviceError::Socket)?;
        let socket = tokio::net::TcpStream::from_std(socket).map_err(IdeviceError::Socket)?;
        let mut responder = PairableHost::new(RpPairingSocket::new_device(socket), info.clone());
        let peer = responder.accept(&mut record, |pin| async move {
            if pin.len() == 6 && pin.bytes().all(|byte| byte.is_ascii_digit()) {
                if let Ok(pin) = std::ffi::CString::new(pin) {
                    // A valid callback is mandatory; the PIN is never logged or persisted.
                    pin_callback.unwrap()(pin.as_ptr(), context);
                }
            }
        }).await?;
        enrolled_record(&record, &info, &peer)
    }));
    match result {
        Ok(bytes) => { output_bytes(bytes, out_record, out_length); null_mut() }
        Err(e) => ffi_err!(e),
    }
}

/// # Safety
/// No FFI call still borrows the host. Null is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vexsign_pairable_host_free(host: *mut VexsignPairableHost) {
    if !host.is_null() { drop(unsafe { Box::from_raw(host) }); }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn host_prepare_has_fresh_identifiers_and_only_bounded_public_txt() {
        let name = CString::new("VexSign enrollment").unwrap();
        let mut identifiers = std::collections::HashSet::new();
        for _ in 0..128 {
            let (mut host, mut data, mut len) = (null_mut(), null_mut(), 0);
            let error = unsafe { vexsign_pairable_host_prepare(name.as_ptr(), &mut host, &mut data, &mut len) };
            assert!(error.is_null());
            assert!(len > 0 && len < MAX_ADVERTISEMENT);
            let txt: plist::Dictionary = plist::from_bytes(unsafe { std::slice::from_raw_parts(data, len) }).unwrap();
            assert!(!txt.contains_key("private_key"));
            assert!(identifiers.insert(txt["identifier"].as_string().unwrap().to_owned()));
            assert!(!unsafe { &*host }.info.allows_pinless_pairing);
            assert_ne!(unsafe { &*host }.info.alt_irk, [0; 16]);
            unsafe { vexsign_device_bytes_free(data, len); vexsign_pairable_host_free(host); }
        }
    }

    #[test]
    fn host_prepare_clears_outputs_on_invalid_name() {
        let (mut host, mut data, mut len) = (null_mut(), null_mut(), 99);
        let name = CString::new("bad\nname").unwrap();
        let error = unsafe { vexsign_pairable_host_prepare(name.as_ptr(), &mut host, &mut data, &mut len) };
        assert!(!error.is_null());
        assert!(host.is_null() && data.is_null());
        assert_eq!(len, 0);
        unsafe { crate::idevice_error_free(error); }
    }

    #[test]
    fn parse_refuses_plain_empty_oversized_and_substituted_keys() {
        assert!(parse_record(&[]).is_err());
        assert!(parse_record(&vec![0; MAX_RECORD + 1]).is_err());
        assert!(parse_record(b"<plist><dict/></plist>").is_err());
        let mut record = RpPairingFile::generate("fixture");
        assert!(parse_record(&record.to_bytes()).is_ok());
        record.e_public_key = RpPairingFile::generate("other").e_public_key;
        assert!(parse_record(&record.to_bytes()).is_err());
    }

    #[test]
    fn cancelled_before_entry_does_not_poll_the_work_future() {
        let cancellation = Arc::new(Semaphore::new(0));
        cancellation.close();
        let result: Result<(), IdeviceError> = run_sync_local(bounded(cancellation, 100, async {
            panic!("pre-cancelled work must not run")
        }));
        assert!(matches!(result, Err(IdeviceError::CanceledByUser)));
    }

    #[test]
    fn deadline_bounds_pending_handshake_future() {
        let result = run_sync_local(bounded(Arc::new(Semaphore::new(0)), 10,
            std::future::pending::<Result<(), IdeviceError>>()));
        assert!(result.is_err());
    }

    #[test]
    fn null_optional_destructors_are_safe() {
        unsafe {
            vexsign_device_bytes_free(null_mut(), 0);
            vexsign_pairable_host_free(null_mut());
            vexsign_device_cancel_free(null_mut());
            vexsign_device_cancel_signal(null_mut());
        }
    }
}
