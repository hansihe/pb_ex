defmodule CEL.EvaluatorTest do
  use ExUnit.Case, async: true

  alias CEL.Checked
  alias CEL.Error
  alias CEL.TestSupport.StringTypes
  alias CEL.Value

  test "evaluates checked source with runtime bindings" do
    assert CEL.eval!("x + 1", %{x: 2}, env(vars: %{x: :int})) == Value.int(3)
  end

  test "preserves uint values at runtime" do
    assert CEL.eval!("1u + 2u") == Value.uint(3)
  end

  test "defers dyn overload failures to runtime" do
    assert {:error, %Error{phase: :eval, message: "no runtime overload for _+_(int, uint)"}} =
             CEL.eval("dyn(1) + 2u")
  end

  test "evaluates dyn arithmetic through dynamic runtime overloads" do
    assert CEL.eval!("dyn(1) + 2") == Value.int(3)
    assert CEL.eval!(~S|dyn("a") + "b"|) == Value.string("ab")
    assert CEL.eval!("dyn(6) / 3") == Value.int(2)
  end

  test "evaluates maps, selects, indexes, and conditionals" do
    expr = ~s|{"a": [1, 2]}.a[true ? 1 : 0]|

    assert CEL.eval!(expr) == Value.int(2)
  end

  test "a provider may name its types with strings" do
    env =
      env(types: {StringTypes, nil}, container: "test", vars: [m: {:message, :"test.Msg"}])

    m = %{"a" => 1, "child" => %{"a" => 2, "e" => 2}}

    assert CEL.Checked.type(CEL.check!("m.child", env)) == {:message, "test.Msg"}
    assert CEL.Checked.type(CEL.check!("m.e", env)) == {:enum, "test.E"}
    assert CEL.eval!("m.a + m.child.a", %{m: m}, env) == Value.int(3)
    assert CEL.eval!("m.child.e == E.Y && m.e == E(0)", %{m: m}, env) == Value.bool(true)
    assert CEL.eval!("[has(m.e), has(m.a), m.?e.hasValue()]", %{m: m}, env) ==
             Value.list([Value.bool(false), Value.bool(true), Value.bool(false)])

    assert CEL.eval!("dyn(m).child.a", %{m: m}, env) == Value.int(2)
    assert CEL.eval!("Msg{a: 5, e: E.X}", %{}, env) ==
             {:message, "test.Msg", %{"a" => Value.int(5), "e" => Value.enum("test.E", 1)}}

    assert CEL.eval!("E('Y')", %{}, env) == Value.enum("test.E", 2)
    assert CEL.eval!("Msg{a: 1} == Msg{a: 1} && type(m) == Msg", %{m: m}, env) == Value.bool(true)
    assert CEL.eval!("type(m)", %{m: m}, env) |> Value.type_name() == "test.Msg"

    assert {:error, %Error{phase: :check, message: "no such field \"b\""}} =
             CEL.check("m.b", env)
  end

  test "evaluates macro-expanded comprehensions" do
    assert CEL.eval!("[1, 2, 3].all(x, x > 0)") == Value.bool(true)
    assert CEL.eval!("[1, 2, 3].exists(x, x == 2)") == Value.bool(true)
    assert CEL.eval!("[1, 2, 3].exists_one(x, x > 1)") == Value.bool(false)
    assert CEL.eval!("[1, 2, 3].filter(x, x > 1)") == Value.list([Value.int(2), Value.int(3)])

    assert CEL.eval!("[1, 2, 3].map(x, x + 1)") ==
             Value.list([Value.int(2), Value.int(3), Value.int(4)])
  end

  test "evaluates comprehension locals separately from root variables" do
    assert CEL.eval!("[1].map(x, x)[0]", %{x: Value.string("root")}, env(vars: %{x: :string})) ==
             Value.int(1)

    assert CEL.eval!(
             "[1].map(x, .x)[0]",
             %{x: Value.string("root")},
             env(vars: %{x: :string})
           ) ==
             Value.string("root")
  end

  test "evaluates cel.bind lexical locals" do
    assert CEL.eval!(~S|cel.bind(x, "a", x + x)|) == Value.string("aa")
    assert CEL.eval!("cel.bind(x, 1, cel.bind(x, 2, x) + x)") == Value.int(3)

    assert {:error, %Error{phase: :eval, message: "division by zero"}} =
             CEL.eval("cel.bind(x, 1 / 0, true)")
  end

  test "evaluates local-qualified selects without stealing root qualified names" do
    assert CEL.eval!(
             ~S|[{"y": 1}].map(x, x.y)[0]|,
             %{"x.y" => Value.string("root")},
             env(vars: %{"x.y" => :string})
           ) == Value.int(1)

    assert CEL.eval!(
             ~S|[{"y": 1}].map(x, .x.y)[0]|,
             %{"x.y" => Value.string("root")},
             env(vars: %{"x.y" => :string})
           ) == Value.string("root")
  end

  test "absorbs runtime errors in CEL logical operators when the result is determined" do
    assert CEL.eval!("dyn([1, 2, 3][3]) || true") == Value.bool(true)
    assert CEL.eval!("dyn([1, 2, 3][3]) && false") == Value.bool(false)

    assert CEL.eval!("(2 / 0 > 3 ? false : true) || true") == Value.bool(true)
    assert CEL.eval!("(2 / 0 > 3 ? false : true) && false") == Value.bool(false)

    assert CEL.eval!("[1, 2, 3].all(e, 6 / (2 - e) == 6)") == Value.bool(false)

    assert {:error, %Error{phase: :eval, message: "division by zero"}} =
             CEL.eval("true && (1 / 0 == 1)")
  end

  test "evaluates bool ordering and dynamic numeric list indexes" do
    assert CEL.eval!("false < true") == Value.bool(true)
    assert CEL.eval!("true >= false") == Value.bool(true)
    assert CEL.eval!("[7, 8, 9][dyn(0u)]") == Value.int(7)
    assert CEL.eval!("[7, 8, 9][dyn(0.0)]") == Value.int(7)
  end

  test "evaluates type denotations as runtime type values" do
    assert CEL.eval!("type(int) == type") == Value.bool(true)
    assert CEL.eval!("bool == bool") == Value.bool(true)
    assert CEL.eval!("list == list") == Value.bool(true)
    assert CEL.eval!("google.protobuf.Timestamp == google.protobuf.Timestamp") == Value.bool(true)
  end

  test "evaluates qualified identifiers with longest-prefix resolution" do
    assert CEL.eval!(
             "a.b.c",
             %{"a.b.c" => Value.string("yeah")},
             env(vars: %{"a.b.c" => :string})
           ) ==
             Value.string("yeah")

    assert CEL.eval!(
             "a.b.c",
             %{
               "a.b" => Value.map(%{Value.string("c") => Value.string("oops")}),
               "a.b.c" => Value.string("yeah")
             },
             env(vars: %{"a.b" => {:map, :string, :string}, "a.b.c" => :string})
           ) == Value.string("yeah")

    assert CEL.eval!(
             "a.b.c",
             %{"a.b" => Value.map(%{Value.string("c") => Value.string("yeah")})},
             env(vars: %{"a.b" => {:map, :string, :string}})
           ) == Value.string("yeah")
  end

  test "evaluates container-relative identifiers and message literals" do
    assert CEL.eval!(
             "y",
             %{"x.y" => Value.bool(true), "y" => Value.string("false")},
             env(
               vars: %{"x.y" => :bool, "y" => :string},
               container: "x"
             )
           ) == Value.bool(true)

    assert CEL.eval!(
             ".y",
             %{"x.y" => Value.bool(true), "y" => Value.string("root")},
             env(
               vars: %{"x.y" => :bool, "y" => :string},
               container: "x"
             )
           ) == Value.string("root")

    assert CEL.eval!("Int32Value{value: 34}", %{}, env(container: "google.protobuf")) ==
             Value.int(34)
  end

  test "evaluates optional chaining through selects, indexes, and entries" do
    assert CEL.eval!("optional.none().optMap(y, y + 1).hasValue()") == Value.bool(false)

    assert CEL.eval!(
             "optional.of(1).optMap(x, .x).orValue('missing')",
             %{x: Value.string("root")},
             env(vars: %{x: :string})
           ) == Value.string("root")

    assert CEL.eval!(
             ~S|optional.of({"y": 1}).optMap(x, x.y).orValue(0)|,
             %{"x.y" => Value.string("root")},
             env(vars: %{"x.y" => :string})
           ) == Value.int(1)

    assert CEL.eval!("optional.of({'c': {'index': 'goodbye'}}).c.index.orValue('default')") ==
             Value.string("goodbye")

    assert CEL.eval!("optional.of({'c': {}}).c.missing.orValue('default')") ==
             Value.string("default")

    assert CEL.eval!("{?'nested': {}.?missing, 'present': true}") ==
             Value.map(%{Value.string("present") => Value.bool(true)})

    assert CEL.eval!("[?{}.?missing, ?optional.of(42), ?optional.none()]") ==
             Value.list([Value.int(42)])

    assert CEL.eval!(~S|has({"foo": optional.none()}.foo)|) == Value.bool(true)
  end

  test "reports field errors for present optional scalar values" do
    assert {:error, %Error{phase: :eval, message: message}} =
             CEL.eval("{'null_key': dyn(null)}.?null_key.invalid.hasValue()")

    assert message =~ "no such key"
  end

  test "evaluates scalar conversions and size" do
    assert CEL.eval!("int(1u)") == Value.int(1)
    assert CEL.eval!("uint('42')") == Value.uint(42)
    assert CEL.eval!("double(1)") == Value.double(1.0)
    assert CEL.eval!("string(b'abc')") == Value.string("abc")
    assert CEL.eval!("bytes('abc')") == Value.bytes("abc")
    assert CEL.eval!("bytes(b'abc')") == Value.bytes("abc")
    assert CEL.eval!("bool('FALSE')") == Value.bool(false)
    assert CEL.eval!("size([1, 2, 3])") == Value.int(3)
    assert CEL.eval!("'fiance\\u0301'.size()") == Value.int(7)
  end

  test "evaluates well-known type message literals as CEL values" do
    assert CEL.eval!(~S|google.protobuf.Int32Value{value: 7}|, %{}, env([])) == Value.int(7)

    assert CEL.eval!(~S|google.protobuf.FloatValue{value: 1.1}|, %{}, env([])) ==
             Value.double(1.100000023841858)

    assert CEL.eval!(~S|google.protobuf.FloatValue{value: -1e40}|, %{}, env([])) ==
             Value.double(:negative_infinity)

    assert CEL.eval!(~S|google.protobuf.Value{string_value: "x"}|, %{}, env([])) ==
             Value.string("x")

    assert CEL.eval!(~S|google.protobuf.ListValue{values: ["x"]}|, %{}, env([])) ==
             Value.list([Value.string("x")])

    assert CEL.eval!(
             ~S|google.protobuf.Any{type_url: "type.googleapis.com/example.Msg", value: b"abc"}|,
             %{},
             env([])
           ) ==
             Value.object("type.googleapis.com/example.Msg", "abc")
  end

  test "evaluates timestamp and duration functions" do
    assert CEL.eval!(~S|string(timestamp("2009-02-13T23:31:30Z"))|) ==
             Value.string("2009-02-13T23:31:30Z")

    assert CEL.eval!(~S|timestamp("2009-02-13T23:00:00Z") + duration("240s")|) ==
             Value.timestamp(1_234_566_240_000_000_000)

    assert CEL.eval!(~S|duration("3730s").getMinutes()|) == Value.int(62)
    assert CEL.eval!(~S|timestamp("2009-02-13T23:31:30Z").getHours("02:00")|) == Value.int(1)
  end

  test "reports runtime conversion failures" do
    assert {:error, %Error{phase: :eval, message: "uint value is out of int range"}} =
             CEL.eval("int(18446744073709551615u)")

    assert {:error, %Error{phase: :eval, message: "bytes value is not valid UTF-8"}} =
             CEL.eval("string(b'\\xff')")

    assert {:error, %Error{phase: :eval, message: "cannot convert string to bool"}} =
             CEL.eval("bool('FaLsE')")

    assert {:error, %Error{phase: :eval, message: "division by zero"}} =
             CEL.eval("1 / 0")

    assert {:error, %Error{phase: :eval, message: "modulus by zero"}} =
             CEL.eval("1 % 0")

    assert {:error, %Error{phase: :eval, message: "integer overflow"}} =
             CEL.eval("9223372036854775807 + 1")

    assert {:error, %Error{phase: :eval, message: "unsigned integer overflow"}} =
             CEL.eval("0u - 1u")
  end

  test "evaluates CEL special double values" do
    assert CEL.eval!("15.75 / 0.0") == Value.double(:infinity)
    assert CEL.eval!("-15.75 / 0.0") == Value.double(:negative_infinity)
    assert CEL.eval!("0.0 / 0.0") == Value.double(:nan)
    assert CEL.eval!("2.0 * 8.988466e307") == Value.double(:infinity)
    assert CEL.eval!("2.0 * -8.988466e307") == Value.double(:negative_infinity)
    assert CEL.eval!("0.0 / 0.0 == 0.0 / 0.0") == Value.bool(false)
    assert CEL.eval!("0.0 / 0.0 != 0.0 / 0.0") == Value.bool(true)
    assert CEL.eval!("double('NaN')") == Value.double(:nan)
    assert CEL.eval!("string(double('Infinity'))") == Value.string("Infinity")
  end

  test "evaluates math extension predicates and extrema" do
    assert CEL.eval!("math.isNaN(0.0 / 0.0)") == Value.bool(true)
    assert CEL.eval!("math.isInf(1.0 / 0.0)") == Value.bool(true)
    assert CEL.eval!("math.isFinite(1.0 / 1.5)") == Value.bool(true)
    assert CEL.eval!("math.bitShiftRight(-8, 0)") == Value.int(-8)
    assert CEL.eval!("math.bitShiftRight(-8, 1)") == Value.int(9_223_372_036_854_775_804)
    assert CEL.eval!("math.bitShiftLeft(-8, 0)") == Value.int(-8)

    assert CEL.eval!("math.greatest(5.4, 10, 3u, -5.0, 9223372036854775807)") ==
             Value.int(9_223_372_036_854_775_807)

    assert CEL.eval!("math.least([5.4, 10, 3u, -5.0, 3.5])") ==
             Value.double(-5.0)

    assert {:error, %Error{phase: :eval, message: "no such overload"}} =
             CEL.eval("math.isNaN(dyn(true))")
  end

  test "evaluates base64 encoder extension functions" do
    assert CEL.eval!(~S|base64.encode(b'hello')|) == Value.string("aGVsbG8=")
    assert CEL.eval!(~S|base64.decode('aGVsbG8=')|) == Value.bytes("hello")
    assert CEL.eval!(~S|base64.decode('aGVsbG8')|) == Value.bytes("hello")

    assert CEL.eval!(~S|base64.decode(base64.encode(b'Hello World!'))|) ==
             Value.bytes("Hello World!")

    assert {:error, %Error{phase: :eval, message: "invalid base64"}} =
             CEL.eval(~S|base64.decode('***')|)
  end

  test "evaluates string extension functions" do
    assert CEL.eval!(~S|'tacocat'.charAt(3)|) == Value.string("o")
    assert CEL.eval!(~S|'©αT'.charAt(1)|) == Value.string("α")
    assert CEL.eval!(~S|'ta©o©αT'.indexOf('©αT', 3)|) == Value.int(4)
    assert CEL.eval!(~S|'bananananana'.lastIndexOf('nana', 7)|) == Value.int(6)
    assert CEL.eval!(~S|'ta©o©αT'.substring(2, 6)|) == Value.string("©o©α")

    assert CEL.eval!(~S|'{0} days {0} hours'.replace('{0}', '2', 1)|) ==
             Value.string("2 days {0} hours")

    assert CEL.eval!(~S|'hello world events!'.split(' ', 2)|) ==
             Value.list([Value.string("hello"), Value.string("world events!")])

    assert CEL.eval!(~S|'hello world events!'.split(' ', 0) == []|) == Value.bool(true)
    assert CEL.eval!(~S|['x', 'y'].join('-')|) == Value.string("x-y")
    assert CEL.eval!(~S|dyn('tacocat').charAt(3)|) == Value.string("o")
    assert CEL.eval!(~S|[dyn('x'), dyn('y')].join('-')|) == Value.string("x-y")
    assert CEL.eval!(~S|'TacoCÆt Xii'.lowerAscii()|) == Value.string("tacocÆt xii")
    assert CEL.eval!(~S|'tacoCαt'.upperAscii()|) == Value.string("TACOCαT")
    assert CEL.eval!(~S|' \f\n\r\t\vtext  '.trim()|) == Value.string("text")
    assert CEL.eval!(~S|'hubba'.matches('ubb')|) == Value.bool(true)
    assert CEL.eval!(~S<matches('grey', 'gr(a|e)y')>) == Value.bool(true)
    assert CEL.eval!(~S|strings.quote("bell\a")|) == Value.string(~S|"bell\a"|)
    assert CEL.eval!(~S|b"abcdef".startsWith(b"abc")|) == Value.bool(true)
    assert CEL.eval!(~S|b"abcdef".endsWith(b"def")|) == Value.bool(true)
    assert CEL.eval!(~S|b"abcdef".contains(b"cd")|) == Value.bool(true)
    assert CEL.eval!(~S|b"abcdef".contains(b"")|) == Value.bool(true)

    assert {:error, %Error{phase: :eval, message: "index out of range: 30"}} =
             CEL.eval(~S|'tacocat'.charAt(30)|)

    assert {:error, %Error{phase: :eval, message: "no such overload"}} =
             CEL.eval(~S|[dyn('x'), dyn(1)].join()|)
  end

  test "uses supplied precompiled regexes for matches calls" do
    checked =
      CEL.check!(~S|value.matches(pattern)|, env(vars: %{value: :string, pattern: :string}))

    matches_id = checked.expr.id
    assert {:call, %{name: "matches"}} = Checked.op(checked, matches_id)

    vars = %{"value" => "aaa", "pattern" => "^z+$"}

    assert {:ok, {:bool, false}} = CEL.Evaluator.eval(checked, vars)

    assert {:ok, {:bool, true}} =
             CEL.Evaluator.eval(checked, vars, regexes: %{matches_id => ~r/^a+$/})
  end

  test "matches with RE2-like Unicode rules and a bounded match" do
    # `.` matches a code point; `\w` stays ASCII, as in RE2.
    assert CEL.eval!(~S|'é'.matches('^.$')|) == Value.bool(true)
    assert CEL.eval!(~S|'é'.matches('^\\w$')|) == Value.bool(false)

    # Catastrophic backtracking ends in an error rather than running on.
    input = String.duplicate("a", 40) <> "b"

    assert {:error, %Error{phase: :eval, message: "regex match exceeded" <> _}} =
             CEL.eval(~s|'#{input}'.matches('^(a+)+$')|)
  end

  test "compiled programs compile literal patterns once" do
    program = CEL.compile!(~S|value.matches('^a+$')|, env(vars: %{value: :string}))
    assert [%Regex{source: "^a+$"}] = Map.values(program.regexes)
    assert CEL.Program.eval!(program, %{"value" => "aaa"}) == Value.bool(true)

    # An invalid literal pattern is reported when evaluated.
    program = CEL.compile!(~S|value.matches('(')|, env(vars: %{value: :string}))
    assert program.regexes == %{}

    assert {:error, %Error{message: "invalid regex" <> _}} =
             CEL.Program.eval(program, %{"value" => "a"})
  end

  def failing([_value]), do: {:error, :no_such_thing}

  test "error messages are strings, with the runtime reason in details" do
    function = %CEL.Function{
      name: "fail",
      overloads: [%CEL.Function.Overload{id: "fail_int", args: [:int], result: :int, eval: {__MODULE__, :failing}}]
    }

    assert {:error,
            %Error{
              message: "no such thing",
              details: %{reason: :no_such_thing}
            }} = CEL.eval("fail(1)", %{}, env(functions: [function]))
  end

  test "evaluates well-known type literals without a schema" do
    assert CEL.eval!("google.protobuf.Int64Value{value: 1}") == Value.int(1)
    assert CEL.eval!("google.protobuf.Int32Value{}") == Value.int(0)
    assert CEL.eval!("google.protobuf.FloatValue{value: 1.1}") == Value.double(1.100000023841858)
    assert CEL.eval!("google.protobuf.StringValue{value: 'a'} == 'a'") == Value.bool(true)
    assert CEL.eval!("google.protobuf.Value{number_value: 1.5}") == Value.double(1.5)
    assert CEL.eval!("google.protobuf.Value{}") == Value.null()
    assert CEL.eval!("google.protobuf.ListValue{values: [1, 'a']}") ==
             Value.list([Value.int(1), Value.string("a")])

    assert CEL.eval!("google.protobuf.Struct{fields: {'a': 1}}") ==
             Value.map(%{Value.string("a") => Value.int(1)})

    assert CEL.eval!("google.protobuf.Timestamp{seconds: 1, nanos: 2}") ==
             Value.timestamp(1_000_000_002)

    assert CEL.eval!("google.protobuf.Duration{seconds: -1}") == Value.duration(-1_000_000_000)

    assert CEL.eval!("Int64Value{value: 1}", %{}, env(container: "google.protobuf")) ==
             Value.int(1)

    # An `Any` it has no schema to unpack stays an object value.
    assert CEL.eval!("google.protobuf.Any{type_url: 'x/pkg.M', value: b'1'}") ==
             Value.object("x/pkg.M", "1")

    assert CEL.Checked.type(CEL.check!("google.protobuf.Int64Value{value: 1}")) == :int
    assert CEL.Checked.type(CEL.check!("google.protobuf.Timestamp{}")) == :timestamp

    assert {:error, %Error{phase: :check, message: "no such field \"nope\""}} =
             CEL.check("google.protobuf.Int64Value{nope: 1}")

    assert {:error, %Error{phase: :check, message: "message field \"value\"" <> _}} =
             CEL.check("google.protobuf.Int64Value{value: 'a'}")

    assert {:error, %Error{phase: :eval, message: "int32 value out of range"}} =
             CEL.eval("google.protobuf.Int32Value{value: 2147483648}")

    assert {:error, %Error{phase: :eval, message: "uint32 value out of range"}} =
             CEL.eval("google.protobuf.UInt32Value{value: 4294967296u}")

    assert {:error, %Error{phase: :check, message: "unknown message type pkg.Nope"}} =
             CEL.check("pkg.Nope{}")
  end

  test "evaluates string format extension" do
    assert CEL.eval!(~S|'%d %s %x'.format([42, 'ok', b'AZ'])|) ==
             Value.string("42 ok 415a")

    assert CEL.eval!(~S|'%.0f %.0f %.3f'.format([1.5, 2.5, 123.4999])|) ==
             Value.string("2 2 123.500")

    assert CEL.eval!(~S|'%s'.format([[double('NaN'), null, {'b': 2, 'a': 1}]])|) ==
             Value.string("[NaN, null, {a: 1, b: 2}]")

    assert CEL.eval!(~S|'%.2f %.0f %.20f'.format([1.005, 0.5, 0.1])|) ==
             Value.string("1.00 0 0.10000000000000000555")

    assert CEL.eval!(~S|'%f'.format([1e303])|) ==
             Value.string(
               "1000000000000000000161765076786456438212668646231659438295495017101117499" <>
                 "2257387478652602430342139152537797735681803374160274458205677791996433915" <>
                 "4160602606861115074612228497617725665004420052727680732706769046211266142" <>
                 "7500197051226489898260678763391449376088547292320814127957486330655468919" <>
                 "122263277568.000000"
             )

    assert CEL.eval!(~S|'%e %e %.2e %e'.format([5e-324, 1.7976931348623157e308, 9.996, -0.0])|) ==
             Value.string("4.940656e-324 1.797693e+308 1.00e+01 -0.000000e+00")

    assert {:error, %Error{phase: :eval, message: message}} = CEL.eval(~S|'%d'.format([null])|)
    assert message =~ "decimal clause"
  end

  test "can evaluate a pre-compiled program" do
    program = CEL.compile!("x.startsWith('he')", env(vars: %{x: :string}))

    assert CEL.Program.eval!(program, %{x: "hello"}) == Value.bool(true)
  end

  defp env(opts), do: CEL.Env.build(opts)
end
