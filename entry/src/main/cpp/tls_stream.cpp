#include <napi/native_api.h>
#include <uv.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <psa/crypto.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
napi_value error(napi_env env, const char *message) {
    napi_throw_error(env, nullptr, message);
    return nullptr;
}
napi_value number(napi_env env, int value) {
    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}
napi_value bytes(napi_env env, const unsigned char *src, size_t length) {
    void *dest;
    napi_value value;
    if (napi_create_arraybuffer(env, length, &dest, &value) != napi_ok) return nullptr;
    if (length) memcpy(dest, src, length);
    return value;
}
napi_value status(napi_env env, int rc) {
    if (rc >= 0 || rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) return number(env, rc);
    char message[192];
    mbedtls_strerror(rc, message, sizeof(message));
    return error(env, message);
}
struct Config {
    mbedtls_ssl_config ssl;
    mbedtls_ctr_drbg_context rng;
    mbedtls_entropy_context entropy;
    mbedtls_x509_crt cert;
    mbedtls_pk_context key;
    Config() {
        mbedtls_ssl_config_init(&ssl);
        mbedtls_ctr_drbg_init(&rng);
        mbedtls_entropy_init(&entropy);
        mbedtls_x509_crt_init(&cert);
        mbedtls_pk_init(&key);
    }
    ~Config() {
        mbedtls_ssl_config_free(&ssl);
        mbedtls_pk_free(&key);
        mbedtls_x509_crt_free(&cert);
        mbedtls_ctr_drbg_free(&rng);
        mbedtls_entropy_free(&entropy);
    }
    int setup(const std::string &certificate, const std::string &privateKey) {
        if (psa_crypto_init() != PSA_SUCCESS) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
        int rc = mbedtls_ctr_drbg_seed(&rng, mbedtls_entropy_func, &entropy, nullptr, 0);
        if (rc) return rc;
        rc = mbedtls_x509_crt_parse(&cert, reinterpret_cast<const unsigned char *>(certificate.c_str()), certificate.size()+1);
        if (rc) return rc;
        rc = mbedtls_pk_parse_key(&key, reinterpret_cast<const unsigned char *>(privateKey.c_str()), privateKey.size()+1,
                                  nullptr, 0, mbedtls_ctr_drbg_random, &rng);
        if (rc) return rc;
        rc = mbedtls_ssl_config_defaults(&ssl, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
        if (rc) return rc;
        mbedtls_ssl_conf_rng(&ssl, mbedtls_ctr_drbg_random, &rng);
        // LocalSend uses self-signed identities. ArkTS pins the authenticated leaf before dispatching transfers.
        mbedtls_ssl_conf_authmode(&ssl, MBEDTLS_SSL_VERIFY_OPTIONAL);
        mbedtls_ssl_conf_ca_chain(&ssl, &cert, nullptr);
        mbedtls_ssl_conf_cert_req_ca_list(&ssl, MBEDTLS_SSL_CERT_REQ_CA_LIST_DISABLED);
        return mbedtls_ssl_conf_own_cert(&ssl, &cert, &key);
    }
};
struct Waiter { int events; napi_deferred promise; };
struct Endpoint {
    napi_env env;
    int fd;
    uv_poll_t poll{};
    std::vector<Waiter> waiting;
    std::shared_ptr<Config> config;
    Endpoint(napi_env e, int f, std::shared_ptr<Config> c) : env(e), fd(f), config(std::move(c)) {}
    virtual ~Endpoint() { if (fd >= 0) ::close(fd); }
    virtual void notifyClose() {}
    void settle(int events) {
        std::vector<napi_deferred> ready;
        for (auto it = waiting.begin(); it != waiting.end();) {
            if (it->events & events) {
                ready.push_back(it->promise);
                it = waiting.erase(it);
            } else ++it;
        }
        // Ark may resume a waiter inline; it can immediately register another wait.
        napi_value value;
        napi_get_undefined(env, &value);
        for (auto deferred : ready) napi_resolve_deferred(env, deferred, value);
    }
    void shutdown() {
        if (fd < 0) return;
        uv_poll_stop(&poll);
        notifyClose();
        ::close(fd);
        fd = -1;
        settle(UV_READABLE | UV_WRITABLE);
    }
    void arm() {
        int events = 0;
        for (auto &w : waiting) events |= w.events;
        if (!events) { uv_poll_stop(&poll); return; }
        if (uv_poll_start(&poll, events, [](uv_poll_t *handle, int err, int ready) {
            auto *p = static_cast<Endpoint *>(handle->data);
            napi_handle_scope scope;
            if (napi_open_handle_scope(p->env, &scope) != napi_ok) return;
            if (err < 0) p->shutdown();
            else { p->settle(ready); if (p->fd >= 0) p->arm(); }
            napi_close_handle_scope(p->env, scope);
        }) < 0) shutdown();
    }
};
int bioSend(void *ctx, const unsigned char *buf, size_t len) {
    int n = send(static_cast<Endpoint *>(ctx)->fd, buf, len, MSG_NOSIGNAL);
    if (n >= 0) return n;
    return errno == EINTR || errno == EAGAIN ? MBEDTLS_ERR_SSL_WANT_WRITE : MBEDTLS_ERR_NET_SEND_FAILED;
}
int bioRecv(void *ctx, unsigned char *buf, size_t len) {
    int n = recv(static_cast<Endpoint *>(ctx)->fd, buf, len, 0);
    if (n >= 0) return n;
    return errno == EINTR || errno == EAGAIN ? MBEDTLS_ERR_SSL_WANT_READ : MBEDTLS_ERR_NET_RECV_FAILED;
}
struct Stream : Endpoint {
    mbedtls_ssl_context ssl;
    using Endpoint::Endpoint;
    ~Stream() override { mbedtls_ssl_free(&ssl); }
    void notifyClose() override { mbedtls_ssl_close_notify(&ssl); }
};
template<class T> T *self(napi_env env, napi_callback_info info, size_t argc = 0, napi_value *args = nullptr) {
    napi_value object;
    void *native = nullptr;
    napi_get_cb_info(env, info, &argc, args, &object, nullptr);
    napi_unwrap(env, object, &native);
    return static_cast<T *>(native);
}
napi_value wait(napi_env env, napi_callback_info info) {
    napi_value arg, promise;
    auto *p = self<Endpoint>(env, info, 1, &arg);
    if (p->fd < 0) return error(env, "Socket closed");
    bool writable = false;
    napi_get_value_bool(env, arg, &writable);
    napi_deferred deferred;
    napi_create_promise(env, &deferred, &promise);
    p->waiting.push_back({writable ? UV_WRITABLE : UV_READABLE, deferred});
    p->arm();
    return promise;
}
napi_value closeEndpoint(napi_env env, napi_callback_info info) {
    self<Endpoint>(env, info)->shutdown();
    return nullptr;
}
napi_value handshake(napi_env env, napi_callback_info info) {
    auto *s = self<Stream>(env, info);
    if (s->fd < 0) return error(env, "Socket closed");
    return status(env, mbedtls_ssl_handshake(&s->ssl));
}
napi_value peerCertificate(napi_env env, napi_callback_info info) {
    auto *s = self<Stream>(env, info);
    const auto *cert = mbedtls_ssl_get_peer_cert(&s->ssl);
    if (!cert) return bytes(env, nullptr, 0);
    if (mbedtls_ssl_get_verify_result(&s->ssl) & ~MBEDTLS_X509_BADCERT_NOT_TRUSTED)
        return error(env, "Invalid peer certificate");
    return bytes(env, cert->raw.p, cert->raw.len);
}
napi_value read(napi_env env, napi_callback_info info) {
    auto *s = self<Stream>(env, info);
    if (s->fd < 0) return error(env, "Socket closed");
    unsigned char data[16384];
    int rc = mbedtls_ssl_read(&s->ssl, data, sizeof(data));
    if (rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) rc = 0;
    return rc > 0 ? bytes(env, data, rc) : status(env, rc);
}
napi_value write(napi_env env, napi_callback_info info) {
    napi_value args[2];
    auto *s = self<Stream>(env, info, 2, args);
    if (s->fd < 0) return error(env, "Socket closed");
    void *buf;
    size_t size;
    uint32_t offset;
    if (napi_get_arraybuffer_info(env, args[0], &buf, &size) != napi_ok ||
        napi_get_value_uint32(env, args[1], &offset) != napi_ok || offset >= size)
        return error(env, "Invalid write range");
    return status(env, mbedtls_ssl_write(&s->ssl, static_cast<unsigned char *>(buf)+offset,
                                         std::min<size_t>(size-offset, MBEDTLS_SSL_OUT_CONTENT_LEN)));
}
#define METHOD(name, fn) {name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr}
napi_value wrap(napi_env env, Endpoint *p, const napi_property_descriptor *methods, size_t count) {
    uv_loop_t *loop;
    if (napi_get_uv_event_loop(env, &loop) != napi_ok || uv_poll_init_socket(loop, &p->poll, p->fd) < 0) {
        delete p;
        return error(env, "Cannot monitor socket");
    }
    p->poll.data = p;
    napi_value object;
    napi_create_object(env, &object);
    napi_wrap(env, object, p, [](napi_env, void *data, void *) {
        auto *p = static_cast<Endpoint *>(data);
        p->shutdown();
        uv_close(reinterpret_cast<uv_handle_t *>(&p->poll), [](uv_handle_t *h) { delete static_cast<Endpoint *>(h->data); });
    }, nullptr, nullptr);
    napi_define_properties(env, object, count, methods);
    return object;
}
napi_value acceptPeer(napi_env env, napi_callback_info info) {
    auto *p = self<Endpoint>(env, info);
    sockaddr_in addr{};
    socklen_t len = sizeof(addr);
    int fd = accept4(p->fd, reinterpret_cast<sockaddr *>(&addr), &len, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) {
        if (errno != EAGAIN && errno != EINTR) return error(env, strerror(errno));
        napi_value empty;
        napi_get_null(env, &empty);
        return empty;
    }
    auto *s = new Stream(env, fd, p->config);
    mbedtls_ssl_init(&s->ssl);
    int rc = mbedtls_ssl_setup(&s->ssl, &s->config->ssl);
    if (rc) { delete s; return status(env, rc); }
    mbedtls_ssl_set_bio(&s->ssl, static_cast<Endpoint *>(s), bioSend, bioRecv, nullptr);
    const napi_property_descriptor methods[] = {METHOD("wait", wait), METHOD("close", closeEndpoint),
        METHOD("handshake", handshake), METHOD("peerCertificate", peerCertificate), METHOD("read", read), METHOD("write", write)};
    napi_value object = wrap(env, s, methods, sizeof(methods)/sizeof(methods[0]));
    if (!object) return nullptr;
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &addr.sin_addr, ip, sizeof(ip));
    napi_value address;
    napi_create_string_utf8(env, ip, NAPI_AUTO_LENGTH, &address);
    napi_set_named_property(env, object, "address", address);
    return object;
}
std::string stringArg(napi_env env, napi_value value) {
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::string result(length + 1, '\0');
    napi_get_value_string_utf8(env, value, result.data(), result.size(), &length);
    result.resize(length);
    return result;
}
napi_value listenSocket(napi_env env, napi_callback_info info) {
    napi_value args[3];
    size_t argc = 3;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int port;
    if (argc != 3 || napi_get_value_int32(env, args[2], &port) != napi_ok || port < 1 || port > 65535)
        return error(env, "Invalid listener arguments");
    auto config = std::make_shared<Config>();
    int rc = config->setup(stringArg(env, args[0]), stringArg(env, args[1]));
    if (rc) return status(env, rc < 0 ? rc : MBEDTLS_ERR_SSL_BAD_INPUT_DATA);
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return error(env, strerror(errno));
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0 || ::listen(fd, 32) < 0) {
        int err = errno;
        ::close(fd);
        return error(env, strerror(err));
    }
    const napi_property_descriptor methods[] = {METHOD("wait", wait), METHOD("close", closeEndpoint), METHOD("accept", acceptPeer)};
    return wrap(env, new Endpoint(env, fd, config), methods, 3);
}
napi_value init(napi_env env, napi_value exports) {
    const napi_property_descriptor methods[] = {METHOD("listen", listenSocket)};
    napi_define_properties(env, exports, 1, methods);
    napi_set_named_property(env, exports, "wantRead", number(env, MBEDTLS_ERR_SSL_WANT_READ));
    napi_set_named_property(env, exports, "wantWrite", number(env, MBEDTLS_ERR_SSL_WANT_WRITE));
    return exports;
}
napi_module module = {1, 0, nullptr, init, "hsend_tls", nullptr, {nullptr}};
__attribute__((constructor)) void registerModule() { napi_module_register(&module); }
}
