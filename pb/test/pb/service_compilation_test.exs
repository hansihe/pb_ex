defmodule PB.ServiceCompilationTest do
  use ExUnit.Case

  # ── Service compilation ──────────────────────────────────────────────

  describe "service compilation" do
    setup do
      descriptor_set = %{
        file: [
          %{
            name: "greeter.proto",
            package: "grpc.test",
            syntax: "proto3",
            message_type: [
              %{name: "HelloRequest", field: [%{name: "name", number: 1, type: :TYPE_STRING}]},
              %{name: "HelloReply", field: [%{name: "message", number: 1, type: :TYPE_STRING}]}
            ],
            service: [
              %{
                name: "Greeter",
                method: [
                  %{
                    name: "SayHello",
                    input_type: ".grpc.test.HelloRequest",
                    output_type: ".grpc.test.HelloReply"
                  },
                  %{
                    name: "SayHelloStream",
                    input_type: ".grpc.test.HelloRequest",
                    output_type: ".grpc.test.HelloReply",
                    server_streaming: true
                  },
                  %{
                    name: "SayHelloBidi",
                    input_type: ".grpc.test.HelloRequest",
                    output_type: ".grpc.test.HelloReply",
                    client_streaming: true,
                    server_streaming: true
                  }
                ]
              }
            ]
          }
        ]
      }

      %{schema: PB.compile(descriptor_set)}
    end

    test "compiles service with methods", %{schema: schema} do
      assert Map.has_key?(schema.services, :"grpc.test.Greeter")
      svc = schema.services[:"grpc.test.Greeter"]
      assert map_size(svc.methods) == 3
    end

    test "unary method has correct types and no streaming", %{schema: schema} do
      method = schema.services[:"grpc.test.Greeter"].methods[:SayHello]
      assert method.input_type == :"grpc.test.HelloRequest"
      assert method.output_type == :"grpc.test.HelloReply"
      assert method.client_streaming == false
      assert method.server_streaming == false
    end

    test "server streaming method", %{schema: schema} do
      method = schema.services[:"grpc.test.Greeter"].methods[:SayHelloStream]
      assert method.client_streaming == false
      assert method.server_streaming == true
    end

    test "bidi streaming method", %{schema: schema} do
      method = schema.services[:"grpc.test.Greeter"].methods[:SayHelloBidi]
      assert method.client_streaming == true
      assert method.server_streaming == true
    end

    test "schema without services has empty services map" do
      descriptor_set = %{
        file: [
          %{
            name: "nosvc.proto",
            package: "nosvc",
            syntax: "proto3",
            message_type: [
              %{name: "Msg", field: [%{name: "x", number: 1, type: :TYPE_INT32}]}
            ]
          }
        ]
      }

      schema = PB.compile(descriptor_set)
      assert schema.services == %{}
    end

    test "multiple services across files" do
      descriptor_set = %{
        file: [
          %{
            name: "a.proto",
            package: "pkg",
            syntax: "proto3",
            message_type: [
              %{name: "Req", field: [%{name: "x", number: 1, type: :TYPE_INT32}]},
              %{name: "Resp", field: [%{name: "y", number: 1, type: :TYPE_INT32}]}
            ],
            service: [
              %{
                name: "SvcA",
                method: [
                  %{name: "Do", input_type: ".pkg.Req", output_type: ".pkg.Resp"}
                ]
              }
            ]
          },
          %{
            name: "b.proto",
            package: "pkg",
            syntax: "proto3",
            service: [
              %{
                name: "SvcB",
                method: [
                  %{name: "Do", input_type: ".pkg.Req", output_type: ".pkg.Resp"}
                ]
              }
            ]
          }
        ]
      }

      schema = PB.compile(descriptor_set)
      assert Map.has_key?(schema.services, :"pkg.SvcA")
      assert Map.has_key?(schema.services, :"pkg.SvcB")
    end
  end
end
