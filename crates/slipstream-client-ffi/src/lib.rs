use libc::{c_char, c_int, c_ushort};
use std::ffi::CStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

use slipstream_core::{parse_host_port, AddressKind};
use slipstream_ffi::{ClientConfig, ResolverMode, ResolverSpec};
use tokio::sync::oneshot;

/// One client = one OS thread + one Tokio current-thread runtime. No global state.
///
/// Stop contract: call `slipstream_client_stop` exactly once per successful start.
/// The pointer is invalid the moment `stop()` returns.
///
/// `alive` is an `Arc<AtomicBool>` shared with the worker thread. It stays valid
/// until ALL references are dropped (both the struct and the thread release it).
/// It is set to false when the thread exits for ANY reason: stop(), natural
/// completion, error, or panic.
pub struct SlipstreamClient {
    alive: Arc<AtomicBool>,
    shutdown: Option<oneshot::Sender<()>>,
    thread: Option<thread::JoinHandle<()>>,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct SlipstreamResolver {
    pub host: *const c_char,
    pub port: c_ushort,
    pub mode: c_int, // 1 = Recursive, 2 = Authoritative
}

#[repr(C)]
pub struct SlipstreamClientConfig {
    pub tcp_listen_host: *const c_char,
    pub tcp_listen_port: c_ushort,
    pub resolvers: *const SlipstreamResolver,
    pub resolver_count: usize,
    pub domain: *const c_char,
    pub congestion_control: *const c_char,
    pub gso: bool,
    pub cert_path: *const c_char,
    pub keep_alive_interval: c_ushort,
    pub debug_poll: bool,
    pub debug_streams: bool,
}

unsafe fn opt_string(p: *const c_char) -> Option<String> {
    if p.is_null() {
        None
    } else {
        Some(CStr::from_ptr(p).to_string_lossy().into_owned())
    }
}

/// Starts a client. Returns an opaque handle, or null on failure.
/// All C strings are copied; the caller's memory may be freed after this returns.
///
/// # Safety
///
/// `config` must be a valid pointer to a `SlipstreamClientConfig` struct.
/// All string fields within must be valid null-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn slipstream_client_start(
    config: *const SlipstreamClientConfig,
) -> *mut SlipstreamClient {
    if config.is_null() {
        return std::ptr::null_mut();
    }
    let cfg = unsafe { &*config };
    if cfg.tcp_listen_host.is_null()
        || cfg.domain.is_null()
        || cfg.resolvers.is_null()
        || cfg.resolver_count == 0
    {
        return std::ptr::null_mut();
    }

    let tcp_listen_host = unsafe { opt_string(cfg.tcp_listen_host) }.unwrap_or_default();
    let domain = unsafe { opt_string(cfg.domain) }.unwrap_or_default();
    let congestion_control = unsafe { opt_string(cfg.congestion_control) };
    let cert_path = unsafe { opt_string(cfg.cert_path) };

    let mut resolvers = Vec::with_capacity(cfg.resolver_count);
    for i in 0..cfg.resolver_count {
        let r = unsafe { *cfg.resolvers.add(i) };
        let Some(host) = (unsafe { opt_string(r.host) }) else {
            return std::ptr::null_mut();
        };
        let mode = if r.mode == 2 {
            ResolverMode::Authoritative
        } else {
            ResolverMode::Recursive
        };
        match parse_host_port(&host, r.port, AddressKind::Resolver) {
            Ok(hp) => resolvers.push(ResolverSpec { resolver: hp, mode }),
            Err(e) => {
                eprintln!("resolver parse error: {}", e);
                return std::ptr::null_mut();
            }
        }
    }

    let port = cfg.tcp_listen_port;
    let gso = cfg.gso;
    let keep_alive = cfg.keep_alive_interval as usize;
    let debug_poll = cfg.debug_poll;
    let debug_streams = cfg.debug_streams;

    let alive = Arc::new(AtomicBool::new(true));
    let alive_thread = alive.clone();
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();

    let thread = thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => {
                let _ = ready_tx.send(Ok(()));
                rt
            }
            Err(e) => {
                let _ = ready_tx.send(Err(e.to_string()));
                alive_thread.store(false, Ordering::Release);
                return;
            }
        };

        // Guard: sets alive=false when the thread exits for ANY reason,
        // including natural completion, error, or panic.
        struct AliveGuard(Arc<AtomicBool>);
        impl Drop for AliveGuard {
            fn drop(&mut self) {
                self.0.store(false, Ordering::Release);
            }
        }
        let _guard = AliveGuard(alive_thread);

        rt.block_on(async {
            let config = ClientConfig {
                tcp_listen_host: &tcp_listen_host,
                tcp_listen_port: port,
                resolvers: &resolvers,
                domain: &domain,
                congestion_control: congestion_control.as_deref(),
                gso,
                cert: cert_path.as_deref(),
                keep_alive_interval: keep_alive,
                debug_poll,
                debug_streams,
            };
            tokio::select! {
                res = slipstream_client::run_client(&config) => {
                    if let Err(e) = res {
                        eprintln!("slipstream client stopped with error: {:?}", e);
                    }
                }
                _ = shutdown_rx => {} // stop() called: run_client future is dropped, RAII cleans up
            }
        });
        // rt drops here. Waits for all spawned tasks (TCP reader/writer)
        // to complete — they detect closed channels and exit.
        drop(rt);
        // alive was already cleared by _guard when run_client returned.
    });

    match ready_rx.recv() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            eprintln!("tokio runtime error: {}", e);
            let _ = thread.join();
            return std::ptr::null_mut();
        }
        Err(_) => {
            let _ = thread.join();
            return std::ptr::null_mut();
        }
    }

    Box::into_raw(Box::new(SlipstreamClient {
        alive,
        shutdown: Some(shutdown_tx),
        thread: Some(thread),
    }))
}

/// Stops and frees one client. Call exactly once; the pointer is invalid afterwards.
/// Returns 0.
///
/// # Safety
///
/// `client` must be a valid pointer returned by `slipstream_client_start`,
/// and must not have been passed to `slipstream_client_stop` before.
#[no_mangle]
pub unsafe extern "C" fn slipstream_client_stop(client: *mut SlipstreamClient) -> c_int {
    if client.is_null() {
        return 0;
    }
    let mut client = unsafe { Box::from_raw(client) };
    if let Some(tx) = client.shutdown.take() {
        let _ = tx.send(()); // Err means the client already finished on its own
    }
    if let Some(t) = client.thread.take() {
        let _ = t.join();
    }
    0
}

/// Returns the library version string. The caller must NOT free the returned pointer.
#[no_mangle]
pub extern "C" fn slipstream_version() -> *const c_char {
    static VERSION: &[u8] = b"0.1.2\0";
    VERSION.as_ptr() as *const c_char
}

/// True while the client is still running. Becomes false if the client exits on its own
/// (error, panic, etc.), not only after stop(). Do not call after stop() has returned.
///
/// # Safety
///
/// `client` must be a valid pointer returned by `slipstream_client_start`.
#[no_mangle]
pub unsafe extern "C" fn slipstream_client_is_running(client: *const SlipstreamClient) -> bool {
    if client.is_null() {
        return false;
    }
    unsafe { (*client).alive.load(Ordering::Acquire) }
}
