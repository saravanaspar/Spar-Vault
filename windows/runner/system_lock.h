#pragma once
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>
class SystemLock {
 public:
  static constexpr UINT kComplete = WM_APP + 46;
  SystemLock(flutter::BinaryMessenger*, HWND);
  ~SystemLock();
  void Complete();
 private:
  struct State;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

