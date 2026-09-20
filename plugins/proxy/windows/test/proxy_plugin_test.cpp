#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <WinInet.h>
#include <Ras.h>

#include <memory>
#include <string>
#include <variant>

#include "proxy_plugin.h"

namespace proxy {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(ProxyPlugin, UnknownMethodIsNotImplemented) {
  ProxyPlugin plugin;
  bool not_implemented = false;
  plugin.HandleMethodCall(
      MethodCall("unknown", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          nullptr, nullptr,
          [&not_implemented]() { not_implemented = true; }));

  EXPECT_TRUE(not_implemented);
}

TEST(ProxyPlugin, StartProxyRejectsMissingArguments) {
  ProxyPlugin plugin;
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("StartProxy", std::make_unique<EncodableValue>(EncodableMap())),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](
              const std::string& code,
              const std::string& message,
              const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, StartProxyRejectsInvalidPort) {
  ProxyPlugin plugin;
  std::string error_code;
  EncodableMap arguments = {
      {EncodableValue("port"), EncodableValue(70000)},
      {EncodableValue("bypassDomain"), EncodableValue(EncodableList())}};

  plugin.HandleMethodCall(
      MethodCall(
          "StartProxy",
          std::make_unique<EncodableValue>(std::move(arguments))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](
              const std::string& code,
              const std::string& message,
              const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, StartProxyRejectsNonStringBypassDomain) {
  ProxyPlugin plugin;
  std::string error_code;
  EncodableList bypass_domain = {
      EncodableValue("localhost"),
      EncodableValue(1)};
  EncodableMap arguments = {
      {EncodableValue("port"), EncodableValue(7890)},
      {EncodableValue("bypassDomain"),
       EncodableValue(std::move(bypass_domain))}};

  plugin.HandleMethodCall(
      MethodCall(
          "StartProxy",
          std::make_unique<EncodableValue>(std::move(arguments))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](
              const std::string& code,
              const std::string& message,
              const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, OwnershipRequiresTheExactEndpointAndFlags) {
  const DWORD owned_flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  EXPECT_TRUE(ProxyPlugin::OwnsProxySettings(17896, owned_flags, L"127.0.0.1:17896"));
  EXPECT_FALSE(ProxyPlugin::OwnsProxySettings(0, owned_flags, L"127.0.0.1:0"));
  EXPECT_FALSE(ProxyPlugin::OwnsProxySettings(17896, owned_flags, L"127.0.0.1:7890"));
  EXPECT_FALSE(ProxyPlugin::OwnsProxySettings(17896, PROXY_TYPE_DIRECT, L"127.0.0.1:17896"));
  EXPECT_FALSE(ProxyPlugin::OwnsProxySettings(
      17896, owned_flags | PROXY_TYPE_AUTO_PROXY_URL, L"127.0.0.1:17896"));
  EXPECT_FALSE(ProxyPlugin::OwnsProxySettings(
      17896, owned_flags, L"http=127.0.0.1:17896;https=127.0.0.1:7890"));
}

struct ProxySettings {
  DWORD flags = 0;
  std::wstring server;
  std::wstring bypass;

  bool Read() {
    INTERNET_PER_CONN_OPTION options[3] = {};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    INTERNET_PER_CONN_OPTION_LIST list = {};
    list.dwSize = sizeof(list);
    list.dwOptionCount = 3;
    list.pOptions = options;
    DWORD size = sizeof(list);
    const bool ok = InternetQueryOption(
        nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) != FALSE;
    flags = options[0].Value.dwValue;
    server = options[1].Value.pszValue != nullptr ? options[1].Value.pszValue : L"";
    bypass = options[2].Value.pszValue != nullptr ? options[2].Value.pszValue : L"";
    if (options[1].Value.pszValue != nullptr) GlobalFree(options[1].Value.pszValue);
    if (options[2].Value.pszValue != nullptr) GlobalFree(options[2].Value.pszValue);
    return ok;
  }

  bool Write() const {
    INTERNET_PER_CONN_OPTION options[3] = {};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[0].Value.dwValue = flags;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[1].Value.pszValue = const_cast<wchar_t*>(server.c_str());
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[2].Value.pszValue = const_cast<wchar_t*>(bypass.c_str());
    INTERNET_PER_CONN_OPTION_LIST list = {};
    list.dwSize = sizeof(list);
    list.dwOptionCount = 3;
    list.pOptions = options;
    return InternetSetOption(
        nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list)) != FALSE;
  }
};

// Run on the disposable Windows CI runner, never on the user's daily host.
TEST(ProxyPlugin, StartupExitAndShutdownRetainAnExistingExternalProxy) {
  ProxySettings previous;
  ASSERT_TRUE(previous.Read());
  struct Restore {
    ProxySettings previous;
    ~Restore() { EXPECT_TRUE(previous.Write()); }
  } restore{previous};
  const ProxySettings external{PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY, L"127.0.0.1:27896"};
  ASSERT_TRUE(external.Write());
  ProxyPlugin plugin;
  for (int i = 0; i < 2; ++i) {
    bool succeeded = false;
    plugin.HandleMethodCall(
        MethodCall("StopProxy", std::make_unique<EncodableValue>()),
        std::make_unique<MethodResultFunctions<>>(
            [&succeeded](const EncodableValue* value) {
              succeeded = value != nullptr && std::get<bool>(*value);
            }, nullptr, nullptr));
    EXPECT_TRUE(succeeded);
  }
  plugin.HandleWindowProc(nullptr, WM_ENDSESSION, TRUE, 0);
  ProxySettings after;
  ASSERT_TRUE(after.Read());
  EXPECT_EQ(after.flags, external.flags);
  EXPECT_EQ(after.server, external.server);
}

TEST(ProxyPlugin, ReleasesItsOwnProxyButRetainsAThirdPartyTakeover) {
  // StartProxy also changes RAS connections. This integration fixture is only
  // permitted on the disposable CI host with no configured RAS connections.
  DWORD bytes = 0;
  DWORD count = 0;
  ASSERT_EQ(RasEnumEntries(nullptr, nullptr, nullptr, &bytes, &count), ERROR_SUCCESS);
  ASSERT_EQ(count, 0u);
  ProxySettings previous;
  ASSERT_TRUE(previous.Read());
  struct Restore {
    ProxySettings previous;
    ~Restore() { EXPECT_TRUE(previous.Write()); }
  } restore{previous};
  ProxyPlugin plugin;
  const auto invoke = [&plugin](const std::string& method, EncodableValue args) {
    bool succeeded = false;
    plugin.HandleMethodCall(
        MethodCall(method, std::make_unique<EncodableValue>(std::move(args))),
        std::make_unique<MethodResultFunctions<>>(
            [&succeeded](const EncodableValue* value) {
              succeeded = value != nullptr && std::get<bool>(*value);
            }, nullptr, nullptr));
    return succeeded;
  };
  const EncodableMap arguments = {
      {EncodableValue("port"), EncodableValue(17896)},
      {EncodableValue("bypassDomain"), EncodableValue(EncodableList())}};
  ASSERT_TRUE(invoke("StartProxy", EncodableValue(arguments)));
  ASSERT_TRUE(invoke("StopProxy", EncodableValue()));
  ProxySettings after;
  ASSERT_TRUE(after.Read());
  EXPECT_EQ(after.flags, static_cast<DWORD>(PROXY_TYPE_DIRECT));
  ASSERT_TRUE(invoke("StartProxy", EncodableValue(arguments)));
  const ProxySettings external{PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY, L"127.0.0.1:27896"};
  ASSERT_TRUE(external.Write());
  ASSERT_TRUE(invoke("StopProxy", EncodableValue()));
  ASSERT_TRUE(after.Read());
  EXPECT_EQ(after.flags, external.flags);
  EXPECT_EQ(after.server, external.server);
}

TEST(ProxyPlugin, RestoresTheSystemProxyOnlyWhenTheSessionReallyEnds) {
  EXPECT_TRUE(ProxyPlugin::IsSessionEnding(WM_ENDSESSION, TRUE));
  // A cancelled shutdown reports itself through the same message, and acting on
  // it would strip the proxy from a session that goes on running.
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_ENDSESSION, FALSE));
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_QUERYENDSESSION, TRUE));
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_CLOSE, TRUE));
}

}  // namespace test
}  // namespace proxy
