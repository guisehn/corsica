defmodule CorsicaTest do
  use ExUnit.Case
  use Plug.Test

  import Corsica
  import ExUnit.CaptureIO

  describe "sanitize_opts/1" do
    test ":max_age" do
      assert sanitize_opts(origins: "*", max_age: 600).max_age == "600"
      assert sanitize_opts(origins: "*").max_age == nil
    end

    test ":expose_headers" do
      assert sanitize_opts(origins: "*", expose_headers: ~w(X-Foo X-Bar)).expose_headers ==
               "X-Foo,X-Bar"

      assert sanitize_opts(origins: "*").expose_headers == nil
    end

    test ":origins is required" do
      assert_raise ArgumentError, "the :origins option is required", fn -> sanitize_opts([]) end
    end

    test "value of :origins" do
      assert sanitize_opts(origins: ["foo.bar", ~r/.*/, {MyMod, :my_fun, []}]).origins ==
               ["foo.bar", ~r/.*/, {MyMod, :my_fun, []}]

      assert sanitize_opts(origins: "*").origins == "*"
      assert sanitize_opts(origins: []).origins == []

      assert capture_io(:stderr, fn -> sanitize_opts(origins: {MyMod, :my_fun}) end) =~
               "passing {MyMod, :my_fun} as an allowed origin is deprecated"
    end

    test ":allow_methods" do
      assert sanitize_opts(origins: "*", allow_methods: ~w(get pOSt PUT)).allow_methods ==
               ~w(GET POST PUT)

      assert sanitize_opts(origins: "*").allow_methods == ~w(PUT PATCH DELETE)
    end

    test ":allow_headers" do
      assert sanitize_opts(origins: "*", allow_headers: ~w(X-Header y-HEADER)).allow_headers ==
               ~w(x-header y-header)

      assert sanitize_opts(origins: "*").allow_headers == []
    end

    test ":allow_credentials" do
      assert sanitize_opts(origins: "*", allow_credentials: true).allow_credentials == true
      assert sanitize_opts(origins: "*").allow_credentials == false
    end

    test ":passthrough_non_cors_requests" do
      assert sanitize_opts(origins: "*", passthrough_non_cors_requests: true).passthrough_non_cors_requests ==
               true

      assert sanitize_opts(origins: "*").passthrough_non_cors_requests == false

      assert capture_io(:stderr, fn ->
               sanitize_opts(origins: ["http://example.com"], passthrough_non_cors_requests: true)
             end) =~
               "if the :passthrough_non_cors_requests option is set to true"
    end
  end

  describe "allowed_origin?/2" do
    defmodule MyOriginChecker do
      def check(_origin), do: Process.get(:corsica_accept_origin, false)
      def check(%Plug.Conn{}, _origin, :test), do: Process.get(:corsica_accept_origin, false)
    end

    test "with allowed origins" do
      conn = conn(:get, "/") |> put_origin("http://foo.com")
      assert allowed_origin?(conn, sanitize_opts(origins: "*"))
      assert allowed_origin?(conn, sanitize_opts(origins: "http://foo.com"))
      assert allowed_origin?(conn, sanitize_opts(origins: ["http://foo.com"]))
      assert allowed_origin?(conn, sanitize_opts(origins: ["http://bar.com", "http://foo.com"]))
      assert allowed_origin?(conn, sanitize_opts(origins: ~r/(foo|bar)\.com$/))
      assert allowed_origin?(conn, sanitize_opts(origins: [~r/(foo|bar)\.com$/]))

      Process.put(:corsica_accept_origin, true)
      assert allowed_origin?(conn, sanitize_opts(origins: {MyOriginChecker, :check, [:test]}))
    end

    test "with non-allowed origins" do
      conn = conn(:get, "/") |> put_origin("http://foo.com")
      refute allowed_origin?(conn, sanitize_opts(origins: "foo.com"))
      refute allowed_origin?(conn, sanitize_opts(origins: ["http://foo.org"]))
      refute allowed_origin?(conn, sanitize_opts(origins: ["http://bar.com", "http://baz.com"]))
      refute allowed_origin?(conn, sanitize_opts(origins: ~r/(foo|bar)\.org$/))

      Process.put(:corsica_accept_origin, false)

      capture_io(:stderr, fn ->
        refute allowed_origin?(conn, sanitize_opts(origins: {MyOriginChecker, :check}))
      end)
    end
  end

  describe "allowed_preflight?/2" do
    test "with allowed requests (method)" do
      conn = put_origin(conn(:get, "/"), "http://foo.com")

      conn = put_req_header(conn, "access-control-request-method", "PATCH")
      assert allowed_preflight?(conn, sanitize_opts(origins: "*", allow_methods: ~w(PUT PATCH)))
      assert allowed_preflight?(conn, sanitize_opts(origins: "*", allow_methods: ~w(patch)))

      opts = sanitize_opts(origins: "*", allow_methods: ~w(PATCH), allow_headers: ~w(X-Foo))
      assert allowed_preflight?(conn, opts)

      # "Simple methods" are always allowed.
      conn = put_req_header(conn, "access-control-request-method", "POST")
      assert allowed_preflight?(conn, sanitize_opts(origins: "*", allow_methods: ~w()))

      # When :allow_methods is :all all methods are allowed.
      conn = put_req_header(conn, "access-control-request-method", "WEIRDMETHOD")
      assert allowed_preflight?(conn, sanitize_opts(origins: "*", allow_methods: :all))
    end

    test "with allowed requests (headers)" do
      conn = put_origin(conn(:get, "/"), "http://foo.com")

      conn =
        conn
        |> put_req_header("access-control-request-method", "PUT")
        |> put_req_header("access-control-request-headers", "X-Foo, X-Bar")

      opts = sanitize_opts(origins: "*", allow_methods: ~w(PUT), allow_headers: ~w(X-Bar x-foo))
      assert allowed_preflight?(conn, opts)

      # "Simple headers" are always allowed.
      conn =
        conn
        |> put_req_header("access-control-request-method", "PUT")
        |> put_req_header("access-control-request-headers", "Accept, Content-Language")

      assert allowed_preflight?(
               conn,
               sanitize_opts(origins: "*", allow_methods: ~w(PUT), allow_headers: ~w())
             )

      # When :allow_headers is :all all headers are allowed.
      conn =
        conn
        |> put_req_header("access-control-request-method", "PUT")
        |> put_req_header("access-control-request-headers", "X-Header, X-Other-Header")

      assert allowed_preflight?(
               conn,
               sanitize_opts(origins: "*", allow_methods: ~w(PUT), allow_headers: :all)
             )
    end

    test "with non-allowed requests" do
      conn =
        conn(:get, "/")
        |> put_origin("http://foo.com")
        |> put_req_header("access-control-request-method", "OPTIONS")

      refute allowed_preflight?(conn, sanitize_opts(origins: "*", allow_methods: ~w(PUT PATCH)))
      refute allowed_preflight?(conn, sanitize_opts(origins: "*", allow_methods: ~w(put)))

      opts = sanitize_opts(origins: "*", allow_methods: ~w(PUT), allow_headers: ~w(X-Foo))
      refute allowed_preflight?(conn, opts)

      conn = conn |> put_req_header("access-control-request-headers", "X-Foo, X-Bar")

      opts = sanitize_opts(origins: "*", allow_methods: ~w(OPTIONS), allow_headers: ~w(X-Bar))
      refute allowed_preflight?(conn, opts)

      opts = sanitize_opts(origins: "*", allow_methods: ~w(OPTIONS), allow_headers: ~w(x-bar))
      refute allowed_preflight?(conn, opts)
    end
  end

  describe "put_cors_simple_resp_headers/2" do
    test "access-control-allow-origin" do
      conn =
        conn(:get, "/")
        |> put_origin("http://foo.bar")
        |> put_cors_simple_resp_headers(origins: "*")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-expose-headers") == []

      conn = conn(:get, "/") |> put_cors_simple_resp_headers(origins: "*")
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "access-control-allow-credentials" do
      conn =
        conn(:get, "/foo")
        |> put_origin("http://foo.bar")
        |> put_cors_simple_resp_headers(allow_credentials: true, origins: "*")

      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["http://foo.bar"]
      assert get_resp_header(conn, "access-control-expose-headers") == []

      conn =
        conn(:get, "/foo")
        |> put_origin("http://foo.bar")
        |> put_cors_simple_resp_headers(allow_credentials: false, origins: "*")

      assert get_resp_header(conn, "access-control-allow-credentials") == []
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-expose-headers") == []
    end

    test "access-control-expose-headers" do
      conn =
        conn(:get, "/foo")
        |> put_origin("http://foo.bar")
        |> put_cors_simple_resp_headers(expose_headers: ~w(X-Foo X-Bar), origins: "*")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-expose-headers") == ["X-Foo,X-Bar"]
    end

    test "\"origin\" is added to the \"vary\" header" do
      conn = conn(:get, "/foo") |> put_origin("http://foo.com")

      new_conn = put_cors_simple_resp_headers(conn, origins: "*")
      assert get_resp_header(new_conn, "vary") == []

      new_conn = put_cors_simple_resp_headers(conn, origins: "http://foo.com")
      assert get_resp_header(new_conn, "vary") == []

      new_conn = put_cors_simple_resp_headers(conn, origins: ["http://foo.com"])
      assert get_resp_header(new_conn, "vary") == []

      new_conn = put_cors_simple_resp_headers(conn, allow_credentials: true, origins: "*")
      assert get_resp_header(new_conn, "vary") == ["origin"]

      new_conn = put_cors_simple_resp_headers(conn, origins: ["http://foo.com", "http://bar.com"])
      assert get_resp_header(new_conn, "vary") == ["origin"]

      new_conn = put_cors_simple_resp_headers(conn, origins: ~r/.*/)
      assert get_resp_header(new_conn, "vary") == ["origin"]

      new_conn =
        conn
        |> put_resp_header("vary", "content-length")
        |> put_cors_simple_resp_headers(origins: ["http://foo.com", "http://bar.com"])

      assert get_resp_header(new_conn, "vary") == ["origin", "content-length"]
    end

    test "telemetry events" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:corsica, :accepted_request],
          [:corsica, :rejected_request],
          [:corsica, :invalid_request]
        ])

      conn = conn(:get, "/") |> put_origin("http://example.com")

      put_cors_simple_resp_headers(conn, origins: "*")
      assert_receive {[:corsica, :accepted_request], ^ref, measurements, meta}
      assert measurements == %{}
      assert meta.request_type == :simple
      assert %Plug.Conn{} = meta.conn

      put_cors_simple_resp_headers(conn, origins: ["http://foo.com"])
      assert_receive {[:corsica, :rejected_request], ^ref, measurements, meta}
      assert measurements == %{}
      assert meta.request_type == :simple
      assert %Plug.Conn{} = meta.conn

      put_cors_simple_resp_headers(conn(:get, "/"), origins: "*")
      assert_receive {[:corsica, :invalid_request], ^ref, measurements, meta}
      assert measurements == %{}
      assert meta.request_type == :simple
      assert %Plug.Conn{} = meta.conn
    end

    test "does nothing to non-CORS requests" do
      conn = conn(:get, "/")
      assert conn == put_cors_simple_resp_headers(conn, origins: "*")
    end

    test "puts headers to non-CORS requests if :passthrough_non_cors_requests is true" do
      conn =
        conn(:options, "/")
        |> put_cors_simple_resp_headers(origins: "*", passthrough_non_cors_requests: true)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "put_cors_preflight_resp_headers/2" do
    test "access-control-allow-methods" do
      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> put_cors_preflight_resp_headers(allow_methods: ~w(GET PUT), origins: "*")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET,PUT"]
      assert get_resp_header(conn, "access-control-allow-headers") == [""]
      assert get_resp_header(conn, "access-control-max-age") == []

      # :allow_methods set to :all.
      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> put_cors_preflight_resp_headers(allow_methods: :all, origins: "*")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["PUT"]
      assert get_resp_header(conn, "access-control-allow-headers") == [""]
      assert get_resp_header(conn, "access-control-max-age") == []
    end

    test "access-control-allow-headers" do
      opts = [allow_methods: ~w(PUT), allow_headers: ~w(X-Foo X-Bar), origins: "*"]

      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> put_cors_preflight_resp_headers(opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["PUT"]
      assert get_resp_header(conn, "access-control-allow-headers") == ["x-foo,x-bar"]
      assert get_resp_header(conn, "access-control-max-age") == []

      # :allow_headers set to :all.
      opts = [allow_methods: ~w(PUT), allow_headers: :all, origins: "*"]

      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> put_req_header("access-control-request-headers", "X-Header, X-Other-Header")
        |> put_cors_preflight_resp_headers(opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["PUT"]
      assert get_resp_header(conn, "access-control-allow-headers") == ["x-header,x-other-header"]
      assert get_resp_header(conn, "access-control-max-age") == []
    end

    test "access-control-allow-private-network" do
      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> put_cors_preflight_resp_headers(origins: "*")

      assert get_resp_header(conn, "access-control-allow-private-network") == []

      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> put_cors_preflight_resp_headers(allow_private_network: true, origins: "*")

      assert get_resp_header(conn, "access-control-allow-private-network") == ["true"]
    end

    test "access-control-max-age" do
      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> put_cors_preflight_resp_headers(max_age: 400, origins: "*")

      assert get_resp_header(conn, "access-control-max-age") == ["400"]
    end

    test "does nothing to non-CORS requests" do
      conn = conn(:options, "/")
      assert conn == put_cors_preflight_resp_headers(conn, origins: "*", max_age: 1)
    end

    test "puts headers to non-CORS requests if :passthrough_non_cors_requests is true" do
      conn =
        conn(:options, "/")
        |> put_cors_preflight_resp_headers(
          origins: "*",
          max_age: 1,
          passthrough_non_cors_requests: true
        )

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-max-age") == ["1"]
    end

    test "telemetry events" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:corsica, :accepted_request],
          [:corsica, :rejected_request],
          [:corsica, :invalid_request]
        ])

      conn(:options, "/")
      |> put_origin("http://example.com")
      |> put_req_header("access-control-request-method", "PUT")
      |> put_cors_preflight_resp_headers(origins: "*")

      assert_receive {[:corsica, :accepted_request], ^ref, measurements, metadata}
      assert measurements == %{}
      assert metadata.request_type == :preflight
      assert %Plug.Conn{} = metadata.conn

      conn(:options, "/")
      |> put_origin("http://example.com")
      |> put_req_header("access-control-request-method", "PUT")
      |> put_cors_preflight_resp_headers(allow_methods: ["GET"], origins: "*")

      assert_receive {[:corsica, :rejected_request], ^ref, measurements, metadata}
      assert measurements == %{}
      assert metadata.request_type == :preflight
      assert %Plug.Conn{} = metadata.conn
      assert metadata.reason == {:req_method_not_allowed, "PUT"}

      conn(:options, "/")
      |> put_origin("http://example.com")
      |> put_req_header("access-control-request-method", "PUT")
      |> put_req_header("access-control-request-headers", "x-foo, x-bar")
      |> put_cors_preflight_resp_headers(allow_headers: ["x-nope"], origins: "*")

      assert_receive {[:corsica, :rejected_request], ^ref, measurements, metadata}
      assert measurements == %{}
      assert metadata.request_type == :preflight
      assert %Plug.Conn{} = metadata.conn
      assert metadata.reason == {:req_headers_not_allowed, ["x-foo", "x-bar"]}

      conn(:options, "/")
      |> put_origin("http://example.com")
      |> put_req_header("access-control-request-method", "PUT")
      |> put_cors_preflight_resp_headers(origins: ["http://foo.com"])

      assert_receive {[:corsica, :rejected_request], ^ref, measurements, metadata}
      assert measurements == %{}
      assert metadata.request_type == :preflight
      assert %Plug.Conn{} = metadata.conn
      assert metadata.reason == :origin_not_allowed

      conn(:options, "/")
      |> put_cors_preflight_resp_headers(origins: "*")

      assert_receive {[:corsica, :invalid_request], ^ref, measurements, metadata}
      assert measurements == %{}
      assert metadata.request_type == :preflight
      assert %Plug.Conn{} = metadata.conn
    end
  end

  describe "send_preflight_resp/4" do
    test "with valid preflight request" do
      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> send_preflight_resp(allow_methods: ~w(PUT), origins: "*")

      assert conn.state == :sent
      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["PUT"]
    end

    test "with invalid preflight request" do
      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> send_preflight_resp(400, origins: "*", allow_methods: ~w(GET POST))

      assert conn.state == :sent
      assert conn.status == 400
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-methods") == []
    end
  end

  describe "using Corsica as a plug" do
    setup do
      plugs = [
        {Corsica, allow_methods: ~w(PUT), origins: "*"},
        &send_resp(&1, 200, "matched")
      ]

      %{plugs: plugs}
    end

    test "with simple requests", %{plugs: plugs} do
      conn =
        conn(:get, "/")
        |> put_origin("http://example.com")
        |> Plug.run(plugs)

      assert conn.state == :sent
      assert conn.status == 200
      assert conn.resp_body == "matched"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      conn =
        conn(:get, "/")
        |> Plug.run(plugs)

      assert conn.state == :sent
      assert conn.status == 200
      assert conn.resp_body == "matched"
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "with preflight requests", %{plugs: plugs} do
      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PUT")
        |> Plug.run(plugs)

      assert conn.state == :sent
      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["PUT"]

      conn =
        conn(:options, "/")
        |> put_origin("http://example.com")
        |> put_req_header("access-control-request-method", "PATCH")
        |> Plug.run(plugs)

      assert conn.state == :sent
      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-methods") == []
    end

    test "with :passthrough_non_cors_requests set to true" do
      conn =
        conn(:get, "/")
        |> Plug.run([
          {Corsica, origins: "*", passthrough_non_cors_requests: true, allow_headers: ~w(X-Foo)},
          &send_resp(&1, 200, "matched")
        ])

      # The whole point is that this is not even a valid CORS request.
      assert get_req_header(conn, "origin") == []

      assert conn.state == :sent
      assert conn.status == 200
      assert conn.resp_body == "matched"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["PUT,PATCH,DELETE"]
      assert get_resp_header(conn, "access-control-allow-headers") == ["x-foo"]
    end
  end

  defp put_origin(conn, origin), do: put_req_header(conn, "origin", origin)
end
