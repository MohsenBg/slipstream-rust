use libc::{c_char, c_int, c_ushort};
use std::ffi::CStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use slipstream_core::{AddressKind, parse_host_port};
use slipstream_ffi::{ClientConfig, ResolverMode, ResolverSpec};
use tokio::sync::oneshot;

// One client owns its own OS thread and a current-thread tokio runtime.
// No globals. The alive flag is shared with the worker so external code can
// poll whether the client died on its own (panic, error, etc).
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

fn opt_string(p: *const c_char) -> Option<String> {
    if p.is_null() {
        None
    } else {
        unsafe { Some(CStr::from_ptr(p).to_string_lossy().into_owned()) }
    }
}

/// Returns an opaque handle on success, null on failure. All strings are copied,
/// so the caller may free them once this returns.
///
/// # Safety
///
/// `config` must point to a valid `SlipstreamClientConfig` whose string fields
/// are null-terminated C strings (or null).
#[unsafe(no_mangle)]
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

    let tcp_listen_host = opt_string(cfg.tcp_listen_host).unwrap_or_default();
    let domain = opt_string(cfg.domain).unwrap_or_default();
    let congestion_control = opt_string(cfg.congestion_control);
    let cert_path = opt_string(cfg.cert_path);

    let mut resolvers = Vec::with_capacity(cfg.resolver_count);
    for i in 0..cfg.resolver_count {
        let r = unsafe { *cfg.resolvers.add(i) };
        let Some(host) = opt_string(r.host) else {
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

        // Flip alive to false no matter how we exit — normal return, error, panic.
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
                _ = shutdown_rx => {}
            }
        });

        // Dropping the runtime waits for spawned tasks to finish
        drop(rt);
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

/// Stops and frees a client. Call exactly once; the pointer is invalid afterwards.
///
/// # Safety
///
/// `client` must come from `slipstream_client_start` and not have been stopped yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slipstream_client_stop(client: *mut SlipstreamClient) -> c_int {
    if client.is_null() {
        return 0;
    }
    let mut client = unsafe { Box::from_raw(client) };
    if let Some(tx) = client.shutdown.take() {
        // Err just means the worker already exited on its own — fine.
        let _ = tx.send(());
    }
    if let Some(t) = client.thread.take() {
        let _ = t.join();
    }
    0
}

/// Returns the library version. Caller must NOT free the pointer.
#[unsafe(no_mangle)]
pub extern "C" fn slipstream_version() -> *const c_char {
    static VERSION: &CStr = c"0.1.3";
    VERSION.as_ptr()
}

/// True while the worker thread is still running. Goes false if it dies on its
/// own (error/panic) as well as after `slipstream_client_stop`. Don't call after stop.
///
/// # Safety
///
/// `client` must come from `slipstream_client_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slipstream_client_is_running(client: *const SlipstreamClient) -> bool {
    if client.is_null() {
        return false;
    }
    unsafe { (*client).alive.load(Ordering::Acquire) }
}
