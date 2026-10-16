defmodule PB.Validate.CELExtensionsTest do
  use ExUnit.Case, async: true

  alias PB.Validate.CELExtensions

  defp eval(source) do
    CEL.eval(source, %{}, CEL.Env.build(functions: CELExtensions.functions()))
  end

  test "evaluates the unique extension" do
    assert {:ok, {:bool, true}} = eval(~S|["foo", "Foo"].unique()|)
    assert {:ok, {:bool, false}} = eval(~S|unique([1, 2, 1])|)
  end

  test "validates hostnames" do
    assert {:ok, {:bool, true}} = eval(~s|"example.com".isHostname()|)
    assert {:ok, {:bool, true}} = eval(~s|"a.".isHostname()|)
    assert {:ok, {:bool, false}} = eval(~s|"foo_bar.com".isHostname()|)
    assert {:ok, {:bool, false}} = eval(~s|"a.1".isHostname()|)
    assert {:ok, {:bool, false}} = eval(~s|"你好.com".isHostname()|)
    assert {:ok, {:bool, false}} = eval(~s|"a..".isHostname()|)
    assert {:ok, {:bool, false}} = eval(~s|"a.1\\n".isHostname()|)
  end

  test "validates email addresses" do
    assert {:ok, {:bool, true}} = eval(~s|"foo+x@example.com".isEmail()|)
    assert {:ok, {:bool, true}} = eval(~s|"...@0.1.2.3".isEmail()|)

    assert {:ok, {:bool, false}} = eval(~s|"foo@".isEmail()|)
    assert {:ok, {:bool, false}} = eval(~s|"foo@example.com.".isEmail()|)
    assert {:ok, {:bool, false}} = eval(~s|"foo@你好.com".isEmail()|)
  end

  test "validates host and port pairs" do
    assert {:ok, {:bool, true}} = eval(~s|"example.com".isHostAndPort(false)|)
    assert {:ok, {:bool, true}} = eval(~s|"example.com:8080".isHostAndPort(true)|)
    assert {:ok, {:bool, true}} = eval(~s|"[::1%foo]:65535".isHostAndPort(true)|)

    assert {:ok, {:bool, false}} = eval(~s|"example.com".isHostAndPort(true)|)
    assert {:ok, {:bool, false}} = eval(~s|"example.com:080".isHostAndPort(false)|)
    assert {:ok, {:bool, false}} = eval(~s|"example.com:65536".isHostAndPort(false)|)
    assert {:ok, {:bool, false}} = eval(~s|"[127.0.0.1]".isHostAndPort(false)|)
    assert {:ok, {:bool, false}} = eval(~s|"example.com:80\\n".isHostAndPort(true)|)
  end

  test "validates IP addresses" do
    assert {:ok, {:bool, true}} = eval(~s|"127.0.0.1".isIp()|)
    assert {:ok, {:bool, true}} = eval(~s|"::1%zone".isIp()|)
    assert {:ok, {:bool, true}} = eval(~s|"::1".isIp(6)|)

    assert {:ok, {:bool, false}} = eval(~s|"::1".isIp(4)|)
    assert {:ok, {:bool, false}} = eval(~s|"127.0.0.1/16".isIp()|)
    assert {:ok, {:bool, false}} = eval(~s|"127.0.0.1 ".isIp()|)
    assert {:ok, {:bool, false}} = eval(~s|"::1%".isIp()|)
  end

  test "validates IP prefixes" do
    assert {:ok, {:bool, true}} = eval(~s|"127.0.0.1/16".isIpPrefix()|)
    assert {:ok, {:bool, true}} = eval(~s|"192.168.0.0/16".isIpPrefix(4, true)|)
    assert {:ok, {:bool, true}} = eval(~s|"2001:db8::/32".isIpPrefix(6, true)|)

    assert {:ok, {:bool, false}} = eval(~s|"192.168.128.0/16".isIpPrefix(4, true)|)
    assert {:ok, {:bool, false}} = eval(~s|"127.0.0.1".isIpPrefix()|)
    assert {:ok, {:bool, false}} = eval(~s|"127.0.0.1/033".isIpPrefix()|)
    assert {:ok, {:bool, false}} = eval(~s|"::1%en0/64".isIpPrefix()|)
  end

  test "validates URI strings" do
    assert {:ok, {:bool, true}} = eval(~s|"https://example.com/foo?x=y#frag".isUri()|)
    assert {:ok, {:bool, true}} = eval(~s|"foo:nz/%c3x%96".isUri()|)
    assert {:ok, {:bool, true}} = eval(~s|"https://[vF.-!$&'()*+,;=._~]".isUri()|)

    assert {:ok, {:bool, false}} = eval(~s|"./foo".isUri()|)
    assert {:ok, {:bool, false}} = eval(~s|"1foo://example.com".isUri()|)
    assert {:ok, {:bool, false}} = eval(~s|"https://foo%c3x%96".isUri()|)
    assert {:ok, {:bool, false}} = eval(~s|"https://example.com#%".isUri()|)
  end

  test "validates URI references" do
    assert {:ok, {:bool, true}} = eval(~s|"".isUriRef()|)
    assert {:ok, {:bool, true}} = eval(~s|"./foo/bar?baz=quux#frag".isUriRef()|)
    assert {:ok, {:bool, true}} = eval(~s|"//[::1]".isUriRef()|)

    assert {:ok, {:bool, false}} = eval(~s|"1foo://example.com".isUriRef()|)
    assert {:ok, {:bool, false}} = eval(~s|":".isUriRef()|)
    assert {:ok, {:bool, false}} = eval(~s|"##".isUriRef()|)
  end

  test "supports protovalidate receiver numeric predicates" do
    assert {:ok, {:bool, true}} = eval("double('NaN').isNan()")
    assert {:ok, {:bool, false}} = eval("1.0.isNan()")

    assert {:ok, {:bool, true}} = eval("double('Infinity').isInf()")
    assert {:ok, {:bool, false}} = eval("1.0.isInf()")
  end
end
