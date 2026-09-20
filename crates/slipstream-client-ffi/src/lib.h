#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const char *host; /* e.g. "1.1.1.1" or "::1" */
  uint16_t port;    /* e.g. 53 */
  int mode;         /* 1 = Recursive, 2 = Authoritative */
} slipstream_resolver_t;

/* Field types/order MUST match the Rust #[repr(C)] struct exactly. */
typedef struct {
  const char *tcp_listen_host;
  uint16_t tcp_listen_port;
  const slipstream_resolver_t *resolvers; /* array; not owned by library */
  size_t resolver_count;                  /* size_t (Rust usize) */
  const char *domain;
  const char *congestion_control; /* optional, may be NULL */
  bool gso;                       /* bool (1 byte) */
  const char *cert_path;          /* optional, may be NULL */
  uint16_t keep_alive_interval;
  bool debug_poll;    /* bool */
  bool debug_streams; /* bool */
} slipstream_client_config_t;

typedef struct slipstream_client slipstream_client_t;

/*
 * Returns the library version string (e.g. "1.2").
 * The returned pointer is to a static string; the caller must NOT free it.
 */
const char *slipstream_version(void);

/*
 * Creates and starts a new Slipstream client instance.
 * Returns non-null handle on success, null on failure.
 *
 * All C configuration strings are copied into owned Rust memory during
 * start(); the caller's memory does not need to remain valid after
 * start() returns.
 *
 * The returned pointer is owned by the library. Call
 * slipstream_client_stop() exactly once to stop and free it.
 * The pointer is invalid the moment slipstream_client_stop() returns.
 *
 * Multiple clients are fully independent:
 *   client1 → task1 / thread1
 *   client2 → task2 / thread2
 *   stop(client2) stops only client2; client1 and client3 continue.
 */
slipstream_client_t *
slipstream_client_start(const slipstream_client_config_t *config);

/*
 * Stops and frees a specific client instance.
 * Cancels that client's Tokio task, joins its thread, and frees its memory.
 * Returns 0 on success.
 *
 * WARNING: The pointer is invalid immediately after this returns.
 * Call stop() exactly once per successful start().
 * Do not use the pointer after stop() returns.
 * Do not attempt to detect repeated stops by reading freed memory.
 */
int slipstream_client_stop(slipstream_client_t *client);

/*
 * Returns true while the client is still running.
 * Becomes false if the client exits on its own (error, panic, etc.).
 * Must NOT be called after slipstream_client_stop() has freed the pointer.
 */
bool slipstream_client_is_running(const slipstream_client_t *client);

#ifdef __cplusplus
}
#endif
