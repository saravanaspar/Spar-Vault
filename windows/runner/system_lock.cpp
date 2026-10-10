#include "system_lock.h"
#include <flutter/standard_method_codec.h>
#include <ncrypt.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <sddl.h>
#include <shellapi.h>
#include <algorithm>
#include <mutex>
#include <thread>
#include <stdexcept>
#include <string>
#include <vector>
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
using Bytes = std::vector<uint8_t>;
namespace {
void Wipe(Bytes& x) { if (!x.empty()) SecureZeroMemory(x.data(), x.size()); }
struct Handle {
  NCRYPT_HANDLE value = 0;
  ~Handle() { if (value) NCryptFreeObject(value); }
};
void Check(SECURITY_STATUS s) {
  if (s != ERROR_SUCCESS) throw std::runtime_error("Windows Hello could not complete the protected-key operation. Set up Hello and a TPM, then retry.");
}
std::string Text(const M& m, const char* name) {
  auto i = m.find(V(name));
  if (i == m.end() || !std::holds_alternative<std::string>(i->second)) throw std::runtime_error("Invalid System lock binding.");
  return std::get<std::string>(i->second);
}
std::string Id(const M& m) {
  auto id = Text(m, "vaultId");
  if (id.size() != 32 || id.find_first_not_of("0123456789abcdef") != std::string::npos) throw std::runtime_error("Invalid vault identifier.");
  return id;
}
std::wstring Wide(const std::string& s) { return std::wstring(s.begin(), s.end()); }
std::string Prefix() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) throw std::runtime_error("Cannot identify the Windows user.");
  DWORD n = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &n);
  Bytes b(n); bool ok = GetTokenInformation(token, TokenUser, b.data(), n, &n) != 0; CloseHandle(token);
  LPSTR sid = nullptr;
  if (!ok || !ConvertSidToStringSidA(reinterpret_cast<TOKEN_USER*>(b.data())->User.Sid, &sid)) throw std::runtime_error("Cannot identify the Windows user.");
  std::string s(sid); LocalFree(sid);
  return s + "//SparVault/SystemLock/";
}
void Scoped(const std::string& name, const std::string& id) {
  const auto prefix = Prefix() + id + "/";
  if (name.size() != prefix.size() + 32 || name.compare(0, prefix.size(), prefix) ||
      name.substr(prefix.size()).find_first_not_of("0123456789abcdef") != std::string::npos) throw std::runtime_error("Invalid System lock key name.");
}
void Set(NCRYPT_KEY_HANDLE h, const wchar_t* p, DWORD v) {
  Check(NCryptSetProperty(h, p, reinterpret_cast<PBYTE>(&v), sizeof(v), 0));
}
DWORD Get(NCRYPT_KEY_HANDLE h, const wchar_t* p) {
  DWORD value = 0, n = 0;
  Check(NCryptGetProperty(h, p, reinterpret_cast<PBYTE>(&value), sizeof(value), &n, 0));
  if (n != sizeof(value)) throw std::runtime_error("Invalid Windows Hello key.");
  return value;
}
void Verify(NCRYPT_KEY_HANDLE h) {
  const DWORD impl = Get(h, L"NgcKeyImplType");
  if (!(impl & NCRYPT_IMPL_HARDWARE_FLAG) || (impl & NCRYPT_IMPL_SOFTWARE_FLAG) ||
      Get(h, L"NgcCacheType") != 1 || (Get(h, NCRYPT_KEY_USAGE_PROPERTY) & 0x8)) {
    throw std::runtime_error("This device cannot provide hardware-backed authentication for every unlock.");
  }
}
std::string Encode(const Bytes& b) {
  DWORD n = 0; if (!CryptBinaryToStringA(b.data(), static_cast<DWORD>(b.size()), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &n)) throw std::runtime_error("Cannot encode System lock binding.");
  std::string s(n, '\0');
  if (!CryptBinaryToStringA(b.data(), static_cast<DWORD>(b.size()), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, &s[0], &n)) throw std::runtime_error("Cannot encode System lock binding.");
  s.resize(n); while (!s.empty() && s.back() == '\0') s.pop_back(); return s;
}
Bytes Decode(const std::string& s) {
  if (s.size() > 344) throw std::runtime_error("Invalid System lock binding.");
  DWORD n = 0;
  if (!CryptStringToBinaryA(s.c_str(), static_cast<DWORD>(s.size()), CRYPT_STRING_BASE64, nullptr, &n, nullptr, nullptr) || n != 256) throw std::runtime_error("Invalid System lock binding.");
  Bytes b(n); if (!CryptStringToBinaryA(s.c_str(), static_cast<DWORD>(s.size()), CRYPT_STRING_BASE64, b.data(), &n, nullptr, nullptr)) throw std::runtime_error("Invalid System lock binding.");
  return b;
}
void Provider(Handle& p) { Check(NCryptOpenStorageProvider(&p.value, L"Microsoft Passport Key Storage Provider", 0)); }
void Delete(const M& m) {
  const auto id = Id(m), name = Text(m, "keyName"); Scoped(name, id);
  Handle p, k; Provider(p);
  auto status = NCryptOpenKey(p.value, &k.value, Wide(name).c_str(), 0, NCRYPT_SILENT_FLAG);
  if (status == NTE_BAD_KEYSET || status == NTE_NOT_FOUND) return;
  Check(status); Check(NCryptDeleteKey(k.value, 0)); k.value = 0;
}
Bytes Decrypt(NCRYPT_KEY_HANDLE h, Bytes& cipher, HWND window) {
  Verify(h);
  Set(h, L"PinCacheIsGestureRequired", 1);
  Check(NCryptSetProperty(h, NCRYPT_WINDOW_HANDLE_PROPERTY, reinterpret_cast<PBYTE>(&window), sizeof(window), 0));
  BCRYPT_OAEP_PADDING_INFO pad{BCRYPT_SHA256_ALGORITHM, nullptr, 0};
  DWORD n = 0;
  // One actual decryption call avoids two authentication prompts.
  Bytes out(256);
  try {
    Check(NCryptDecrypt(h, cipher.data(), static_cast<DWORD>(cipher.size()), &pad,
      out.data(), static_cast<DWORD>(out.size()), &n, NCRYPT_PAD_OAEP_FLAG));
    out.resize(n); return out;
  } catch (...) { Wipe(out); throw; }
}
V Work(const std::string& method, const M& m, HWND window, std::string& newName) {
  if (method == "delete") { Delete(m); return V(); }
  const auto id = Id(m);
  Handle p, k; Provider(p);
  Bytes plain, cipher, root;
  try {
    if (method == "enable") {
      auto it = m.find(V("key"));
      if (it == m.end() || !std::holds_alternative<Bytes>(it->second)) throw std::runtime_error("Invalid System lock key.");
      root = std::get<Bytes>(it->second);
      if (root.size() != 32) throw std::runtime_error("Invalid System lock key.");
      Bytes nonce(16); Check(BCryptGenRandom(nullptr, nonce.data(), 16, BCRYPT_USE_SYSTEM_PREFERRED_RNG));
      static const char hex[] = "0123456789abcdef";
      newName = Prefix() + id + "/"; for (auto b : nonce) { newName += hex[b >> 4]; newName += hex[b & 15]; }
      Check(NCryptCreatePersistedKey(p.value, &k.value, BCRYPT_RSA_ALGORITHM, Wide(newName).c_str(), 0, 0));
      Set(k.value, NCRYPT_LENGTH_PROPERTY, 2048);
      Set(k.value, NCRYPT_KEY_USAGE_PROPERTY, NCRYPT_ALLOW_DECRYPT_FLAG);
      Set(k.value, NCRYPT_EXPORT_POLICY_PROPERTY, 0);
      Set(k.value, L"NgcCacheType", 1);
      Check(NCryptFinalizeKey(k.value, 0)); Verify(k.value);
      const auto prefix = "SparVault/system-lock/windows/v1|" + id + "|";
      plain.assign(prefix.begin(), prefix.end()); plain.insert(plain.end(), root.begin(), root.end());
      BCRYPT_OAEP_PADDING_INFO pad{BCRYPT_SHA256_ALGORITHM, nullptr, 0}; DWORD n = 0; cipher.resize(256);
      Check(NCryptEncrypt(k.value, plain.data(), static_cast<DWORD>(plain.size()), &pad, cipher.data(), 256, &n, NCRYPT_PAD_OAEP_FLAG));
      cipher.resize(n); auto proof = Decrypt(k.value, cipher, window);
      bool match = proof == plain; Wipe(proof); if (!match) throw std::runtime_error("Windows Hello key verification failed.");
      Wipe(root); Wipe(plain);
      return V(M{{V("keyName"), V(newName)}, {V("ciphertext"), V(Encode(cipher))}});
    }
    auto name = Text(m, "keyName"); Scoped(name, id);
    Check(NCryptOpenKey(p.value, &k.value, Wide(name).c_str(), 0, 0));
    cipher = Decode(Text(m, "ciphertext")); plain = Decrypt(k.value, cipher, window);
    const auto prefix = "SparVault/system-lock/windows/v1|" + id + "|";
    if (plain.size() != prefix.size() + 32 || !std::equal(prefix.begin(), prefix.end(), plain.begin())) throw std::runtime_error("System lock binding belongs to another vault.");
    root.assign(plain.begin() + prefix.size(), plain.end()); V reply(root); Wipe(root); Wipe(plain); return reply;
  } catch (...) { Wipe(root); Wipe(plain); throw; }
}
void WipeValue(V& v) { if (auto b = std::get_if<Bytes>(&v)) Wipe(*b); }
}
struct SystemLock::State {
  std::mutex mutex; bool alive = true, busy = false; uint64_t epoch = 0, jobEpoch = 0;
  HWND window; V reply; std::string error, newName, id;
  std::unique_ptr<flutter::MethodResult<V>> result;
};
SystemLock::SystemLock(flutter::BinaryMessenger* messenger, HWND window) : state_(std::make_shared<State>()) {
  state_->window = window;
  channel_ = std::make_unique<flutter::MethodChannel<V>>(messenger, "spar/system_lock", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<V>& call, std::unique_ptr<flutter::MethodResult<V>> result) {
    const auto method = call.method_name();
    if (method == "cancel") { std::lock_guard<std::mutex> l(state_->mutex); ++state_->epoch; result->Success(); return; }
    if (method == "setup") { ShellExecuteW(state_->window, L"open", L"ms-settings:signinoptions", nullptr, nullptr, SW_SHOWNORMAL); result->Success(V(true)); return; }
    if (method == "status") {
      std::string ready = "not_enrolled"; try { Handle p; Provider(p); ready = "ready"; } catch (...) {}
      result->Success(V(M{{V("systemProvider"), V("windows")}, {V("screenLock"), V(ready)}})); return;
    }
    if (method != "enable" && method != "unlock" && method != "delete") { result->NotImplemented(); return; }
    if (!call.arguments() || !std::holds_alternative<M>(*call.arguments())) { result->Error("invalid", "Invalid System lock request."); return; }
    auto args = std::get<M>(*call.arguments()); std::string id;
    try { id = Id(args); } catch (const std::exception& e) { result->Error("invalid", e.what()); return; }
    auto s = state_;
    { std::lock_guard<std::mutex> l(s->mutex);
      if (s->busy) { result->Error("busy", "System authentication is already running."); return; }
      s->busy = true; s->jobEpoch = s->epoch; s->id = id; s->result = std::move(result);
    }
    std::thread([s, args = std::move(args), method, id]() mutable {
      V reply; std::string error, name;
      try { reply = Work(method, args, s->window, name); } catch (const std::exception& e) { error = e.what(); }
      auto it = args.find(V("key")); if (it != args.end()) WipeValue(it->second);
      bool abandon;
      { std::lock_guard<std::mutex> l(s->mutex);
        abandon = !s->alive || s->epoch != s->jobEpoch || !error.empty();
        if (abandon) WipeValue(reply);
        s->reply = std::move(reply); s->error = std::move(error); s->newName = abandon ? "" : name;
        if (s->alive) PostMessage(s->window, SystemLock::kComplete, 0, 0);
      }
      if (abandon && !name.empty()) { try { Delete(M{{V("keyName"), V(name)}, {V("vaultId"), V(id)}}); } catch (...) {} }
    }).detach();
  });
}
SystemLock::~SystemLock() {
  channel_->SetMethodCallHandler(nullptr);
  std::string orphan, id;
  {
    std::lock_guard<std::mutex> l(state_->mutex);
    state_->alive = false; ++state_->epoch;
    if (state_->result) { state_->result->Error("cancelled", "Application closed."); state_->result.reset(); }
    WipeValue(state_->reply); orphan = state_->newName; id = state_->id;
  }
  if (!orphan.empty()) { try { Delete(M{{V("keyName"), V(orphan)}, {V("vaultId"), V(id)}}); } catch (...) {} }
}
void SystemLock::Complete() {
  std::lock_guard<std::mutex> l(state_->mutex); if (!state_->result) return;
  if (state_->epoch != state_->jobEpoch) {
    state_->result->Error("cancelled", "System authentication was cancelled.");
    if (!state_->newName.empty()) { try { Delete(M{{V("keyName"), V(state_->newName)}, {V("vaultId"), V(state_->id)}}); } catch (...) {} }
  } else if (!state_->error.empty()) state_->result->Error("authentication", state_->error);
  else state_->result->Success(state_->reply);
  WipeValue(state_->reply); state_->result.reset(); state_->newName.clear(); state_->error.clear(); state_->busy = false;
}

