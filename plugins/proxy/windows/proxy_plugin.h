#ifndef FLUTTER_PLUGIN_PROXY_PLUGIN_H_
#define FLUTTER_PLUGIN_PROXY_PLUGIN_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>
#include <string>

namespace proxy {

class ProxyPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  ProxyPlugin() = default;

  explicit ProxyPlugin(flutter::PluginRegistrarWindows* registrar);

  ~ProxyPlugin() override;

  ProxyPlugin(const ProxyPlugin&) = delete;
  ProxyPlugin& operator=(const ProxyPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static bool IsSessionEnding(UINT message, WPARAM wparam);

  static bool OwnsProxySettings(int port, DWORD flags, const std::wstring& server);

  std::optional<LRESULT> HandleWindowProc(
      HWND window, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  bool StopOwnedProxy();

  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  int window_proc_id_ = -1;
  // Whether this process is the one that pointed Windows at a proxy.
  bool proxy_applied_ = false;
  int proxy_port_ = 0;
};

}  // namespace proxy

#endif  // FLUTTER_PLUGIN_PROXY_PLUGIN_H_
