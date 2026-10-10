#include "system_lock.h"
#include <fido.h>
#include <fido/es256.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>
#include <algorithm>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using Bytes = std::vector<unsigned char>;
namespace {
void Check(int code) { if (code != FIDO_OK) throw std::runtime_error(std::string("Security key operation failed: ") + fido_strerr(code)); }
void Wipe(Bytes& b) { if (!b.empty()) OPENSSL_cleanse(b.data(), b.size()); }
Bytes Random(size_t n) { Bytes b(n); if (RAND_bytes(b.data(), static_cast<int>(n)) != 1) throw std::runtime_error("Cannot generate security key challenge."); return b; }
std::string Text(FlValue* args, const char* key) {
  FlValue* v = args ? fl_value_lookup_string(args, key) : nullptr;
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) throw std::runtime_error("Invalid System lock binding.");
  return fl_value_get_string(v);
}
std::string Id(FlValue* args) {
  auto id = Text(args, "vaultId");
  if (id.size() != 32 || id.find_first_not_of("0123456789abcdef") != std::string::npos) throw std::runtime_error("Invalid vault identifier.");
  return id;
}
Bytes Decode(FlValue* args, const char* key, size_t n, bool variable = false) {
  auto value = Text(args, key);
  if (value.size() > ((n + 2) / 3) * 4) throw std::runtime_error("Invalid System lock binding.");
  gsize size = 0; guchar* p = g_base64_decode(value.c_str(), &size);
  Bytes out(p, p + size); g_free(p);
  gchar* encoded = g_base64_encode(out.data(), out.size());
  bool valid = value == encoded && (variable ? size > 0 && size <= n : size == n); g_free(encoded);
  if (!valid) throw std::runtime_error("Invalid System lock binding.");
  return out;
}
void Put(FlValue* value, const char* key, const Bytes& b) {
  gchar* encoded = g_base64_encode(b.data(), b.size());
  fl_value_set_string_take(value, key, fl_value_new_string(encoded)); g_free(encoded);
}
struct Devices {
  fido_dev_info_t* value = fido_dev_info_new(16); size_t count = 0;
  Devices() { if (!value) throw std::runtime_error("Cannot enumerate security keys."); Check(fido_dev_info_manifest(value, 16, &count)); }
  ~Devices() { fido_dev_info_free(&value, 16); }
};
struct Device { fido_dev_t* value = fido_dev_new(); ~Device() { if (value) { fido_dev_close(value); fido_dev_free(&value); } } };
struct Credential { fido_cred_t* value = fido_cred_new(); ~Credential() { fido_cred_free(&value); } };
struct Assertion { fido_assert_t* value = fido_assert_new(); ~Assertion() { fido_assert_free(&value); } };
struct PublicKey { es256_pk_t* value = es256_pk_new(); ~PublicKey() { es256_pk_free(&value); } };
struct Info { fido_cbor_info_t* value = fido_cbor_info_new(); ~Info() { fido_cbor_info_free(&value); } };
struct State {
  GtkWindow* window; GtkWidget* dialog = nullptr; bool alive = true, busy = false;
  unsigned long epoch = 0;
};
struct Job {
  std::shared_ptr<State> state; FlMethodCall* call; unsigned long epoch;
  std::string path, id, error; bool enroll;
  Bytes pin, credential, publicKey, salt, secret;
  ~Job() { Wipe(pin); Wipe(secret); g_object_unref(call); }
};
void RespondError(FlMethodCall* call, const char* text) { fl_method_call_respond_error(call, "authentication", text, nullptr, nullptr); }
void Run(Job& j) {
  Device device; if (!device.value) throw std::runtime_error("Cannot open the security key.");
  Check(fido_dev_set_timeout(device.value, 15000));
  Check(fido_dev_open(device.value, j.path.c_str()));
  if (!fido_dev_is_fido2(device.value) || !fido_dev_has_pin(device.value)) throw std::runtime_error("Use a FIDO2 security key with a configured PIN.");
  Info info; Check(fido_dev_get_cbor_info(device.value, info.value));
  bool supported = false;
  for (size_t i = 0; i < fido_cbor_info_extensions_len(info.value); ++i) {
    if (std::string(fido_cbor_info_extensions_ptr(info.value)[i]) == "hmac-secret") supported = true;
  }
  if (!supported) throw std::runtime_error("This security key does not support hmac-secret.");
  const char* pin = reinterpret_cast<const char*>(j.pin.data());
  if (j.enroll) {
    Credential cred; auto challenge = Random(32), user = Random(32);
    Check(fido_cred_set_type(cred.value, COSE_ES256));
    Check(fido_cred_set_clientdata_hash(cred.value, challenge.data(), challenge.size()));
    Check(fido_cred_set_rp(cred.value, "spar-vault.local", "Spar Vault"));
    Check(fido_cred_set_user(cred.value, user.data(), user.size(), j.id.c_str(), "Spar Vault", nullptr));
    Check(fido_cred_set_extensions(cred.value, FIDO_EXT_HMAC_SECRET));
    Check(fido_cred_set_rk(cred.value, FIDO_OPT_FALSE));
    Check(fido_cred_set_uv(cred.value, FIDO_OPT_TRUE));
    Check(fido_dev_make_cred(device.value, cred.value, pin));
    Check(fido_cred_x5c_len(cred.value) ? fido_cred_verify(cred.value) : fido_cred_verify_self(cred.value));
    const auto n = fido_cred_id_len(cred.value), pk = fido_cred_pubkey_len(cred.value);
    if (!n || n > 2048 || pk != 64) throw std::runtime_error("Invalid security key credential.");
    j.credential.assign(fido_cred_id_ptr(cred.value), fido_cred_id_ptr(cred.value) + n);
    j.publicKey.assign(fido_cred_pubkey_ptr(cred.value), fido_cred_pubkey_ptr(cred.value) + pk);
    j.salt = Random(32);
  }
  Assertion assertion; auto challenge = Random(32);
  Check(fido_assert_set_rp(assertion.value, "spar-vault.local"));
  Check(fido_assert_set_clientdata_hash(assertion.value, challenge.data(), challenge.size()));
  Check(fido_assert_allow_cred(assertion.value, j.credential.data(), j.credential.size()));
  Check(fido_assert_set_up(assertion.value, FIDO_OPT_TRUE));
  Check(fido_assert_set_uv(assertion.value, FIDO_OPT_TRUE));
  Check(fido_assert_set_extensions(assertion.value, FIDO_EXT_HMAC_SECRET));
  Check(fido_assert_set_hmac_salt(assertion.value, j.salt.data(), j.salt.size()));
  Check(fido_dev_get_assert(device.value, assertion.value, pin));
  PublicKey pk; Check(es256_pk_from_ptr(pk.value, j.publicKey.data(), j.publicKey.size()));
  if (fido_assert_count(assertion.value) != 1 ||
      fido_assert_id_len(assertion.value, 0) != j.credential.size() ||
      !std::equal(j.credential.begin(), j.credential.end(), fido_assert_id_ptr(assertion.value, 0)) ||
      (fido_assert_flags(assertion.value, 0) & 0x05) != 0x05) throw std::runtime_error("Security key did not verify PIN and touch.");
  Check(fido_assert_verify(assertion.value, 0, COSE_ES256, pk.value));
  if (fido_assert_hmac_secret_len(assertion.value, 0) != 32) throw std::runtime_error("Security key did not return the protected secret.");
  auto secret = fido_assert_hmac_secret_ptr(assertion.value, 0); j.secret.assign(secret, secret + 32);
}
gboolean Complete(gpointer data) {
  std::unique_ptr<Job> job(static_cast<Job*>(data)); auto& s = *job->state;
  if (s.dialog) { gtk_widget_destroy(s.dialog); s.dialog = nullptr; }
  if (s.alive) {
    if (s.epoch != job->epoch) RespondError(job->call, "System authentication was cancelled.");
    else if (!job->error.empty()) RespondError(job->call, job->error.c_str());
    else {
      g_autoptr(FlValue) value = job->enroll ? fl_value_new_map() : fl_value_new_uint8_list(job->secret.data(), job->secret.size());
      if (job->enroll) {
        Put(value, "credential", job->credential); Put(value, "publicKey", job->publicKey); Put(value, "salt", job->salt);
        fl_value_set_string_take(value, "secret", fl_value_new_uint8_list(job->secret.data(), job->secret.size()));
      }
      fl_method_call_respond_success(job->call, value, nullptr);
      FlValue* bytes = job->enroll ? fl_value_lookup_string(value, "secret") : value;
      OPENSSL_cleanse(const_cast<uint8_t*>(fl_value_get_uint8_list(bytes)), fl_value_get_length(bytes));
    }
  }
  s.busy = false; return G_SOURCE_REMOVE;
}
void Handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto state = *static_cast<std::shared_ptr<State>*>(data); auto& s = *state;
  std::string method = fl_method_call_get_name(call);
  if (method == "cancel") { ++s.epoch; if (s.dialog) gtk_dialog_response(GTK_DIALOG(s.dialog), GTK_RESPONSE_CANCEL); fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (method == "setup") { fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (method == "status") {
    g_autoptr(FlValue) value = fl_value_new_map();
    std::string ready = "no_hardware"; try { Devices d; if (d.count) ready = "ready"; } catch (...) {}
    fl_value_set_string_take(value, "systemProvider", fl_value_new_string("fido2"));
    fl_value_set_string_take(value, "screenLock", fl_value_new_string(ready.c_str()));
    fl_method_call_respond_success(call, value, nullptr); return;
  }
  if (method != "enable" && method != "unlock") { fl_method_call_respond_not_implemented(call, nullptr); return; }
  if (s.busy) { RespondError(call, "System authentication is already running."); return; }
  auto j = std::unique_ptr<Job>(new Job{});
  j->state = state; j->call = FL_METHOD_CALL(g_object_ref(call)); j->epoch = s.epoch; j->enroll = method == "enable";
  try {
    auto args = fl_method_call_get_args(call); j->id = Id(args);
    if (!j->enroll) { j->credential = Decode(args, "credential", 2048, true); j->publicKey = Decode(args, "publicKey", 64); j->salt = Decode(args, "salt", 32); }
    Devices devices; if (!devices.count) throw std::runtime_error("Connect a FIDO2 security key first.");
    s.busy = true;
    s.dialog = gtk_dialog_new_with_buttons("System lock — security key", s.window, GTK_DIALOG_MODAL, "Cancel", GTK_RESPONSE_CANCEL, "Continue", GTK_RESPONSE_OK, nullptr);
    auto box = gtk_dialog_get_content_area(GTK_DIALOG(s.dialog));
    auto label = gtk_label_new("Choose your security key and enter its PIN. Then touch the key.");
    auto combo = gtk_combo_box_text_new(); std::vector<std::string> paths;
    for (size_t i = 0; i < devices.count; ++i) {
      auto info = fido_dev_info_ptr(devices.value, i); auto path = fido_dev_info_path(info);
      if (!path) continue;
      paths.emplace_back(path);
      auto product = fido_dev_info_product_string(info);
      gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(combo), product ? product : "FIDO2 security key");
    }
    if (paths.empty()) throw std::runtime_error("Cannot access a FIDO2 security key.");
    gtk_combo_box_set_active(GTK_COMBO_BOX(combo), 0);
    auto entry = gtk_entry_new(); gtk_entry_set_visibility(GTK_ENTRY(entry), FALSE); gtk_entry_set_max_length(GTK_ENTRY(entry), 63);
    gtk_entry_set_input_purpose(GTK_ENTRY(entry), GTK_INPUT_PURPOSE_PASSWORD);
    gtk_container_add(GTK_CONTAINER(box), label); gtk_container_add(GTK_CONTAINER(box), combo); gtk_container_add(GTK_CONTAINER(box), entry);
    gtk_widget_show_all(s.dialog);
    int response = gtk_dialog_run(GTK_DIALOG(s.dialog));
    if (response != GTK_RESPONSE_OK || s.epoch != j->epoch) throw std::runtime_error("System authentication was cancelled.");
    int selected = gtk_combo_box_get_active(GTK_COMBO_BOX(combo));
    if (selected < 0 || static_cast<size_t>(selected) >= paths.size()) throw std::runtime_error("Choose a security key.");
    j->path = paths[static_cast<size_t>(selected)];
    const char* pin = gtk_entry_get_text(GTK_ENTRY(entry));
    j->pin.assign(pin, pin + strlen(pin)); j->pin.push_back(0);
    gtk_entry_set_text(GTK_ENTRY(entry), "");
    if (j->pin.size() < 5) throw std::runtime_error("Enter the security key PIN.");
    gtk_widget_destroy(s.dialog); s.dialog = gtk_dialog_new_with_buttons("Touch your security key", s.window, GTK_DIALOG_MODAL, "Cancel", GTK_RESPONSE_CANCEL, nullptr);
    gtk_container_add(GTK_CONTAINER(gtk_dialog_get_content_area(GTK_DIALOG(s.dialog))), gtk_label_new("Touch the security key. Each operation has a 15-second timeout."));
    g_signal_connect(s.dialog, "response", G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer p) {
      auto s = static_cast<State*>(p); ++s->epoch; gtk_widget_hide(GTK_WIDGET(dialog));
    }), &s);
    gtk_widget_show_all(s.dialog);
    Job* raw = j.release();
    std::thread([raw]() { try { Run(*raw); } catch (const std::exception& e) { raw->error = e.what(); } Wipe(raw->pin); g_idle_add_full(G_PRIORITY_DEFAULT, Complete, raw, nullptr); }).detach();
  } catch (const std::exception& e) {
    if (s.dialog) { gtk_widget_destroy(s.dialog); s.dialog = nullptr; }
    s.busy = false; RespondError(call, e.what());
  }
}
}
void spar_system_lock_register(FlView* view, GtkWindow* window) {
  fido_init(0);
  auto state = std::make_shared<State>(); state->window = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)), "spar/system_lock", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, Handle, new std::shared_ptr<State>(state),
    +[](gpointer p) { delete static_cast<std::shared_ptr<State>*>(p); });
  g_signal_connect_data(window, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer p) {
    auto state = *static_cast<std::shared_ptr<State>*>(p); state->alive = false; ++state->epoch;
    if (state->dialog) { gtk_widget_destroy(state->dialog); state->dialog = nullptr; }
  }), new std::shared_ptr<State>(state), +[](gpointer p, GClosure*) { delete static_cast<std::shared_ptr<State>*>(p); }, G_CONNECT_DEFAULT);
  g_object_set_data_full(G_OBJECT(view), "spar-system-lock", channel, g_object_unref);
}

