#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const char *host;
  uint16_t port;
  int mode; /* 1 = Recursive, 2 = Authoritative */
} slipstream_resolver_t;

/* Field types/order MUST match the Rust #[repr(C)] struct exactly. */
typedef struct {
  const char *tcp_listen_host;
  uint16_t tcp_listen_port;
  const slipstream_resolver_t *resolvers; /* array; not owned */
  size_t resolver_count;
  const char *domain;
  const char *congestion_control; /* optional, may be NULL */
  bool gso;
  const char *cert_path; /* optional, may be NULL */
  uint16_t keep_alive_interval;
  bool debug_poll;
  bool debug_streams;
} slipstream_client_config_t;

typedef struct slipstream_client slipstream_client_t;

/* Returns the library version string. Do not free the returned pointer. */
const char *slipstream_version(void);

/*
 * Starts a new client. Returns a handle on success, NULL on failure.
 * Strings are copied into owned Rust memory, so caller memory may be freed
 * once this returns. Call slipstream_client_stop() exactly once to free it.
 */
slipstream_client_t *
slipstream_client_start(const slipstream_client_config_t *config);

/*
 * Stops and frees a client instance. Returns 0.
 * The pointer is invalid the moment this returns.
 */
int slipstream_client_stop(slipstream_client_t *client);

/*
 * True while the client is running. Returns false if the client dies on
 * its own (e.g. error or panic). Do not call after slipstream_client_stop().
 */
bool slipstream_client_is_running(const slipstream_client_t *client);

#ifdef __cplusplus
}
#endif
